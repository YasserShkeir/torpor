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

/// Per-session figures Claude Code computes for us and hands the statusline.
///
/// Kept apart from `QuotaSnapshot` on purpose, and the distinction is the whole
/// point of this type:
///
/// * `rate_limits` is **account-wide**. Whichever session rendered last speaks
///   for the account, so the single shared snapshot is authoritative for it.
/// * `cost` and `context_window` are **per session**. Every session's shim run
///   overwrites that same shared file, so reading cost from it would attribute
///   one session's spend to the whole app — and the number would jump around as
///   different sessions took turns rendering.
///
/// So the shim also drops a copy keyed by session id, and these come from
/// there. Collapsing the two back into one file looks like a simplification and
/// is a correctness regression.
struct SessionUsage: Equatable {
    var sessionId: String
    /// What Claude Code says this session has cost, in US dollars. Exact and
    /// already computed — no local price table to maintain, no fast-mode
    /// multiplier, no cache-write ratio, nothing to go stale when prices move.
    var costUSD: Double?
    /// Context window occupancy, 0-100, as the server computes it.
    var contextUsedPercentage: Double?
    /// Tokens resident in the context window. `total_input_tokens` already
    /// includes the cache reads and creations — on a live payload it equals
    /// `current_usage`'s four components summed — so the resident count is
    /// just the two totals added, not a fifth number to reconcile.
    var contextTokens: Int?
    var contextWindowSize: Int?
    /// Effort level the session is running at — "low", "medium", "high",
    /// "xhigh", "max" — as Claude Code reports it.
    ///
    /// Per session, like cost, and for a sharper reason than the others: the
    /// `/effort` slash command changes it for one session mid-conversation, so
    /// the account-wide snapshot would report whichever session drew its
    /// statusline last. It is also the *only* way to learn the level at all —
    /// a `/effort` setting never reaches argv, so hibernate has nothing to
    /// capture from the process.
    var effortLevel: String?
    var capturedAt: Date
}

/// Reads the usage snapshots written by Torpor's statusline shim.
///
/// This is deliberately the *only* quota path. Claude Code hands the statusline
/// a JSON payload on stdin containing `rate_limits.five_hour.used_percentage`,
/// `rate_limits.seven_day.used_percentage` and their `resets_at` timestamps —
/// documented, server-computed, and already in the user's possession. The same
/// payload also carries `cost.total_cost_usd`, `context_window` and `model`,
/// which the shim extracts alongside them.
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

    /// One file per session id, written by the shim next to the shared
    /// snapshot. See `SessionUsage` for why this exists.
    static var sessionsDirectory: URL {
        Paths.support.appendingPathComponent("usage-sessions", isDirectory: true)
    }

    /// Whether Claude Code has written a statusline payload at all.
    ///
    /// Lets the UI tell "nothing has reported yet" apart from "something
    /// reported but carried no plan limits" — the permanent state of an
    /// API-key, Bedrock or Vertex account, which has no plan quota to show.
    static var payloadExists: Bool {
        FileManager.default.fileExists(atPath: snapshotURL.path)
    }

    /// Read as loose dictionaries rather than through `Codable`.
    ///
    /// The payload is undocumented and has gained fields between Claude Code
    /// releases; one key changing shape must cost us that key, not the whole
    /// decode. Every lookup below is therefore an optional cast that degrades
    /// to nil on its own.
    private static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// JSON numbers arrive as `NSNumber` and the payload mixes forms — `44`
    /// for a percentage, `206.73778174999995` for a cost — so a same-type cast
    /// to `Double` or `Int` would drop whichever form it was not expecting.
    private static func number(_ raw: Any?) -> Double? { (raw as? NSNumber)?.doubleValue }

    /// Bounded, because `Int(someDouble)` traps rather than overflows and this
    /// file is parsed from whatever a future Claude Code writes.
    private static func integer(_ raw: Any?) -> Int? {
        guard let value = number(raw), value.magnitude < 1e15 else { return nil }
        return Int(value)
    }

    private static func window(_ raw: Any?) -> QuotaSnapshot.Window? {
        guard let values = raw as? [String: Any],
              let percentage = number(values["used_percentage"]) else { return nil }
        return .init(usedPercentage: percentage,
                     resetsAt: number(values["resets_at"])
                        .map { Date(timeIntervalSince1970: $0) })
    }

    /// When the shim last wrote a file. The payload carries no capture time of
    /// its own, so the modification date is it.
    private static func writtenAt(_ url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    /// Account-wide quota, from the shared snapshot.
    ///
    /// The newest write wins by construction: every session overwrites the same
    /// path, and `rate_limits` is account-wide, so whoever rendered last is
    /// telling the truth about the account regardless of which session it was.
    static func read() -> QuotaSnapshot? {
        guard let payload = object(at: snapshotURL),
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }

        var scoped: [String: QuotaSnapshot.Window] = [:]
        if let opus = window(limits["seven_day_opus"]) { scoped["Opus"] = opus }
        if let sonnet = window(limits["seven_day_sonnet"]) { scoped["Sonnet"] = sonnet }

        let captured = number(payload["captured_at"]).map { Date(timeIntervalSince1970: $0) }
            ?? writtenAt(snapshotURL)

        return QuotaSnapshot(
            fiveHour: window(limits["five_hour"]),
            sevenDay: window(limits["seven_day"]),
            scoped: scoped,
            capturedAt: captured ?? Date(),
            sourceSessionId: payload["session_id"] as? String
        )
    }

    /// Per-session cost and context, keyed by session id.
    ///
    /// Also the only thing that ever deletes these files, so it prunes to the
    /// sessions still running. An empty `live` set is treated as "we could not
    /// enumerate sessions this pass" rather than "nothing is running": deleting
    /// everything on a failed probe would throw away cost figures no later
    /// render can reconstruct, since `total_cost_usd` only reappears while the
    /// session that owns it is still alive.
    static func sessionUsage(live: Set<String>) -> [String: SessionUsage] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory, includingPropertiesForKeys: nil)
        else { return [:] }

        var out: [String: SessionUsage] = [:]
        for file in files where file.pathExtension == "json" {
            let sessionId = file.deletingPathExtension().lastPathComponent
            guard live.contains(sessionId) else {
                if !live.isEmpty { try? FileManager.default.removeItem(at: file) }
                continue
            }
            if let usage = usage(at: file, sessionId: sessionId) { out[sessionId] = usage }
        }
        return out
    }

    /// One session's figures, without the pruning pass.
    ///
    /// Hibernate needs the effort level for exactly one session, at the moment
    /// it captures the record, and must not be the thing that deletes another
    /// session's cost file as a side effect of asking.
    static func sessionUsage(sessionId: String) -> SessionUsage? {
        // The id is built into a path here, and unlike `sessionUsage(live:)` —
        // which reads ids back off filenames — it arrives from the registry,
        // where every field is undocumented and optional. A `..` in it would
        // walk out of the directory. The shim strips the same character class
        // on the way in; this is the matching check on the way out.
        guard !sessionId.isEmpty,
              sessionId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return usage(at: sessionsDirectory.appendingPathComponent("\(sessionId).json"),
                     sessionId: sessionId)
    }

    private static func usage(at file: URL, sessionId: String) -> SessionUsage? {
        guard let payload = object(at: file) else { return nil }
        let cost = payload["cost"] as? [String: Any] ?? [:]
        let context = payload["context_window"] as? [String: Any] ?? [:]
        let effort = payload["effort"] as? [String: Any] ?? [:]
        let input = integer(context["total_input_tokens"])
        let output = integer(context["total_output_tokens"])
        return SessionUsage(
            sessionId: sessionId,
            costUSD: number(cost["total_cost_usd"]),
            contextUsedPercentage: number(context["used_percentage"]),
            contextTokens: (input == nil && output == nil)
                ? nil : (input ?? 0) + (output ?? 0),
            contextWindowSize: integer(context["context_window_size"]),
            effortLevel: (effort["level"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            capturedAt: writtenAt(file) ?? Date()
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
    /// Tokens per model. The scanner already reads `message.model` on every
    /// record to build `models`; keeping the counts costs nothing and is the
    /// only per-model figure available without a server.
    ///
    /// Nothing renders it since the model split was removed, but the scanner is
    /// the source of truth for it, so it is kept correct rather than allowed to
    /// drift — a bucket that can go negative is a bug waiting for its reader.
    var byModel: [String: Int] = [:]
    /// Of `total`, how much came from subagent transcripts rather than the
    /// parent conversation.
    var subagentTokens: Int = 0

    var billable: Int { input + output }
    var total: Int { input + output + cacheRead + cacheCreation }

    static func + (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        TokenTotals(input: a.input + b.input,
                    output: a.output + b.output,
                    cacheRead: a.cacheRead + b.cacheRead,
                    cacheCreation: a.cacheCreation + b.cacheCreation,
                    messages: a.messages + b.messages,
                    models: a.models.union(b.models),
                    byModel: a.byModel.merging(b.byModel, uniquingKeysWith: +),
                    subagentTokens: a.subagentTokens + b.subagentTokens)
    }
}

/// Incremental transcript reader.
///
/// Three correctness rules, each of which a naive implementation gets wrong:
///
/// * **Deduplicate on `(message.id, requestId)`, keeping the largest snapshot.**
///   Streaming writes the same message repeatedly with growing token counts;
///   summing rows double-counts badly. Records carrying neither fall back to
///   their own `uuid` — see `dedupeKey`.
/// * **Read `subagents/**/*.jsonl` too.** An earlier version skipped them,
///   assuming their usage was already counted in the parent. It isn't. Measured
///   on one real session: parent 252.1M tokens, subagents 91.1M, and the
///   `(message.id, requestId)` sets intersect in exactly **zero** places. They
///   are additive, not duplicated. Worse, some models appear *only* in subagent
///   transcripts — `claude-haiku-4-5` never shows up in a parent — so skipping
///   them hid a whole model from the split. The "~20x inflation" that motivated
///   the skip came from scanning the projects tree unscoped, which picks up
///   every other session's subagents as well.
/// * **Classify by each record's own `message.model`.** A session can be served
///   by a different model than the one the UI displays.
/// An actor, not a class, so the parse runs off the main thread. The scan is
/// incremental once warm, but the first pass after launch reads every open
/// session's transcript from byte zero — including its `subagents/` tree, which
/// on the development machine was 407 files and 159 MB. That is not work the UI
/// can be made to wait on.
actor TranscriptScanner {

    /// What one deduplicated message contributed, so a later, larger snapshot
    /// of the same message can replace it rather than add to it.
    private struct Contribution {
        /// Which `byModel` bucket this landed in. Without it the back-out below
        /// subtracts from whichever model the *newer* record names, and a retry
        /// served by a different model drives the wrong bucket negative —
        /// 12 real occurrences in this machine's transcripts.
        var model = ""
        var input = 0, output = 0, cacheRead = 0, cacheCreation = 0
        var sum: Int { input + output + cacheRead + cacheCreation }
    }

    private var offsets: [String: UInt64] = [:]
    private var cache: [String: TokenTotals] = [:]
    /// transcript path -> dedupe key -> contribution already counted.
    private var seen: [String: [String: Contribution]] = [:]
    /// Every transcript path each session touched on its last scan.
    ///
    /// The keep-set for `prune` is built from these rather than from session
    /// ids, because a session's files are not all named after it.
    private var pathsBySession: [String: Set<String>] = [:]

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

    /// Every transcript belonging to a session: the parent, plus each subagent
    /// transcript under `<sessionId>/subagents/`. Scoped to this session, so it
    /// never picks up another session's subagents.
    static func transcriptURLs(cwd: String, sessionId: String) -> [URL] {
        let parent = transcriptURL(cwd: cwd, sessionId: sessionId)
        var urls = [parent]
        let subagents = parent
            .deletingPathExtension()
            .appendingPathComponent("subagents", isDirectory: true)
        if let walker = FileManager.default.enumerator(
            at: subagents, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                urls.append(url)
            }
        }
        return urls
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

    /// Drop cached lookups for sessions that have ended.
    ///
    /// `searchCache` is `static` — it outlives every scanner instance, so
    /// nothing else would ever release it.
    private static func forgetSearches(keeping live: Set<String>) {
        searchLock.lock()
        defer { searchLock.unlock() }
        searchCache = searchCache.filter { live.contains($0.key) }
    }

    /// Dedupe identity for one record.
    ///
    /// Falls back to the record's own `uuid` when a record carries neither
    /// `message.id` nor `requestId`: those are real, separately charged
    /// responses, and collapsing them all onto the key `"|"` kept only the
    /// single largest of them for the whole file. Every record in this
    /// machine's `~/.claude/projects` carries a `uuid`, and the last resort — a
    /// fresh identity — can only over-count by failing to dedupe, never
    /// under-count by merging two genuinely separate charges.
    private static func dedupeKey(record: [String: Any], message: [String: Any]) -> String {
        let messageId = message["id"] as? String ?? ""
        let requestId = record["requestId"] as? String ?? ""
        if messageId.isEmpty && requestId.isEmpty {
            return "uuid:" + (record["uuid"] as? String ?? UUID().uuidString)
        }
        return "\(messageId)|\(requestId)"
    }

    /// Forget state for sessions that are no longer live.
    ///
    /// Without this, `offsets`/`cache`/`seen` grow for the lifetime of the
    /// process — an unbounded leak in an app whose entire purpose is reclaiming
    /// memory — and closed sessions keep contributing to the "tokens across
    /// open sessions" total.
    ///
    /// The keep-set is the set of paths the live sessions actually touched, not
    /// `<sessionId>.jsonl`. Subagent transcripts are named `agent-<hex>.jsonl`
    /// and `journal.jsonl` under `<sessionId>/subagents/**`, so a keep-set built
    /// from session ids matched none of them and every prune wiped their scan
    /// state — after which the next poll re-read every subagent file from byte
    /// zero, forever.
    func prune(keeping live: Set<String>) {
        // An empty set is far more often a failed registry read than a machine
        // with nothing running — `registryLooksBroken` exists because that read
        // can fail — and `allSatisfy` is vacuously true on it, so without this
        // the guard below waves through an empty keep-set and drops everything.
        guard !live.isEmpty else { return }
        pathsBySession = pathsBySession.filter { live.contains($0.key) }
        // A pass that did not visit every live session has an incomplete
        // keep-set, and pruning against it would drop offsets we are about to
        // need. Skipping one prune costs nothing; a wrong one costs a full
        // re-read of the corpus.
        guard live.allSatisfy({ pathsBySession[$0] != nil }) else { return }
        let keep = pathsBySession.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for key in offsets.keys where !keep.contains(key) {
            offsets.removeValue(forKey: key)
            cache.removeValue(forKey: key)
            seen.removeValue(forKey: key)
        }
        Self.forgetSearches(keeping: live)
    }

    /// Totals for one session, across its parent transcript and every subagent
    /// transcript, reading only bytes appended since the last call.
    ///
    /// Per-file state is keyed by full path, so adding files needs no other
    /// change. Subagent transcripts are counted separately as well, because
    /// "how much of this went to subagents" is worth knowing on its own.
    /// Cancellable, and it has to be.
    ///
    /// This reads every transcript a session owns, which on this machine is
    /// 400-odd files across 159 MB, with synchronous FileHandle I/O. The caller
    /// cancels the previous scan whenever a newer poll supersedes it — but
    /// cancelling a Task does nothing to work already running inside an actor,
    /// and without a check in this loop the cancelled scan ran to completion
    /// anyway while the next one queued behind it. Every poll then added more
    /// than it withdrew: after a day the process was on 64 threads at 100% CPU
    /// with the main actor starved, so the menu bar item stopped responding to
    /// clicks entirely.
    ///
    /// Checked per file rather than per session, because one session's subagent
    /// tree is itself minutes of work.
    func totals(cwd: String, sessionId: String) -> TokenTotals {
        var combined = TokenTotals()
        let parent = Self.transcriptURL(cwd: cwd, sessionId: sessionId)
        let urls = Self.transcriptURLs(cwd: cwd, sessionId: sessionId)
        pathsBySession[sessionId] = Set(urls.map(\.path))
        for url in urls {
            if Task.isCancelled { return combined }
            var part = totals(at: url)
            if url != parent { part.subagentTokens = part.total }
            combined = combined + part
        }
        return combined
    }

    private func totals(at url: URL) -> TokenTotals {
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
            return totals(at: url)
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
            let name = model.isEmpty ? "" : model.replacingOccurrences(of: "[1m]", with: "")

            // Only the top-level counts. `message.usage.iterations[]` repeats
            // them per iteration, so summing that array double-counts.
            let contribution = Contribution(
                model: name,
                input: usage["input_tokens"] as? Int ?? 0,
                output: usage["output_tokens"] as? Int ?? 0,
                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                cacheCreation: usage["cache_creation_input_tokens"] as? Int ?? 0
            )
            if contribution.sum == 0 { continue }

            let dedupeKey = Self.dedupeKey(record: obj, message: message)

            if let previous = seenHere[dedupeKey] {
                // Streaming rewrites a message with growing counts. Adopt only
                // the larger snapshot, backing out the one it supersedes — from
                // the bucket it was actually filed under, which a retry served
                // by a different model makes different from this record's.
                guard contribution.sum > previous.sum else { continue }
                totals.input -= previous.input
                totals.output -= previous.output
                totals.cacheRead -= previous.cacheRead
                totals.cacheCreation -= previous.cacheCreation
                if !previous.model.isEmpty {
                    totals.byModel[previous.model, default: 0] -= previous.sum
                }
            } else {
                totals.messages += 1
            }

            totals.input += contribution.input
            totals.output += contribution.output
            totals.cacheRead += contribution.cacheRead
            totals.cacheCreation += contribution.cacheCreation
            if !name.isEmpty {
                totals.models.insert(name)
                totals.byModel[name, default: 0] += contribution.sum
            }
            seenHere[dedupeKey] = contribution
        }

        seen[key] = seenHere
        cache[key] = totals
        return totals
    }

}
