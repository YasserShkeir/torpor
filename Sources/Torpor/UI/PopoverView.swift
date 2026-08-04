import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var engine: Engine
    var openSettings: () -> Void
    @State private var confirmingReclaimAll = false
    /// sessionId of the record whose Forget is armed. Forget destroys the only
    /// saved copy of a session's command line — the one action in this panel
    /// that cannot be undone — so it is gated like hibernate, which can.
    @State private var confirmingForget: String?
    @ObservedObject private var log = MessageLog.shared
    /// Deliberately not in Preferences: a preferences file that fails to decode
    /// would otherwise replay the welcome to an existing user.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    var body: some View {
        // Torpor is an .accessory app, so without this a new user's first
        // interaction is a bare notification-permission dialog from something
        // with no window and no dock icon. The policy check keeps `--render`,
        // which runs .prohibited, capturing the panel rather than the welcome.
        if !hasSeenWelcome, NSApplication.shared.activationPolicy() == .accessory {
            FirstRunView(engine: engine) { hasSeenWelcome = true }
                .frame(width: 400)
        } else {
            mainPanel
        }
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    quotaSection
                    sessionsSection
                    if !engine.hibernated.isEmpty { hibernatedSection }
                    // An unreadable store rendered as no section at all, which
                    // reads as "nothing hibernated" — the opposite of the truth,
                    // at the one moment the records matter.
                    if let why = engine.hibernationLoadFailure {
                        VStack(alignment: .leading, spacing: 5) {
                            SectionHeader("Hibernated")
                            Text("Couldn't read your hibernated sessions")
                                .font(.callout).bold()
                            Text("\(why)\n\nThe file hasn't been overwritten, so the records are still on disk at ~/Library/Application Support/Torpor/hibernated.json.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 520)

            if !log.messages.isEmpty {
                Divider()
                MessageStrip(log: log, horizontalPadding: 14)
            }

            Divider()
            footer
        }
        .frame(width: 400)
        .logsEngineMessages(engine)
        .onChange(of: engine.confirmationGeneration) {
            confirmingReclaimAll = false
            confirmingForget = nil
        }
    }

    // MARK: - Header

    /// One line.
    ///
    /// The app name is dropped: this popover only ever appears under Torpor's
    /// own menu bar item, so the title was a row of pixels telling the user
    /// something they had just clicked. "Reclaimable" was also the loudest
    /// element on the panel and completely inert — it is now the button.
    private var header: some View {
        HStack(spacing: 8) {
            Text(engine.sessions.isEmpty
                 ? "No sessions"
                 : "^[\(engine.sessions.count) session](inflect: true)")
                .font(.system(size: 12, weight: .semibold))
            Text(Fmt.bytes(engine.totalFootprint))
                .font(.system(size: 11, design: .rounded)).monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)

            if engine.reclaimableFootprint > 0 {
                if confirmingReclaimAll {
                    Button("Hibernate \(reclaimableSessions.count)") {
                        confirmingReclaimAll = false
                        engine.hibernateIdleSessions()
                    }
                    .controlSize(.small).tint(.orange)
                    .disabled(engine.isBusyWithBatch)
                    Button { confirmingReclaimAll = false } label: {
                        Image(systemName: "xmark").font(.system(size: 8))
                    }
                    .buttonStyle(.borderless).controlSize(.mini)
                } else {
                    Button {
                        confirmingReclaimAll = true
                    } label: {
                        // Named for what it does. "Reclaim" was a fourth verb
                        // for an action the rest of the app — including this
                        // button's own tooltip — calls hibernate.
                        Label("Hibernate \(reclaimableSessions.count) idle · \(Fmt.bytes(engine.reclaimableFootprint))",
                              systemImage: "moon.zzz.fill")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .tint(.orange)
                    .help("Hibernate \(reclaimableSessions.count) session\(reclaimableSessions.count == 1 ? "" : "s") idle for \(Int(engine.preferences.notifyIdleMinutes)) minutes or more.")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var reclaimableSessions: [Session] {
        let cutoff = max(0, engine.preferences.notifyIdleMinutes) * 60
        return engine.sessions.filter { $0.declaredStatus == "idle" && ($0.idleFor ?? 0) >= cutoff }
    }

    // MARK: - Usage

    @ViewBuilder
    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                SectionHeader("Usage")
                Spacer()
                if let quota = engine.quota {
                    Circle()
                        .fill(quota.isStale ? Color.orange : Color.green)
                        .frame(width: 4, height: 4)
                    Text(quota.isStale ? "stale · \(Fmt.duration(quota.age))"
                                       : Fmt.duration(quota.age))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .help(quota.isStale
                              ? "Read \(Fmt.duration(quota.age)) ago. Refreshes when a session redraws its statusline."
                              : "Read \(Fmt.duration(quota.age)) ago.")
                }
            }

            if let quota = engine.quota {
                if let five = quota.fiveHour {
                    GaugeRow(label: "5-hour", window: five, windowLength: 5 * 3600)
                }
                if let week = quota.sevenDay {
                    GaugeRow(label: "Week", window: week, windowLength: 7 * 86_400)
                }
                ForEach(engine.visibleScopedRows, id: \.name) { row in
                    GaugeRow(label: row.name, window: row.window, windowLength: 7 * 86_400)
                }
                // Claude.ai shows a per-model weekly row and the statusline does
                // not, so the absence looks like a Torpor bug rather than a
                // missing field. Say where the rows come from, once, here —
                // buried in Settings it only got read by people not looking for
                // it.
                if engine.visibleScopedRows.isEmpty, engine.preferences.authMode == .statusline {
                    Button(action: openSettings) {
                        Text("No per-model rows on this source. Fable and Opus come from your account, not the statusline.")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                            .underline()
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .help("Per-model rows come from your account, not the statusline. Torpor can read them with your own OAuth credential — see the Account tab first.")
                }
            } else {
                notConnectedCard
            }

            if engine.credits.hasAnything { creditsRow }

            if let console = engine.console, console.monthToDateUSD > 0 {
                HStack {
                    Text("Console spend, month to date").font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("$\(String(format: "%.2f", console.monthToDateUSD))")
                        .font(.system(size: 10, design: .rounded)).monospacedDigit()
                }
            }

            let week = engine.weekTokens
            if week.total > 0 {
                Text(week.subagentTokens > 0
                     ? "\(Fmt.tokens(week.total)) tokens in open sessions · \(Int(Double(week.subagentTokens) / Double(week.total) * 100))% from subagents"
                     : "\(Fmt.tokens(week.total)) tokens in open sessions · \(Fmt.tokens(week.billable)) billable")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }

        }
    }

    private var creditsRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider().padding(.vertical, 2)
            if let remaining = engine.credits.remainingUSD {
                HStack {
                    Text("Usage credits").font(.caption)
                    Spacer()
                    Text("$\(String(format: "%.2f", remaining))")
                        .font(.system(.caption, design: .rounded)).bold().monospacedDigit()
                }
            }
            if let oneTime = engine.credits.oneTimeRemainingUSD {
                HStack {
                    Text("One-time credit").font(.caption)
                    Spacer()
                    Text("$\(String(format: "%.2f", oneTime))")
                        .font(.system(.caption, design: .rounded)).monospacedDigit()
                    if let expiry = engine.credits.oneTimeExpiresAt {
                        Text("· expires \(Fmt.duration(expiry.timeIntervalSinceNow))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if engine.credits.usingExtraUsage {
                Label("Spending overage credits, not plan quota", systemImage: "creditcard")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var notConnectedCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("No usage data yet").font(.callout).bold()
            Text(engine.usageEmptyExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if engine.preferences.authMode == .statusline,
                   engine.statuslineState != .installed {
                    Button("Set up usage reporting") { engine.installStatusline() }
                        .controlSize(.small)
                }
                Button("Open Settings", action: openSettings)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader("Sessions")
                Spacer()
                if !engine.sessions.isEmpty {
                    Text("\(Fmt.bytes(engine.totalFootprint))")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if engine.sessions.isEmpty {
                if engine.registryLooksBroken {
                    // There are session files and Torpor decoded none of them,
                    // which is not the same fact as "nothing is running" — and
                    // rendering it as the latter is the app confidently saying
                    // the opposite of the truth.
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Torpor can't read the session list",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).bold().foregroundStyle(.orange)
                        Text(engine.sessionsEmptyExplanation)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Check for Updates…") { engine.updater.checkForUpdates() }
                                .controlSize(.small)
                                .disabled(!engine.updater.canCheck)
                            Button("Report this") { NSWorkspace.shared.open(Links.issues) }
                                .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                } else {
                    Text(engine.sessionsEmptyExplanation)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }

            if engine.preferences.groupByProject {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(engine.groupedSessions) { group in
                        ProjectGroupView(group: group, engine: engine)
                    }
                }
            } else {
                VStack(spacing: 1) {
                    ForEach(engine.sessions) { session in
                        SessionRow(session: session,
                                   tokens: engine.tokens[session.sessionId] ?? TokenTotals(),
                                   engine: engine)
                    }
                }
            }
        }
    }

    /// What was freed, how long ago, and the effort level revive will restore.
    ///
    /// The level is shown because it is the part of the session's configuration
    /// the user cannot see anywhere else: `/effort` never reaches argv, so
    /// nothing on the row would otherwise say it survived the round trip. Only
    /// a level revive will actually pass is shown — advertising one the CLI
    /// would reject is worse than saying nothing.
    private static func hibernatedDetail(_ record: HibernatedSession) -> String {
        var parts = ["\(Fmt.bytes(record.reclaimedBytes)) freed",
                     "\(Fmt.duration(Date().timeIntervalSince(record.hibernatedAt))) ago"]
        if let effort = record.replayableEffort { parts.append("\(effort) effort") }
        return parts.joined(separator: " · ")
    }

    private var hibernatedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Hibernated")
            ForEach(engine.hibernated) { record in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.name).font(.callout)
                            Text(Self.hibernatedDetail(record))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revive") { engine.revive(record) }
                            .controlSize(.small)
                            .help(record.resumeCommand)

                        if confirmingForget == record.sessionId {
                            Button("Forget") {
                                confirmingForget = nil
                                engine.forget(record)
                            }
                            .controlSize(.small).tint(.red)
                            Button { confirmingForget = nil } label: {
                                Image(systemName: "xmark").font(.system(size: 8))
                            }
                            .buttonStyle(.borderless).controlSize(.mini)
                        } else {
                            Button { confirmingForget = record.sessionId } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                            .accessibilityLabel("Forget \(record.name)")
                            .accessibilityHint("Discards the saved command line. The conversation stays on disk but Torpor can no longer reopen it for you.")
                            .help("Forget this session. The conversation stays on disk; Torpor loses the command line that reopens it.")
                        }
                    }

                    if confirmingForget == record.sessionId {
                        Text("Loses the captured flags — --mcp-config, --add-dir. The conversation stays on disk.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        // Said before the click, not after it. Reviving
                        // activates the terminal and closes this popover, so an
                        // after-the-fact notice about the original tab being
                        // unreachable lands on a panel nobody is looking at —
                        // and it changes what the button is going to do.
                        Text(record.reviveExpectation(
                            fallbackTerminal: engine.preferences.launchTerminal))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(9)
                .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: openSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless).controlSize(.small)
            .keyboardShortcut(",", modifiers: .command)

            Spacer()

            Button("Refresh") { engine.refresh() }
                .buttonStyle(.borderless).controlSize(.small)
                // The only action in this panel that is idempotent and ends
                // nothing, so the only one that can safely carry a key
                // equivalent in a transient popover.
                .keyboardShortcut("r", modifiers: .command)
                // Every hibernate button greys out during a batch; this one did
                // not, and refresh runs the reconcile loop.
                .disabled(engine.isBusyWithBatch)

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).controlSize(.small)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

// MARK: - First run

/// One screen, shown once, before Torpor asks the user for anything.
///
/// Deliberately not a tour: two verbs, one offer and one warning about the
/// permission dialog macOS is about to show. Closing the popover without
/// choosing leaves it in place, which is right — nothing has been asked yet.
struct FirstRunView: View {
    @ObservedObject var engine: Engine
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Torpor manages the Claude Code sessions you leave open.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                verb("pause.circle.fill", .cyan, "Freeze",
                     "Pauses a session: no CPU, memory unchanged. Thaw puts it back.")
                verb("moon.zzz.fill", .orange, "Hibernate",
                     "Ends a session and gives back its memory. Revive reopens it where it was.")
            }

            Divider()

            // "your prompt looks the same" on its own was false for the common
            // case: Claude Code ships no statusline, so most people gain one.
            // The Account tab has said so all along; the first thing a new user
            // reads did not.
            Text("Usage comes from a small script Torpor adds to your Claude Code statusline. No credentials, no network calls. It runs whatever statusline you already had, so your prompt looks the same — if you had none, it prints the model and folder.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("macOS may ask about notifications — used only for idle sessions and usage warnings.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if engine.statuslineState != .installed {
                    Button("Set up usage reporting") {
                        engine.installStatusline()
                        done()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Spacer()
                Button("Skip") { done() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(16)
    }

    private func verb(_ symbol: String, _ tint: Color, _ name: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout).bold()
                Text(text).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Messages

/// One error or notice, with the moment Torpor first saw it.
struct LoggedMessage: Identifiable, Equatable {
    enum Kind { case error, notice }
    let id = UUID()
    let kind: Kind
    let text: String
    let at: Date
}

/// The engine's errors and notices, with arrival times and a dismiss.
///
/// The engine publishes one `lastError` and one `lastNotice` slot: no
/// timestamp, no dismiss, and clearing happens only when a *later* action
/// succeeds — so a failure with no follow-up sat there forever and a second
/// failure silently erased the first. Watching those two slots from the views
/// that render them fixes all three without changing the engine, and sharing
/// one instance means the popover and Settings agree on the list.
final class MessageLog: ObservableObject {
    static let shared = MessageLog()

    @Published private(set) var messages: [LoggedMessage] = []

    /// This is a strip above a footer, not a console.
    private let cap = 5
    private var lastSeenError: String?
    private var lastSeenNotice: String?

    func absorb(error: String?, notice: String?) {
        // Compared against what was last *seen*, not what is still listed, so a
        // dismissed message does not immediately come back while the engine
        // still holds it in its slot.
        if error != lastSeenError {
            lastSeenError = error
            add(.error, error)
        }
        if notice != lastSeenNotice {
            lastSeenNotice = notice
            add(.notice, notice)
        }
    }

    func dismiss(_ id: UUID) { messages.removeAll { $0.id == id } }
    func dismissAll() { messages.removeAll() }

    private func add(_ kind: LoggedMessage.Kind, _ text: String?) {
        guard let text, !text.isEmpty else { return }
        messages.insert(LoggedMessage(kind: kind, text: text, at: Date()), at: 0)
        if messages.count > cap { messages.removeLast(messages.count - cap) }
    }
}

extension View {
    /// Feeds the engine's one-slot error and notice into the shared log.
    func logsEngineMessages(_ engine: Engine) -> some View {
        onAppear {
            MessageLog.shared.absorb(error: engine.lastError, notice: engine.lastNotice)
        }
        .onChange(of: engine.lastError) {
            MessageLog.shared.absorb(error: engine.lastError, notice: engine.lastNotice)
        }
        .onChange(of: engine.lastNotice) {
            MessageLog.shared.absorb(error: engine.lastError, notice: engine.lastNotice)
        }
    }
}

/// The message log, rendered. Shared by the popover and Settings so an error
/// raised in one is dismissible in the other.
struct MessageStrip: View {
    @ObservedObject var log: MessageLog
    var horizontalPadding: CGFloat
    /// Settings can accumulate several at once across its tabs; the popover
    /// rarely shows more than one.
    var showsDismissAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(log.messages) { message in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: message.kind == .error
                          ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(message.kind == .error ? Color.orange : Color.secondary)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(message.text)
                            .font(.caption)
                            .foregroundStyle(message.kind == .error ? Color.primary : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // Relative age: this panel is transient, and "4m ago"
                        // is what tells you whether it described what you just
                        // did or something from before you opened the window.
                        Text("\(Fmt.duration(Date().timeIntervalSince(message.at))) ago")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    Button { log.dismiss(message.id) } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Dismiss")
                }
            }
            if showsDismissAll, log.messages.count > 1 {
                Button("Dismiss all") { log.dismissAll() }
                    .buttonStyle(.borderless).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalPadding).padding(.vertical, 7)
    }
}

// MARK: - Components

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.caption2).bold()
            .foregroundStyle(.secondary)
            .kerning(0.6)
            // Lets the VoiceOver rotor jump Usage → Sessions → Hibernated.
            .accessibilityAddTraits(.isHeader)
    }
}

/// One usage window on a single line: label, inline bar, percentage, countdown.
///
/// The previous two-line form (label row above a full-width bar) cost about
/// 26pt per window; three windows plus a freshness row filled a third of the
/// panel before a single session appeared.
struct GaugeRow: View {
    let label: String
    let window: QuotaSnapshot.Window
    /// Length of the window this belongs to, used to place the pace tick.
    let windowLength: TimeInterval

    private var tint: Color {
        switch window.usedPercentage {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    /// How far through the window we are, 0…1. Anthropic publishes the window
    /// structure but not a start time, so this is derived from the reset time.
    private var elapsed: Double? {
        guard let resets = window.resetsAt, windowLength > 0 else { return nil }
        let remaining = resets.timeIntervalSinceNow
        guard remaining > 0, remaining <= windowLength else { return nil }
        return 1 - (remaining / windowLength)
    }

    private var countdown: String {
        guard let resets = window.resetsAt, resets > Date() else { return "" }
        return Fmt.duration(resets.timeIntervalSinceNow)
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
                .lineLimit(1)

            InlineBar(fraction: min(window.usedPercentage / 100, 1),
                      elapsed: elapsed, tint: tint)
                .frame(height: 6)
                .padding(.vertical, 3)

            Text("\(Int(window.usedPercentage))%")
                .font(.system(size: 10, design: .rounded)).bold()
                .foregroundStyle(tint).monospacedDigit()
                .frame(width: 32, alignment: .trailing)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            // 34pt fitted "2h 49m" and not "23h 59m", which the weekly window
            // shows for a whole day near its reset — and a too-narrow frame
            // makes SwiftUI wrap rather than clip, so the row silently grew a
            // second line. Sized for the longest string Fmt.duration emits, and
            // told outright never to wrap.
            Text(countdown)
                .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 46, alignment: .trailing)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(Int(window.usedPercentage)) percent used"
                            + (countdown.isEmpty ? "" : ", resets in \(countdown)"))
    }
}

/// Track, fill, and a tick marking elapsed time in the window.
///
/// Fill left of the tick means you are inside the pace the window can carry;
/// fill past it means you are burning faster than the clock.
struct InlineBar: View {
    let fraction: Double
    let elapsed: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.20))
                Capsule()
                    .fill(tint)
                    // Never render a sliver so thin it reads as empty.
                    .frame(width: max(height, width * fraction))
                if let elapsed {
                    // Same marker as the menu bar: solid white, standing proud
                    // of the bar at both ends so it reads as a deliberate mark.
                    // The faint dark edge keeps it legible in light mode, where
                    // white over the unfilled track would otherwise vanish.
                    let inset = 1.5 / max(width, 1)
                    let position = min(max(elapsed, inset), 1 - inset)
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.35))
                            .frame(width: 3, height: height + 7)
                        Rectangle()
                            .fill(.white)
                            .frame(width: 2, height: height + 6)
                    }
                    .offset(x: width * position - 1.5)
                    // The one place the marker is explained outside Settings.
                    .help("\(Int(elapsed * 100))% of this window has elapsed. "
                          + MenuBarMetric.markerMeaning)
                }
            }
        }
    }
}

/// One working directory and every session inside it.
///
/// Deliberately single-line: with a dozen sessions across seven projects, a
/// two-line header plus two-line rows made the panel taller than the screen.
struct ProjectGroupView: View {
    let group: Engine.ProjectGroup
    @ObservedObject var engine: Engine
    @State private var collapsed = false
    @State private var confirming = false

    /// Renders every status present, so the counts always sum to the number of
    /// rows below. "busy" is shown as "working" for consistency with the row
    /// labels; anything else is shown under its own name.
    private var counts: String {
        let order = ["busy", "idle"]
        let histogram = group.statusCounts
        var parts: [String] = []
        for key in order where (histogram[key] ?? 0) > 0 {
            parts.append("\(histogram[key]!) \(key == "busy" ? "working" : key)")
        }
        for (key, value) in histogram.sorted(by: { $0.key < $1.key })
        where !order.contains(key) && value > 0 {
            parts.append("\(value) \(key)")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.1)) { collapsed.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 8)
                        Text(group.name).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(counts).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Three unlabelled children otherwise: VoiceOver read a chevron
                // glyph name, the folder, and a bare count with no relation.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(group.name), \(counts), \(Fmt.bytes(group.totalFootprint))")
                .accessibilityHint(collapsed ? "Shows the sessions in this project" : "Hides them")
                .accessibilityAddTraits(.isButton)

                Spacer(minLength: 4)

                Text(Fmt.bytes(group.totalFootprint))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(group.allIdle ? .orange : .secondary)

                // Only offered when every session here is explicitly idle —
                // never when one is working, and never when one's status is
                // unknown, because those cannot be judged safe.
                if group.allIdle {
                    if confirming {
                        Button("Hibernate \(group.sessions.count)") {
                            confirming = false
                            engine.hibernateGroup(group)
                        }
                        .controlSize(.mini).tint(.orange)
                        .disabled(engine.isBusyWithBatch)
                        Button {
                            confirming = false
                        } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                            .buttonStyle(.borderless).controlSize(.mini)
                    } else {
                        Button {
                            confirming = true
                        } label: {
                            Image(systemName: "moon.zzz.fill").font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.orange)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .disabled(engine.isBusyWithBatch)
                        .accessibilityLabel("Hibernate all idle sessions in \(group.name)")
                        .accessibilityHint("Ends \(group.sessions.count) sessions and frees \(Fmt.bytes(group.totalFootprint))")
                        .help("Hibernate all \(group.sessions.count) idle session\(group.sessions.count == 1 ? "" : "s") in \(group.name) — frees \(Fmt.bytes(group.totalFootprint)).")
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(group.allIdle ? Color.orange.opacity(0.09) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 5))

            if confirming {
                Text("Frees \(Fmt.bytes(group.totalFootprint)). Each revives in one click.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !collapsed {
                VStack(spacing: 1) {
                    ForEach(group.sessions) { session in
                        SessionRow(session: session,
                                   tokens: engine.tokens[session.sessionId] ?? TokenTotals(),
                                   engine: engine,
                                   showsProject: false)
                    }
                }
                .padding(.leading, 8)
            }
        }
        .onChange(of: engine.confirmationGeneration) { confirming = false }
    }
}

struct SessionRow: View {
    let session: Session
    let tokens: TokenTotals
    @ObservedObject var engine: Engine
    /// False inside a project group, where repeating the folder name on every
    /// row is noise — the row shows what distinguishes it instead.
    var showsProject: Bool = true
    @State private var expanded = false
    @State private var confirmingHibernate = false

    /// Leads with termination. The previous copy ("frees N and reopens on
    /// demand") described suspend-to-disk, which is not what happens.
    private var hibernateExplanation: String {
        switch session.declaredStatus {
        case "idle":
            return "Hibernate ends this session and frees \(Fmt.bytes(session.totalFootprint)). One click reopens it where it was."
        case "busy":
            return "Working. Freeze pauses it; hibernate waits until it's idle."
        default:
            return "Status unknown, so Torpor won't end it. Freeze still works."
        }
    }

    private var statusColor: Color {
        if session.isFrozen { return .cyan }
        switch session.declaredStatus {
        case "busy": return .green
        case "idle": return .secondary
        default: return .yellow
        }
    }

    private var statusSymbol: String {
        if session.isFrozen { return "pause.circle.fill" }
        switch session.declaredStatus {
        case "busy": return "circle.fill"
        case "idle": return "circle"
        default: return "questionmark.circle"
        }
    }

    private var statusText: String {
        if session.isFrozen { return "frozen" }
        guard let status = session.declaredStatus else { return "unknown" }
        if status == "idle", let idle = session.idleFor { return "idle \(Fmt.duration(idle))" }
        return status
    }

    /// What Claude Code reports about this session's context window and cost.
    private var usage: SessionUsage? { engine.sessionUsage[session.sessionId] }

    /// Context occupancy, but only once it is worth acting on. Below this the
    /// number is in the expanded detail; above it, the conversation is close to
    /// being compacted, which is the one context fact a collapsed row can use.
    private var contextPressure: Double? {
        guard let percent = usage?.contextUsedPercentage, percent >= 70 else { return nil }
        return percent
    }

    private var contextSummary: String? {
        guard let percent = usage?.contextUsedPercentage else { return nil }
        guard let resident = usage?.contextTokens, let size = usage?.contextWindowSize, size > 0 else {
            return "\(Int(percent))% full"
        }
        return "\(Int(percent))% full · \(Fmt.tokens(resident)) of \(Fmt.tokens(size))"
    }

    /// Registry names look like `<project>-<suffix>`; inside a group the
    /// project part is already in the header, so only the suffix is shown.
    private var title: String {
        if showsProject { return session.projectName }
        let base = session.projectName
        if session.name.hasPrefix(base + "-") {
            return String(session.name.dropFirst(base.count + 1))
        }
        return session.name.isEmpty ? "pid \(session.pid)" : session.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.1)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    // Shape as well as colour: the dot alone was the only status
                    // indicator in a collapsed row, which excludes colour-blind
                    // users entirely.
                    Image(systemName: statusSymbol)
                        .font(.system(size: 7))
                        .foregroundStyle(statusColor)
                        .frame(width: 8)

                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(statusText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if let percent = contextPressure {
                        Text("ctx \(Int(percent))%")
                            .font(.system(size: 9))
                            .foregroundStyle(percent >= 90 ? Color.red : Color.orange)
                            .monospacedDigit()
                            .help("Context \(Int(percent))% full. Claude Code compacts the conversation when it fills.")
                    }

                    if session.childCount > 0 {
                        Text("\(session.childCount) MCP")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }

                    Text(Fmt.bytes(session.totalFootprint))
                        .font(.system(size: 11, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.secondary)

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .frame(width: 8)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Six unlabelled children otherwise, read as six separate items
            // with no hint that the actions live behind the row.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(statusText), \(Fmt.bytes(session.totalFootprint))"
                                + (contextPressure.map { ", context \(Int($0)) percent full" } ?? "")
                                + (session.childCount > 0 ? ", \(session.childCount) MCP servers" : ""))
            .accessibilityHint(expanded
                               ? "Hides this session's actions"
                               : "Shows Freeze, Hibernate and Reveal in Finder")
            .accessibilityAddTraits(.isButton)

            if expanded {
                detail
                    .padding(.horizontal, 6)
                    .padding(.bottom, 5)
            }
        }
        .background(expanded ? Color.secondary.opacity(0.09) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .onChange(of: engine.confirmationGeneration) { confirmingHibernate = false }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                DetailRow("Path", session.cwd, truncateHead: true)
                DetailRow("Age", "\(Fmt.duration(session.age)) · v\(session.version) · pid \(session.pid)")
                DetailRow("Memory", "\(Fmt.bytes(session.totalFootprint)) across \(session.childCount + 1) processes")
                if tokens.total > 0 {
                    DetailRow("Tokens", "\(Fmt.tokens(tokens.total)) total · \(Fmt.tokens(tokens.billable)) billable · \(tokens.messages) msgs")
                    if !tokens.models.isEmpty {
                        DetailRow("Models", tokens.models.sorted().joined(separator: ", "))
                    }
                }
                // Claude Code's own figures, not Torpor's arithmetic, so they
                // are stated plainly — no tilde, no "about".
                if let cost = usage?.costUSD, cost > 0 {
                    DetailRow("Cost", "$\(String(format: "%.2f", cost))")
                }
                if let context = contextSummary {
                    DetailRow("Context", context)
                }
            }

            if let percent = usage?.contextUsedPercentage, percent >= 80 {
                Text("Close to the context limit. Claude Code will pause to compact, summarising away some earlier detail.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(session.isFrozen
                 ? "Frozen: no CPU. Memory unchanged — macOS had already compressed most of it."
                 : hibernateExplanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if session.isFrozen {
                    Button("Thaw") { engine.thaw(session) }.controlSize(.small)
                } else {
                    Button("Freeze") { engine.freeze(session) }.controlSize(.small)
                        .help("Pauses this session and its MCP servers. No CPU; frees little memory.")
                }

                // Only offered for a session the registry reports as idle, and
                // always behind a confirm — this ends a process. Every other
                // route to the same signal is guarded the same way.
                if session.declaredStatus == "idle" {
                    if confirmingHibernate {
                        Button("Hibernate") {
                            confirmingHibernate = false
                            engine.hibernate(session)
                        }
                        .controlSize(.small).tint(.orange)
                        Button("Cancel") { confirmingHibernate = false }
                            .controlSize(.small).buttonStyle(.borderless)
                    } else {
                        Button("Hibernate") { confirmingHibernate = true }
                            .controlSize(.small).tint(.orange)
                            .help("Ends this session and frees \(Fmt.bytes(session.totalFootprint)). Reopens in one click.")
                    }
                } else {
                    Text(session.declaredStatus == "busy"
                         ? "Working — hibernate is disabled"
                         : "Status unknown — hibernate is disabled")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless).controlSize(.small)
                .help("Reveal \(session.cwd) in Finder")
            }
        }
    }

    private func DetailRow(_ label: String, _ value: String, truncateHead: Bool = false) -> some View {
        GridRow {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption2)
                .lineLimit(1)
                .truncationMode(truncateHead ? .head : .tail)
                .textSelection(.enabled)
        }
    }
}

struct LabeledStepper: View {
    let title: String
    @Binding var value: Double
    let step: Double
    let range: ClosedRange<Double>
    let unit: String

    var body: some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            Text("\(Int(value)) \(unit)")
                .font(.system(.caption, design: .rounded))
                .monospacedDigit()
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .controlSize(.mini)
        }
    }
}
