import AppKit
import Darwin
import Foundation

/// Low-level process inspection built on libproc and sysctl.
///
/// The important design decision here is that memory is reported as
/// `phys_footprint`, not RSS. On Apple Silicon, macOS compresses cold pages
/// aggressively and RSS excludes them entirely: an idle Claude Code session
/// measured 24 MB RSS against 319 MB footprint. RSS-based tools understate
/// idle sessions by more than an order of magnitude, which is precisely the
/// case this app exists to surface.
enum ProcProbe {

    struct Snapshot {
        var pid: Int32
        var ppid: Int32
        /// Total memory charged to the process, including compressed pages.
        var footprint: UInt64
        /// Pages still occupying physical RAM. Freezing can only ever reclaim
        /// this much; hibernating reclaims the whole footprint.
        var resident: UInt64
        var startTime: Date

        /// NOTE: `footprint - resident` is *not* a valid compressed-bytes
        /// identity and was removed. The two counters have different accounting
        /// bases — footprint excludes clean file-backed and shared pages that
        /// RSS includes — so the difference was measured up to 56% wrong, and
        /// 27% of processes have `resident >= footprint`, clamping to a flat 0.
        /// A true figure needs `task_info(TASK_VM_INFO)`, which requires a
        /// task-port entitlement Torpor cannot obtain. Report footprint only:
        /// it is correct, stable, and the figure hibernate actually frees.
    }

    // MARK: - Enumeration

    /// All PIDs visible to the current user.
    static func allPIDs() -> [Int32] {
        var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        // Pad generously: the process table can grow between the sizing call
        // and the fetch, and a short read silently truncates the tail.
        let capacity = Int(count) / MemoryLayout<Int32>.size + 64
        var buffer = [Int32](repeating: 0, count: capacity)
        count = buffer.withUnsafeMutableBufferPointer { ptr in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, ptr.baseAddress,
                          Int32(capacity * MemoryLayout<Int32>.size))
        }
        guard count > 0 else { return [] }
        let n = Int(count) / MemoryLayout<Int32>.size
        return buffer.prefix(n).filter { $0 > 0 }
    }

    // MARK: - Per-process detail

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        return rc == size ? info : nil
    }

    /// `phys_footprint` and friends via `proc_pid_rusage`.
    static func rusage(_ pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? info : nil
    }

    static func snapshot(_ pid: Int32) -> Snapshot? {
        guard let bsd = bsdInfo(pid) else { return nil }
        guard let ru = rusage(pid) else { return nil }

        return Snapshot(
            pid: pid,
            ppid: Int32(bitPattern: bsd.pbi_ppid),
            footprint: ru.ri_phys_footprint,
            resident: ru.ri_resident_size,
            startTime: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec))
        )
    }

    /// Controlling terminal, e.g. `/dev/ttys016`, or nil when the process has
    /// none. This is the handle that lets revive find the exact tab a session
    /// was running in: the shell that launched it survives the hibernate and
    /// stays sitting at a prompt on the same tty.
    static func tty(_ pid: Int32) -> String? {
        guard let info = bsdInfo(pid) else { return nil }
        // e_tdev is UInt32 here; NODEV is all-ones and means "no controlling
        // terminal" — a VS Code-hosted session, or anything under launchd.
        guard info.e_tdev != UInt32.max, info.e_tdev != 0 else { return nil }
        let device = dev_t(bitPattern: info.e_tdev)
        guard let name = devname(device, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// Display names for the terminals worth naming, keyed by bundle id.
    ///
    /// `localizedName` alone is not good enough for the case this exists to
    /// describe: VS Code's is the bare "Code", which reads as a compiler in a
    /// sentence about where a session used to live. Anything absent from this
    /// table still gets named, just with whatever the app calls itself.
    private static let hostNames: [String: String] = [
        "com.apple.Terminal": "Terminal",
        // Matches the AppleScript target in SessionControl.scriptableTerminals.
        // The app calls itself "iTerm2"; `tell application "iTerm"` is what
        // actually drives it, and the two must agree or a scriptable host
        // would be reported as unreachable.
        "com.googlecode.iterm2": "iTerm",
        "com.microsoft.VSCode": "VS Code",
        "com.microsoft.VSCodeInsiders": "VS Code Insiders",
        "com.visualstudio.code.oss": "VS Code OSS",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
        "dev.warp.Warp-Stable": "Warp",
        "com.mitchellh.ghostty": "Ghostty",
        "net.kovidgoyal.kitty": "kitty",
        "co.zeit.hyper": "Hyper",
        "org.alacritty": "Alacritty",
        "com.apple.dt.Xcode": "Xcode",
    ]

    /// The application whose terminal a process is running in, found by walking
    /// the parent chain until a real GUI app turns up.
    ///
    /// A tty alone does not answer this and cannot: every one of the machine's
    /// nine live sessions has a controlling terminal, and all nine of them are
    /// VS Code's, which has no scripting API for its integrated terminal.
    /// Revive needs to know that *before* it decides where to reopen, and the
    /// user needs to be told it rather than handed a new window as though
    /// nothing was lost.
    ///
    /// The walk skips helper processes on purpose. A VS Code session's chain is
    /// `claude -> zsh -> Code Helper -> Code`, and only the last of those is a
    /// registered application: Launch Services returns nil for the helper, and
    /// an Electron helper that *is* registered has called `TransformProcessType`
    /// on itself and reports `.prohibited`. Both are stepped over, so the answer
    /// is the app the user would name.
    ///
    /// Returns nil when there is no GUI ancestor at all — a session under tmux,
    /// a launchd agent, or an ssh login. That is a real answer and is reported
    /// as one, not folded into "some terminal we cannot script".
    static func hostApplication(of pid: Int32) -> String? {
        var current = pid
        // Bounded rather than `while`: PID reuse can leave a cycle in the
        // parent chain, which `descendants(of:index:)` guards against for the
        // same reason.
        for _ in 0..<32 {
            guard let info = bsdInfo(current) else { return nil }
            let parent = Int32(bitPattern: info.pbi_ppid)
            // 1 is launchd: past it there is nothing left to attribute to.
            guard parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent),
               app.activationPolicy != .prohibited {
                if let bundleID = app.bundleIdentifier, let name = hostNames[bundleID] {
                    return name
                }
                return app.localizedName
            }
            current = parent
        }
        return nil
    }

    /// The running application a recorded host name refers to, if it is still
    /// open. The inverse of the lookup `hostApplication(of:)` performs.
    ///
    /// Matched through `hostNames` first, because that is where most recorded
    /// names came from: VS Code's `localizedName` is the bare "Code", so a
    /// name-only match would never find the app we wrote down as "VS Code".
    /// The `localizedName` fallback covers hosts absent from that table, which
    /// is exactly how they were named in the first place.
    ///
    /// `.prohibited` processes are skipped for the same reason the parent walk
    /// skips them: an Electron helper is not the app the user would point at.
    static func runningApplication(named host: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            guard app.activationPolicy != .prohibited else { return false }
            if let bundleID = app.bundleIdentifier, let name = hostNames[bundleID] {
                return name == host
            }
            return app.localizedName == host
        }
    }

    // MARK: - Argument vector capture

    /// A process's captured command line.
    struct Arguments {
        /// The path the kernel actually exec'd. Always absolute and always the
        /// real binary — argv[0] is whatever the parent chose to pass, commonly
        /// a bare `claude` that revive would have to re-resolve off whatever
        /// PATH the new shell happens to have after cd-ing into the project.
        var executablePath: String
        var argv: [String]
    }

    /// Full argv of a running process via `KERN_PROCARGS2`, with the exec path.
    ///
    /// This is what makes revive faithful. `claude --resume` is documented as
    /// lossy — it drops `--mcp-config`, `--settings`, `--plugin-dir`,
    /// `--add-dir` and `--model`. Capturing argv before we terminate a session
    /// lets us replay those flags on the way back up, so a revived session is
    /// configured exactly as the original was.
    static func arguments(_ pid: Int32) -> Arguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        guard size > MemoryLayout<Int32>.size else { return nil }

        // Layout: argc (Int32), exec path (NUL-terminated), NUL padding,
        // then argc NUL-separated argv entries, then the environment.
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size

        // Read the exec path rather than discarding it: revive needs a path it
        // can run without asking a fresh shell's PATH what `claude` means.
        let pathStart = index
        while index < size, buffer[index] != 0 { index += 1 }
        let executablePath = String(decoding: buffer[pathStart..<index], as: UTF8.self)
        guard !executablePath.isEmpty else { return nil }
        // Then the run of NUL padding that follows it.
        while index < size, buffer[index] == 0 { index += 1 }

        var args: [String] = []
        var current = [UInt8]()
        while index < size, args.count < Int(argc) {
            let byte = buffer[index]
            if byte == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
            index += 1
        }
        // Refuse a short read rather than salvaging it. A truncated buffer
        // yields a plausible-but-wrong final argument (a clipped
        // `--mcp-config /path/to/conf`), which would then be persisted and
        // replayed on revive. Callers treat nil as "cannot restore this
        // session", which is the correct outcome.
        guard args.count == Int(argc) else { return nil }
        return Arguments(executablePath: executablePath, argv: args)
    }

    /// Working directory of a running process, via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.
    static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
        }
        guard rc == size else { return nil }
        var path = info.pvi_cdir.vip_path
        return withUnsafePointer(to: &path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// Whether any live process still holds this controlling terminal — i.e.
    /// whether the tab is still open with a shell sitting in it.
    ///
    /// Distinguishes "you closed that tab" from "that terminal cannot be
    /// scripted", which are different messages for the user.
    static func ttyIsLive(_ tty: String) -> Bool {
        for pid in allPIDs() where ProcProbe.tty(pid) == tty { return true }
        return false
    }

    // MARK: - Process tree

    /// Children of each PID, for the whole visible process table.
    static func childIndex(_ snapshots: [Snapshot]) -> [Int32: [Int32]] {
        var index: [Int32: [Int32]] = [:]
        for s in snapshots {
            index[s.ppid, default: []].append(s.pid)
        }
        return index
    }

    /// Every descendant of `root`, depth-first. Used both to total a session's
    /// true cost (its MCP servers are separate processes, ~150 MB per session
    /// on a typical setup) and to signal the tree in the correct order.
    static func descendants(of root: Int32, index: [Int32: [Int32]]) -> [Int32] {
        var out: [Int32] = []
        var stack = index[root] ?? []
        // A visited set, not just a counter: the process table can contain a
        // self-parent or a cycle after PID reuse, and without this the same pid
        // is emitted thousands of times — each occurrence then summed again
        // into the session's footprint.
        var visited: Set<Int32> = [root]
        while let pid = stack.popLast() {
            guard out.count < 10_000 else { break }
            guard visited.insert(pid).inserted else { continue }
            out.append(pid)
            if let kids = index[pid] { stack.append(contentsOf: kids) }
        }
        return out
    }
}
