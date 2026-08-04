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
/// These are the same server-computed numbers `/usage` renders. The payload
/// also carries `cost.total_cost_usd`, `context_window`, `model` and
/// `effort.level`, which Torpor reads too. `effort` is the only one of them
/// that cannot be recovered any other way: `/effort` sets it mid-session, so it
/// never appears in the process's argv for hibernate to capture.
///
/// The shim extracts *only* those fields to a snapshot file and then delegates
/// to whatever statusline the user already had, so installing Torpor never
/// costs them their prompt. It extracts rather than tees because the rest of
/// the payload — transcript path, working directory, repo host/owner/name,
/// session name, prompt id — is nothing Torpor reads, and what is never written
/// cannot leak out of a snapshot file.
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
        /// settings.json points at a Torpor shim that cannot run: the old
        /// space-containing location, or a path where the file is no longer
        /// there. Either way the user's prompt is broken until it is repaired.
        case needsRepair
        case foreign(command: String)   // some other statusline is configured
        /// settings.json exists but is not readable as a JSON object. We must
        /// not touch it in this state — writing would discard whatever is there.
        case settingsUnreadable(String)
    }

    enum InstallError: LocalizedError {
        case settingsUnparseable(path: String, underlying: String)
        case backupFailed(path: String, underlying: String)
        case claudeNeverRan(path: String)

        var errorDescription: String? {
            switch self {
            case let .settingsUnparseable(path, underlying):
                return "\(path) is not valid JSON (\(underlying)). Torpor will not overwrite it — fix or move the file, then try again."
            case let .backupFailed(path, underlying):
                return "Could not back up \(path) (\(underlying)). settings.json was not modified."
            case let .claudeNeverRan(path):
                return "Claude Code has not run on this Mac yet — \(path) does not exist. Start a session, then install."
            }
        }
    }

    /// Where the chained command is mirrored inside settings.json.
    ///
    /// The shim carries its own copy on its `TORPOR_CHAIN_JSON` line, but that
    /// copy dies with `~/.torpor` — which is on the Homebrew cask's zap list and
    /// is what any "remove the leftovers" script deletes — and it is the only
    /// record of the statusline the user had before Torpor. This second copy
    /// lives in the same file as the command that points at the shim, so
    /// whatever survives to describe the install also survives to undo it.
    private static let mirrorKey = "torpor"
    private static let chainKey = "previousStatusLineCommand"

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
        if command == Paths.statuslineShim.path {
            // settings.json can point at a shim that is no longer there —
            // `rm -rf ~/.torpor`, a cleanup script, the cask's zap — and every
            // render then runs a missing file. Reporting .installed for that
            // claims health at the one moment the prompt is actually broken.
            return FileManager.default.isExecutableFile(atPath: command)
                ? .installed : .needsRepair
        }
        // An install pointing at the old, space-containing location never ran:
        // report it as needing repair so the fix is one click away.
        if command == Paths.legacyStatuslineShim.path { return .needsRepair }
        return .foreign(command: command)
    }

    /// The chained command mirrored into settings.json, for when the shim that
    /// normally carries it is gone.
    private static func mirroredChain(in root: [String: Any]?) -> String? {
        guard let value = (root?[mirrorKey] as? [String: Any])?[chainKey] as? String,
              !value.isEmpty else { return nil }
        return value
    }

    /// Copy settings.json aside before it is touched. Returns where it went, or
    /// nil when there was nothing to copy.
    ///
    /// Called before the *first* mutation on every path, not just before the
    /// final write — an earlier version backed up after the shim had already
    /// been rewritten and the legacy shim deleted, so "no changes were made"
    /// was untrue by the time it could be printed.
    @discardableResult
    private static func backupSettings() throws -> URL? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        let stamp = ISO8601DateFormatter.filenameSafe.string(from: Date())
        // `copyItem` throws on an existing destination, so a name two
        // operations can share is a name that makes the second one fail — and
        // Install-then-Remove in Settings is two clicks, not two seconds. The
        // stamp carries milliseconds; the suffix covers the rest.
        for attempt in 1...20 {
            let name = attempt == 1
                ? "settings.\(stamp).json.backup"
                : "settings.\(stamp)-\(attempt).json.backup"
            let backup = Paths.support.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: backup.path) { continue }
            do {
                try FileManager.default.copyItem(at: settingsURL, to: backup)
                return backup
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw InstallError.backupFailed(path: settingsURL.path,
                                                underlying: error.localizedDescription)
            }
        }
        throw InstallError.backupFailed(path: settingsURL.path,
                                        underlying: "too many backups share this timestamp")
    }

    /// Write the shim and point `settings.json` at it, preserving any existing
    /// statusline by chaining to it. Returns where settings.json was backed up,
    /// or nil when there was no settings.json to back up.
    @discardableResult
    static func install() throws -> URL? {
        // First, before anything is written. `~/.claude` is the one directory
        // Torpor does not create, and the write below used to fail on its
        // absence with Foundation's "The folder settings.json doesn't exist" —
        // after the shim had already landed in ~/.torpor. Its absence also
        // means there is nothing here to read yet, so refusing is the honest
        // answer rather than creating a settings.json Claude Code may never
        // look at.
        let directory = settingsURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw InstallError.claudeNeverRan(path: directory.path)
        }

        // Refuses rather than clobbers: reading throws on an unparseable file.
        let existing = try readSettings()

        // Recover the chained command from whichever source still holds it.
        // Order matters — on a repair, the old shim is the *only* remaining
        // copy of CHAIN, so it must be read before it is deleted, and when
        // ~/.torpor has been deleted outright the mirror in settings.json is
        // the last copy there is.
        var chained: String?
        switch currentState() {
        case let .foreign(command):
            chained = command
        case .installed:
            chained = chainedCommand(in: Paths.statuslineShim) ?? mirroredChain(in: existing)
        case .needsRepair:
            chained = chainedCommand(in: Paths.legacyStatuslineShim)
                ?? chainedCommand(in: Paths.statuslineShim)
                ?? mirroredChain(in: existing)
        case .notInstalled, .settingsUnreadable:
            break
        }

        // Before the first mutation of anything.
        let backup = try backupSettings()

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
        if let chained {
            root[mirrorKey] = [chainKey: chained]
        } else {
            root.removeValue(forKey: mirrorKey)
        }

        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys])

        try out.write(to: settingsURL, options: .atomic)
        return backup
    }

    /// Remove the shim from settings.json, restoring a chained statusline if
    /// one was captured at install time.
    static func uninstall() throws {
        guard var root = try readSettings() else { return }
        let configured = (root["statusLine"] as? [String: Any])?["command"] as? String
        let isOurs = configured == Paths.statuslineShim.path
            || configured == Paths.legacyStatuslineShim.path
        // Somebody else's statusline is not ours to delete. Without this, an
        // uninstall run a second time — or run after the user configured their
        // own — removed the statusLine key outright, which is exactly the
        // breakage uninstall exists to prevent.
        guard isOurs || root[mirrorKey] != nil else { return }

        // Removing rewrites settings.json too. It gets the same backup as
        // install.
        try backupSettings()

        if isOurs {
            // The shim may be gone (~/.torpor deleted), so fall back to the
            // mirror this file carries.
            let previous = chainedCommand(in: Paths.statuslineShim) ?? mirroredChain(in: root)
            if let previous, !previous.isEmpty {
                // Only `command` is replaced. padding, refreshInterval and
                // hideVimModeIndicator are the user's — rebuilding the dict
                // from scratch handed their prompt back with a different
                // layout and nothing said about why.
                var statusLine = root["statusLine"] as? [String: Any] ?? [:]
                statusLine["type"] = "command"
                statusLine["command"] = previous
                root["statusLine"] = statusLine
            } else {
                root.removeValue(forKey: "statusLine")
            }
        }
        root.removeValue(forKey: mirrorKey)

        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
    }

    /// Bumped whenever the shim's *output* changes, so a shim written by an
    /// earlier release can be recognised on disk.
    /// 3 adds `effort.level`, which hibernate replays as `--effort` — a level
    /// set with the `/effort` slash command is never in argv, so the payload is
    /// the only place it exists. Without the bump every existing install keeps
    /// a shim that has never written the field.
    private static let shimVersion = 3

    private static var installedShimIsCurrent: Bool {
        guard let text = try? String(contentsOf: Paths.statuslineShim, encoding: .utf8)
        else { return false }
        return text.contains("# TORPOR_SHIM: \(shimVersion)")
    }

    /// Rewrite an installed shim that predates the current format.
    ///
    /// The shim is only ever written when the user installs it, so without this
    /// an upgrade leaves the previous release's script running forever — and
    /// this release's script extracts fields the previous one never wrote, so
    /// the app would keep showing nothing for them. settings.json is not
    /// touched: it already points at the right path. The chained statusline is
    /// recovered from the shim being replaced, exactly as `install` does.
    ///
    /// Only ever runs against a shim that is actually on disk: `currentState`
    /// reports `.needsRepair` for a missing one, and rewriting *that* here
    /// would hand the user a chain-less shim — losing their third-party
    /// statusline — on a background refresh they never asked for.
    static func refreshIfStale() {
        guard currentState() == .installed, !installedShimIsCurrent else { return }
        let chained = chainedCommand(in: Paths.statuslineShim)
            ?? mirroredChain(in: try? readSettings())
        try? writeShim(chaining: chained)
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

    /// Pulls the fields Torpor reads out of the statusline payload and prints
    /// `<session_id> <json>` — one line, the id first so the shell can split it
    /// off with parameter expansion instead of another process.
    ///
    /// One awk pass rather than a dozen `sed` calls per render, and awk is the
    /// only extra tool: it is in POSIX and on every macOS install, which `jq`
    /// and `python` are not. Objects are located by brace matching, not by
    /// `[^}]*`, because `context_window` nests `current_usage` before the
    /// fields we want. A raw string literal so the awk escapes stay readable.
    private static let extractor = #"""
    function slice(src, name,   i, n, j, c, start, depth) {
        i = index(src, "\"" name "\"")
        if (i == 0) return ""
        n = length(src)
        start = 0
        for (j = i; j <= n; j++) {
            c = substr(src, j, 1)
            if (c == "{") { start = j; break }
            if (c == "}" || c == ",") return ""
        }
        if (start == 0) return ""
        depth = 0
        for (j = start; j <= n; j++) {
            c = substr(src, j, 1)
            if (c == "{") depth++
            else if (c == "}") { depth--; if (depth == 0) return substr(src, start, j - start + 1) }
        }
        return ""
    }
    function number(src, key,   v) {
        if (src == "") return ""
        if (match(src, "\"" key "\"[ \t]*:[ \t]*-?[0-9]+([.][0-9]+)?")) {
            v = substr(src, RSTART, RLENGTH)
            sub(/^[^:]*:[ \t]*/, "", v)
            return v
        }
        return ""
    }
    function text(src, key,   v) {
        if (src == "") return ""
        if (match(src, "\"" key "\"[ \t]*:[ \t]*\"[^\"]*\"")) {
            v = substr(src, RSTART, RLENGTH)
            sub(/^[^:]*:[ \t]*"/, "", v)
            sub(/"$/, "", v)
            gsub(/\\/, "", v)
            return v
        }
        return ""
    }
    function quote(v) { return (v == "" ? "" : "\"" v "\"") }
    function pair(k, v) { return (v == "" ? "" : "\"" k "\":" v) }
    function join(a, b) { return (a == "" ? b : (b == "" ? a : a "," b)) }
    function window(src, name,   s, o, r) {
        s = slice(src, name)
        if (s == "") return ""
        o = number(s, "used_percentage")
        if (o == "") return ""
        o = "\"used_percentage\":" o
        r = number(s, "resets_at")
        if (r != "") o = o ",\"resets_at\":" r
        return "{" o "}"
    }
    { doc = doc $0 }
    END {
        sid = text(doc, "session_id")
        gsub(/[^A-Za-z0-9_-]/, "", sid)
        out = pair("session_id", quote(sid))

        src = slice(doc, "rate_limits")
        part = join(pair("five_hour", window(src, "five_hour")),
                    pair("seven_day", window(src, "seven_day")))
        part = join(part, pair("seven_day_opus", window(src, "seven_day_opus")))
        part = join(part, pair("seven_day_sonnet", window(src, "seven_day_sonnet")))
        if (part != "") out = join(out, pair("rate_limits", "{" part "}"))

        src = slice(doc, "cost")
        part = pair("total_cost_usd", number(src, "total_cost_usd"))
        if (part != "") out = join(out, pair("cost", "{" part "}"))

        src = slice(doc, "context_window")
        part = join(pair("used_percentage", number(src, "used_percentage")),
                    pair("context_window_size", number(src, "context_window_size")))
        part = join(part, pair("total_input_tokens", number(src, "total_input_tokens")))
        part = join(part, pair("total_output_tokens", number(src, "total_output_tokens")))
        if (part != "") out = join(out, pair("context_window", "{" part "}"))

        src = slice(doc, "model")
        part = join(pair("id", quote(text(src, "id"))),
                    pair("display_name", quote(text(src, "display_name"))))
        if (part != "") out = join(out, pair("model", "{" part "}"))

        src = slice(doc, "effort")
        part = pair("level", quote(text(src, "level")))
        if (part != "") out = join(out, pair("effort", "{" part "}"))

        printf "%s {%s}\n", (sid == "" ? "-" : sid), out
    }
    """#

    private static func writeShim(chaining previous: String?,
                                  to destination: URL? = nil) throws {
        let snapshot = QuotaReader.snapshotURL.path
        let sessions = QuotaReader.sessionsDirectory.path
        let chain = previous.map { shellQuote($0) } ?? "''"
        let chainJSON = String(
            decoding: (try? JSONEncoder().encode(previous ?? "")) ?? Data("\"\"".utf8),
            as: UTF8.self)

        // Deliberately POSIX sh and awk, with no jq/python dependency: this runs
        // on every statusline render, in the user's shell, and must never fail
        // or stall.
        let script = """
        #!/bin/sh
        # Torpor statusline shim — extracts the handful of fields Torpor reads
        # from Claude Code's statusline payload into a snapshot file so the menu
        # bar app can read server-authoritative quota, then delegates to
        # whatever statusline was configured before.
        #
        # Managed by Torpor. The line below is how Torpor recovers your original
        # statusline on uninstall — keep it if you edit CHAIN by hand.
        # TORPOR_CHAIN_JSON: \(chainJSON)
        # TORPOR_SHIM: \(shimVersion)
        CHAIN=\(chain)

        SNAP=\(shellQuote(snapshot))
        SNAPDIR=$(dirname "$SNAP")
        SESSDIR=\(shellQuote(sessions))
        # Per-process temp names: many sessions render concurrently, and a
        # shared temp path lets two writers splice a single file.
        TMP="$SNAP.$$"
        TMPS="$SNAP.session.$$"
        trap 'rm -f "$TMP" "$TMPS"' EXIT

        payload=$(cat)

        line=$(printf '%s' "$payload" | LC_ALL=C awk '\(extractor)' 2>/dev/null)
        if [ -n "$line" ]; then
            # awk printed "<session_id> <json>", and a session id never contains
            # a space, so the first one splits it — no extra process needed.
            sid=${line%% *}
            snap=${line#* }
            [ -d "$SNAPDIR" ] || mkdir -p "$SNAPDIR" 2>/dev/null
            if printf '%s' "$snap" > "$TMP" 2>/dev/null; then
                chmod 600 "$TMP" 2>/dev/null
                # rate_limits are account-wide, so the shared snapshot is right
                # whichever session wrote it last. cost and context_window are
                # per session, so each session also keeps its own copy —
                # without it the session that rendered last would speak for all
                # of them and the app would report one session's spend as the
                # whole account's.
                if [ "$sid" != "-" ]; then
                    [ -d "$SESSDIR" ] || mkdir -p "$SESSDIR" 2>/dev/null
                    if cp "$TMP" "$TMPS" 2>/dev/null; then
                        chmod 600 "$TMPS" 2>/dev/null
                        mv -f "$TMPS" "$SESSDIR/$sid.json" 2>/dev/null
                    fi
                fi
                mv -f "$TMP" "$SNAP" 2>/dev/null
            fi
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
    ///
    /// Milliseconds because this names a backup: at second resolution, Install
    /// and Remove clicked one after the other produce the same filename and the
    /// second operation refuses rather than overwrite the first's recovery copy.
    static let filenameSafe: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay,
                                   .withTime, .withTimeZone, .withFractionalSeconds]
        return formatter
    }()
}
