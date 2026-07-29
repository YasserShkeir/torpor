import Foundation
import Testing
@testable import Torpor

/// The scanner is the one component that reads an unbounded amount of disk on a
/// five-second timer, and the two ways it goes wrong are expensive in different
/// currencies: losing its incremental state burns CPU forever, and mis-counting
/// a deduplicated message quietly reports the wrong spend.
///
/// Every transcript below is written into the throwaway home `Fixtures.swift`
/// installs — see `testHome`. Nothing here reads the real `~/.claude`.
@Suite struct TranscriptScannerTests {

    // MARK: - prune

    /// Rewrites a transcript with content of exactly the same byte length.
    ///
    /// That is what makes "did the scanner do any work?" observable from
    /// outside: `offsets` is private, but with the offset intact the file has
    /// no bytes past it, so the scan short-circuits to its cache and reports the
    /// *old* numbers. Only a scan that started again from byte zero can report
    /// the new ones.
    private func rewriteSameLength(_ sandbox: TranscriptSandbox,
                                   _ url: URL,
                                   _ lines: [String]) throws {
        let before = try Data(contentsOf: url).count
        try sandbox.write(lines, to: url)
        let after = try Data(contentsOf: url).count
        #expect(before == after, "the swap has to be length-preserving to prove anything")
    }

    /// A session with the subagent tree the real one has: some transcripts
    /// directly under `subagents/`, some under `subagents/workflows/wf_<hex>/`,
    /// and a `journal.jsonl` that carries no usage at all.
    private func liveSession() throws -> (TranscriptSandbox, flat: URL, nested: URL) {
        let sandbox = try TranscriptSandbox()
        let flat = sandbox.subagent("agent-a3c1a1d4a05238c8c.jsonl")
        let nested = sandbox.subagent("workflows/wf_36b5f63f-689/agent-ae733538688ebb3fa.jsonl")
        try sandbox.write([usageLine(messageId: "msg_parent", requestId: "req_parent",
                                     uuid: "u-parent", input: 5000)], to: sandbox.parent)
        try sandbox.write([usageLine(messageId: "msg_flat", requestId: "req_flat",
                                     uuid: "u-flat", input: 1000)], to: flat)
        try sandbox.write([usageLine(messageId: "msg_nested", requestId: "req_nested",
                                     uuid: "u-nested", input: 3000)], to: nested)
        try sandbox.write([nonUsageLine()], to: sandbox.subagent("journal.jsonl"))
        return (sandbox, flat, nested)
    }

    /// Same tree, same message ids, different — but same-width — token counts.
    private func swappedCounts(_ sandbox: TranscriptSandbox,
                               flat: URL, nested: URL) throws {
        try rewriteSameLength(sandbox, flat,
                              [usageLine(messageId: "msg_flat", requestId: "req_flat",
                                         uuid: "u-flat", input: 2000)])
        try rewriteSameLength(sandbox, nested,
                              [usageLine(messageId: "msg_nested", requestId: "req_nested",
                                         uuid: "u-nested", input: 4000)])
    }

    /// The regression that cost 94% CPU for an hour and three quarters.
    ///
    /// The keep-set used to be built from `"<sessionId>.jsonl"` basenames, but a
    /// session's subagent transcripts are named `agent-<hex>.jsonl` and
    /// `journal.jsonl` under `<sessionId>/subagents/**`. No subagent path ever
    /// matched, so every prune discarded their offsets — and the next poll, five
    /// seconds later, re-read the entire subagent corpus from byte zero. On this
    /// machine that was 407 files and 159 MB, forever.
    @Test func subagentScanStateSurvivesAPruneOfAStillLiveSession() async throws {
        let (sandbox, flat, nested) = try liveSession()
        let scanner = TranscriptScanner()

        let first = await sandbox.totals(scanner)
        #expect(first.total == 9000)
        #expect(first.subagentTokens == 4000, "the two subagent files, and not the parent")
        #expect(first.messages == 3, "journal.jsonl carries no usage and adds none")

        await scanner.prune(keeping: [sandbox.sessionId])
        try swappedCounts(sandbox, flat: flat, nested: nested)

        // Unchanged: the offsets survived, so the second pass opened the
        // subagent files, found nothing past its mark and read no bytes.
        let second = await sandbox.totals(scanner)
        #expect(second == first, "the prune wiped the subagent offsets")
    }

    /// The complementary half. A keep-set that never drops anything is not a
    /// prune at all, and the state it holds is an unbounded leak in an app whose
    /// entire purpose is reclaiming memory.
    @Test func aPruneDropsTheStateOfASessionThatHasEnded() async throws {
        let (ending, endingFlat, endingNested) = try liveSession()
        let (staying, stayingFlat, stayingNested) = try liveSession()
        let scanner = TranscriptScanner()

        _ = await ending.totals(scanner)
        let stayingFirst = await staying.totals(scanner)

        // Both sessions were scanned this pass, so the keep-set is complete and
        // the prune is allowed to act on it.
        await scanner.prune(keeping: [staying.sessionId])

        try swappedCounts(ending, flat: endingFlat, nested: endingNested)
        try swappedCounts(staying, flat: stayingFlat, nested: stayingNested)

        let endingAfter = await ending.totals(scanner)
        #expect(endingAfter.total == 11000, "the ended session's state was not dropped")
        #expect(endingAfter.subagentTokens == 6000)

        let stayingAfter = await staying.totals(scanner)
        #expect(stayingAfter == stayingFirst, "a live session lost its state to another's prune")
    }

    /// A pass that did not reach every live session has an incomplete keep-set,
    /// and pruning against it drops offsets that are about to be needed.
    /// Skipping one prune costs nothing; a wrong one costs a full re-read.
    @Test func aLiveSetNamingAnUnscannedSessionPrunesNothing() async throws {
        let (sandbox, flat, nested) = try liveSession()
        let scanner = TranscriptScanner()
        let first = await sandbox.totals(scanner)

        await scanner.prune(keeping: [sandbox.sessionId, UUID().uuidString])
        try swappedCounts(sandbox, flat: flat, nested: nested)

        let second = await sandbox.totals(scanner)
        #expect(second == first)
    }

    /// Recorded, not endorsed.
    ///
    /// `QuotaReader.sessionUsage(live:)` treats an empty `live` as "we could not
    /// enumerate sessions" and deletes nothing. `prune` does not: `[].allSatisfy`
    /// is vacuously true, so an empty set sails past the incomplete-keep-set
    /// guard with an empty keep-set and removes every offset the process holds.
    ///
    /// The caller reaches that state on any transient registry read failure —
    /// `Engine.refresh` derives `live` from the sessions it just loaded, and
    /// tracks `registryLooksBroken` precisely because that read can fail. The
    /// symptom is the prune regression above in miniature: one bad read costs a
    /// full re-scan of the corpus.
    ///
    @Test func anEmptyLiveSetPrunesNothing() async throws {
        let (sandbox, flat, nested) = try liveSession()
        let scanner = TranscriptScanner()
        _ = await sandbox.totals(scanner)

        await scanner.prune(keeping: [])
        try swappedCounts(sandbox, flat: flat, nested: nested)

        let after = await sandbox.totals(scanner)
        #expect(after.total == 9000,
                "the offsets survived, so the rewritten bytes are behind them and not re-read")
    }

    // MARK: - Deduplication

    /// Two snapshots of one message, and the bucket the surviving one belongs
    /// in. The smaller is written first, as streaming writes it.
    struct SupersedeCase: Sendable {
        let name: String
        let first: String?
        let second: String
        let bucket: String
    }

    /// Streaming rewrites a message with growing counts, so the scanner keeps
    /// only the largest snapshot and backs the superseded one out. It has to
    /// back it out of the bucket it was *filed under* — a retry served by a
    /// different model makes that different from the model the newer record
    /// names, and subtracting from the wrong one drives a bucket negative.
    /// Twelve real occurrences in this machine's transcripts.
    @Test(arguments: [
        SupersedeCase(name: "a retry served by a different model",
                      first: "claude-sonnet-4-5", second: "claude-opus-4-8",
                      bucket: "claude-opus-4-8"),

        // The first snapshot files under no bucket at all, so there is nothing
        // to back out and a blind subtraction has nothing to aim at either.
        SupersedeCase(name: "the first snapshot names no model",
                      first: nil, second: "claude-opus-4-8",
                      bucket: "claude-opus-4-8"),
        SupersedeCase(name: "the first snapshot's model is the empty string",
                      first: "", second: "claude-opus-4-8",
                      bucket: "claude-opus-4-8"),

        // The context-length suffix is stripped, so the 1M and standard variants
        // of one model share a bucket rather than splitting the split.
        SupersedeCase(name: "the 1M suffix is not part of the bucket name",
                      first: "claude-opus-5", second: "claude-opus-5[1m]",
                      bucket: "claude-opus-5"),

        // The control. If the back-out is wrong in the plain case too, every
        // case above fails for a reason that has nothing to do with models.
        SupersedeCase(name: "the same model twice",
                      first: "claude-opus-4-8", second: "claude-opus-4-8",
                      bucket: "claude-opus-4-8"),
    ])
    func aSupersededSnapshotIsBackedOutOfTheBucketItWasFiledUnder(
        _ testCase: SupersedeCase) async throws {
        let sandbox = try TranscriptSandbox()
        try sandbox.write([
            usageLine(model: testCase.first, messageId: "msg_A", requestId: "req_A",
                      uuid: "u1", input: 12, output: 40, cacheRead: 900, cacheCreation: 48),
            usageLine(model: testCase.second, messageId: "msg_A", requestId: "req_A",
                      uuid: "u2", input: 12, output: 1341, cacheRead: 19879,
                      cacheCreation: 18540),
        ], to: sandbox.parent)

        let totals = await sandbox.totals(TranscriptScanner())

        // The larger snapshot exactly, not the sum of the two (40772) and not
        // the smaller (1000).
        #expect(totals.total == 39772, "\(testCase.name)")
        #expect(totals.input == 12, "\(testCase.name)")
        #expect(totals.output == 1341, "\(testCase.name)")
        #expect(totals.cacheRead == 19879, "\(testCase.name)")
        #expect(totals.cacheCreation == 18540, "\(testCase.name)")
        #expect(totals.messages == 1, "\(testCase.name): one message, written twice")

        #expect(totals.byModel.values.allSatisfy { $0 >= 0 },
                "\(testCase.name): negative bucket \(totals.byModel)")
        #expect(totals.byModel.filter { $0.value != 0 } == [testCase.bucket: 39772],
                "\(testCase.name): \(totals.byModel)")
    }

    /// The other direction: a *smaller* later snapshot is not adopted, so
    /// nothing is backed out and no bucket moves.
    @Test func aSmallerLaterSnapshotIsIgnoredEntirely() async throws {
        let sandbox = try TranscriptSandbox()
        try sandbox.write([
            usageLine(model: "claude-opus-4-8", messageId: "msg_A", requestId: "req_A",
                      uuid: "u1", input: 12, output: 1341, cacheRead: 19879,
                      cacheCreation: 18540),
            usageLine(model: "claude-sonnet-4-5", messageId: "msg_A", requestId: "req_A",
                      uuid: "u2", input: 12, output: 40, cacheRead: 900, cacheCreation: 48),
        ], to: sandbox.parent)

        let totals = await sandbox.totals(TranscriptScanner())
        #expect(totals.total == 39772)
        #expect(totals.messages == 1)
        #expect(totals.byModel.filter { $0.value != 0 } == ["claude-opus-4-8": 39772])
        #expect(totals.byModel.values.allSatisfy { $0 >= 0 })
    }

    /// Records carrying neither `message.id` nor `requestId` used to collide on
    /// the key `"|"`, so the whole file contributed only its single largest one.
    /// They are separately billed responses; every one has to be counted.
    @Test(arguments: [[100, 500, 20], [100, 100, 100], [7, 7, 7], [1, 2, 3]])
    func recordsCarryingNoIdentityAreEachCounted(_ counts: [Int]) async throws {
        let sandbox = try TranscriptSandbox()
        try sandbox.write(counts.enumerated().map { index, count in
            usageLine(messageId: nil, requestId: nil, uuid: "uuid-\(index)", input: count)
        }, to: sandbox.parent)

        let totals = await sandbox.totals(TranscriptScanner())
        #expect(totals.total == counts.reduce(0, +),
                "collapsed onto one key: kept \(totals.total) of \(counts)")
        #expect(totals.messages == counts.count)
    }

    /// A record with an id still deduplicates even when a sibling has none —
    /// the fallback must not disable the real key.
    @Test func theUuidFallbackDoesNotDisableDeduplicationForRecordsThatHaveIds()
        async throws {
        let sandbox = try TranscriptSandbox()
        try sandbox.write([
            usageLine(messageId: nil, requestId: nil, uuid: "u1", input: 100),
            usageLine(messageId: "msg_A", requestId: "req_A", uuid: "u2", input: 200),
            usageLine(messageId: "msg_A", requestId: "req_A", uuid: "u3", input: 900),
        ], to: sandbox.parent)

        let totals = await sandbox.totals(TranscriptScanner())
        #expect(totals.total == 1000, "100 plus the larger of the two msg_A snapshots")
        #expect(totals.messages == 2)
    }

    // MARK: - Incremental reading

    /// A transcript that shrank was compacted or replaced, and the old offset
    /// now points into the middle of unrelated content. Reading from it
    /// produces a partial record and a number nobody can explain.
    @Test func aTranscriptThatShrinksIsReadAgainFromZero() async throws {
        let sandbox = try TranscriptSandbox()
        let scanner = TranscriptScanner()
        try sandbox.write((0..<3).map {
            usageLine(messageId: "msg_\($0)", requestId: "req_\($0)",
                      uuid: "u\($0)", input: 1000)
        }, to: sandbox.parent)

        let before = try Data(contentsOf: sandbox.parent).count
        let firstPass = await sandbox.totals(scanner)
        #expect(firstPass.total == 3000)

        try sandbox.write([usageLine(messageId: "msg_compacted", requestId: "req_compacted",
                                     uuid: "u9", input: 42)], to: sandbox.parent)
        let after = try Data(contentsOf: sandbox.parent).count
        #expect(after < before, "the file has to actually shrink for this to test anything")

        let totals = await sandbox.totals(scanner)
        #expect(totals.total == 42)
        #expect(totals.messages == 1, "the pre-compaction messages were counted again")
        #expect(totals.byModel["claude-opus-4-8"] == 42)
    }

    /// Appended bytes are added to what was already counted, and nothing is
    /// read twice. This is the ordinary case the offsets exist for.
    @Test func onlyBytesAppendedSinceTheLastPassAreRead() async throws {
        let sandbox = try TranscriptSandbox()
        let scanner = TranscriptScanner()
        try sandbox.write([usageLine(messageId: "msg_1", requestId: "req_1",
                                     uuid: "u1", input: 1000)], to: sandbox.parent)
        let firstPass = await sandbox.totals(scanner)
        #expect(firstPass.total == 1000)

        try sandbox.write([
            usageLine(messageId: "msg_1", requestId: "req_1", uuid: "u1", input: 1000),
            usageLine(messageId: "msg_2", requestId: "req_2", uuid: "u2", input: 250),
        ], to: sandbox.parent)

        let totals = await sandbox.totals(scanner)
        #expect(totals.total == 1250)
        #expect(totals.messages == 2)
    }

    /// `message.usage.iterations[]` repeats the top-level counts once per
    /// iteration. Summing it is the obvious-looking fix somebody will reach for,
    /// and it multiplies the reported spend by the iteration count.
    @Test(arguments: [1, 3, 7])
    func iterationsAreNotAddedOnTopOfTheCountsTheyRepeat(_ iterations: Int) async throws {
        let sandbox = try TranscriptSandbox()
        try sandbox.write([usageLine(uuid: "u1", input: 2, output: 1341, cacheRead: 19879,
                                     cacheCreation: 18540, iterations: iterations)],
                          to: sandbox.parent)

        let totals = await sandbox.totals(TranscriptScanner())
        #expect(totals.input == 2)
        #expect(totals.output == 1341)
        #expect(totals.cacheRead == 19879)
        #expect(totals.cacheCreation == 18540)
        #expect(totals.total == 39762, "\(iterations) iterations were summed in")
        #expect(totals.byModel["claude-opus-4-8"] == 39762)
        #expect(totals.messages == 1)
    }

    // MARK: - Subagents

    /// An earlier audit claimed subagent transcripts were skipped. They are not,
    /// and they must not be: their `(message.id, requestId)` sets do not
    /// intersect the parent's at all, so their tokens are additive. The opposite
    /// error — counting them in both the parent's totals and their own — is just
    /// as available, hence both halves below.
    @Test func subagentTranscriptsAreCountedAndCountedOnce() async throws {
        let sandbox = try TranscriptSandbox()
        let scanner = TranscriptScanner()
        try sandbox.write([usageLine(messageId: "msg_parent", requestId: "req_parent",
                                     uuid: "u-parent", input: 1000)], to: sandbox.parent)
        try sandbox.write([usageLine(messageId: "msg_flat", requestId: "req_flat",
                                     uuid: "u-flat", input: 300)],
                          to: sandbox.subagent("agent-a3c1a1d4a05238c8c.jsonl"))
        // Nested a level deeper, as the workflow subagents really are.
        try sandbox.write([usageLine(messageId: "msg_nested", requestId: "req_nested",
                                     uuid: "u-nested", input: 700)],
                          to: sandbox.subagent(
                            "workflows/wf_36b5f63f-689/agent-ae733538688ebb3fa.jsonl"))

        let first = await sandbox.totals(scanner)
        #expect(first.total == 2000, "a nested subagent transcript was missed")
        #expect(first.subagentTokens == 1000)
        #expect(first.total - first.subagentTokens == 1000, "the parent's own share")
        #expect(first.messages == 3)

        // Nothing changed on disk, so the second pass must report the same
        // numbers rather than adding the subagents in again.
        let second = await sandbox.totals(scanner)
        #expect(second == first)
    }

    /// The scan is scoped to one session's own `subagents/` tree. Walking the
    /// project directory instead picks up every other session's subagents and
    /// inflates the total roughly twentyfold — the measurement that once
    /// motivated skipping subagents altogether.
    @Test func oneSessionsScanNeverPicksUpAnothersSubagents() async throws {
        let shared = "/Users/tester/work/\(UUID().uuidString)"
        let mine = try TranscriptSandbox(cwd: shared)
        let theirs = try TranscriptSandbox(cwd: shared)

        try mine.write([usageLine(messageId: "msg_m", requestId: "req_m",
                                  uuid: "u-m", input: 1000)], to: mine.parent)
        try mine.write([usageLine(messageId: "msg_ms", requestId: "req_ms",
                                  uuid: "u-ms", input: 300)],
                       to: mine.subagent("agent-a1111111111111111.jsonl"))
        try theirs.write([usageLine(messageId: "msg_t", requestId: "req_t",
                                    uuid: "u-t", input: 9000)], to: theirs.parent)
        try theirs.write([usageLine(messageId: "msg_ts", requestId: "req_ts",
                                    uuid: "u-ts", input: 7000)],
                         to: theirs.subagent("agent-a2222222222222222.jsonl"))

        let totals = await mine.totals(TranscriptScanner())
        #expect(totals.total == 1300)
        #expect(totals.subagentTokens == 300)
        #expect(totals.messages == 2)
    }

    /// Synthetic records carry no real usage and no billable model.
    @Test func syntheticRecordsContributeNothing() async throws {
        let sandbox = try TranscriptSandbox()
        try sandbox.write([
            usageLine(model: "<synthetic>", messageId: "msg_s", requestId: "req_s",
                      uuid: "u1", input: 900),
            usageLine(messageId: "msg_r", requestId: "req_r", uuid: "u2", input: 100),
        ], to: sandbox.parent)

        let totals = await sandbox.totals(TranscriptScanner())
        #expect(totals.total == 100)
        #expect(totals.messages == 1)
        #expect(totals.models == ["claude-opus-4-8"])
    }

    /// A half-written final line is left for the next pass rather than parsed,
    /// dropped, or allowed to advance the offset past itself.
    @Test func aPartiallyWrittenTailIsLeftForTheNextPass() async throws {
        let sandbox = try TranscriptSandbox()
        let scanner = TranscriptScanner()
        let complete = usageLine(messageId: "msg_1", requestId: "req_1",
                                 uuid: "u1", input: 1000)
        let partial = usageLine(messageId: "msg_2", requestId: "req_2",
                                uuid: "u2", input: 250)

        // No trailing newline on the second record: Claude Code is mid-write.
        try Data((complete + "\n" + String(partial.prefix(40))).utf8)
            .write(to: sandbox.parent)
        let firstPass = await sandbox.totals(scanner)
        #expect(firstPass.total == 1000)

        try sandbox.write([complete, partial], to: sandbox.parent)
        let totals = await sandbox.totals(scanner)
        #expect(totals.total == 1250, "the record completed across two passes was lost")
        #expect(totals.messages == 2)
    }
}
