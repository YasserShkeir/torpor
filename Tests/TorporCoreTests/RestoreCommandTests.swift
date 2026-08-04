import Foundation
import Testing
@testable import Torpor

/// A hibernated session comes back exactly one way: the user copies its command
/// and pastes it into a terminal of their choosing. That makes `resumeCommandLine`
/// the single load-bearing string in the app — if it is wrong, the session is
/// gone as far as the user is concerned — and `restoreSummary` the sentence that
/// has to persuade them it is worth pasting.
///
/// This suite replaces ReviveHostTests, which pinned a routing decision that no
/// longer exists (original tab / new window / handoff, chosen from a captured
/// tty and host application). Reopening in place worked only for Terminal and
/// iTerm, the only two terminals macOS lets an app script by tab; every route to
/// the rest is closed — TIOCSTI is EPERM, measured; the `code` CLI has no
/// command-execution flag; `vscode://` reaches extensions only; synthetic
/// keystrokes need Accessibility and land in whatever has focus. The parts of
/// that suite worth keeping — the command string, the shell quoting, the
/// sentence shown before the click — are here.
///
/// What is not tested is the clipboard write itself: asserting on the general
/// pasteboard would clobber whatever the developer had copied. What can be
/// pinned without touching it is *what* would go on it, which is where the bugs
/// would be.

// MARK: - The string that gets copied

/// What lands on the clipboard has to be a line a shell will accept verbatim —
/// the user pastes it and presses Return, with nothing left to fix up.
@Test func theCopiedLineIsWhatAShellNeeds() {
    let session = record(cwd: "/Users/t/it's a project",
                         arguments: ["--model", "opus"])
    #expect(session.resumeCommandLine
            == "cd \(shellQuote(session.cwd)) && \(session.resumeCommand)")
    #expect(session.resumeCommandLine.hasPrefix("cd '/Users/t/it'\\''s a project'"))
    #expect(session.resumeCommandLine.hasSuffix(session.resumeCommand))
    #expect(session.resumeCommandLine.contains("--resume"))
    #expect(session.resumeCommandLine.contains("--model opus"))
}

/// A real `/bin/sh` reaches the recorded directory when handed this line. The
/// resume itself is not run — `claude` need not exist here — so the assertion is
/// on the `cd` half actually landing, which is the half the quoting can break.
@Test func aRealShellAcceptsTheCopiedLine() throws {
    let temp = try TempDir()
    defer { temp.remove() }
    let target = try temp.makeDirectory(named: "it's a $(dir)")

    let session = record(cwd: target.path)
    // Everything up to the resume: the half a shell can be asked to run here.
    // Asserted by a marker file, which no amount of path normalisation can make
    // ambiguous.
    let cd = String(session.resumeCommandLine.dropLast(session.resumeCommand.count))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", cd + "printf ok > landed"]
    process.currentDirectoryURL = temp.url
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()

    #expect(FileManager.default.fileExists(
        atPath: target.appendingPathComponent("landed").path))
    #expect(!temp.exists("landed"))
    // The `$(dir)` in the directory name never ran.
    #expect(!temp.exists("dir"))
}

/// The line goes into a terminal the user picked, quite possibly the one they
/// were reading. An earlier version inserted `clear` — it existed to hide the
/// dead session's scrollback when Torpor reopened in the session's *own* tab,
/// and there is no such tab any more.
@Test func theCopiedLineDoesNotClearTheUsersScrollback() {
    #expect(!record(cwd: "/tmp/p").resumeCommandLine.contains("clear"))
}

/// The command always carries the absolute path, never `~`. The tilde would be
/// expanded by whichever shell the line is pasted into, which is not necessarily
/// the account the session ran under.
@Test func theCopiedLineNeverAbbreviatesTheHomeDirectory() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let session = record(cwd: home + "/work/api")
    #expect(session.resumeCommandLine.contains(home + "/work/api"))
    #expect(!session.resumeCommandLine.contains("~"))
    // …while the sentence a human reads does abbreviate it.
    #expect(session.displayDirectory == "~/work/api")
}

// MARK: - The sentence said before the click

/// The row has to justify the paste before it happens. `claude --resume <id>`
/// typed by hand loses the directory, the replayed flags and the effort level,
/// so all three are named.

@Test func theSummaryNamesTheDirectory() {
    #expect(record(cwd: "/tmp/some-project").restoreSummary.contains("/tmp/some-project"))
}

@Test func theSummaryNamesTheFlagsAndTheEffortLevel() {
    let line = record(arguments: ["--model", "opus"], effort: "high").restoreSummary
    #expect(line.contains("--model opus"))
    #expect(line.contains("high effort"))
}

/// A record with nothing to replay must not claim anything extra — no dangling
/// "with", no invented effort.
@Test func theSummaryOfABareRecordClaimsNothingExtra() {
    let line = record().restoreSummary
    #expect(line.contains("/tmp/p"))
    #expect(!line.contains(" with "))
    #expect(!line.contains("effort"))
    #expect(line.hasSuffix("."))
}

/// Every shape says the same thing about the mechanism: you paste it. There is
/// no longer a shape that promises a tab, a window, or anything Torpor does on
/// the user's behalf.
@Test(arguments: [[], ["--model", "opus"], ["--add-dir", "../lib"]])
func everySummaryPromisesAPaste(_ arguments: [String]) {
    for effort in [nil, "high", "nonsense"] {
        let line = record(arguments: arguments, effort: effort).restoreSummary
        #expect(line.hasPrefix("Paste it into any terminal"), "\(line)")
        // Nothing is opened, reopened or reached for.
        #expect(!line.lowercased().contains("window"), "\(line)")
        #expect(!line.lowercased().contains("tab"), "\(line)")
    }
}

/// A `--mcp-config` path plus two `--add-dir`s is a realistic argv and would wrap
/// the caption into a paragraph in a 400pt popover. Past the threshold the flags
/// are named without their values — the whole line is still in the tooltip and in
/// `--resume-command`.
@Test func aLongFlagListCollapsesToFlagNames() throws {
    let session = record(arguments: [
        "--mcp-config", "/Users/tester/Library/Application Support/servers.json",
        "--add-dir", "../lib", "--model", "opus",
    ])
    let summary = try #require(session.flagSummary)
    #expect(summary == "--mcp-config --add-dir --model")
    #expect(!summary.contains("servers.json"))
    // And the command itself is untouched: the shortening is display only.
    #expect(session.resumeCommand.contains("servers.json"))
}

/// Short enough to read, so it is shown whole.
@Test func aShortFlagListIsShownWithItsValues() {
    #expect(record(arguments: ["--model", "opus"]).flagSummary == "--model opus")
    #expect(record().flagSummary == nil)
}

// MARK: - Records already on disk

/// The fields `tty` and `hostApplication` were removed with the reopen-in-place
/// feature. Every `hibernated.json` written before that still carries both, and
/// they are not a lost setting — `HibernationStore` refuses to overwrite a file
/// it could not read, so one failed decode would make *every* hibernated session
/// unrestorable at once. The synthesized decoder ignores unknown keys; this pins
/// that it stays true.
@Test func aRecordCarryingTheRemovedFieldsStillDecodes() throws {
    let json = """
    {"sessionId":"abc","cwd":"/tmp/p","name":"p","executable":"claude",
     "executablePath":"/usr/local/bin/claude","entrypoint":"cli",
     "arguments":["--model","opus"],"hibernatedAt":"1970-01-01T00:00:00Z",
     "reclaimedBytes":12345,"version":"2.1.220","effort":"high",
     "tty":"/dev/ttys004","hostApplication":"VS Code"}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let restored = try decoder.decode(HibernatedSession.self, from: Data(json.utf8))
    #expect(restored.sessionId == "abc")
    #expect(restored.effort == "high")
    #expect(restored.resumeCommandLine == "cd /tmp/p && claude --resume abc --model opus --effort high")
}

/// A whole store file of such records, decoded as the app decodes it.
@Test func aWholeStoreFileOfOldRecordsDecodes() throws {
    let json = """
    [{"sessionId":"a","cwd":"/tmp/a","name":"a","executable":"claude",
      "arguments":[],"hibernatedAt":"1970-01-01T00:00:00Z","reclaimedBytes":0,
      "version":"2.1.220","tty":"/dev/ttys001","hostApplication":"Terminal"},
     {"sessionId":"b","cwd":"/tmp/b","name":"b","executable":"claude",
      "arguments":[],"hibernatedAt":"1970-01-01T00:00:00Z","reclaimedBytes":0,
      "version":"2.1.220","tty":null,"hostApplication":null}]
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let restored = try decoder.decode([HibernatedSession].self, from: Data(json.utf8))
    #expect(restored.count == 2)
    #expect(restored.map(\.sessionId) == ["a", "b"])
}

// MARK: - The arm-then-confirm label

/// The bug this fixes: both halves of every two-click hibernate said
/// "Hibernate", so the first click looked like it had done nothing. The confirm
/// must not say the same word as the thing that armed it.
@Test(arguments: [1, 2, 7])
func theConfirmLabelIsNotTheWordThatArmedIt(_ count: Int) {
    let label = hibernateConfirmLabel(count)
    #expect(!label.contains("Hibernate"), "\(label)")
    #expect(label.hasPrefix("End"), "\(label)")
}

/// It counts what it is about to end, and agrees with itself about plurals.
@Test func theConfirmLabelCountsWhatItEnds() {
    #expect(hibernateConfirmLabel(1) == "End Session")
    #expect(hibernateConfirmLabel(3) == "End 3 Sessions")
}
