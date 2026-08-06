import Foundation
import Testing
@testable import Torpor

/// One argv shape and what the allowlist is expected to make of it.
struct FlagCase: Sendable {
    let name: String
    let argv: [String]
    let expected: [String]
    /// Flags whose values could not be carried across faithfully. Non-empty is
    /// what makes `SessionControl.hibernate` throw instead of writing a record.
    var refused: [String] = []
}

@Test("replayableFlags over real argv shapes", arguments: [
    FlagCase(name: "separated value flag",
             argv: ["--model", "opus"], expected: ["--model", "opus"]),
    FlagCase(name: "equals form",
             argv: ["--model=opus"], expected: ["--model=opus"]),

    // The bug this table exists for. The parser used to consume exactly two
    // argv entries per flag, so `../lib` was dropped and the revived session
    // reported file-not-found on half its tree with nothing said.
    FlagCase(name: "every value of a multi-value flag survives",
             argv: ["--add-dir", "../shared", "../lib"],
             expected: ["--add-dir", "../shared", "../lib"]),
    FlagCase(name: "a multi-value run stops at the next flag",
             argv: ["--add-dir", "../shared", "../lib", "--model", "opus"],
             expected: ["--add-dir", "../shared", "../lib", "--model", "opus"]),
    FlagCase(name: "--mcp-config takes several paths too",
             argv: ["--mcp-config", "./a.json", "./b.json", "./c.json"],
             expected: ["--mcp-config", "./a.json", "./b.json", "./c.json"]),

    // The other half of the same decision: a single-value flag must not eat a
    // positional prompt as if it were a second model.
    FlagCase(name: "a single-value flag does not swallow the prompt",
             argv: ["--model", "opus", "fix the parser"],
             expected: ["--model", "opus"]),

    FlagCase(name: "stream plumbing is dropped",
             argv: ["--output-format", "stream-json", "--input-format", "stream-json",
                    "--replay-user-messages", "--model", "sonnet"],
             expected: ["--model", "sonnet"]),
    FlagCase(name: "the prompt and -p are dropped",
             argv: ["-p", "summarise this repo"], expected: []),
    FlagCase(name: "the bool allowlist admits only what it names",
             argv: ["--no-chrome", "--verbose"], expected: ["--no-chrome"]),
    FlagCase(name: "empty argv",
             argv: [], expected: []),

    FlagCase(name: "a trailing value flag with no value is refused, not dropped",
             argv: ["--model"], expected: [], refused: ["--model"]),
    FlagCase(name: "a value flag followed only by another flag is refused",
             argv: ["--add-dir", "--model", "opus"],
             expected: ["--model", "opus"], refused: ["--add-dir"]),
])
func replayable(_ testCase: FlagCase) {
    let (flags, refused) = HibernatedSession.replayable(from: testCase.argv)
    #expect(flags == testCase.expected, "\(testCase.name): flags")
    #expect(refused == testCase.refused, "\(testCase.name): refused")
    #expect(record(arguments: testCase.argv).replayableFlags() == testCase.expected,
            "\(testCase.name): via the record")
}

/// All of a flag's values or none of them.
///
/// A truncated command line is the dangerous outcome, because it revives and
/// then misbehaves: `--add-dir ../shared` without `../lib` is a session that
/// reports file-not-found on half its tree. Refusing is loud and recoverable.
@Test(arguments: ["--add-dir", "--mcp-config"])
func aPartiallyReplayableFlagIsRefusedWholesale(_ flag: String) {
    let argv = [flag, "./ok.json", #"{"env":{"GITHUB_TOKEN":"ghp_deadbeef"}}"#]
    let (flags, refused) = HibernatedSession.replayable(from: argv)
    #expect(refused == [flag])
    #expect(flags.isEmpty, "the replayable half must not be kept on its own")
    #expect(!flags.contains("./ok.json"))

    // The refusal names the flag and never the value, because the value is the
    // secret and this string reaches lastError, notifications and stderr.
    let message = SessionControl.ControlError
        .unreplayableFlags(pid: 1234, flags: refused).errorDescription ?? ""
    #expect(message.contains(flag))
    #expect(!message.contains("ghp_deadbeef"))
}

/// A recorded decision, not an accident of the allowlist — and one that flipped.
///
/// These flags were excluded while revive *executed* the line itself, in a
/// Terminal tab Torpor opened from a menu bar click: replaying them would have
/// started an agent with every prompt disabled, days after the user decided
/// that. Torpor executes nothing now. The command goes on the clipboard, the
/// row's tooltip shows it verbatim, and the user picks the terminal and presses
/// Return. Excluding them stopped protecting anyone and started handing back a
/// line that silently does not restore the session it names.
///
/// The tripwire still stands, pointing the other way: if anything ever runs this
/// command on the user's behalf again, these two go back on the excluded list
/// and this test flips with it. Changing it either way is a security decision.
@Test func permissionFlagsAreReplayedBecauseTheUserRunsTheLine() {
    let argv = ["--dangerously-skip-permissions", "--permission-mode", "acceptEdits",
                "--model", "opus"]
    let session = record(arguments: argv)
    let (flags, refused) = HibernatedSession.replayable(from: argv)

    #expect(refused.isEmpty, "a permission grant is replayed, not refused")
    #expect(flags.contains("--dangerously-skip-permissions"))
    #expect(flags.contains("--permission-mode"))
    #expect(flags.contains("acceptEdits"))
    #expect(flags.contains("--model"))
    #expect(flags.contains("opus"))
    // The value has to stay attached to its flag, not merely be present.
    let mode = flags.firstIndex(of: "--permission-mode")
    #expect(mode.map { flags.indices.contains($0 + 1) && flags[$0 + 1] == "acceptEdits" } == true)
    #expect(session.resumeCommand.contains("--dangerously-skip-permissions"))
    #expect(session.resumeCommand.contains("acceptEdits"))
}

/// Inline JSON for `--settings`/`--mcp-config`/`--agent` routinely carries an
/// `env` block with a GITHUB_TOKEN or a database URL. Refusing is what stops it
/// reaching disk at all: capture applies this allowlist *before* building the
/// record, and a non-empty `refused` aborts the hibernate.
@Test(arguments: ["--settings", "--mcp-config", "--agent"])
func inlineJSONValuesAreNeitherReplayedNorPersisted(_ flag: String) throws {
    let secret = #"{"env":{"GITHUB_TOKEN":"ghp_deadbeef"}}"#
    let shapes = [
        [flag, secret],
        ["\(flag)=\(secret)"],
        [flag, "  " + secret],
        [flag, #"[{"command":"npx","env":{"DB":"postgres://u:ghp_deadbeef@h/db"}}]"#],
    ]
    for argv in shapes {
        let (flags, refused) = HibernatedSession.replayable(from: argv)
        #expect(flags.isEmpty, "\(argv)")
        #expect(refused == [flag], "\(argv)")

        var session = record(arguments: argv)
        #expect(!session.resumeCommand.contains("ghp_deadbeef"))

        // What capture would actually write: the filtered argv, never the raw
        // one. Encoded rather than inspected field by field, because the whole
        // record is what lands in hibernated.json.
        session.arguments = flags
        let encoded = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        #expect(!encoded.contains("ghp_deadbeef"), "\(argv)")
    }

    // A path in the same position is fine — that is the whole distinction.
    #expect(HibernatedSession.replayable(from: [flag, "/tmp/config.json"]).flags
            == [flag, "/tmp/config.json"])
}

/// A session hosted by VS Code or the desktop app is not the CLI: its binary
/// expects stream-json on stdin, so reviving *that* in a terminal produces a
/// process waiting for JSON from the keyboard.
@Test(arguments: [
    ("/Users/x/.vscode/extensions/anthropic.claude-code/bin/claude", "cli"),
    ("/Applications/Claude.app/Contents/bin/claude", "cli"),
    ("/usr/local/bin/claude", "claude-vscode"),
])
func hostedEntrypointsRestoreWithPlainClaude(_ testCase: (String, String)) {
    #expect(record(executable: testCase.0, entrypoint: testCase.1).restoreExecutable == "claude")
}

@Test func aPlainCLISessionKeepsItsOwnBinary() {
    #expect(record(executable: "/usr/local/bin/claude", entrypoint: "cli").restoreExecutable
            == "/usr/local/bin/claude")
}

/// The kernel's exec path is preferred over argv[0] only while it still exists:
/// it is typically an installer-owned symlink that moves on every Claude Code
/// update, and a fortnight-old record would otherwise run a path that is gone.
@Test func aVanishedExecutablePathFallsBackToArgvZero() {
    #expect(record(executable: "claude",
                   executablePath: "/nonexistent/bin/claude").restoreExecutable == "claude")
}
