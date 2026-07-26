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
        let isHosted = hostedPaths.contains { executable.contains($0) }
        if isHosted || (entrypoint != nil && entrypoint != "cli") { return "claude" }
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

    /// Flags worth carrying across a hibernate/revive cycle.
    ///
    /// Deliberately an allowlist. The captured argv of a real session contains
    /// a great deal that must not be replayed — stream plumbing
    /// (`--output-format`, `--input-format`, `--replay-user-messages`),
    /// one-shot flags, and permission grants scoped to the old process.
    /// Replaying those would produce a session that behaves nothing like an
    /// interactive one.
    func replayableFlags() -> [String] {
        let valueFlags: Set<String> = [
            "--model", "--settings", "--mcp-config", "--add-dir",
            "--plugin-dir", "--setting-sources",
            "--agent", "--effort", "--fallback-model", "--name",
        ]
        // Deliberately excludes --dangerously-skip-permissions and
        // --permission-mode. Replaying them would launch a fresh agent with
        // permission prompts disabled, days after the user made that call, in a
        // terminal they did not type into. The comment above says this
        // allowlist excludes permission grants scoped to the old process —
        // these are exactly that.
        let boolFlags: Set<String> = ["--no-chrome"]

        // `--settings`, `--mcp-config` and `--agent` accept inline JSON as well
        // as a path, and an inline MCP definition routinely carries an `env`
        // block with GITHUB_TOKEN, database URLs or an API key. Replaying a
        // path is fine; persisting and echoing a JSON blob is not, so those are
        // dropped and the session resumes with its configured defaults.
        func isInlineJSON(_ value: String) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        }

        var out: [String] = []
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            // Support both "--flag value" and "--flag=value".
            if let eq = arg.firstIndex(of: "="), valueFlags.contains(String(arg[arg.startIndex..<eq])) {
                let value = String(arg[arg.index(after: eq)...])
                if !isInlineJSON(value) { out.append(arg) }
                index += 1
                continue
            }
            if valueFlags.contains(arg), index + 1 < arguments.count {
                let value = arguments[index + 1]
                if !isInlineJSON(value) {
                    out.append(arg)
                    out.append(value)
                }
                index += 2
                continue
            }
            if boolFlags.contains(arg) {
                out.append(arg)
                index += 1
                continue
            }
            index += 1
        }
        return out
    }
}

func shellQuote(_ s: String) -> String {
    if s.isEmpty { return "''" }
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@,+"))
    if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct Preferences: Codable {
    // Sessions
    var pollSeconds: Double = 5
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
    var menuBarMetric: MenuBarMetric = .highest
    var timeMarker: TimeMarker = .remaining
    /// Model-scoped usage rows hidden from the popover, by server-supplied
    /// name (e.g. "Sonnet"). Empty means show everything the server reports —
    /// a row is never hidden by default, only by choice.
    var hiddenUsageRows: Set<String> = []
    /// Which model-scoped window the menu bar tracks when the metric is `.model`.
    var menuBarModel: String = ""
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

    /// Decoded leniently so a preferences file written by an older build — or
    /// one a user hand-edited — loads with defaults for anything missing rather
    /// than resetting every setting.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        // Clamped to the ranges the steppers enforce. The doc comment above
        // advertises tolerance of a hand-edited file, and an out-of-range
        // Double reaches `UInt64(...)` in Engine and traps on the first poll —
        // crashing before any UI exists to fix it with.
        func clamped(_ key: CodingKeys, _ fallback: Double, _ lower: Double, _ upper: Double) -> Double {
            let raw: Double = value(key, fallback)
            guard raw.isFinite else { return fallback }
            return min(max(raw, lower), upper)
        }
        pollSeconds = clamped(.pollSeconds, 5, 2, 60)
        notifyIdleMinutes = clamped(.notifyIdleMinutes, 30, 5, 480)
        notifyIdleFootprintMB = clamped(.notifyIdleFootprintMB, 250, 50, 4000)
        notifyQuotaPercent = clamped(.notifyQuotaPercent, 80, 50, 99)
        autoHibernateEnabled = value(.autoHibernateEnabled, false)
        autoHibernateIdleMinutes = clamped(.autoHibernateIdleMinutes, 120, 30, 1440)
        autoHibernateFootprintMB = clamped(.autoHibernateFootprintMB, 300, 100, 4000)
        launchTerminal = value(.launchTerminal, "Terminal")
        notificationsEnabled = value(.notificationsEnabled, true)
        groupByProject = value(.groupByProject, true)
        authMode = value(.authMode, .statusline)
        consoleUsageEnabled = value(.consoleUsageEnabled, false)
        acknowledgedRiskModes = value(.acknowledgedRiskModes, [])
        // Styles that drew the app logo were removed; a preferences file
        // naming one decodes to nil and falls back rather than resetting
        // everything else the user configured.
        menuBarStyle = value(.menuBarStyle, .bar)
        colorMode = value(.colorMode, .adaptive)
        menuBarMetric = value(.menuBarMetric, .highest)
        timeMarker = value(.timeMarker, .remaining)
        hiddenUsageRows = value(.hiddenUsageRows, [])
        menuBarModel = value(.menuBarModel, "")
        hideWhenIdle = value(.hideWhenIdle, false)
        launchAtLogin = value(.launchAtLogin, false)
    }

    /// True when the selected mode is allowed to make network calls.
    var liveFetchPermitted: Bool {
        switch authMode {
        case .statusline: return false
        case .consoleAPIKey: return consoleUsageEnabled
        case .cliCredentials, .pastedToken: return acknowledgedRiskModes.contains(authMode)
        }
    }

    static func load() -> Preferences {
        guard let data = try? Data(contentsOf: Paths.preferences),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return prefs
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Paths.preferences, options: .atomic)
    }
}

/// Persisted list of hibernated sessions.
final class HibernationStore {
    private(set) var sessions: [HibernatedSession] = []

    init() { reload() }

    func reload() {
        guard let data = try? Data(contentsOf: Paths.hibernationStore) else {
            sessions = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        sessions = (try? decoder.decode([HibernatedSession].self, from: data)) ?? []
    }

    func add(_ session: HibernatedSession) {
        sessions.removeAll { $0.sessionId == session.sessionId }
        sessions.insert(session, at: 0)
        persist()
    }

    func remove(sessionId: String) {
        sessions.removeAll { $0.sessionId == sessionId }
        persist()
    }

    func markReviving(sessionId: String) {
        guard let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        sessions[index].revivingSince = Date()
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: Paths.hibernationStore, options: .atomic)
        // Records hold captured command lines, which can name private paths.
        // 0600 rather than the default 0644.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Paths.hibernationStore.path)
    }
}
