import Foundation
import Testing
@testable import Torpor

/// Directory names a user can really create, each of which means something to
/// `/bin/sh` if it reaches the shell unquoted.
private let hostileNames = [
    "it's mine",
    #"pre\'escaped"#,
    "line\nbreak",
    "spaces here",
    "semi;pipe|amp&",
    #"quote"double"#,
    "$(touch pwned)",
    "`touch pwned`",
    "${HOME}",
    "*glob*",
    "--looks-like-a-flag",
    "tab\there",
    "hash#comment",
    "paren(s)",
]

@Suite struct ShellEscapingTests {

    /// Runs `command` with the temp directory as cwd, so that anything the
    /// quoting fails to contain lands there and can be asserted absent rather
    /// than escaping into the repository.
    private func runShell(_ command: String, from directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }

    /// Exactly the line that goes on the clipboard, so this test breaks if
    /// either half of it moves.
    private func restoreCommand(cwd: String, arguments: [String] = []) -> String {
        record(cwd: cwd, arguments: arguments).resumeCommandLine
    }

    /// The load-bearing test: a real `/bin/sh` must land in the directory whose
    /// name it was given, whatever that name contains. Asserted by having the
    /// shell create a marker file, which no amount of path normalisation can
    /// make ambiguous.
    @Test(arguments: hostileNames)
    func aRealShellLandsInAHostilyNamedDirectory(_ name: String) throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let target = try temp.makeDirectory(named: name)

        _ = try runShell("cd \(shellQuote(target.path)) && printf ok > landed", from: temp.url)

        #expect(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("landed").path),
                "the shell did not reach \(name)")
        // Nothing escaped into the parent: no stray marker, and no file created
        // by a substitution the quoting was supposed to neutralise.
        #expect(!temp.exists("landed"))
        #expect(!temp.exists("pwned"))
    }

    /// Command substitution inside a directory name is inert. Deliberately
    /// `touch` rather than anything destructive — the assertion is that the
    /// file does *not* appear, and a test that has to run the payload to find
    /// out must be able to survive running it.
    @Test(arguments: ["$(touch pwned)", "`touch pwned`", "$(echo pwned > pwned)"])
    func commandSubstitutionInADirectoryNameNeverRuns(_ name: String) throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let target = try temp.makeDirectory(named: name)

        _ = try runShell("cd \(shellQuote(target.path)) && printf ok > landed", from: temp.url)

        #expect(!temp.exists("pwned"))
        #expect(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("landed").path))
    }

    /// The whole restore command, not just the `cd`: the session id and every
    /// replayed value pass through the same quoting.
    @Test func theComposedRestoreCommandQuotesEveryPartIndependently() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let target = try temp.makeDirectory(named: "it's a project")
        let shared = try temp.makeDirectory(named: "shared dir")

        let command = restoreCommand(cwd: target.path,
                                     arguments: ["--add-dir", shared.path, "--model", "opus"])
        #expect(command.hasPrefix("cd '"))
        #expect(command.contains(shellQuote(shared.path)))
        #expect(command.contains("--resume '11111111-2222-3333-4444-555555555555'")
                || command.contains("--resume 11111111-2222-3333-4444-555555555555"))

        // `claude` is not on a CI runner, so only the parts before it are run.
        // Word-splitting is what this proves: `echo` sees one argument per
        // quoted value, so a count of three means nothing split.
        let prefix = "cd \(shellQuote(target.path)) && "
        let counted = try runShell(
            prefix + "for a in \(shellQuote(shared.path)) \(shellQuote("--model")) "
                   + "\(shellQuote("opus")); do echo x; done",
            from: temp.url)
        #expect(counted == "x\nx\nx\n")
    }

    /// A single quote is the only character the `'…'` form cannot contain, and
    /// `'\''` is the idiom that closes, escapes and reopens. Pinned because the
    /// obvious alternatives (backslash-escaping inside single quotes, or
    /// switching to double quotes) are both wrong.
    @Test func aSingleQuoteUsesTheCloseEscapeReopenIdiom() {
        #expect(shellQuote("it's") == #"'it'\''s'"#)
        #expect(shellQuote("''") == #"''\'''\'''"#)
    }

    @Test func safePathsAreNotQuotedAndEmptyIs() {
        #expect(shellQuote("") == "''")
        #expect(shellQuote("/Users/y/Documents/GitHub/clauderam")
                == "/Users/y/Documents/GitHub/clauderam")
        #expect(shellQuote("--model") == "--model")
        // The safe set is deliberately narrow: anything outside it is quoted
        // whole rather than escaped character by character.
        #expect(shellQuote("/tmp/a b").hasPrefix("'"))
        #expect(shellQuote("~").hasPrefix("'"), "an unquoted tilde would expand")
        #expect(shellQuote("*").hasPrefix("'"))
        #expect(shellQuote("$HOME").hasPrefix("'"))
    }

    /// There is exactly one escaping layer now, and this is it.
    ///
    /// There used to be two: shell quoting, then an AppleScript string-literal
    /// escape applied on top, because the line was handed to Terminal or iTerm
    /// over an Apple event. Nothing scripts a terminal any more — the line goes
    /// on the clipboard and a human pastes it — so the second layer is gone, and
    /// a directory name containing a quote or a backslash has to survive the
    /// remaining one on its own. Run against a real `/bin/sh`, because the whole
    /// point is what a shell does with it.
    @Test func aDirectoryNameWithQuotesAndBackslashesSurvivesTheOnlyEscapingLayer() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let target = try temp.makeDirectory(named: #"quote"and\backslash'and"#)
        let command = restoreCommand(cwd: target.path)
        // The characters really are in there, so the quoting is doing work.
        #expect(command.contains("\""))
        #expect(command.contains("\\"))

        let cd = String(command.prefix(upTo: command.range(of: " && ")!.upperBound))
        _ = try runShell(cd + "printf ok > landed", from: temp.url)
        #expect(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("landed").path))
        #expect(!temp.exists("landed"))
    }
}
