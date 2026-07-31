import AppKit
import Foundation

/// A small command-line surface alongside the menu bar UI.
///
/// Two reasons this exists rather than being GUI-only: the statusline shim
/// edits a file the user owns, so they should be able to read it before it is
/// installed; and a session manager is genuinely useful from a script.
enum CLI {

    /// Column padding. Deliberately not `String(format:)` — `%s` there expects
    /// a C string, and handing it a Swift String segfaults.
    private static func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
        // Truncate rather than overflow: one over-wide cell — a status value
        // added upstream, say `compacting` — otherwise shifts every later
        // column on that row and only that row, which reads as corrupt output.
        guard s.count < width else { return String(s.prefix(max(0, width - 1))) + " " }
        let fill = String(repeating: " ", count: width - s.count)
        return right ? fill + s : s + fill
    }

    static let usage = """
    Torpor — session manager for Claude Code

    USAGE
      Torpor                          Launch the menu bar app
      Torpor --list                   List running sessions with memory
      Torpor --groups                 List sessions grouped by project folder
      Torpor --hibernated             List hibernated sessions
      Torpor --freeze <pid>           SIGSTOP a session and its MCP subtree
      Torpor --thaw <pid>             SIGCONT it again
      Torpor --hibernate <pid>        Capture argv, terminate, free its memory
      Torpor --preview <pid>          Show what --hibernate would capture, change nothing
      Torpor --revive <session-id>    Reopen it in a terminal, flags replayed
      Torpor --resume-command <id>    Print what --revive would run
      Torpor --emit-shim <path>       Write the statusline shim for inspection
      Torpor --install-statusline     Install the shim into ~/.claude/settings.json
      Torpor --uninstall-statusline   Remove it, restoring any chained statusline
      Torpor --status                 Show quota and statusline state
      Torpor --version                Print the version (-v)
      Torpor --help                   This text (-h)

    DIAGNOSTICS
      Torpor --render <dir>           Render the popover and settings offscreen
      Torpor --render-live <path>     Render the menu bar item as it is right now

    Memory is phys_footprint, compressed pages included — RSS understates an
    idle session by more than 10x.
    """

    /// Returns true when the argument was handled and the process should exit.
    static func run(_ arguments: [String]) -> Bool {
        guard let command = arguments.dropFirst().first else { return false }

        switch command {
        case "--help", "-h":
            print(usage)

        case "--version", "-v":
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            print("Torpor \(version ?? "dev")")

        case "--list":
            let sessions = runningSessions()
            if sessions.isEmpty { print("No running Claude Code sessions."); break }
            print(pad("PID", 7) + pad("STATUS", 9) + pad("IDLE", 12)
                  + pad("FOOTPRINT", 11, right: true) + pad("RESIDENT", 11, right: true)
                  + pad("MCP", 5, right: true) + "  PROJECT")
            var total: UInt64 = 0
            for s in sessions {
                print(pad("\(s.pid)", 7)
                      + pad(s.declaredStatus ?? "unknown", 9)
                      + pad(s.idleFor.map(Fmt.duration) ?? "-", 12)
                      + pad(Fmt.bytes(s.totalFootprint), 11, right: true)
                      + pad(Fmt.bytes(s.totalResident), 11, right: true)
                      + pad("\(s.childCount)", 5, right: true)
                      + "  " + s.projectName)
                total += s.totalFootprint
            }
            print("\n\(sessions.count) session\(sessions.count == 1 ? "" : "s"), \(Fmt.bytes(total)) total footprint")

        case "--groups":
            // Deliberately does NOT construct an Engine: Engine.init starts a
            // poll timer, requests notification authorisation, evaluates
            // notification rules and — if the preference is on — runs
            // auto-hibernate, which terminates processes. A listing command
            // must not do any of that.
            let groups = Engine.group(sessions: runningSessions())
            if groups.isEmpty { print("No running Claude Code sessions."); break }
            for group in groups {
                let flags = group.statusCounts.sorted { $0.key < $1.key }
                    .map { "\($0.value) \($0.key == "busy" ? "working" : $0.key)" }
                let marker = group.allIdle ? "  [all idle — can hibernate as a group]" : ""
                print("\(group.name)  \(Fmt.bytes(group.totalFootprint))  \(flags.joined(separator: ", "))\(marker)")
                for session in group.sessions {
                    let state = session.declaredStatus ?? "unknown"
                    let idle = session.idleFor.map { " \(Fmt.duration($0))" } ?? ""
                    print("    pid \(session.pid)  \(state)\(idle)  \(Fmt.bytes(session.totalFootprint))")
                }
            }

        case "--hibernated":
            let store = HibernationStore()
            // An unreadable store is empty in memory too, and printing "nothing
            // hibernated" for it tells the user their records are gone at the
            // one moment they need them — each holds the only copy of its
            // session's argv.
            if let why = store.loadFailure {
                fail("""
                Could not read \(Paths.hibernationStore.path): \(why)
                Torpor has not written over it, so the records are still there. Move that \
                file aside to start fresh — but the resume commands are in it.
                """)
            }
            if store.sessions.isEmpty { print("Nothing hibernated."); break }
            for record in store.sessions {
                print("\(record.name)  freed \(Fmt.bytes(record.reclaimedBytes))  \(Fmt.duration(Date().timeIntervalSince(record.hibernatedAt))) ago")
                print("  \(record.resumeCommand)")
            }

        case "--emit-shim":
            guard let path = arguments.dropFirst(2).first else {
                usageError("--emit-shim needs a path")
            }
            do {
                try StatuslineInstaller.emitShim(to: URL(fileURLWithPath: path))
                print("Wrote \(path)")
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }

        case "--install-statusline":
            do {
                // The backup sentence is printed only when a backup was really
                // written: on a machine with no settings.json there is nothing
                // to copy, and sending a cautious first-time user to an empty
                // directory is how they learn to distrust the tool that has
                // just edited their Claude Code config.
                if let backup = try StatuslineInstaller.install() {
                    print("Installed. A backup of settings.json is at \(backup.path).")
                } else {
                    print("Installed. You had no settings.json, so there was nothing to back up.")
                }
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }

        case "--uninstall-statusline":
            do {
                try StatuslineInstaller.uninstall()
                print("Removed.")
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }

        case "--status":
            switch StatuslineInstaller.currentState() {
            case .installed: print("statusline: Torpor shim installed")
            case .needsRepair: print("statusline: installed at an unusable path — run --install-statusline to repair")
            case .notInstalled:
                print("statusline: not installed — run --install-statusline to read your usage limits (no credentials, no network calls)")
            case let .foreign(command): print("statusline: another command configured (\(command))")
            case let .settingsUnreadable(why): print("statusline: settings.json unreadable — \(why)")
            }
            if let quota = QuotaReader.read() {
                if let five = quota.fiveHour {
                    print(String(format: "5-hour:  %5.1f%%", five.usedPercentage))
                }
                if let week = quota.sevenDay {
                    print(String(format: "weekly:  %5.1f%%", week.usedPercentage))
                }
                for (name, window) in quota.scoped.sorted(by: { $0.key < $1.key }) {
                    print("weekly \(name): " + String(format: "%5.1f%%", window.usedPercentage))
                }
                print("captured \(Fmt.duration(quota.age)) ago\(quota.isStale ? " (stale)" : "")")
            } else if !QuotaReader.payloadExists {
                print("quota: nothing written yet — numbers arrive the next time a session draws its statusline")
            } else if snapshotIsParseable {
                // The payload is there and carries no `rate_limits`, which is
                // the permanent state of an API-key, Bedrock or Vertex account.
                // "no snapshot yet" told those users to wait for a number that
                // is never coming.
                print("quota: Claude Code sent no plan limits. Only Pro and Max accounts have them.")
            } else {
                print("quota: \(QuotaReader.snapshotURL.path) is unreadable — delete it and it will be rewritten")
            }

        case "--freeze", "--thaw":
            guard let raw = arguments.dropFirst(2).first, let pid = Int32(raw) else {
                usageError("\(command) needs a pid")
            }
            let frozen = FrozenStore()
            do {
                if command == "--freeze" {
                    try SessionControl.freeze(pid: pid, store: frozen)
                    print("Froze \(pid) and its subtree. CPU stops; memory is unchanged.")
                } else {
                    try SessionControl.thaw(pid: pid, store: frozen)
                    print("Thawed \(pid).")
                }
            } catch { fail(error.localizedDescription) }

        case "--preview":
            // Dry run: show exactly what hibernate would capture and what
            // revive would run, without touching the session.
            guard let raw = arguments.dropFirst(2).first, let pid = Int32(raw) else {
                usageError("--preview needs a pid")
            }
            guard let session = runningSessions().first(where: { $0.pid == pid }) else {
                fail("pid \(pid) is not a known Claude Code session")
            }
            guard let captured = ProcProbe.arguments(pid),
                  let executable = captured.argv.first else {
                fail("could not read argv for \(pid) — hibernate would refuse")
            }
            // Same filter hibernate applies before writing the record, so the
            // preview describes the record that would actually be stored —
            // including the refusal. Without this, --preview cheerfully
            // described a hibernate that --hibernate then declined.
            let (replayable, refused) = HibernatedSession.replayable(
                from: Array(captured.argv.dropFirst()))
            let tty = ProcProbe.tty(pid)
            let record = HibernatedSession(
                sessionId: session.sessionId, cwd: session.cwd, name: session.name,
                executable: executable, executablePath: captured.executablePath,
                arguments: replayable,
                hibernatedAt: Date(), reclaimedBytes: session.totalFootprint,
                version: session.version, entrypoint: session.entrypoint, tty: tty)
            print("session:   \(session.projectName) (\(session.sessionId))")
            print("would free: \(Fmt.bytes(session.totalFootprint)) across \(session.childCount + 1) processes")
            print("argv seen:  \(captured.argv.count - 1) flags")
            print("replaying:  \(replayable.isEmpty ? "(none)" : replayable.joined(separator: " "))")
            if !refused.isEmpty {
                // Only the flag names — the values are the reason they are
                // refused (an inline --mcp-config carries its servers' secrets).
                print("refusing:   \(refused.joined(separator: " ")) — carries an inline value Torpor will not store")
                print("hibernate would refuse this session; nothing would be terminated.")
            }
            print("terminal:  " + (tty.map { "\($0) — revive returns to this tab if it is still open" }
                                   ?? "no tty (VS Code-hosted) — revive opens a new window"))
            print("revive runs:")
            print("  cd \(shellQuote(record.cwd)) && \(record.resumeCommand)")

        case "--hibernate":
            guard let raw = arguments.dropFirst(2).first, let pid = Int32(raw) else {
                usageError("--hibernate needs a pid")
            }
            guard let session = runningSessions().first(where: { $0.pid == pid }) else {
                fail("pid \(pid) is not a known Claude Code session")
            }
            // Hibernating is async — it waits out a SIGTERM grace period by
            // yielding rather than blocking — and `run` is synchronous, so this
            // one-shot command drives the main queue itself and exits from
            // inside the task. `dispatchMain()` returns Never, so nothing after
            // it is reachable. The store is held by the task, not left as a
            // temporary the caller has already released.
            let hibernateStore = HibernationStore()
            Task {
                do {
                    let record = try await SessionControl.hibernate(session: session,
                                                                    store: hibernateStore)
                    print("Hibernated \(record.name), reclaimed \(Fmt.bytes(record.reclaimedBytes)).")
                    print("Revive with: Torpor --revive \(record.sessionId)")
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                    exit(1)
                }
            }
            dispatchMain()

        case "--revive":
            guard let id = arguments.dropFirst(2).first else {
                usageError("--revive needs a session id")
            }
            let store = HibernationStore()
            let record = hibernated(matching: id, in: store, flag: "--revive")
            do {
                try SessionControl.revive(record,
                                          terminal: Preferences.load().launchTerminal,
                                          store: store)
                print("Revived \(record.name).")
            } catch { fail(error.localizedDescription) }

        case "--resume-command":
            // Print what revive *would* run, without running it.
            guard let id = arguments.dropFirst(2).first else {
                usageError("--resume-command needs a session id")
            }
            let record = hibernated(matching: id, in: HibernationStore(),
                                    flag: "--resume-command")
            print("cd \(shellQuote(record.cwd)) && \(record.resumeCommand)")

        case "--render-live":
            // Renders the exact item the menu bar is drawing right now, at 8x,
            // so it can be inspected rather than squinted at.
            guard let out = arguments.dropFirst(2).first else {
                usageError("--render-live needs a path")
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let message = MainActor.assumeIsolated { () -> String in
                let engine = Engine(sideEffects: false)
                defer { engine.stop() }
                engine.refresh()
                let saved = engine.preferences.menuBarMetric
                var rows: [(String, NSImage)] = []
                for metric in MenuBarMetric.allCases {
                    engine.preferences.menuBarMetric = metric
                    rows.append((metric.label,
                                 MenuBarRenderer.composite(engine.menuBarInput,
                                                           background: NSColor(white: 0.13, alpha: 1))))
                }
                engine.preferences.menuBarMetric = saved
                let input = engine.menuBarInput

                let scale: CGFloat = 6
                let labelFont = NSFont.systemFont(ofSize: 13, weight: .medium)
                // Measured, not guessed: a hard-coded 150 painted the bar over
                // the tail of "Weekly limit (all models)", and that clipped
                // label shipped in docs/images/menubar.png.
                let labelWidth = (rows.map {
                    NSString(string: $0.0).size(withAttributes: [.font: labelFont]).width
                }.max() ?? 140) + 20
                let rowHeight = (rows.first?.1.size.height ?? 22) * scale + 8
                let widest = rows.map(\.1.size.width).max() ?? 60
                let big = NSSize(width: labelWidth + widest * scale + 16,
                                 height: rowHeight * CGFloat(rows.count))
                let scaled = NSImage(size: big, flipped: false) { rect in
                    NSColor(white: 0.13, alpha: 1).setFill()
                    rect.fill()
                    NSGraphicsContext.current?.imageInterpolation = .none
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: labelFont,
                        .foregroundColor: NSColor.white,
                    ]
                    for (index, row) in rows.enumerated() {
                        let y = big.height - rowHeight * CGFloat(index + 1)
                        NSString(string: row.0).draw(at: NSPoint(x: 10, y: y + rowHeight / 2 - 8),
                                                     withAttributes: attrs)
                        row.1.draw(in: NSRect(x: labelWidth, y: y + 4,
                                              width: row.1.size.width * scale,
                                              height: row.1.size.height * scale))
                    }
                    return true
                }
                guard let tiff = scaled.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    return "encode failed"
                }
                try? png.write(to: URL(fileURLWithPath: out))
                return """
                metric=\(engine.preferences.menuBarMetric.rawValue) \
                style=\(engine.preferences.menuBarStyle.rawValue) \
                colour=\(engine.preferences.colorMode.rawValue)
                fraction=\(input.fraction.map { String(format: "%.3f", $0) } ?? "nil") \
                windowElapsed=\(input.windowElapsed.map { String(format: "%.3f", $0) } ?? "nil")
                """
            }
            print(message)

        case "--render":
            // Offscreen UI render, for review and for CI diffing.
            guard let dir = arguments.dropFirst(2).first else {
                usageError("--render needs an output directory")
            }
            let base = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            // SwiftUI and AppKit drawing both need an initialised NSApplication,
            // but not a visible one.
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let result = MainActor.assumeIsolated { () -> String? in
                do {
                    try PreviewRenderer.menuBarSheet(to: base.appendingPathComponent("menubar.png"))
                    let engine = Engine(sideEffects: false)
                    defer { engine.stop() }
                    engine.refresh()
                    // Token totals now arrive from an off-actor scan, so a
                    // screenshot taken immediately shows none. Let it land.
                    RunLoop.current.run(until: Date().addingTimeInterval(1))
                    try PreviewRenderer.view(PopoverView(engine: engine, openSettings: {}),
                                             size: NSSize(width: 400, height: 700),
                                             to: base.appendingPathComponent("popover.png"))
                    try PreviewRenderer.view(SettingsView(engine: engine),
                                             size: NSSize(width: 620, height: 520),
                                             to: base.appendingPathComponent("settings.png"))
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            if let result { fail(result) }
            print("Rendered menubar.png, popover.png, settings.png into \(dir)")

        default:
            // Nothing we don't recognise may reach the GUI — not a stray flag,
            // and not a subcommand shape either. `Torpor list` used to launch a
            // second menu bar instance that never returned to the shell, with a
            // poll timer, a notification prompt and, if the preference is on,
            // auto-hibernate, which terminates sessions. Only a bare `Torpor`
            // gets the app, which is what docs/cli.md promises.
            if command.hasPrefix("-") {
                usageError("Unknown option: \(command)\n\n\(usage)")
            }
            // The suggestion is read back out of the usage text so a flag added
            // there is offered here without a second list to keep in step.
            if usage.contains(" --\(command) ") {
                usageError("Torpor takes flags, not subcommands — did you mean --\(command)?")
            }
            usageError("Torpor takes flags, not subcommands — try --list, or --help for all of them.")
        }
        return true
    }

    /// Sessions, or a hard stop when the registry is there and unreadable.
    ///
    /// `load()` throws the outcome away, so a schema change upstream came out as
    /// "No running Claude Code sessions." — the app confidently asserting the
    /// opposite of the truth. The popover has an orange card for this state; the
    /// CLI had nothing.
    private static func runningSessions() -> [Session] {
        let result = SessionRegistry.loadDetailed()
        guard !result.looksBroken else {
            fail("""
            Read \(result.filesSeen) session file\(result.filesSeen == 1 ? "" : "s") in \
            \(SessionRegistry.directory.path) and understood none of them.
            Claude Code's session format has probably changed. Check for a Torpor update.
            """)
        }
        return result.sessions
    }

    /// Resolve a session-id prefix to exactly one hibernated record.
    ///
    /// An empty id used to match the first record, because `"".hasPrefix` is
    /// true for everything — so `--revive "$SESSION"` with the variable unset
    /// opened a terminal for a session the user never named. An ambiguous
    /// prefix picked whichever record happened to be first in the file.
    private static func hibernated(matching id: String,
                                   in store: HibernationStore,
                                   flag: String) -> HibernatedSession {
        guard !id.isEmpty else { usageError("\(flag) needs a session id") }
        // Case-insensitive: a session id copied out of a UI that upper-cased it
        // otherwise matched nothing at all.
        let prefix = id.lowercased()
        let matches = store.sessions.filter { $0.sessionId.lowercased().hasPrefix(prefix) }
        guard let record = matches.first else {
            // "no hibernated session matching X" would be a lie when the file
            // holding them simply did not decode.
            if let why = store.loadFailure {
                fail("could not read \(Paths.hibernationStore.path): \(why)")
            }
            fail("no hibernated session matching \(id)")
        }
        guard matches.count == 1 else {
            fail("\(id) matches \(matches.count) hibernated sessions:\n"
                 + matches.map { "  \($0.sessionId)  \($0.name)" }.joined(separator: "\n"))
        }
        return record
    }

    /// Whether the statusline snapshot is at least well-formed JSON.
    ///
    /// Tells "written, but this account has no plan limits" — permanent for an
    /// API-key, Bedrock or Vertex account — apart from "written and corrupt",
    /// which `QuotaReader.read()` reports as the same nil.
    private static var snapshotIsParseable: Bool {
        guard let data = try? Data(contentsOf: QuotaReader.snapshotURL) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// The command ran and failed.
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }

    /// The command was never run, because the arguments were wrong.
    ///
    /// Separate exit code because docs/cli.md promises one: a script has to be
    /// able to tell "I passed garbage" (2) from "the freeze genuinely failed"
    /// (1), and every missing-argument guard used to exit 1.
    private static func usageError(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(2)
    }
}
