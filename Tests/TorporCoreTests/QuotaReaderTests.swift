import Foundation
import Testing
@testable import Torpor

/// The statusline payload is undocumented, written by a program Torpor does not
/// ship, and has gained and reshaped keys between Claude Code releases. So
/// tolerance *is* the contract: one key changing shape has to cost that key and
/// nothing else, and no input may take the reader down.
///
/// `.serialized` because both files these tests write live at one fixed path
/// under the shared throwaway home — see `testHome` in `Fixtures.swift`. Every
/// other suite keeps out of the way by owning a unique path; this one cannot.
@Suite(.serialized) struct QuotaReaderTests {

    // MARK: - Fixtures

    /// The live payload, field for field, off this machine's
    /// `usage-snapshot.json` — plus the two model-scoped weekly rows the reader
    /// also understands, which only some accounts are sent.
    private func payload(sessionId: String = "521e9fa5-6cc4-4f46-911b-29dcd7157bad",
                         fiveHourPercentage: Any = 73) -> [String: Any] {
        [
            "session_id": sessionId,
            "rate_limits": [
                "five_hour": ["used_percentage": fiveHourPercentage,
                              "resets_at": 1785334200],
                "seven_day": ["used_percentage": 80, "resets_at": 1785628800],
                "seven_day_opus": ["used_percentage": 41, "resets_at": 1785628800],
                "seven_day_sonnet": ["used_percentage": 12, "resets_at": 1785628800],
            ],
            "cost": ["total_cost_usd": 282.0996187500002],
            "context_window": [
                "used_percentage": 16,
                "context_window_size": 1000000,
                "total_input_tokens": 163930,
                "total_output_tokens": 163,
            ],
            "model": ["id": "claude-opus-5[1m]", "display_name": "Opus 5 (1M context)"],
        ]
    }

    /// Clears both paths the reader owns. Not a teardown — a setup, because a
    /// leftover file from the previous test is the failure mode that makes a
    /// serialized suite lie.
    private func reset() {
        _ = testHome
        try? FileManager.default.removeItem(at: QuotaReader.snapshotURL)
        try? FileManager.default.removeItem(at: QuotaReader.sessionsDirectory)
    }

    private func writeSnapshot(_ object: [String: Any]) throws {
        try write(JSONSerialization.data(withJSONObject: object), to: QuotaReader.snapshotURL)
    }

    private func writeSnapshot(raw: String) throws {
        try write(Data(raw.utf8), to: QuotaReader.snapshotURL)
    }

    /// The per-session copy the shim drops alongside the shared snapshot. It is
    /// the same payload; only which fields are read from it differs.
    private func writeSessionFile(_ object: [String: Any], for sessionId: String) throws {
        try write(JSONSerialization.data(withJSONObject: object),
                  to: QuotaReader.sessionsDirectory.appendingPathComponent("\(sessionId).json"))
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    // MARK: - The happy path

    @Test func aFullPayloadParsesEveryFieldTheUIRendersFromIt() throws {
        reset()
        let sessionId = "521e9fa5-6cc4-4f46-911b-29dcd7157bad"
        try writeSnapshot(payload())
        try writeSessionFile(payload(), for: sessionId)

        // Account-wide, from the shared snapshot.
        let quota = try #require(QuotaReader.read())
        #expect(quota.fiveHour?.usedPercentage == 73)
        #expect(quota.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1785334200))
        #expect(quota.sevenDay?.usedPercentage == 80)
        #expect(quota.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1785628800))
        #expect(quota.scoped["Opus"]?.usedPercentage == 41)
        #expect(quota.scoped["Sonnet"]?.usedPercentage == 12)
        #expect(quota.sourceSessionId == sessionId)
        // The payload carries no capture time, so the file's write time is it.
        #expect(quota.age < 60)
        #expect(quota.isStale == false)

        // Per session, from the session's own copy. Reading these from the
        // shared snapshot instead would attribute one session's spend to the
        // whole app, which is why there are two files.
        let usage = try #require(QuotaReader.sessionUsage(live: [sessionId])[sessionId])
        #expect(usage.costUSD == 282.0996187500002)
        #expect(usage.contextUsedPercentage == 16)
        #expect(usage.contextWindowSize == 1_000_000)
        #expect(usage.contextTokens == 164_093, "input plus output, not a fifth number")
    }

    /// An explicit `captured_at` wins over the file's modification date.
    @Test func anExplicitCaptureTimeIsPreferredOverTheFilesWriteTime() throws {
        reset()
        var object = payload()
        object["captured_at"] = 1_785_300_000
        try writeSnapshot(object)

        let quota = try #require(QuotaReader.read())
        #expect(quota.capturedAt == Date(timeIntervalSince1970: 1_785_300_000))
        #expect(quota.isStale, "a capture that old is not current quota")
    }

    // MARK: - Number shapes

    /// Real payloads carry both forms of the same field: a bare `70` from one
    /// Claude Code build, `28.999999999999996` from another. A same-type cast to
    /// `Double` or to `Int` drops whichever it was not expecting, and the loss
    /// is silent — the window simply stops rendering.
    @Test(arguments: [
        (70 as Any, 70.0),
        (28.999999999999996 as Any, 28.999999999999996),
        (0 as Any, 0.0),
        (100 as Any, 100.0),
        (99.5 as Any, 99.5),
        (1e-9 as Any, 1e-9),
    ])
    func usedPercentageParsesAsBothAnIntegerAndAFullPrecisionDouble(
        _ testCase: (Any, Double)) throws {
        reset()
        try writeSnapshot(payload(fiveHourPercentage: testCase.0))
        let quota = try #require(QuotaReader.read())
        #expect(quota.fiveHour?.usedPercentage == testCase.1)
    }

    /// `Int(someDouble)` traps rather than overflowing, and this file is parsed
    /// from whatever a future Claude Code writes. Out-of-range integers have to
    /// degrade to nil, not take the app down.
    @Test func anAbsurdIntegerDegradesToNilRatherThanTrapping() throws {
        reset()
        let sessionId = "e0e0e0e0-0000-0000-0000-000000000000"
        var object = payload()
        object["context_window"] = [
            "used_percentage": 16,
            "context_window_size": 1e18,
            "total_input_tokens": 1e300,
            "total_output_tokens": 163,
        ]
        try writeSessionFile(object, for: sessionId)

        let usage = try #require(QuotaReader.sessionUsage(live: [sessionId])[sessionId])
        #expect(usage.contextWindowSize == nil)
        #expect(usage.contextTokens == 163, "the unreadable half is dropped, not the pair")
        #expect(usage.contextUsedPercentage == 16)
    }

    // MARK: - Degradation

    /// Dropped one at a time and cumulatively: `cost`, then `context_window`,
    /// then `model`. Each loss costs that field and leaves `rate_limits`
    /// readable, which is the whole reason this is parsed as dictionaries rather
    /// than through `Codable`. `model` is still written by the shim but nothing
    /// reads it, so dropping it must cost nothing at all.
    @Test(arguments: [["cost"],
                      ["cost", "context_window"],
                      ["cost", "context_window", "model"],
                      ["context_window"],
                      ["model"],
                      ["session_id"]])
    func aMissingKeyCostsThatKeyAndNothingElse(_ dropped: [String]) throws {
        reset()
        let sessionId = "d0d0d0d0-0000-0000-0000-000000000000"
        var object = payload(sessionId: sessionId)
        for key in dropped { object.removeValue(forKey: key) }
        try writeSnapshot(object)
        try writeSessionFile(object, for: sessionId)

        let quota = try #require(QuotaReader.read(), "rate_limits stopped parsing over \(dropped)")
        #expect(quota.fiveHour?.usedPercentage == 73, "\(dropped)")
        #expect(quota.sevenDay?.usedPercentage == 80, "\(dropped)")
        #expect(quota.sourceSessionId == (dropped.contains("session_id") ? nil : sessionId))

        let usage = try #require(QuotaReader.sessionUsage(live: [sessionId])[sessionId])
        #expect(usage.costUSD == (dropped.contains("cost") ? nil : 282.0996187500002))
        #expect(usage.contextUsedPercentage
                == (dropped.contains("context_window") ? nil : 16))
        #expect(usage.contextTokens == (dropped.contains("context_window") ? nil : 164_093))
    }

    /// A window missing its percentage is not a window. Losing one must not cost
    /// the other, or a single reshaped key blanks the whole readout.
    @Test func oneUnreadableWindowDoesNotCostTheOther() throws {
        reset()
        try writeSnapshot([
            "rate_limits": [
                "five_hour": ["resets_at": 1785334200],
                "seven_day": ["used_percentage": 80, "resets_at": 1785628800],
            ],
        ])
        let quota = try #require(QuotaReader.read())
        #expect(quota.fiveHour == nil)
        #expect(quota.sevenDay?.usedPercentage == 80)

        // And a window with no reset time still reports its percentage.
        reset()
        try writeSnapshot(["rate_limits": ["five_hour": ["used_percentage": 73]]])
        let second = try #require(QuotaReader.read())
        #expect(second.fiveHour?.usedPercentage == 73)
        #expect(second.fiveHour?.resetsAt == nil)
        #expect(second.sevenDay == nil)
        #expect(second.scoped.isEmpty)

        // A percentage that arrives as a string — the shape change this reader
        // exists to survive — costs that window and not the decode.
        reset()
        try writeSnapshot(["rate_limits": ["five_hour": "73%",
                                          "seven_day": ["used_percentage": 80]]])
        let third = try #require(QuotaReader.read())
        #expect(third.fiveHour == nil)
        #expect(third.sevenDay?.usedPercentage == 80)
    }

    /// The permanent state of an API-key, Bedrock or Vertex account: the shim
    /// runs and writes a payload, but there is no plan quota in it to show. The
    /// UI has to tell that apart from "nothing has reported yet", because one is
    /// a fact about the account and the other is a setup step.
    @Test func aPayloadWithNoRateLimitsYieldsNoQuotaButStillCountsAsAPayload() throws {
        reset()
        #expect(QuotaReader.payloadExists == false, "nothing has ever been written")
        #expect(QuotaReader.read() == nil)

        var object = payload()
        object.removeValue(forKey: "rate_limits")
        try writeSnapshot(object)

        #expect(QuotaReader.payloadExists, "the shim ran; it just carried no plan limits")
        #expect(QuotaReader.read() == nil)

        // And an empty one, which is what an account with no windows at all
        // actually writes.
        try writeSnapshot(["session_id": "x", "rate_limits": [:]])
        #expect(QuotaReader.payloadExists)
        let quota = try #require(QuotaReader.read())
        #expect(quota.fiveHour == nil)
        #expect(quota.sevenDay == nil)
        #expect(quota.scoped.isEmpty)
    }

    /// The shim writes this file from POSIX sh and awk while Claude Code is
    /// rendering. Torpor reads it on a five-second timer. A half-written or
    /// reshaped file is not an exceptional case, it is a scheduled one.
    @Test(arguments: [
        "",
        "{",
        #"{"rate_limits": {"five_hour": {"used_perce"#,
        "not json at all",
        "[1, 2, 3]",
        #""a bare string""#,
        "null",
        #"{"rate_limits": "five_hour"}"#,
        #"{"rate_limits": [1, 2]}"#,
        "\u{0}\u{1}\u{2}",
    ])
    func garbageOrTruncatedJSONReturnsNilRatherThanTrapping(_ raw: String) throws {
        reset()
        try writeSnapshot(raw: raw)
        #expect(QuotaReader.read() == nil, "parsed something out of \(raw.debugDescription)")
        #expect(QuotaReader.payloadExists, "the file is there; it is its contents that are not")
    }

    /// One unreadable session file must not cost the readable ones — they are
    /// separate files precisely so one session cannot spoil another's figures.
    @Test func oneUnreadableSessionFileDoesNotCostTheOthers() throws {
        reset()
        let good = "aaaaaaaa-0000-0000-0000-000000000000"
        let bad = "bbbbbbbb-0000-0000-0000-000000000000"
        try writeSessionFile(payload(), for: good)
        try write(Data("{\"cost\": ".utf8),
                  to: QuotaReader.sessionsDirectory.appendingPathComponent("\(bad).json"))

        let usage = QuotaReader.sessionUsage(live: [good, bad])
        #expect(usage[good]?.costUSD == 282.0996187500002)
        #expect(usage[bad] == nil)
    }

    /// `sessionUsage` is the only thing that ever deletes these files, and
    /// `total_cost_usd` only reappears while the session that owns it is alive —
    /// so a failed session probe, which arrives as an empty `live`, must delete
    /// nothing. Deleting on it throws away a figure no later render can rebuild.
    @Test func anEmptyLiveSetDeletesNothing() throws {
        reset()
        let sessionId = "cccccccc-0000-0000-0000-000000000000"
        let file = QuotaReader.sessionsDirectory.appendingPathComponent("\(sessionId).json")
        try writeSessionFile(payload(), for: sessionId)

        #expect(QuotaReader.sessionUsage(live: []).isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path),
                "an empty live set means 'could not enumerate', not 'nothing is running'")

        // A non-empty set that omits the session does mean it has ended.
        _ = QuotaReader.sessionUsage(live: ["dddddddd-0000-0000-0000-000000000000"])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// `effort.level` is per session for a sharper reason than cost is: the
    /// `/effort` command changes it for one conversation, so reading it from
    /// the shared snapshot would report whichever session drew its statusline
    /// last — and hibernate would then revive a session at someone else's
    /// setting.
    @Test func effortIsReadFromTheSessionsOwnFile() throws {
        reset()
        let mine = "eeeeeeee-0000-0000-0000-000000000000"
        let theirs = "ffffffff-0000-0000-0000-000000000000"
        var high = payload(sessionId: mine)
        high["effort"] = ["level": "xhigh"]
        var low = payload(sessionId: theirs)
        low["effort"] = ["level": "low"]
        try writeSessionFile(high, for: mine)
        try writeSessionFile(low, for: theirs)

        let usage = QuotaReader.sessionUsage(live: [mine, theirs])
        #expect(usage[mine]?.effortLevel == "xhigh")
        #expect(usage[theirs]?.effortLevel == "low")
    }

    /// The single-session read hibernate uses. It must answer for one session
    /// without pruning — capture happens while other sessions are still live,
    /// and deleting their cost files as a side effect of asking about this one
    /// would throw away figures no later render can rebuild.
    @Test func theSingleSessionReadDeletesNothing() throws {
        reset()
        let mine = "aaaaaaaa-1111-0000-0000-000000000000"
        let other = "bbbbbbbb-1111-0000-0000-000000000000"
        var object = payload(sessionId: mine)
        object["effort"] = ["level": "max"]
        try writeSessionFile(object, for: mine)
        try writeSessionFile(payload(sessionId: other), for: other)

        #expect(QuotaReader.sessionUsage(sessionId: mine)?.effortLevel == "max")
        #expect(QuotaReader.sessionUsage(sessionId: other)?.effortLevel == nil,
                "absent effort is nil, not a guess")
        for id in [mine, other] {
            #expect(FileManager.default.fileExists(
                atPath: QuotaReader.sessionsDirectory
                    .appendingPathComponent("\(id).json").path))
        }
        // A session that never rendered has no file, which is not an error.
        #expect(QuotaReader.sessionUsage(sessionId: "no-such-session") == nil)
    }

    /// The id is built into a path, and it comes from the registry — an
    /// undocumented file where every field is optional and none is validated.
    /// `sessionUsage(live:)` reads its ids back off filenames and never had
    /// this exposure; the single-session read does.
    @Test(arguments: ["../../../../etc/passwd", "a/b", "", "..", "a b"])
    func aSessionIdThatIsNotOneReadsNothing(_ id: String) {
        #expect(QuotaReader.sessionUsage(sessionId: id) == nil)
    }
}
