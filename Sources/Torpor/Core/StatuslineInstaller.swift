import Foundation

/// Installs a statusline shim into `~/.claude/settings.json`.
///
/// Claude Code invokes the configured statusline command on every render and
/// hands it a JSON payload on stdin. That payload contains, for Claude.ai
/// subscribers, a documented `rate_limits` object:
///
///     rate_limits.five_hour.used_percentage   (0-100)
///     rate_limits.five_hour.resets_at         (unix seconds)
///     rate_limits.seven_day.used_percentage
///     rate_limits.seven_day.resets_at
///
/// These are the same server-computed numbers `/usage` renders. The shim tees
/// the payload to a snapshot file and then delegates to whatever statusline the
/// user already had, so installing Torpor never costs them their prompt.
///
/// Two honest limitations, surfaced in the UI rather than hidden:
///  * The snapshot only refreshes while some session is rendering. If every
///    session is idle, the numbers age. Torpor shows the capture time.
///  * `rate_limits` is absent until a session's first API response, and each
///    window can be independently absent.
enum StatuslineInstaller {

    enum State: Equatable {
        case notInstalled
        case installed
        /// Installed at the old location, which never actually ran.
        case needsRepair
        case foreign(command: String)   // some other statusline is configured
        /// settings.json exists but is not readable as a JSON object. We must
        /// not touch it in this state — writing would discard whatever is there.
        case settingsUnreadable(String)
    }

    enum InstallError: LocalizedError {
        case settingsUnparseable(path: String, underlying: String)
        case backupFailed(path: String, underlying: String)

        var errorDescription: String? {
            switch self {
            case let .settingsUnparseable(path, underlying):
                return "\(path) is not valid JSON (\(underlying)). Torpor will not overwrite it — fix or move the file, then try again."
            case let .backupFailed(path, underlying):
                return "Could not back up \(path) (\(underlying)). No changes were made."
            }
        }
    }

    /// Resolved so a `settings.json` symlinked into a dotfiles repo — a common
    /// setup for this audience — is written through rather than replaced by a
    /// regular file, which would silently orphan every later dotfiles edit.
    static var settingsURL: URL {
        Paths.claude
            .appendingPathComponent("settings.json")
            .resolvingSymlinksInPath()
    }

    /// Reads settings.json. Returns nil when the file is absent (fine — we can
    /// create it) and throws when it exists but cannot be parsed (not fine).
    private static func readSettings() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: settingsURL)
        } catch {
            throw InstallError.settingsUnparseable(path: settingsURL.path,
                                                   underlying: error.localizedDescription)
        }
        // An empty file is treated as absent rather than corrupt.
        if data.isEmpty { return nil }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.settingsUnparseable(path: settingsURL.path,
                                                       underlying: "top level is not an object")
            }
            return object
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.settingsUnparseable(path: settingsURL.path,
                                                   underlying: error.localizedDescription)
        }
    }

    static func currentState() -> State {
        let root: [String: Any]?
        do { root = try readSettings() } catch {
            return .settingsUnreadable(error.localizedDescription)
        }
        guard let root,
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return .notInstalled
        }
        if command == Paths.statuslineShim.path { return .installed }
        // An install pointing at the old, space-containing location never ran:
        // report it as needing repair so the fix is one click away.
        if command == Paths.legacyStatuslineShim.path { return .needsRepair }
        return .foreign(command: command)
    }

    /// Write the shim and point `settings.json` at it, preserving any existing
    /// statusline by chaining to it.
    static func install() throws {
        // Refuses rather than clobbers: reading throws on an unparseable file.
        let existing = try readSettings()

        // Recover the chained command from whichever source still holds it.
        // Order matters — on a repair, the old shim is the *only* remaining
        // copy of CHAIN, so it must be read before it is deleted.
        var chained: String?
        switch currentState() {
        case let .foreign(command):
            chained = command
        case .installed:
            chained = chainedCommand(in: Paths.statuslineShim)
        case .needsRepair:
            chained = chainedCommand(in: Paths.legacyStatuslineShim)
                ?? chainedCommand(in: Paths.statuslineShim)
        case .notInstalled, .settingsUnreadable:
            break
        }

        try writeShim(chaining: chained)

        // Only now is it safe to drop the old copy.
        if Paths.legacyStatuslineShim != Paths.statuslineShim,
           FileManager.default.fileExists(atPath: Paths.legacyStatuslineShim.path) {
            try? FileManager.default.removeItem(at: Paths.legacyStatuslineShim)
        }

        var root = existing ?? [:]
        var statusLine = root["statusLine"] as? [String: Any] ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = Paths.statuslineShim.path
        root["statusLine"] = statusLine

        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys])

        // Back up before touching a file the user owns. A failed backup aborts
        // the install rather than proceeding unprotected, and backups are
        // timestamped so a second install cannot eat the original.
        if existing != nil {
            let stamp = ISO8601DateFormatter.filenameSafe.string(from: Date())
            let backup = Paths.support.appendingPathComponent("settings.\(stamp).json.backup")
            do {
                try FileManager.default.copyItem(at: settingsURL, to: backup)
            } catch {
                throw InstallError.backupFailed(path: settingsURL.path,
                                                underlying: error.localizedDescription)
            }
        }

        try out.write(to: settingsURL, options: .atomic)
    }

    /// Remove the shim from settings.json, restoring a chained statusline if
    /// one was captured at install time.
    static func uninstall() throws {
        guard var root = try readSettings() else { return }
        if let previous = chainedCommand(in: Paths.statuslineShim), !previous.isEmpty {
            root["statusLine"] = ["type": "command", "command": previous]
        } else {
            root.removeValue(forKey: "statusLine")
        }
        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
    }

    /// Recover the chained command from a shim on disk.
    ///
    /// Read from a JSON comment line rather than by un-quoting the shell
    /// literal: `shellQuote` encodes an embedded quote as `'\''`, and naively
    /// stripping the outer quotes leaves that sequence in the recovered string.
    /// JSON round-trips exactly and survives newlines.
    private static func chainedCommand(in url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let marker = "# TORPOR_CHAIN_JSON: "
        for line in text.split(separator: "\n", omittingEmptySubsequences: false)
        where line.hasPrefix(marker) {
            let payload = String(line.dropFirst(marker.count))
            guard let data = payload.data(using: .utf8),
                  let value = try? JSONDecoder().decode(String.self, from: data),
                  !value.isEmpty else { return nil }
            return value
        }
        return nil
    }

    /// Render the shim to an arbitrary path, so it can be inspected before it
    /// is installed. `Torpor --emit-shim <path>` uses this.
    static func emitShim(to url: URL, chaining previous: String? = nil) throws {
        try writeShim(chaining: previous, to: url)
    }

    private static func writeShim(chaining previous: String?,
                                  to destination: URL? = nil) throws {
        let snapshot = QuotaReader.snapshotURL.path
        let chain = previous.map { shellQuote($0) } ?? "''"
        let chainJSON = String(
            decoding: (try? JSONEncoder().encode(previous ?? "")) ?? Data("\"\"".utf8),
            as: UTF8.self)

        // Deliberately POSIX sh with no jq/python dependency: this runs on every
        // statusline render, in the user's shell, and must never fail or stall.
        let script = """
        #!/bin/sh
        # Torpor statusline shim — tees Claude Code's statusline payload to a
        # snapshot file so the menu bar app can read server-authoritative quota,
        # then delegates to whatever statusline was configured before.
        #
        # Managed by Torpor. The line below is how Torpor recovers your original
        # statusline on uninstall — keep it if you edit CHAIN by hand.
        # TORPOR_CHAIN_JSON: \(chainJSON)
        CHAIN=\(chain)

        SNAP=\(shellQuote(snapshot))
        SNAPDIR=$(dirname "$SNAP")
        # Per-process temp name: many sessions render concurrently, and a shared
        # temp path lets two writers splice a single file.
        TMP="$SNAP.$$"
        trap 'rm -f "$TMP"' EXIT

        payload=$(cat)

        [ -d "$SNAPDIR" ] || mkdir -p "$SNAPDIR" 2>/dev/null
        if printf '%s' "$payload" > "$TMP" 2>/dev/null; then
            chmod 600 "$TMP" 2>/dev/null
            mv -f "$TMP" "$SNAP" 2>/dev/null
        fi

        if [ -n "$CHAIN" ]; then
            printf '%s' "$payload" | sh -c "$CHAIN"
        else
            # Minimal default line. Everything here is cosmetic; the data Torpor
            # needs was already written above. LC_ALL=C so an invalid UTF-8 byte
            # cannot make sed emit "illegal byte sequence" into the prompt.
            dir=$(printf '%s' "$payload" | LC_ALL=C sed -n 's/.*"current_dir"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' 2>/dev/null)
            model=$(printf '%s' "$payload" | LC_ALL=C sed -n 's/.*"display_name"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' 2>/dev/null)
            [ -n "$dir" ] && dir=$(basename "$dir")
            printf '%s %s' "${model:-claude}" "${dir:-}"
        fi
        """

        let target = destination ?? Paths.statuslineShim
        try script.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: target.path)
    }
}

extension ISO8601DateFormatter {
    /// Colons are legal in HFS+/APFS filenames but display as `/` in Finder,
    /// so timestamps in filenames use a dash-separated form.
    static let filenameSafe: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay,
                                   .withTime, .withTimeZone]
        return formatter
    }()
}
