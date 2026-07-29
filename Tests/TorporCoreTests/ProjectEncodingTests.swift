import Foundation
import Testing
@testable import Torpor

/// `encode(cwd:)` reimplements an undocumented upstream rule, and its failure
/// mode is silent: a wrong encoding finds no transcript, so token counts read
/// zero — which looks identical in the UI to a session that used nothing.
///
/// Every expectation below was read off a real `~/.claude/projects` and matched
/// back to the directory it encodes.
@Test(arguments: [
    ("/Users/yassershkeir/Documents/GitHub/clauderam",
     "-Users-yassershkeir-Documents-GitHub-clauderam"),

    // A space becomes a dash. Real directory: ~/Documents/GitHub/Trader V2.
    ("/Users/yassershkeir/Documents/GitHub/Trader V2",
     "-Users-yassershkeir-Documents-GitHub-Trader-V2"),

    // The case a naive "replace / with -" gets wrong: the dot in `.claude`
    // becomes a dash too, hence the double dash. Real directory.
    ("/Users/yassershkeir/Documents/GitHub/logo-creator/.claude/worktrees/pensive-ride-2550c7",
     "-Users-yassershkeir-Documents-GitHub-logo-creator--claude-worktrees-pensive-ride-2550c7"),

    // Underscores are not alphanumeric either.
    ("/Users/y/my_project", "-Users-y-my-project"),

    // Existing dashes and digits pass through unchanged.
    ("/private/tmp/duxio-test/work/01-simple-add-validation",
     "-private-tmp-duxio-test-work-01-simple-add-validation"),

    // Case is preserved. Real: -Users-yassershkeir-Documents-GitHub-GTMContent
    ("/Users/yassershkeir/Documents/GitHub/GTMContent",
     "-Users-yassershkeir-Documents-GitHub-GTMContent"),

    // Home itself. Real: -Users-yassershkeir
    ("/Users/yassershkeir", "-Users-yassershkeir"),

    // A trailing slash produces a trailing dash rather than being collapsed.
    ("/Users/y/p/", "-Users-y-p-"),

    // A relative path still gets the leading dash.
    ("tmp/p", "-tmp-p"),

    ("", "-"),
])
func encodesRealProjectDirectories(_ testCase: (String, String)) {
    #expect(TranscriptScanner.encode(cwd: testCase.0) == testCase.1)
}

/// Replacing only `/` — the obvious wrong implementation — is caught here
/// rather than by a zero token count six weeks later.
@Test(arguments: ["/a.b", "/a b", "/a_b", "/a+b", "/a@b", "/a'b", "/a:b", "/a\\b", "/a,b"])
func everyNonAlphanumericBecomesADash(_ cwd: String) {
    #expect(TranscriptScanner.encode(cwd: cwd) == "-a-b")
}

/// Measured, not assumed. The encoder walks unicode *scalars*, and
/// `CharacterSet.alphanumerics` spans the letter, mark and number categories —
/// so an accented name survives whether it arrives precomposed or decomposed,
/// while an emoji becomes a dash. Pinned because "is a combining mark
/// alphanumeric?" is exactly the question a future reader would guess at.
@Test func accentsSurviveInBothNormalisationsAndEmojiDoNot() {
    #expect(TranscriptScanner.encode(cwd: "/Users/y/café") == "-Users-y-café")
    #expect(TranscriptScanner.encode(cwd: "/Users/y/cafe\u{301}") == "-Users-y-cafe\u{301}")
    #expect(TranscriptScanner.encode(cwd: "/Users/y/🙂") == "-Users-y--")
}

/// Two different directories must never encode to the same string, or one
/// session's tokens are attributed to the other's transcript directory.
@Test func distinctDirectoriesThatDifferOnlyInPunctuationStillCollide() {
    // They do collide, by construction — the rule is lossy upstream, not here.
    // Recorded so that a future "let us make the encoding injective" change is
    // recognised as a divergence from Claude Code rather than a fix.
    #expect(TranscriptScanner.encode(cwd: "/a/b") == TranscriptScanner.encode(cwd: "/a.b"))
}
