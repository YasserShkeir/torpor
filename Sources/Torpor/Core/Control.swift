import AppKit
import Darwin
import Foundation

/// Freezing, thawing, hibernating and reviving sessions.
///
/// A note on what each tier actually buys you, measured rather than assumed:
///
/// * **Freeze (SIGSTOP)** stops CPU immediately. It frees almost no memory.
///   macOS has already compressed roughly 90% of an idle session's footprint,
///   and nothing in the kernel's page-reclaim path consults task state, so a
///   stopped process's pages age out exactly as an untouched running process's
///   do. On a machine with eight idle sessions, a perfect freeze reclaimed
///   ~344 MB against 2.8 GB of committed footprint. Freeze is a CPU control and
///   a guard against the idle GC runaway — not a memory control.
///
/// * **Hibernate (terminate + revive)** frees the entire footprint, including
///   the compressed pages sitting in swap. That is where the memory is.
///
/// Torpor presents both honestly rather than marketing freeze as a memory tier.
enum SessionControl {

    enum ControlError: LocalizedError {
        case signalFailed(pid: Int32, signal: Int32, errno: Int32)
        case noArguments(pid: Int32)
        case terminateTimedOut(pid: Int32)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case let .signalFailed(pid, sig, err):
                return "Signal \(sig) to pid \(pid) failed: \(String(cString: strerror(err)))"
            case let .noArguments(pid):
                return "Could not read the command line of pid \(pid); refusing to hibernate a session we cannot restore."
            case let .terminateTimedOut(pid):
                return "Session \(pid) did not exit after SIGTERM."
            case let .launchFailed(message):
                return "Could not launch the revived session: \(message)"
            }
        }
    }

    // MARK: - Freeze / thaw

    /// Stop a session and its whole subtree.
    ///
    /// Order matters. Children are stopped first so that a parent cannot spawn
    /// or reap work while its descendants are being suspended; on resume the
    /// order is inverted so the parent is scheduling again before its MCP
    /// servers start producing output.
    static func freeze(pid: Int32) throws {
        let tree = subtree(of: pid)
        // Best-effort on children: a process that exits mid-loop must not stop
        // us stopping the rest, or the tree is left half-frozen.
        for child in tree.reversed() { try? signal(child, SIGSTOP) }   // deepest first
        try signal(pid, SIGSTOP)
    }

    static func thaw(pid: Int32) throws {
        // Parent first so it is scheduling again before its MCP servers resume
        // producing output — but children are resumed regardless of what the
        // parent's signal did, because leaving them stopped is unrecoverable
        // from the UI once the parent is gone.
        defer { for child in subtree(of: pid) { try? signal(child, SIGCONT) } }
        try signal(pid, SIGCONT)
    }

    static func freeze(session: Session) throws { try freeze(pid: session.pid) }
    static func thaw(session: Session) throws { try thaw(pid: session.pid) }

    /// Whether a process is currently stopped (`SIDL`/`SSTOP` in the BSD info).
    static func isStopped(_ pid: Int32) -> Bool {
        guard let info = ProcProbe.bsdInfo(pid) else { return false }
        return info.pbi_status == UInt32(SSTOP)
    }

    private static func subtree(of root: Int32) -> [Int32] {
        let snapshots = ProcProbe.allPIDs().compactMap { ProcProbe.snapshot($0) }
        return ProcProbe.descendants(of: root, index: ProcProbe.childIndex(snapshots))
    }

    private static func signal(_ pid: Int32, _ sig: Int32) throws {
        guard pid > 1 else { return }
        if kill(pid, sig) != 0 {
            let err = errno
            // ESRCH just means it exited underneath us, which is benign.
            if err == ESRCH { return }
            throw ControlError.signalFailed(pid: pid, signal: sig, errno: err)
        }
    }

    // MARK: - Hibernate

    /// Capture everything needed to restore the session, then end it.
    ///
    /// We read argv *before* signalling, because once the process is gone the
    /// kernel no longer has its arguments and the session becomes unrestorable.
    /// If argv cannot be read we refuse rather than terminate something we
    /// cannot bring back.
    /// Capture argv and persist a restore record, without signalling anything.
    /// Split out so a batch can capture every session before terminating any of
    /// them — once a process is gone the kernel no longer has its arguments.
    static func prepare(session: Session, store: HibernationStore) throws -> HibernatedSession {
        guard let argv = ProcProbe.arguments(session.pid), let executable = argv.first else {
            throw ControlError.noArguments(pid: session.pid)
        }
        let record = HibernatedSession(
            sessionId: session.sessionId,
            cwd: session.cwd,
            name: session.name,
            executable: executable,
            arguments: Array(argv.dropFirst()),
            hibernatedAt: Date(),
            reclaimedBytes: session.totalFootprint,
            version: session.version,
            entrypoint: session.entrypoint,
            tty: ProcProbe.tty(session.pid)
        )
        // Persist before signalling: a crash between the two should leave a
        // recoverable record, not an orphaned session we've forgotten.
        store.add(record)
        return record
    }

    /// Hibernate several sessions at once.
    ///
    /// Terminates them concurrently and waits once, rather than serialising a
    /// six-second grace period per session — hibernating a four-session project
    /// group otherwise takes half a minute with the UI wedged behind it.
    /// Async throughout so the wait yields the main actor instead of blocking it.
    @discardableResult
    static func hibernate(sessions: [Session], store: HibernationStore) async -> [HibernatedSession] {
        var prepared: [(Session, HibernatedSession, [Int32: Date])] = []

        for session in sessions {
            guard let record = try? prepare(session: session, store: store) else { continue }
            var descendants: [Int32: Date] = [:]
            for child in subtree(of: session.pid) {
                if let snap = ProcProbe.snapshot(child) { descendants[child] = snap.startTime }
            }
            prepared.append((session, record, descendants))
        }
        guard !prepared.isEmpty else { return [] }

        // Identity captured before signalling, so every later liveness check
        // compares against the process we actually targeted.
        var identities: [Int32: Date] = [:]
        for (session, _, _) in prepared {
            identities[session.pid] = ProcProbe.snapshot(session.pid)?.startTime ?? session.startedAt
        }
        let targets = prepared.map { (pid: $0.0.pid, startedAt: identities[$0.0.pid] ?? Date()) }

        for (session, _, _) in prepared {
            if isStopped(session.pid) { try? thaw(session: session) }
            try? signal(session.pid, SIGTERM)
        }

        await waitForExit(targets, timeout: 6)

        for target in targets where isStillSameProcess(pid: target.pid, startedAt: target.startedAt) {
            try? signal(target.pid, SIGKILL)
        }
        await waitForExit(targets, timeout: 3)

        // Report only what actually died, and roll back the record for anything
        // that survived — otherwise a session appears in the live list and the
        // Hibernated list at once, with a Revive button that would start a
        // second process against the same transcript.
        var succeeded: [HibernatedSession] = []
        for (index, (session, record, descendants)) in prepared.enumerated() {
            let target = targets[index]
            if isStillSameProcess(pid: target.pid, startedAt: target.startedAt) {
                store.remove(sessionId: session.sessionId)
                continue
            }
            reapOrphans(ourDescendants: descendants)
            succeeded.append(record)
        }
        return succeeded
    }

    /// True only if this pid still holds *the same* process we started with.
    ///
    /// `ProcProbe.isAlive` answers "does some process hold this number", which
    /// is a different question: PIDs recycle (measured at ~36-40/s on a busy
    /// machine, so the full range wraps in well under an hour), and a zombie
    /// still answers yes. Both would make us stop waiting — or escalate to
    /// SIGKILL — against whatever inherited the number.
    static func isStillSameProcess(pid: Int32, startedAt: Date) -> Bool {
        guard let snap = ProcProbe.snapshot(pid) else { return false }
        guard let info = ProcProbe.bsdInfo(pid), info.pbi_status != UInt32(SZOMB) else {
            return false
        }
        return abs(snap.startTime.timeIntervalSince(startedAt)) < 1
    }

    private static func waitForExit(_ targets: [(pid: Int32, startedAt: Date)],
                                    timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if targets.allSatisfy({ !isStillSameProcess(pid: $0.pid, startedAt: $0.startedAt) }) {
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    @discardableResult
    static func hibernate(session: Session, store: HibernationStore) throws -> HibernatedSession {
        guard let argv = ProcProbe.arguments(session.pid), let executable = argv.first else {
            throw ControlError.noArguments(pid: session.pid)
        }

        // Record this session's own descendants before we signal, so cleanup
        // afterwards can be scoped to exactly the processes we orphaned. Doing
        // it the other way round — scanning for reparented helpers globally —
        // risks killing an unrelated session's MCP server.
        // Keyed by start time as well as PID: between the parent dying and the
        // cleanup scan, the kernel could recycle a PID onto a new process.
        var ownDescendants: [Int32: Date] = [:]
        for child in subtree(of: session.pid) {
            if let snap = ProcProbe.snapshot(child) { ownDescendants[child] = snap.startTime }
        }

        let record = HibernatedSession(
            sessionId: session.sessionId,
            cwd: session.cwd,
            name: session.name,
            executable: executable,
            arguments: Array(argv.dropFirst()),
            hibernatedAt: Date(),
            reclaimedBytes: session.totalFootprint,
            version: session.version,
            entrypoint: session.entrypoint,
            tty: ProcProbe.tty(session.pid)
        )
        // Persist before signalling: a crash between the two should leave a
        // recoverable record, not an orphaned session we've forgotten.
        store.add(record)

        // A frozen process will not act on SIGTERM, so wake it first.
        if isStopped(session.pid) { try? thaw(session: session) }

        try signal(session.pid, SIGTERM)

        // Give Claude Code a moment to flush its transcript and shut its MCP
        // children down cleanly. Only escalate if it refuses.
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if !ProcProbe.isAlive(session.pid) { break }
            usleep(150_000)
        }

        if ProcProbe.isAlive(session.pid) {
            try signal(session.pid, SIGKILL)
            let hardDeadline = Date().addingTimeInterval(3)
            while Date() < hardDeadline, ProcProbe.isAlive(session.pid) {
                usleep(150_000)
            }
            if ProcProbe.isAlive(session.pid) {
                throw ControlError.terminateTimedOut(pid: session.pid)
            }
        }

        // MCP servers are children of the session and normally exit with it.
        // Anything from *this* session still standing is an orphan we made.
        reapOrphans(ourDescendants: ownDescendants)

        return record
    }

    /// Terminate the session's own descendants if they outlived it.
    ///
    /// Scoped deliberately: only PIDs we recorded as belonging to this session
    /// before it died, and only if they have since been reparented to launchd
    /// (ppid == 1), which is what "orphaned" actually means. A helper that
    /// still has a live parent belongs to someone else and is left alone.
    private static func reapOrphans(ourDescendants: [Int32: Date]) {
        for (pid, startedAt) in ourDescendants {
            guard let snap = ProcProbe.snapshot(pid) else { continue }  // already gone
            // Same PID *and* same start time, or it is a different process.
            guard abs(snap.startTime.timeIntervalSince(startedAt)) < 1 else { continue }
            guard snap.ppid == 1 else { continue }
            _ = try? signal(pid, SIGTERM)
        }
    }

    // MARK: - Revive

    /// Bring a hibernated session back in a fresh terminal window.
    ///
    /// The user never types `--resume` or hunts for a session id: Torpor opens
    /// the terminal at the original working directory and replays the original
    /// flags alongside the resume.
    /// How a revive actually landed, so the UI can say what happened rather
    /// than implying the session came back where it left.
    enum ReviveOutcome {
        case originalTab(app: String)
        case newWindow(app: String)
    }

    /// Bundle identifiers of terminals that expose a per-tab `tty` in their
    /// scripting dictionary. VS Code's integrated terminal — where a great many
    /// Claude Code sessions actually live — has no such API and cannot be
    /// targeted from outside, so those sessions always get a new window.
    private static let scriptableTerminals: [(bundleID: String, name: String)] = [
        ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm"),
    ]

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Run `command` in whichever open tab owns `tty`, if one exists.
    ///
    /// This is the point of capturing the tty at hibernate time: killing the
    /// `claude` process leaves its parent shell alive, so the tab is still
    /// open, still in the right directory, sitting at a prompt. Reopening
    /// there restores the window layout the user already had.
    private static func reviveInOriginalTab(command: String, tty: String) -> String? {
        let escaped = appleScriptEscape(command)
        let ttyLiteral = appleScriptEscape(tty)

        for terminal in scriptableTerminals where isRunning(terminal.bundleID) {
            let script: String
            switch terminal.bundleID {
            case "com.apple.Terminal":
                script = """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            try
                                if (tty of t) is "\(ttyLiteral)" then
                                    do script "\(escaped)" in t
                                    set selected of t to true
                                    set index of w to 1
                                    activate
                                    return "ok"
                                end if
                            end try
                        end repeat
                    end repeat
                end tell
                return "no"
                """
            default:
                script = """
                tell application "iTerm"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                try
                                    if (tty of s) is "\(ttyLiteral)" then
                                        tell s to write text "\(escaped)"
                                        select t
                                        select w
                                        activate
                                        return "ok"
                                    end if
                                end try
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "no"
                """
            }

            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error == nil, result?.stringValue == "ok" { return terminal.name }
        }
        return nil
    }

    @discardableResult
    static func revive(_ record: HibernatedSession,
                       terminal: String,
                       store: HibernationStore) throws -> ReviveOutcome {
        let command = "cd \(shellQuote(record.cwd)) && clear && \(record.resumeCommand)"

        // Prefer the tab the session died in. Only its own shell may still be
        // sitting on that tty, so a match is unambiguous.
        if let tty = record.tty, let app = reviveInOriginalTab(command: command, tty: tty) {
            store.markReviving(sessionId: record.sessionId)
            return .originalTab(app: app)
        }
        try launch(command: command, terminal: terminal)
        // Deliberately NOT removed here. `launch` only knows the Apple event was
        // accepted; it cannot see whether the shell found `claude`, whether the
        // directory still exists, or whether the transcript was pruned. Dropping
        // the record now would destroy the only copy of the captured argv on a
        // revive that printed "command not found". Engine clears it once a live
        // session with this id appears in the registry.
        store.markReviving(sessionId: record.sessionId)
        return .newWindow(app: terminal)
    }

    /// AppleScript string-literal escaping. Applied *after* shell quoting —
    /// the order matters, and reversing it breaks on a directory containing a
    /// quote.
    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func launch(command: String, terminal: String) throws {
        let escaped = appleScriptEscape(command)

        let script: String
        switch terminal.lowercased() {
        case "iterm", "iterm2":
            script = """
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(escaped)"
                end tell
            end tell
            """
        default:
            script = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
        }

        var error: NSDictionary?
        guard let apple = NSAppleScript(source: script) else {
            throw ControlError.launchFailed("could not compile the launch script")
        }
        apple.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            throw ControlError.launchFailed(message)
        }
    }
}
