import Foundation
import Testing
@testable import Torpor

/// Effort is the one piece of a session's configuration that hibernate cannot
/// read off the process: `/effort` sets it mid-conversation, so it is never in
/// argv. It comes from the statusline payload instead, which means it arrives
/// as an arbitrary string from a file Torpor does not own — and lands on a
/// command line. These tests are about that seam.

/// The five levels `claude --effort` documents.
@Test(arguments: ["low", "medium", "high", "xhigh", "max"])
func anAcceptedEffortLevelIsReplayed(_ level: String) {
    let session = record(effort: level)
    #expect(session.replayableEffort == level)
    #expect(session.resumeCommand.hasSuffix("--effort \(level)"))
}

/// The reason this is an allowlist and not a pass-through: the CLI rejects an
/// unrecognised value and refuses to start, so replaying one turns a revive
/// that would have worked at the default into one that does not run at all.
/// Reviving at the default effort is a small loss; not reviving is the whole
/// session.
@Test(arguments: [
    "ultra", "maximum", "", "  ", "-1", "high --dangerously-skip-permissions",
    "high; rm -rf ~", "$(whoami)",
])
func anUnacceptedEffortLevelIsDropped(_ level: String) {
    let session = record(effort: level)
    #expect(session.replayableEffort == nil, "\(level)")
    #expect(!session.resumeCommand.contains("--effort"), "\(level)")
    // Whatever the string was, none of it reaches the command line.
    #expect(session.resumeCommand == record().resumeCommand, "\(level)")
}

/// Case and surrounding space are tolerated on the way in — the payload is
/// undocumented — but what comes out is always one of the five literals, never
/// the string as written.
@Test(arguments: [("XHigh", "xhigh"), (" max ", "max"), ("LOW", "low")])
func aLevelIsNormalisedBeforeItIsReplayed(_ testCase: (String, String)) {
    #expect(record(effort: testCase.0).replayableEffort == testCase.1)
    #expect(record(effort: testCase.0).resumeCommand.hasSuffix("--effort \(testCase.1)"))
}

/// A level typed on the command line was the user's choice and is already
/// replayed by the flag allowlist. Emitting the captured one as well would put
/// `--effort` on the line twice and leave the CLI to pick.
@Test(arguments: [["--effort", "high"], ["--effort=high"]])
func anArgvSuppliedEffortIsNotDuplicated(_ argv: [String]) {
    let session = record(arguments: argv, effort: "low")
    #expect(session.replayableEffort == nil)

    let command = session.resumeCommand
    #expect(command.components(separatedBy: "--effort").count - 1 == 1)
    #expect(command.contains("high"))
    #expect(!command.contains("low"))
    // And the argv-supplied one really is still there, whichever form it took.
    #expect(command == record(arguments: argv).resumeCommand)
}

/// Every record written before the shim reported effort has none, and must
/// produce exactly the command it produced before this existed.
@Test func aRecordWithNoCapturedEffortIsUnchanged() {
    let session = record(arguments: ["--model", "opus", "--add-dir", "../lib"])
    #expect(session.effort == nil)
    #expect(session.replayableEffort == nil)
    #expect(session.resumeCommand
            == "claude --resume 11111111-2222-3333-4444-555555555555 --model opus --add-dir ../lib")
}

/// A level that survives a round trip through `hibernated.json` — the record is
/// decoded from disk on every poll, and a field that does not encode is a field
/// that works until the app is restarted.
@Test func effortAndHostSurviveTheStore() throws {
    let session = record(tty: "/dev/ttys004", hostApplication: "VS Code", effort: "xhigh")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let restored = try decoder.decode(HibernatedSession.self,
                                      from: try encoder.encode(session))
    #expect(restored.effort == "xhigh")
    #expect(restored.hostApplication == "VS Code")
    #expect(restored.tty == "/dev/ttys004")
    #expect(restored.resumeCommand == session.resumeCommand)
}

/// Records predating both fields still decode. They are the ones sitting in a
/// real `hibernated.json` right now, and a failed decode is not one lost
/// setting — `HibernationStore` keeps the whole file rather than overwrite what
/// it could not read, so every hibernated session would stop being revivable.
@Test func aRecordWithoutTheNewFieldsStillDecodes() throws {
    let json = """
    {"sessionId":"abc","cwd":"/tmp/p","name":"p","executable":"claude",
     "arguments":["--model","opus"],"hibernatedAt":"1970-01-01T00:00:00Z",
     "reclaimedBytes":0,"version":"2.1.220"}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let restored = try decoder.decode(HibernatedSession.self, from: Data(json.utf8))
    #expect(restored.effort == nil)
    #expect(restored.hostApplication == nil)
    #expect(restored.resumeCommand == "claude --resume abc --model opus")
}
