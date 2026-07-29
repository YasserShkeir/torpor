import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var engine: Engine
    var openSettings: () -> Void
    @State private var confirmingReclaimAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    quotaSection
                    sessionsSection
                    if !engine.hibernated.isEmpty { hibernatedSection }
                }
                .padding(14)
            }
            .frame(maxHeight: 520)

            if let error = engine.lastError {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                    Text(error)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
            } else if let notice = engine.lastNotice {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary).font(.caption)
                    Text(notice)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
            }

            Divider()
            footer
        }
        .frame(width: 400)
        .onChange(of: engine.confirmationGeneration) { confirmingReclaimAll = false }
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
                        Label("Reclaim \(Fmt.bytes(engine.reclaimableFootprint))",
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
                              ? "Last captured \(Fmt.duration(quota.age)) ago. Refreshes when a session next renders its statusline."
                              : "Captured \(Fmt.duration(quota.age)) ago.")
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
                Text("\(Fmt.tokens(week.total)) tokens in open sessions · \(Fmt.tokens(week.billable)) billable")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }

            let split = engine.modelSplit
            if split.count > 1 {
                Divider().padding(.vertical, 1)
                HStack(spacing: 5) {
                    SectionHeader("By model")
                    Spacer()
                    Text("share of tokens, not of your limit")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                ForEach(split.prefix(5), id: \.model) { row in
                    HStack(spacing: 7) {
                        Text(row.model)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: 82, alignment: .leading).lineLimit(1)
                        // No pace marker: this is spend, not a window, so there
                        // is no clock to compare it against.
                        InlineBar(fraction: row.share, elapsed: nil, tint: .accentColor)
                            .frame(height: 5)
                        Text("\(Int((row.share * 100).rounded()))%")
                            .font(.system(size: 10, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                        Text(Fmt.tokens(row.tokens))
                            .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
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
                Text("Nothing running. Torpor shows sessions as soon as you start one.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
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

    private var hibernatedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Hibernated")
            ForEach(engine.hibernated) { record in
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.name).font(.callout)
                        Text("\(Fmt.bytes(record.reclaimedBytes)) freed · \(Fmt.duration(Date().timeIntervalSince(record.hibernatedAt))) ago")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revive") { engine.revive(record) }
                        .controlSize(.small)
                        .help(record.resumeCommand)
                    Button { engine.forget(record) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Forget \(record.name)")
                        .accessibilityHint("Discards the saved command line. The conversation stays on disk but Torpor can no longer reopen it for you.")
                        .help("Forget this session. The conversation stays on disk, but Torpor loses the saved command line and can no longer reopen it for you.")
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

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).controlSize(.small)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
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

            Text(countdown)
                .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 34, alignment: .trailing)
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
                    .help("\(Int(elapsed * 100))% of this window has elapsed")
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
                        .help("Hibernate all \(group.sessions.count) idle session\(group.sessions.count == 1 ? "" : "s") in \(group.name), freeing \(Fmt.bytes(group.totalFootprint)). Each stays one click from coming back.")
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(group.allIdle ? Color.orange.opacity(0.09) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 5))

            if confirming {
                Text("Frees \(Fmt.bytes(group.totalFootprint)). They move to Hibernated and revive in one click.")
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
            return "Hibernate ends this session and frees \(Fmt.bytes(session.totalFootprint)). The conversation is saved; one click reopens it in a terminal."
        case "busy":
            return "This session is working. Freeze pauses it; hibernate is only offered once it goes idle."
        default:
            return "Torpor cannot tell whether this session is idle, so it will not end it. Freeze is still available."
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
            }

            Text(session.isFrozen
                 ? "Frozen: using no CPU. Its memory is unchanged — macOS had already compressed most of it."
                 : hibernateExplanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if session.isFrozen {
                    Button("Thaw") { engine.thaw(session) }.controlSize(.small)
                } else {
                    Button("Freeze") { engine.freeze(session) }.controlSize(.small)
                        .help("Pause this session and its MCP servers. Stops CPU use; frees little memory.")
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
                            .help("Ends this session and frees \(Fmt.bytes(session.totalFootprint)). The conversation is saved and reopens in one click.")
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
