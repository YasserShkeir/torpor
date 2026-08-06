import Foundation

enum Paths {
    static var claude: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    static var support: URL {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Torpor", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Space-free home for anything another program has to *execute*.
    ///
    /// `~/Library/Application Support` contains a space, and Claude Code runs
    /// the configured statusline command through a shell — an unquoted path
    /// splits at the space and the command fails silently on every render.
    /// Quoting it in settings.json would fix the shell case but break if the
    /// command is ever exec'd directly, so the executable lives here instead.
    static var scripts: URL {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".torpor", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var hibernationStore: URL { support.appendingPathComponent("hibernated.json") }
    static var frozenStore: URL { support.appendingPathComponent("frozen.json") }
    static var preferences: URL { support.appendingPathComponent("preferences.json") }
    static var statuslineShim: URL { scripts.appendingPathComponent("statusline-shim.sh") }
    /// Where the shim used to live, so an existing install can be migrated.
    static var legacyStatuslineShim: URL {
        support.appendingPathComponent("statusline-shim.sh")
    }
}

/// A session that Torpor terminated, and the one command that brings it back.
///
/// `arguments` is the point of the whole record. `claude --resume <id>` is
/// documented as lossy: it restores conversation history but drops
/// `--mcp-config`, `--settings`, `--plugin-dir`, `--add-dir` and `--model`.
/// Because Torpor captures the live argv before terminating, the line it hands
/// back carries those flags — making it strictly more faithful than the resume
/// the user would have typed by hand.
///
/// Fields are only ever *added* to this type. `tty` and `hostApplication` were
/// removed when reopening in place was dropped (see `SessionControl`), and a
/// `hibernated.json` written before that still holds both — the synthesized
/// decoder ignores keys the struct no longer declares, so those records keep
/// working. `RestoreCommandTests` pins it.
struct HibernatedSession: Codable, Identifiable, Hashable {
    var sessionId: String
    var cwd: String
    var name: String
    var executable: String
    /// The path the kernel actually exec'd, as opposed to argv[0], which is
    /// whatever the parent chose to pass — commonly a bare `claude`. Optional so
    /// records written before it was captured still decode.
    var executablePath: String?
    var arguments: [String]
    var hibernatedAt: Date
    /// Footprint reclaimed at the moment of hibernation, for honest reporting.
    var reclaimedBytes: UInt64
    var version: String
    /// Registry `entrypoint`: "cli", "claude-vscode", … Optional so records
    /// written by earlier versions still decode.
    var entrypoint: String?
    /// Effort level the session was running at, as Claude Code reported it to
    /// the statusline.
    ///
    /// Captured because `/effort` sets it mid-session, so it is not in argv and
    /// there is nothing for `replayable(from:)` to find. Stored raw and
    /// validated at replay time — see `replayableEffort` — so a level a future
    /// CLI adds is kept on disk rather than discarded at capture.
    var effort: String?

    var id: String { sessionId }

    /// Which binary the restore command should actually run.
    ///
    /// A session hosted by VS Code or the desktop app is not the CLI: it is a
    /// harness-specific binary that expects stream-json plumbing on stdin and
    /// stdout. Relaunching *that* in a terminal produces a process that reads
    /// JSON from the keyboard. For any non-CLI entrypoint the line names the
    /// ordinary `claude` on PATH instead, which is what the user actually wants
    /// when they paste it into a terminal.
    var restoreExecutable: String {
        let hostedPaths = ["/.vscode/extensions/", "/Claude.app/", "/claude.app/"]
        let candidates = [executable, executablePath ?? ""]
        let isHosted = hostedPaths.contains { marker in candidates.contains { $0.contains(marker) } }
        if isHosted || (entrypoint != nil && entrypoint != "cli") { return "claude" }
        // argv[0] is usually the bare name, which leaves the command depending
        // on whatever PATH the pasting shell has after cd-ing into the project.
        // The kernel's exec path is absolute, so prefer it — but only if it
        // still exists now: it is typically ~/.local/bin/claude, an
        // installer-owned symlink that moves on every Claude Code update, and a
        // record kept for a fortnight would otherwise run a path that is gone
        // where a bare `claude` would still have resolved. The name check keeps
        // the shim case honest: a node-hosted install execs `node` with the CLI
        // as argv[1], and `node --resume` is not a command.
        if let path = executablePath,
           URL(fileURLWithPath: path).lastPathComponent
               == URL(fileURLWithPath: executable).lastPathComponent,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return executable
    }

    /// Effort levels `claude --effort` accepts. Anything else is dropped rather
    /// than passed through.
    ///
    /// Not because the CLI would reject it — measured on 2.1.x, `claude
    /// --effort ultra` prints "Unknown --effort value 'ultra' — ignoring it"
    /// and carries on at the default. The reason is `resumeCommand`: the level
    /// is the one part of that line assembled from a file Torpor does not own,
    /// and it is appended *unquoted*. Membership of this set is what keeps it a
    /// bare word. Widen it to a pass-through and `"high; rm -rf ~"` from a
    /// malformed statusline payload becomes a shell command.
    static let effortLevels: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    /// The captured effort level, if it is safe to put on the command line.
    ///
    /// Nil when nothing was captured, when the level is not one the CLI
    /// accepts, or when argv already carries `--effort` — that one was typed by
    /// the user and wins, and emitting a second occurrence would leave the CLI
    /// to pick between them.
    var replayableEffort: String? {
        guard let effort else { return nil }
        let level = effort.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.effortLevels.contains(level) else { return nil }
        guard !replayableFlags().contains(where: {
            $0 == "--effort" || $0.hasPrefix("--effort=")
        }) else { return nil }
        return level
    }

    /// The command the user pastes. Flags that `--resume` would otherwise drop
    /// are re-applied; flags that describe the old invocation's I/O plumbing
    /// are not, because the restored session runs in a fresh terminal.
    var resumeCommand: String {
        var parts = [shellQuote(restoreExecutable), "--resume", shellQuote(sessionId)]
        parts.append(contentsOf: replayableFlags().map(shellQuote))
        // Appended rather than merged into the allowlist: `/effort` sets this
        // mid-session, so it was never in argv and `replayable(from:)` has
        // nothing to carry. Quoted like every other part of this line even
        // though `effortLevels` guarantees a bare word — the guarantee lives in
        // a different function, and a line that quotes some of its arguments
        // and not others invites the next widening of that set to be unsafe.
        if let level = replayableEffort {
            parts.append(contentsOf: ["--effort", shellQuote(level)])
        }
        return parts.joined(separator: " ")
    }

    /// The whole line, `cd` included: one string a user can paste into any
    /// shell and press Return. This is the only way a hibernated session comes
    /// back, so it is the only string that has to be right.
    ///
    /// Deliberately no `clear`. An earlier version inserted one, to hide the
    /// dead session's scrollback when Torpor reopened *in the session's own
    /// tab*; nothing reopens anything now, and wiping the scrollback of a tab
    /// the user chose to paste into — possibly the one they were reading — was
    /// never ours to do.
    var resumeCommandLine: String { "cd \(shellQuote(cwd)) && \(resumeCommand)" }

    /// Flags worth carrying across a hibernate/restore cycle, and the flags we
    /// could not carry faithfully.
    ///
    /// Deliberately an allowlist. The captured argv of a real session contains
    /// a great deal that must not be replayed — stream plumbing
    /// (`--output-format`, `--input-format`, `--replay-user-messages`),
    /// one-shot flags, and permission grants scoped to the old process.
    /// Replaying those would produce a session that behaves nothing like an
    /// interactive one.
    ///
    /// Static and taking the argv explicitly so hibernate can apply it *before*
    /// building the record. What reaches disk is then only the allowlist below:
    /// a captured prompt, permission grants and stream plumbing are never
    /// written at all, not merely ignored on the way back up.
    ///
    /// `refused` names the *flags* we dropped a value from — never the values,
    /// which are the secret. A non-empty `refused` means the record would be a
    /// partial copy of the invocation, and capture refuses rather than reviving
    /// a session quietly missing half its configuration.
    static func replayable(from arguments: [String]) -> (flags: [String], refused: [String]) {
        let valueFlags: Set<String> = [
            "--model", "--settings", "--mcp-config", "--add-dir",
            "--plugin-dir", "--setting-sources",
            "--agent", "--effort", "--fallback-model", "--name",
            // Same reasoning as --dangerously-skip-permissions below: it
            // describes how the session the user is restoring actually ran, and
            // they read the line before running it.
            "--permission-mode",
        ]
        // Only these accept several space-separated values. Consuming the run
        // greedily for every value flag would swallow a positional prompt —
        // `claude --model opus "fix the parser"` — as if it were a second model.
        let multiValueFlags: Set<String> = ["--add-dir", "--mcp-config"]
        // `--dangerously-skip-permissions` is here, and it was deliberately not
        // here until Torpor stopped launching anything.
        //
        // The old reason was sound for the old design: revive opened a Terminal
        // tab and ran the line itself, so replaying this flag would have started
        // an agent with every prompt disabled, days after the decision, in a
        // window the user did not type into. Nothing about that is true now.
        // Restoring a session is a command on the clipboard: the user reads it
        // (it is in the row's tooltip verbatim), picks the terminal, and presses
        // Return. Torpor executes nothing.
        //
        // What the exclusion bought instead was a command that quietly does not
        // restore the session it claims to. That is the exact failure this
        // allowlist refuses everywhere else — see the all-or-nothing rule on
        // `--add-dir` below, and the refusal to hibernate at all rather than
        // drop an inline `--mcp-config`. A user who ran in auto mode and pastes
        // a line that silently is not auto mode has been handed a worse answer
        // than either.
        //
        // If a future version ever executes the command on the user's behalf
        // again, this belongs back on the excluded list and the test that
        // guards it has to flip with it.
        let boolFlags: Set<String> = ["--no-chrome", "--dangerously-skip-permissions"]

        // `--settings`, `--mcp-config` and `--agent` accept inline JSON as well
        // as a path, and an inline MCP definition routinely carries an `env`
        // block with GITHUB_TOKEN, database URLs or an API key. A path is fine;
        // a JSON blob is not written to disk at all.
        func isInlineJSON(_ value: String) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        }

        var out: [String] = []
        var refused: [String] = []
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            // Support both "--flag value" and "--flag=value".
            if let eq = arg.firstIndex(of: "="), valueFlags.contains(String(arg[arg.startIndex..<eq])) {
                let value = String(arg[arg.index(after: eq)...])
                if isInlineJSON(value) { refused.append(String(arg[arg.startIndex..<eq])) }
                else { out.append(arg) }
                index += 1
                continue
            }
            if valueFlags.contains(arg) {
                var values: [String] = []
                var next = index + 1
                while next < arguments.count, !arguments[next].hasPrefix("-") {
                    values.append(arguments[next])
                    next += 1
                    if !multiValueFlags.contains(arg) { break }
                }
                // All of a flag's values or none of them. Keeping `--add-dir
                // ../shared` while dropping `../lib` would restore a session
                // that reports file-not-found on half its tree, with nothing said.
                if values.isEmpty || values.contains(where: isInlineJSON) { refused.append(arg) }
                else { out.append(arg); out.append(contentsOf: values) }
                index = next
                continue
            }
            if boolFlags.contains(arg) {
                out.append(arg)
                index += 1
                continue
            }
            index += 1
        }
        return (out, refused)
    }

    func replayableFlags() -> [String] { Self.replayable(from: arguments).flags }

    /// `cwd` with the user's home written as `~`.
    ///
    /// Only for display. The command itself always carries the absolute path,
    /// because `~` is the *pasting* shell's home and a line copied under one
    /// account and run under another must not silently land somewhere else.
    var displayDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }

    /// The replayed flags, short enough to sit on one line under a button.
    ///
    /// A real session's flags can be `--mcp-config /Users/…/servers.json
    /// --add-dir ../lib --add-dir ../shared`, which wraps a caption into a
    /// paragraph in a 400pt popover. Past a threshold this names the flags and
    /// drops their values; the whole line is still one hover away in the
    /// tooltip, and `--resume-command` prints it verbatim.
    var flagSummary: String? {
        let flags = replayableFlags()
        guard !flags.isEmpty else { return nil }
        let full = flags.joined(separator: " ")
        guard full.count > 44 else { return full }
        let names = flags.filter { $0.hasPrefix("-") }
        return names.isEmpty ? full : names.joined(separator: " ")
    }

    /// What pasting the command actually does, said before it is copied.
    ///
    /// This is the whole promise of the hibernated row, and it is deliberately
    /// specific: a line that only said "copies a command" gives nobody a reason
    /// to paste it. The directory, the flags and the effort level are the three
    /// things `claude --resume <id>` on its own would lose, so they are the
    /// three worth naming — the effort level especially, because `/effort`
    /// never reaches argv and this is the only place in the app it appears.
    ///
    /// A pure read of the record: it renders per row on every poll tick, so
    /// nothing here touches the process table or the filesystem.
    var restoreSummary: String {
        var line = "Paste it into any terminal: it moves to \(displayDirectory) and resumes this session"
        if let flags = flagSummary { line += " with \(flags)" }
        if let effort = replayableEffort { line += ", at \(effort) effort" }
        return line + "."
    }
}

func shellQuote(_ s: String) -> String {
    if s.isEmpty { return "''" }
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@,+"))
    if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// A store could not be written, or was not safe to write.
///
/// Surfaced rather than swallowed: hibernate must refuse when the record fails
/// to land, because the record is the only copy of the argv the restore
/// command is rebuilt from.
enum StoreError: LocalizedError {
    case writeFailed(URL, Error)
    case unreadable(URL, String)

    var errorDescription: String? {
        switch self {
        case let .writeFailed(url, underlying):
            return "Could not write \(url.lastPathComponent): \(underlying.localizedDescription)"
        case let .unreadable(url, reason):
            return "Could not read \(url.lastPathComponent) (\(reason)); refusing to overwrite it."
        }
    }
}

/// A subtree Torpor stopped with SIGSTOP.
///
/// Persisted because a stopped process is unreachable from the UI once its
/// parent dies: the children are reparented to launchd, `isFrozen` is recomputed
/// only from the PIDs of live registry sessions, and a SIGSTOPped MCP server
/// then holds its footprint indefinitely with nothing on screen referring to it.
struct FrozenSubtree: Codable, Identifiable, Hashable {
    var pid: Int32
    /// Start time, so a recycled PID is never mistaken for the session.
    var startedAt: Date
    var children: [FrozenChild]

    var id: Int32 { pid }
}

struct FrozenChild: Codable, Hashable {
    var pid: Int32
    var startedAt: Date
}

/// Persisted list of frozen subtrees. Same lock discipline as
/// `HibernationStore`, for the same reason.
final class FrozenStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FrozenSubtree] = []

    var records: [FrozenSubtree] { lock.withLock { storage } }

    init() { reload() }

    func record(pid: Int32) -> FrozenSubtree? {
        lock.withLock { storage.first { $0.pid == pid } }
    }

    func reload() { lock.withLock { loadLocked() } }

    private func loadLocked() {
        guard let data = try? Data(contentsOf: Paths.frozenStore) else {
            storage = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Unlike a hibernation record this is only a cleanup hint — losing it
        // costs a sweep, not a session — so a bad read is not kept.
        storage = (try? decoder.decode([FrozenSubtree].self, from: data)) ?? []
    }

    func add(_ subtree: FrozenSubtree) throws {
        try mutate { list in
            list.removeAll { $0.pid == subtree.pid }
            list.append(subtree)
        }
    }

    func remove(pid: Int32) throws {
        try mutate { list in list.removeAll { $0.pid == pid } }
    }

    private func mutate(_ body: (inout [FrozenSubtree]) -> Void) throws {
        try lock.withLock {
            let snapshot = storage
            body(&storage)
            do { try persistLocked() } catch { storage = snapshot; throw error }
        }
    }

    private func persistLocked() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // No 0600 here: this file holds PIDs and process names, not command lines.
        do {
            try encoder.encode(storage).write(to: Paths.frozenStore, options: .atomic)
        } catch {
            throw StoreError.writeFailed(Paths.frozenStore, error)
        }
    }
}

struct Preferences: Codable {
    // Sessions
    /// Sessions are long-lived and their footprint moves slowly, so a tighter
    /// interval buys nothing an idle-time readout does not already give you —
    /// it just wakes the CPU and re-walks every process tree more often.
    var pollSeconds: Double = 30
    var notifyIdleMinutes: Double = 30
    var notifyIdleFootprintMB: Double = 250
    var notifyQuotaPercent: Double = 80
    var autoHibernateEnabled = false
    var autoHibernateIdleMinutes: Double = 120
    var autoHibernateFootprintMB: Double = 300
    // `launchTerminal` ("Terminal" or "iTerm") used to live here, choosing which
    // app Torpor opened a window in. Nothing opens a window any more — restoring
    // is a command the user pastes wherever they want it — so the setting had no
    // effect to have. A file that still carries the key simply drops it: the
    // overlay in `load()` only copies keys the defaults still declare.
    var notificationsEnabled = true
    /// Group the session list by working directory.
    var groupByProject = true

    // Account
    var authMode: AuthMode = .statusline
    /// Console spend is an additive panel, not a usage source: it cannot change
    /// any gauge. This is its own switch rather than a radio option.
    var consoleUsageEnabled = false
    /// Modes whose account-risk disclosure the user has accepted.
    ///
    /// Per-mode, not one shared flag: with a single Bool, accepting the notice
    /// under "Connect with Claude CLI" pre-accepted it for "Paste token" too,
    /// so clicking the other radio merely to read its description made live
    /// fetching permitted and the next poll fired at the endpoint before the
    /// panel had been read. Defaulting this non-empty anywhere, including in a
    /// migration, would defeat the point of showing it.
    var acknowledgedRiskModes: Set<AuthMode> = []

    // Appearance
    var menuBarStyle: MenuBarStyle = .bar
    var colorMode: ColorMode = .adaptive
    /// Which quota window the menu bar's bar measures. The default used to be
    /// `.highest`, which no longer exists; the 5-hour window is the one that
    /// actually moves during a working day.
    var menuBarMetric: MenuBarMetric = .fiveHour
    /// Which memory figure sits beside that bar.
    var memoryFigure: MemoryFigure = .total
    /// Whether the status item carries a second row saying how long is left.
    /// It no longer chooses the *format* of that row — see `TimeMarker`, which
    /// still decodes the two formats it used to offer and draws both as a
    /// duration.
    var timeMarker: TimeMarker = .remaining
    /// Model-scoped usage rows hidden from the popover, by server-supplied
    /// name (e.g. "Sonnet"). Empty means show everything the server reports —
    /// a row is never hidden by default, only by choice.
    var hiddenUsageRows: Set<String> = []
    /// Remove the status item entirely when no session is running.
    ///
    /// Off by default. Torpor is an .accessory app with no dock icon and no
    /// window, so a first run with no sessions would otherwise show nothing at
    /// all, and every route to Settings is behind the icon it just hid.
    var hideWhenIdle = false
    /// Register with launchd so Torpor is running after a reboot. A session
    /// monitor that only runs when you remember to open it cannot notice that
    /// something went idle three days ago.
    var launchAtLogin = false

    /// Every property carries its own default, so this is the whole of it. Kept
    /// explicit to suppress the memberwise initializer: `Preferences()` should
    /// mean "the defaults", never a half-filled struct.
    init() {}

    /// Clamped to what the controls can actually express. The doc comment above
    /// advertises tolerance of a hand-edited file, and an out-of-range Double
    /// reaches `UInt64(...)` in Engine and traps on the first poll — crashing
    /// before any UI exists to fix it with.
    private func clamped() -> Preferences {
        func clamp(_ v: Double, _ fallback: Double, _ lower: Double, _ upper: Double) -> Double {
            guard v.isFinite else { return fallback }
            return min(max(v, lower), upper)
        }
        var p = self
        // `TimeMarker` still decodes the two values it retired, so the setting
        // survives the rename — but they are not in `allCases`, and a segmented
        // picker whose selection matches no segment shows nothing selected.
        // Collapsing them here finishes the migration on load rather than
        // waiting for the user to touch a control that looks broken.
        p.timeMarker = p.timeMarker.showsDuration ? .remaining : .none
        p.pollSeconds = clamp(p.pollSeconds, 30, 2, 60)
        p.notifyIdleMinutes = clamp(p.notifyIdleMinutes, 30, 5, 480)
        p.notifyIdleFootprintMB = clamp(p.notifyIdleFootprintMB, 250, 50, 4000)
        p.notifyQuotaPercent = clamp(p.notifyQuotaPercent, 80, 50, 99)
        p.autoHibernateIdleMinutes = clamp(p.autoHibernateIdleMinutes, 120, 30, 1440)
        p.autoHibernateFootprintMB = clamp(p.autoHibernateFootprintMB, 300, 100, 4000)
        return p
    }

    /// True when the selected mode is allowed to make network calls.
    var liveFetchPermitted: Bool {
        switch authMode {
        case .statusline: return false
        case .consoleAPIKey: return consoleUsageEnabled
        case .cliCredentials, .pastedToken: return acknowledgedRiskModes.contains(authMode)
        }
    }

    /// The only supported way to read the file.
    ///
    /// The stored object is overlaid key by key onto the *encoded defaults* and
    /// then decoded by the synthesized conformance, so every preference is
    /// decoded by the compiler. The hand-maintained assignment list this
    /// replaced could silently omit a newly added property — the setting saved
    /// and never came back — because nothing tied it to the declarations.
    ///
    /// A value the struct cannot decode — a menu bar style a later build
    /// removed, a number hand-edited into a string — is restored to its default
    /// and the decode retried, so one stale key costs that setting rather than
    /// everything the user configured. A key a later build *deleted* costs
    /// nothing at all: the overlay only copies keys the defaults still have, so
    /// `menuBarModel` sitting in an old file is dropped rather than rejected.
    /// Enums with removed cases should still decode leniently themselves — see
    /// `MenuBarMetric.init(from:)` — because landing on a sensible case is a
    /// migration, and this loop's job is corrupt files.
    static func load() -> Preferences {
        let defaults = Preferences()
        guard let data = try? Data(contentsOf: Paths.preferences),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoded = try? JSONEncoder().encode(defaults),
              let base = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else { return defaults }

        var merged = base
        for (key, value) in stored where base[key] != nil { merged[key] = value }

        // Terminates: each pass either returns or restores a key it has not
        // restored before, and there are finitely many keys.
        var restored: Set<String> = []
        while true {
            guard let blob = try? JSONSerialization.data(withJSONObject: merged) else {
                return defaults
            }
            do {
                return try JSONDecoder().decode(Preferences.self, from: blob).clamped()
            } catch let error as DecodingError {
                guard let key = error.badKey, let fallback = base[key],
                      restored.insert(key).inserted else { return defaults }
                merged[key] = fallback
            } catch {
                return defaults
            }
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Paths.preferences, options: .atomic)
    }
}

private extension DecodingError {
    /// The top-level key whose value could not be decoded.
    var badKey: String? {
        switch self {
        case let .typeMismatch(_, context), let .valueNotFound(_, context),
             let .dataCorrupted(context):
            return context.codingPath.first?.stringValue
        case let .keyNotFound(key, context):
            return context.codingPath.first?.stringValue ?? key.stringValue
        @unknown default:
            return nil
        }
    }
}

/// Persisted list of hibernated sessions.
///
/// Lock-guarded rather than an actor or a `@MainActor` type. The batch hibernate
/// deliberately runs off the main actor so its six-second wait does not wedge
/// the UI, while `Engine.refresh()` reads this list synchronously on every poll
/// tick and `CLI.run` reads it synchronously in a process that has not started a
/// run loop. Either isolation would push `await` into both of those synchronous
/// paths; a lock makes the mutation safe and leaves every call site as it is.
final class HibernationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HibernatedSession] = []
    /// Why the last load failed, when it did. Read by `persistLocked`, which
    /// will not write over a file it could not read.
    private var failure: String?

    var sessions: [HibernatedSession] { lock.withLock { storage } }

    /// Why the last load failed, or nil when the file was read — or was simply
    /// absent, which is not a failure.
    ///
    /// Exposed because `sessions` is empty in both cases and the two mean
    /// opposite things: "nothing is hibernated" against "the file holding the
    /// only copy of those sessions' argv could not be read, and has not been
    /// overwritten". A caller that cannot tell them apart tells the user their
    /// records do not exist at the moment they most need to be told otherwise.
    var loadFailure: String? { lock.withLock { failure } }

    init() { reload() }

    func reload() { lock.withLock { loadLocked() } }

    private func loadLocked() {
        let url = Paths.hibernationStore
        guard FileManager.default.fileExists(atPath: url.path) else {
            storage = []
            failure = nil
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var decoded: [HibernatedSession]
        do {
            decoded = try decoder.decode([HibernatedSession].self, from: Data(contentsOf: url))
        } catch {
            // Deliberately keeps the in-memory copy. Each record holds the only
            // copy of the argv its restore command needs, and zeroing here made a
            // transient read error look like an empty store — which the next
            // reconcile pass would then write back over the file.
            failure = error.localizedDescription
            return
        }
        // Re-filtered on load, not only at capture. A record written by an
        // earlier build holds the raw argv, so an inline --mcp-config from last
        // week is still sitting in this file with its GITHUB_TOKEN in it.
        // Rewritten in place, so the blob actually leaves the disk rather than
        // merely being ignored on the way back up.
        var changed = false
        for index in decoded.indices {
            let flags = HibernatedSession.replayable(from: decoded[index].arguments).flags
            if flags != decoded[index].arguments {
                decoded[index].arguments = flags
                changed = true
            }
        }
        storage = decoded
        failure = nil
        if changed { try? persistLocked() }
    }

    func add(_ session: HibernatedSession) throws {
        try mutate { list in
            list.removeAll { $0.sessionId == session.sessionId }
            list.insert(session, at: 0)
        }
    }

    func remove(sessionId: String) throws {
        try mutate { list in list.removeAll { $0.sessionId == sessionId } }
    }

    /// Mutate and persist as one step, restoring the list if the write fails.
    ///
    /// Without the rollback, a record that failed to reach disk is still in
    /// memory and gets written by the *next* session's successful persist — so
    /// a batch hibernate where one write fails transiently ends up publishing a
    /// Hibernated entry, offering a restore command, for a session that was
    /// never terminated.
    private func mutate(_ body: (inout [HibernatedSession]) -> Void) throws {
        try lock.withLock {
            let snapshot = storage
            body(&storage)
            do { try persistLocked() } catch { storage = snapshot; throw error }
        }
    }

    private func persistLocked() throws {
        let url = Paths.hibernationStore
        // A failed load left `storage` holding something other than what is on
        // disk — in a fresh CLI process, nothing at all. Writing it would
        // destroy every record we could not read, so refuse and let the caller
        // turn that into a refusal to hibernate.
        if let failure { throw StoreError.unreadable(url, failure) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(storage).write(to: url, options: .atomic)
        } catch {
            throw StoreError.writeFailed(url, error)
        }
        // Records hold captured command lines, which can name private paths.
        // 0600 rather than the default 0644.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }
}
