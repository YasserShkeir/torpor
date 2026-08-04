import AppKit
import Foundation
import Testing
@testable import Torpor

/// Reviving into the original tab works by matching a tty against Terminal or
/// iTerm over AppleScript. That is the whole scriptable set: VS Code exposes no
/// API for its integrated terminal, and the alternative is closed off by the
/// kernel — `TIOCSTI` against a tty the process does not control returns EPERM,
/// measured. So for those sessions the honest outcome is to hand the user the
/// command and name the app it belongs in, rather than open a window they did
/// not ask for. These tests pin the decision, the string, and the sentence.
///
/// What is not tested here is the clipboard write and the activation: both need
/// a live pasteboard and a live process, and asserting on the general
/// pasteboard would clobber whatever the developer had copied. What can be
/// pinned without either is everything that decides *which* of them happens and
/// *what* goes into them, which is where the bugs would be.

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

// MARK: - Which way a record goes

/// The two shapes that cannot be driven back to a tab, and so are handed over
/// instead of being guessed at with a new window.

@Test func anUnscriptableHostIsHandedOff() {
    #expect(SessionControl.route(for: record(tty: "/dev/ttys004",
                                             hostApplication: "VS Code")) == .handoff)
    #expect(SessionControl.route(for: record(tty: "/dev/ttys004",
                                             hostApplication: "Cursor")) == .handoff)
}

/// `revive` matches a tab by tty and gives up at once without one, so no tty is
/// a handoff whatever the host says — a scriptable host is not enough.
@Test func aRecordWithNoTTYIsHandedOffWhateverTheHost() {
    #expect(SessionControl.route(for: record(hostApplication: "Terminal")) == .handoff)
    #expect(SessionControl.route(for: record(hostApplication: "iTerm")) == .handoff)
    #expect(SessionControl.route(for: record()) == .handoff)
}

/// The path the handoff must not have swallowed: a scriptable host with a live
/// tty still goes for the tab it died in.
@Test(arguments: ["Terminal", "iTerm"])
func aScriptableHostWithATTYStillTakesTheOriginalTab(_ host: String) {
    #expect(SessionControl.route(for: record(tty: "/dev/ttys004",
                                             hostApplication: host)) == .originalTab)
}

/// A record written before hosts were captured has no host and still gets the
/// tab search: nil means "not known", not "not scriptable", and those records
/// are the ones the tab match was written for.
@Test func aRecordWithNoCapturedHostStillTriesItsTab() {
    #expect(SessionControl.route(for: record(tty: "/dev/ttys004")) == .originalTab)
}

// MARK: - The string that gets handed over

/// What lands on the clipboard has to be a line a shell will accept verbatim —
/// the user pastes it and presses Return, with nothing left to fix up.
@Test func theHandedOverLineIsWhatAShellNeeds() {
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
/// resume itself is not run — `claude` need not exist here — so the assertion
/// is on the `cd` half actually landing, which is the half the quoting can
/// break.
@Test func aRealShellAcceptsTheHandedOverLine() throws {
    let temp = try TempDir()
    defer { temp.remove() }
    let target = try temp.makeDirectory(named: "it's a $(dir)")

    let session = record(cwd: target.path)
    // Everything up to the resume: the half a shell can be asked to run here.
    // Asserted by a marker file, which no amount of path normalisation can
    // make ambiguous.
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

/// The one difference from the line `revive` runs in a tab. `clear` is there to
/// hide the dead session's scrollback in its *own* tab; wiping the scrollback of
/// a tab the user chose to paste into is not ours to do.
@Test func theHandedOverLineDoesNotClearTheUsersScrollback() {
    #expect(!record(cwd: "/tmp/p").resumeCommandLine.contains("clear"))
}

// MARK: - What the outcome says

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

/// A handoff has to name the app it brought forward, or the user is left
/// holding a clipboard with no idea where it was meant to go.
@Test func aHandoffNamesTheAppItBroughtForward() {
    let notice = SessionControl.notice(
        for: .handedOff(host: "VS Code", broughtForward: true),
        record: record(tty: "/dev/ttys004", hostApplication: "VS Code"))
    #expect(notice.contains("VS Code"))
    #expect(notice.lowercased().contains("paste"))
    // And says nothing about a window, because none was opened.
    #expect(!notice.contains("window"))
}

/// Nothing was raised — the app is closed, or this is `--revive` from a shell,
/// which cannot raise anything. Claiming otherwise sends the user hunting for a
/// window that never came forward. The app is still named: it is where the
/// session was, and where the paste belongs.
@Test func aHandoffThatRaisedNothingDoesNotClaimToHave() {
    let notice = SessionControl.notice(
        for: .handedOff(host: "Cursor", broughtForward: false),
        record: record(tty: "/dev/ttys004", hostApplication: "Cursor"))
    #expect(notice.contains("Cursor"))
    #expect(!notice.contains("brought"))
    #expect(notice.lowercased().contains("paste"))
}

/// No host was ever captured, so there is no app to name and none is invented.
@Test func aHandoffWithNoKnownHostNamesNothing() {
    let notice = SessionControl.notice(for: .handedOff(host: nil, broughtForward: false),
                                       record: record())
    #expect(notice.lowercased().contains("paste"))
    #expect(!notice.contains("brought"))
}

// MARK: - Said before the click

/// The popover's line is rendered per row on every poll tick, so it must be a
/// pure read of the record. These pin what each captured shape claims.

@Test func aScriptableHostPromisesTheOriginalTab() {
    let line = record(tty: "/dev/ttys004", hostApplication: "Terminal")
        .reviveExpectation(fallbackTerminal: "Terminal")
    #expect(line.contains("original Terminal tab"))
}

/// The user should learn this while deciding, not after the fact — activating
/// the host closes the popover the notice would have been written into. And it
/// has to read as a choice rather than a failure: Torpor knows which app the
/// session lived in and knows it cannot type into it, so it says what it will
/// do instead, naming the app.
@Test func anUnscriptableHostIsNamedBeforeTheClick() {
    let line = record(tty: "/dev/ttys004", hostApplication: "VS Code")
        .reviveExpectation(fallbackTerminal: "iTerm")
    #expect(line.contains("VS Code"))
    #expect(line.hasPrefix("Copies the command"))
    // No window is promised, because the plain click will not open one.
    #expect(!line.contains("window"))
}

/// `revive` matches a tab by tty and gives up at once without one, so a
/// scriptable host is not on its own enough to promise the original tab — and
/// the app is still worth naming, since it is the one being brought forward.
@Test func aScriptableHostWithNoTTYDoesNotPromiseATab() {
    let line = record(hostApplication: "Terminal")
        .reviveExpectation(fallbackTerminal: "Terminal")
    #expect(!line.contains("original"))
    #expect(line.contains("no tty"))
    #expect(line.contains("Terminal"))
}

/// A record written before hosts were captured knows only that it had a tty.
/// Claiming more than that would be the same dishonesty in the other direction.
@Test func aRecordWithNoCapturedHostClaimsOnlyWhatItKnows() {
    let withTTY = record(tty: "/dev/ttys004").reviveExpectation(fallbackTerminal: "Terminal")
    #expect(withTTY.contains("if it's still open"))
    #expect(!withTTY.contains("can't be scripted"))

    // Neither a tab nor a host: nothing to bring forward and nothing to name.
    let without = record().reviveExpectation(fallbackTerminal: "Terminal")
    #expect(without.hasPrefix("Copies the command"))
    #expect(!without.contains("Terminal"))
}

/// The sentence under the button and the button itself have to be the same
/// decision. They were two copies of one condition; this pins that they agree
/// for every shape a record can take.
@Test func theSentenceAndTheButtonAgree() {
    for tty in [nil, "/dev/ttys004"] {
        for host in [nil, "Terminal", "iTerm", "VS Code", "Ghostty"] {
            let session = record(tty: tty, hostApplication: host)
            let line = session.reviveExpectation(fallbackTerminal: "Terminal")
            let handsOff = SessionControl.route(for: session) == .handoff
            #expect(line.hasPrefix("Copies the command") == handsOff,
                    "tty \(tty ?? "nil"), host \(host ?? "nil"): \(line)")
        }
    }
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

/// The handoff brings the host forward by looking a recorded *name* back up
/// among the running applications. A name nothing answers to must be nil rather
/// than a wrong app — activating the wrong window would put the paste target
/// somewhere the user is not looking.
@Test func anUnknownHostNameResolvesToNoApplication() {
    #expect(ProcProbe.runningApplication(named: "Not An App \(UUID().uuidString)") == nil)
    #expect(ProcProbe.runningApplication(named: "") == nil)
}

/// The `localizedName` fallback, against the one application a Mac with a
/// window server always has running. Skipped where there is no GUI session,
/// which is honest rather than a failure.
@Test func aRunningApplicationIsFoundByTheNameItWasRecordedUnder() {
    guard !NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty else { return }
    #expect(ProcProbe.runningApplication(named: "Finder")?.bundleIdentifier
            == "com.apple.finder")
}

/// The parent-chain walk must terminate on a process with no GUI ancestor
/// rather than loop, and must not mistake launchd for an application.
@Test func theHostWalkTerminates() {
    #expect(ProcProbe.hostApplication(of: 1) == nil)
    #expect(ProcProbe.hostApplication(of: -1) == nil)
    // Whatever it answers for this process, it answers without hanging.
    _ = ProcProbe.hostApplication(of: getpid())
}
