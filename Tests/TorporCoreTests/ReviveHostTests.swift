import Foundation
import Testing
@testable import Torpor

/// Reviving into the original tab works by matching a tty against Terminal or
/// iTerm over AppleScript. That is the whole scriptable set: VS Code exposes no
/// API for its integrated terminal, and the alternative is closed off by the
/// kernel — `TIOCSTI` against a tty the process does not control returns EPERM,
/// measured. So for those sessions the honest outcome is a new window that says
/// where the session came from, and these tests pin that it is said.

@Test(arguments: ["Terminal", "iTerm"])
func theScriptableTerminalsAreRecognised(_ host: String) {
    #expect(SessionControl.isScriptable(host: host))
}

/// Every terminal that hosts sessions on real machines and cannot be driven
/// back to a tab. A regression here is silent: revive would attempt an
/// AppleScript search that cannot match, raising an Automation consent prompt
/// to answer a question already known.
@Test(arguments: ["VS Code", "Cursor", "Warp", "Ghostty", "kitty", "Xcode", "iTerm2", nil])
func everythingElseIsNotScriptable(_ host: String?) {
    #expect(!SessionControl.isScriptable(host: host))
}

/// The point of the whole change. A new window opened for a VS Code session
/// must name VS Code, rather than the generic "your terminal can't be scripted"
/// the user got before — which left them guessing which terminal it meant.
@Test func aNewWindowNamesTheAppItCouldNotReachBack() {
    let session = record(tty: "/dev/ttys004", hostApplication: "VS Code")
    let notice = SessionControl.notice(
        for: .newWindow(app: "Terminal", unreachableHost: "VS Code"), record: session)
    #expect(notice.contains("VS Code"))
    #expect(notice.contains("new Terminal window"))
}

/// A closed tab is the user's own doing and a different sentence. Passing a nil
/// host is what keeps the two apart, and this asserts they do not collapse.
@Test func aClosedTabIsNotReportedAsAnUnscriptableApp() {
    let session = record(tty: "/dev/ttys999")
    let notice = SessionControl.notice(
        for: .newWindow(app: "Terminal", unreachableHost: nil), record: session)
    #expect(notice.contains("/dev/ttys999"))
    #expect(!notice.contains("VS Code"))
}

/// A Terminal tab that is still open and still wasn't driven means the Apple
/// event was refused, not that Terminal is unscriptable. Telling the user their
/// terminal has no scripting API here is false, and points at the wrong fix —
/// the actual one is a checkbox in Privacy & Security.
@Test func aScriptableHostThatRefusedTheEventPointsAtAutomationPermission() {
    // Needs a tty that is genuinely live, and the test process's own is the
    // only one available. A test run with no controlling terminal cannot
    // exercise this branch, and skipping is honest.
    guard let live = ProcProbe.tty(getpid()) else { return }
    let notice = SessionControl.notice(
        for: .newWindow(app: "Terminal", unreachableHost: nil),
        record: record(tty: live, hostApplication: "Terminal"))
    #expect(notice.contains("Automation"))
    #expect(!notice.contains("can't be scripted"))
}

/// No controlling terminal at all — launchd, or an ssh login with no pty — is a
/// third fact, and claiming a tab was closed would be inventing one.
@Test func noTTYIsItsOwnSentence() {
    let notice = SessionControl.notice(
        for: .newWindow(app: "Terminal", unreachableHost: nil), record: record())
    #expect(notice.contains("no tty"))
}

@Test func theOriginalTabIsReportedAsSuch() {
    let notice = SessionControl.notice(for: .originalTab(app: "iTerm"),
                                       record: record(tty: "/dev/ttys004",
                                                      hostApplication: "iTerm"))
    #expect(notice.contains("original iTerm tab"))
}

// MARK: - Said before the click

/// The popover's line is rendered per row on every poll tick, so it must be a
/// pure read of the record. These pin what each captured shape claims.

@Test func aScriptableHostPromisesTheOriginalTab() {
    let line = record(tty: "/dev/ttys004", hostApplication: "Terminal")
        .reviveExpectation(fallbackTerminal: "Terminal")
    #expect(line.contains("original Terminal tab"))
}

/// The user should learn this while deciding, not after the window has opened
/// and taken focus off the popover the notice would have been written into.
@Test func anUnscriptableHostIsNamedBeforeTheClick() {
    let line = record(tty: "/dev/ttys004", hostApplication: "VS Code")
        .reviveExpectation(fallbackTerminal: "iTerm")
    #expect(line.contains("VS Code"))
    #expect(line.contains("new iTerm window"))
}

/// `revive` matches a tab by tty and gives up at once without one, so a
/// scriptable host is not on its own enough to promise the original tab.
@Test func aScriptableHostWithNoTTYDoesNotPromiseATab() {
    let line = record(hostApplication: "Terminal")
        .reviveExpectation(fallbackTerminal: "Terminal")
    #expect(!line.contains("original"))
    #expect(line.contains("no tty"))
}

/// A record written before hosts were captured knows only that it had a tty.
/// Claiming more than that would be the same dishonesty in the other direction.
@Test func aRecordWithNoCapturedHostClaimsOnlyWhatItKnows() {
    let withTTY = record(tty: "/dev/ttys004").reviveExpectation(fallbackTerminal: "Terminal")
    #expect(withTTY.contains("if it's still open"))
    #expect(!withTTY.contains("can't be scripted"))

    let without = record().reviveExpectation(fallbackTerminal: "Terminal")
    #expect(without == "Reopens in a new Terminal window.")
}

// MARK: - The live probe

/// `Session.tty` used to be decoded from `~/.claude/sessions/<pid>.json`, which
/// has no `tty` field — so it was always nil, `reviveInOriginalTab` was never
/// reached, and every revive opened a new window. It comes from the live
/// process now. This asserts the probe works against the one process the test
/// certainly has: itself.
@Test func theTTYProbeReadsTheLiveProcess() {
    let mine = ProcProbe.tty(getpid())
    // A test bundle may legitimately run with no controlling terminal (CI), so
    // the assertion is on the shape when there is one, not on its presence.
    if let mine { #expect(mine.hasPrefix("/dev/tty")) }
    #expect(ProcProbe.tty(-1) == nil)
}

/// The parent-chain walk must terminate on a process with no GUI ancestor
/// rather than loop, and must not mistake launchd for an application.
@Test func theHostWalkTerminates() {
    #expect(ProcProbe.hostApplication(of: 1) == nil)
    #expect(ProcProbe.hostApplication(of: -1) == nil)
    // Whatever it answers for this process, it answers without hanging.
    _ = ProcProbe.hostApplication(of: getpid())
}
