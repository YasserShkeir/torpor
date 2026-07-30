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

    static var claudeSessions: URL { claude.appendingPathComponent("sessions", isDirectory: true) }
    static var claudeProjects: URL { claude.appendingPathComponent("projects", isDirectory: true) }

    static var hibernationStore: URL { support.appendingPathComponent("hibernated.json") }
    static var frozenStore: URL { support.appendingPathComponent("frozen.json") }
    static var preferences: URL { support.appendingPathComponent("preferences.json") }
    static var statuslineShim: URL { scripts.appendingPathComponent("statusline-shim.sh") }
    /// Where the shim used to live, so an existing install can be migrated.
    static var legacyStatuslineShim: URL {
        support.appendingPathComponent("statusline-shim.sh")
    }
}

/// A session that Torpor terminated and can bring back.
///
/// `arguments` is the point of the whole record. `claude --resume <id>` is
/// documented as lossy: it restores conversation history but drops
/// `--mcp-config`, `--settings`, `--plugin-dir`, `--add-dir` and `--model`.
/// Because Torpor captures the live argv before terminating, revive can replay
/// those flags — making the app's resume strictly more faithful than typing the
/// command by hand.
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
    /// Controlling terminal of the session at the moment it was hibernated,
    /// e.g. `/dev/ttys016`. The shell that launched it survives, so this is
    /// how revive reopens the session in the tab it actually died in rather
    /// than a fresh window. Nil for sessions with no tty (VS Code-hosted).
    var tty: String?
    /// Set when a revive has been launched but the session has not yet
    /// reappeared in the registry. The record is kept until it does, because
    /// launching a terminal proves nothing about whether `claude` actually ran.
    var revivingSince: Date?

    var id: String { sessionId }

    /// Which binary revive should actually run.
    ///
    /// A session hosted by VS Code or the desktop app is not the CLI: it is a
    /// harness-specific binary that expects stream-json plumbing on stdin and
    /// stdout. Relaunching *that* in a terminal produces a process that reads
    /// JSON from the keyboard. For any non-CLI entrypoint we revive with the
    /// ordinary `claude` on PATH instead, which is what the user actually wants
    /// when they click Revive in a menu bar app.
    var reviveExecutable: String {
        let hostedPaths = ["/.vscode/extensions/", "/Claude.app/", "/claude.app/"]
        let candidates = [executable, executablePath ?? ""]
        let isHosted = hostedPaths.contains { marker in candidates.contains { $0.contains(marker) } }
        if isHosted || (entrypoint != nil && entrypoint != "cli") { return "claude" }
        // argv[0] is usually the bare name, which leaves revive depending on
        // whatever PATH the new shell has after cd-ing into the project. The
        // kernel's exec path is absolute, so prefer it — but only if it still
        // exists now, at revive time: it is typically ~/.local/bin/claude, an
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

    /// The command revive will run. Flags that `--resume` would otherwise drop
    /// are re-applied; flags that describe the old invocation's I/O plumbing
    /// are not, because the revived session runs in a fresh terminal.
    var resumeCommand: String {
        var parts = [shellQuote(reviveExecutable), "--resume", shellQuote(sessionId)]
        parts.append(contentsOf: replayableFlags().map(shellQuote))
        return parts.joined(separator: " ")
    }

    /// Flags worth carrying across a hibernate/revive cycle, and the flags we
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
        ]
        // Only these accept several space-separated values. Consuming the run
        // greedily for every value flag would swallow a positional prompt —
        // `claude --model opus "fix the parser"` — as if it were a second model.
        let multiValueFlags: Set<String> = ["--add-dir", "--mcp-config"]
        // Deliberately excludes --dangerously-skip-permissions and
        // --permission-mode. Replaying them would launch a fresh agent with
        // permission prompts disabled, days after the user made that call, in a
        // terminal they did not type into. The comment above says this
        // allowlist excludes permission grants scoped to the old process —
        // these are exactly that.
        let boolFlags: Set<String> = ["--no-chrome"]

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
                // ../shared` while dropping `../lib` would revive a session that
                // reports file-not-found on half its tree, with nothing said.
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
/// to land, because the record is the only copy of the argv a revive can be
/// rebuilt from.
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
    var name: String
    var children: [FrozenChild]
    var frozenAt: Date

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
    var launchTerminal = "Terminal"   // or "iTerm"
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
            // copy of the argv its revive needs, and zeroing here made a
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

    func markReviving(sessionId: String) throws {
        try mutate { list in
            guard let index = list.firstIndex(where: { $0.sessionId == sessionId }) else { return }
            list[index].revivingSince = Date()
        }
    }

    /// Mutate and persist as one step, restoring the list if the write fails.
    ///
    /// Without the rollback, a record that failed to reach disk is still in
    /// memory and gets written by the *next* session's successful persist — so
    /// a batch hibernate where one write fails transiently ends up publishing a
    /// Hibernated entry, with a live Revive button, for a session that was never
    /// terminated.
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
