import Foundation

/// Server-authoritative quota, as reported by Claude Code itself.
struct QuotaSnapshot: Codable, Equatable {
    struct Window: Codable, Equatable {
        var usedPercentage: Double
        var resetsAt: Date?
    }
    var fiveHour: Window?
    var sevenDay: Window?
    /// Model-scoped weekly windows (`seven_day_opus`, `seven_day_sonnet`, and
    /// any server-driven rows such as Fable) keyed by their limit name.
    var scoped: [String: Window] = [:]
    var capturedAt: Date
    var sourceSessionId: String?

    var age: TimeInterval { Date().timeIntervalSince(capturedAt) }
    /// The snapshot only refreshes while some session is rendering its
    /// statusline. Beyond this we show it as stale rather than as truth.
    var isStale: Bool { age > 900 }
}

/// Reads the quota snapshot written by Torpor's statusline shim.
///
/// This is deliberately the *only* quota path. Claude Code hands the statusline
/// a JSON payload on stdin containing `rate_limits.five_hour.used_percentage`,
/// `rate_limits.seven_day.used_percentage` and their `resets_at` timestamps —
/// documented, server-computed, and already in the user's possession.
///
/// This is the default and the only path that needs no credentials.
///
/// Torpor *can* also read the OAuth token out of the Keychain and call
/// `api.anthropic.com/api/oauth/usage` with a `claude-code/<version>`
/// User-Agent — see UsageAPI — which is the exact pattern Anthropic enforced
/// against in January 2026, with automated bans of end users' accounts. That
/// path is inert unless the user selects it and accepts a disclosure naming
/// that risk. It must never become reachable without that consent.
enum QuotaReader {

    static var snapshotURL: URL {
        Paths.support.appendingPathComponent("usage-snapshot.json")
    }

    private struct Payload: Decodable {
        struct Limits: Decodable {
            struct Window: Decodable {
                var used_percentage: Double?
                var resets_at: Double?
            }
            var five_hour: Window?
            var seven_day: Window?
            var seven_day_opus: Window?
            var seven_day_sonnet: Window?
        }
        var rate_limits: Limits?
        var session_id: String?
        var captured_at: Double?
    }

    /// Whether Claude Code has written a statusline payload at all.
    ///
    /// Lets the UI tell "nothing has reported yet" apart from "something
    /// reported but carried no plan limits" — the permanent state of an
    /// API-key, Bedrock or Vertex account, which has no plan quota to show.
    static var payloadExists: Bool {
        FileManager.default.fileExists(atPath: snapshotURL.path)
    }

    static func read() -> QuotaSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        guard let limits = payload.rate_limits else { return nil }

        func window(_ w: Payload.Limits.Window?) -> QuotaSnapshot.Window? {
            guard let w, let pct = w.used_percentage else { return nil }
            return .init(usedPercentage: pct,
                         resetsAt: w.resets_at.map { Date(timeIntervalSince1970: $0) })
        }

        var scoped: [String: QuotaSnapshot.Window] = [:]
        if let opus = window(limits.seven_day_opus) { scoped["Opus"] = opus }
        if let sonnet = window(limits.seven_day_sonnet) { scoped["Sonnet"] = sonnet }

        var captured = payload.captured_at.map { Date(timeIntervalSince1970: $0) }
        if captured == nil {
            let attrs = try? FileManager.default.attributesOfItem(atPath: snapshotURL.path)
            captured = attrs?[.modificationDate] as? Date
        }

        return QuotaSnapshot(
            fiveHour: window(limits.five_hour),
            sevenDay: window(limits.seven_day),
            scoped: scoped,
            capturedAt: captured ?? Date(),
            sourceSessionId: payload.session_id
        )
    }
}

/// Per-session token totals, computed from the local transcript.
struct TokenTotals: Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheCreation: Int = 0
    var messages: Int = 0
    var models: Set<String> = []

    var billable: Int { input + output }
    var total: Int { input + output + cacheRead + cacheCreation }

    static func + (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        TokenTotals(input: a.input + b.input,
                    output: a.output + b.output,
                    cacheRead: a.cacheRead + b.cacheRead,
                    cacheCreation: a.cacheCreation + b.cacheCreation,
                    messages: a.messages + b.messages,
                    models: a.models.union(b.models))
    }
}

/// Incremental transcript reader.
///
/// Three correctness rules, each of which a naive implementation gets wrong:
///
/// * **Deduplicate on `(message.id, requestId)`, keeping the largest snapshot.**
///   Streaming writes the same message repeatedly with growing token counts;
///   summing rows double-counts badly.
/// * **Skip `subagents/*.jsonl`.** On this machine 3,329 of 3,490 transcript
///   files are subagent transcripts whose usage is already reflected in the
///   parent session. Counting them inflates totals by ~20x.
/// * **Classify by each record's own `message.model`.** A session can be served
///   by a different model than the one the UI displays.
final class TranscriptScanner {

    /// What one deduplicated message contributed, so a later, larger snapshot
    /// of the same message can replace it rather than add to it.
    private struct Contribution {
        var input = 0, output = 0, cacheRead = 0, cacheCreation = 0
        var sum: Int { input + output + cacheRead + cacheCreation }
    }

    private var offsets: [String: UInt64] = [:]
    private var cache: [String: TokenTotals] = [:]
    /// session path -> (messageId|requestId) -> contribution already counted.
    private var seen: [String: [String: Contribution]] = [:]

    static var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Claude Code encodes a project directory by replacing every character
    /// that is not alphanumeric with `-`.
    ///
    /// Replacing only `/` is wrong and fails silently: a session in
    /// `…/my-project/.claude/worktrees/x` really lives under
    /// `-Users-…-my-project--claude-worktrees-x` (the dot became a dash, hence
    /// the double), and one in `…/My Project` under `…-My-Project`. Under the
    /// narrow rule the file simply isn't found and token counts read zero,
    /// which looks identical to a session that used nothing.
    static func encode(cwd: String) -> String {
        var out = ""
        out.reserveCapacity(cwd.count + 1)
        for character in cwd.unicodeScalars {
            out.append(CharacterSet.alphanumerics.contains(character) ? Character(character) : "-")
        }
        if !out.hasPrefix("-") { out = "-" + out }
        return out
    }

    /// Resolved transcript location, with a self-correcting fallback.
    ///
    /// If the derived directory doesn't hold the file — because the encoding
    /// rule changed upstream again, or the session moved — search the projects
    /// tree once for the session id and remember the answer. That keeps token
    /// counts working through a rule change instead of silently zeroing.
    static func transcriptURL(cwd: String, sessionId: String) -> URL {
        let derived = projectsRoot
            .appendingPathComponent(encode(cwd: cwd), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: derived.path) { return derived }
        if let found = resolvedBySearch(sessionId: sessionId) { return found }
        return derived
    }

    private static var searchCache: [String: URL] = [:]
    private static let searchLock = NSLock()

    private static func resolvedBySearch(sessionId: String) -> URL? {
        searchLock.lock()
        defer { searchLock.unlock() }
        if let cached = searchCache[sessionId] {
            return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
        }
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil) else { return nil }
        for directory in directories {
            let candidate = directory.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                searchCache[sessionId] = candidate
                return candidate
            }
        }
        return nil
    }

    /// Forget state for sessions that are no longer live.
    ///
    /// Without this, `offsets`/`cache`/`seen` grow for the lifetime of the
    /// process — an unbounded leak in an app whose entire purpose is reclaiming
    /// memory — and closed sessions keep contributing to the "tokens across
    /// open sessions" total.
    func prune(keeping live: Set<String>) {
        let keep = Set(live.map { Self.transcriptURL(cwd: "", sessionId: $0).lastPathComponent })
        for key in offsets.keys where !keep.contains(URL(fileURLWithPath: key).lastPathComponent) {
            offsets.removeValue(forKey: key)
            cache.removeValue(forKey: key)
            seen.removeValue(forKey: key)
        }
    }

    /// Totals for one session, reading only bytes appended since last call.
    func totals(cwd: String, sessionId: String) -> TokenTotals {
        let url = Self.transcriptURL(cwd: cwd, sessionId: sessionId)
        let key = url.path

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return cache[key] ?? TokenTotals()
        }
        defer { try? handle.close() }

        let start = offsets[key] ?? 0
        let size = (try? handle.seekToEnd()) ?? 0
        if size < start {
            // File was truncated or replaced — start over.
            offsets[key] = 0
            cache[key] = TokenTotals()
            seen[key] = [:]
            return totals(cwd: cwd, sessionId: sessionId)
        }
        guard size > start else { return cache[key] ?? TokenTotals() }

        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return cache[key] ?? TokenTotals()
        }

        // Only consume through the last complete line; leave a partial tail for
        // the next pass so a mid-write read never loses or corrupts a record.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return cache[key] ?? TokenTotals()
        }
        let consumable = data[data.startIndex...lastNewline]
        offsets[key] = start + UInt64(consumable.count)

        var totals = cache[key] ?? TokenTotals()
        var seenHere = seen[key] ?? [:]

        for line in consumable.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            let model = message["model"] as? String ?? ""
            // Synthetic records carry no real usage.
            if model == "<synthetic>" { continue }

            let contribution = Contribution(
                input: usage["input_tokens"] as? Int ?? 0,
                output: usage["output_tokens"] as? Int ?? 0,
                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                cacheCreation: usage["cache_creation_input_tokens"] as? Int ?? 0
            )
            if contribution.sum == 0 { continue }

            let messageId = message["id"] as? String ?? ""
            let requestId = obj["requestId"] as? String ?? ""
            let dedupeKey = "\(messageId)|\(requestId)"

            if let previous = seenHere[dedupeKey] {
                // Streaming rewrites a message with growing counts. Adopt only
                // the larger snapshot, backing out the one it supersedes.
                guard contribution.sum > previous.sum else { continue }
                totals.input -= previous.input
                totals.output -= previous.output
                totals.cacheRead -= previous.cacheRead
                totals.cacheCreation -= previous.cacheCreation
            } else {
                totals.messages += 1
            }

            totals.input += contribution.input
            totals.output += contribution.output
            totals.cacheRead += contribution.cacheRead
            totals.cacheCreation += contribution.cacheCreation
            if !model.isEmpty {
                totals.models.insert(model.replacingOccurrences(of: "[1m]", with: ""))
            }
            seenHere[dedupeKey] = contribution
        }

        seen[key] = seenHere
        cache[key] = totals
        return totals
    }

}
