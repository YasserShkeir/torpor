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

    // MARK: - Argument vector capture

    /// A process's captured command line.
    struct Arguments {
        /// The path the kernel actually exec'd. Always absolute and always the
        /// real binary — argv[0] is whatever the parent chose to pass, commonly
        /// a bare `claude` that the restore command would have to re-resolve
        /// off whatever PATH the pasting shell happens to have after cd-ing
        /// into the project.
        var executablePath: String
        var argv: [String]
    }

    /// Full argv of a running process via `KERN_PROCARGS2`, with the exec path.
    ///
    /// This is what makes the restore command faithful. `claude --resume` is
    /// documented as lossy — it drops `--mcp-config`, `--settings`,
    /// `--plugin-dir`, `--add-dir` and `--model`. Capturing argv before we
    /// terminate a session lets us put those flags back into the line the user
    /// pastes, so the restored session is configured exactly as the original
    /// was.
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

        // Read the exec path rather than discarding it: the restore command
        // needs a path that runs without asking a fresh shell's PATH what
        // `claude` means.
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
        // put on the clipboard. Callers treat nil as "cannot restore this
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
