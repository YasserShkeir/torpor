import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        TabView {
            AccountTab(engine: engine)
                .tabItem { Label("Account", systemImage: "person.badge.key") }
            AppearanceTab(engine: engine)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            SessionsTab(engine: engine)
                .tabItem { Label("Sessions", systemImage: "square.stack.3d.up") }
            NotificationsTab(engine: engine)
                .tabItem { Label("Notifications", systemImage: "bell") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 520)
    }
}

// MARK: - Account

struct AccountTab: View {
    @ObservedObject var engine: Engine
    @State private var pastedToken = ""
    @State private var consoleKey = ""
    @State private var showToken = false

    private var mode: AuthMode { engine.preferences.authMode }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard

                VStack(alignment: .leading, spacing: 10) {
                    Text("Usage source").font(.headline)
                    ForEach(AuthMode.allCases) { option in
                        sourceRow(option)
                    }
                }

                Divider()
                detailForSelectedMode()
            }
            .padding(20)
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: engine.accountStatus.connected
                  ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(engine.accountStatus.connected ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.accountStatus.detail).font(.callout)
                if let error = engine.accountStatus.lastFetchError {
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if let last = engine.accountStatus.lastFetch {
                    Text("Last refreshed \(Fmt.duration(Date().timeIntervalSince(last))) ago")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if mode != .statusline {
                Button("Refresh") { engine.forceRefreshAccount() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sourceRow(_ option: AuthMode) -> some View {
        Button {
            engine.preferences.authMode = option
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode == option ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(mode == option ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(option.label).font(.callout).foregroundStyle(.primary)
                        if option.isSanctioned {
                            Tag("Supported", color: .green)
                        } else {
                            Tag("Account risk", color: .red)
                        }
                    }
                    Text(option.summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func detailForSelectedMode() -> some View {
        switch mode {
        case .statusline:
            VStack(alignment: .leading, spacing: 10) {
                Text("Statusline shim").font(.headline)
                Text("Claude Code passes its statusline command a JSON payload containing your 5-hour and weekly rate-limit percentages. The shim copies that payload to a file and then runs whatever statusline you already had, so your prompt is unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    switch engine.statuslineState {
                    case .installed:
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                        Spacer()
                        Button("Remove") { engine.uninstallStatusline() }
                    case .foreign(let command):
                        VStack(alignment: .leading) {
                            Text("Another statusline is configured").font(.caption)
                            Text(command).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Install (chains to it)") { engine.installStatusline() }
                    case .needsRepair:
                        VStack(alignment: .leading) {
                            Text("Installed at an unusable path").font(.caption).foregroundStyle(.orange)
                            Text("The old location contained a space, so Claude Code could not run it.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Repair") { engine.installStatusline() }
                    case .notInstalled:
                        Text("Not installed").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Install") { engine.installStatusline() }
                    case let .settingsUnreadable(why):
                        // No Install button here on purpose: writing would
                        // discard whatever is actually in the file.
                        VStack(alignment: .leading) {
                            Label("settings.json can't be read", systemImage: "exclamationmark.octagon.fill")
                                .font(.caption).foregroundStyle(.red)
                            Text(why).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                }
                Text("A backup of settings.json is written to Application Support before any change.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

        case .cliCredentials, .pastedToken:
            VStack(alignment: .leading, spacing: 12) {
                RiskPanel(
                    note: mode.riskNote ?? "",
                    accepted: $engine.preferences.acknowledgedTokenRisk
                )

                if engine.preferences.acknowledgedTokenRisk {
                    if mode == .cliCredentials {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Connect with Claude CLI").font(.headline)
                            Text(engine.accountStatus.claudeCodeCredentialsAvailable
                                 ? "Claude Code credentials found in your Keychain. macOS will ask for permission the first time Torpor reads them."
                                 : "No Claude Code credentials found. Run `claude` in a terminal and sign in first.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Connect") { engine.connectWithClaudeCLI() }
                                .disabled(!engine.accountStatus.claudeCodeCredentialsAvailable)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Subscription token").font(.headline)
                            HStack {
                                if showToken {
                                    TextField("sk-ant-oat…", text: $pastedToken)
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    SecureField("sk-ant-oat…", text: $pastedToken)
                                        .textFieldStyle(.roundedBorder)
                                }
                                Button {
                                    showToken.toggle()
                                } label: {
                                    Image(systemName: showToken ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                                Button("Save") {
                                    engine.saveSubscriptionToken(pastedToken)
                                    pastedToken = ""
                                }
                                .disabled(pastedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            Text("Stored in your login Keychain. Torpor never writes it to disk in plain text and never sends it anywhere except api.anthropic.com.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Button("Disconnect and clear the subscription token", role: .destructive) {
                        engine.clearSubscriptionCredential()
                    }
                    .controlSize(.small)
                }
            }

        case .consoleAPIKey:
            VStack(alignment: .leading, spacing: 10) {
                Text("Console API key").font(.headline)
                Text("Shows Anthropic Console spend: month-to-date cost, a daily chart and a per-model breakdown. This is the path Anthropic documents for third-party tools.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    SecureField("sk-ant-admin…", text: $consoleKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        engine.saveConsoleKey(consoleKey)
                        consoleKey = ""
                    }
                    .disabled(consoleKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Label("Console spend is a separate ledger from your Pro/Max subscription limits. It does not show plan usage, and the Admin API is unavailable to individual accounts.",
                      systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let console = engine.console {
                    Divider()
                    Text("Month to date: $\(String(format: "%.2f", console.monthToDateUSD))")
                        .font(.callout).bold()

                    if console.days.contains(where: { $0.costUSD > 0 }) {
                        DailyCostChart(days: console.days)
                    }

                    ForEach(console.byModel.sorted(by: { $0.value > $1.value }).prefix(6), id: \.key) { model, cost in
                        HStack {
                            Text(model).font(.caption)
                            Spacer()
                            Text("$\(String(format: "%.2f", cost))").font(.caption).monospacedDigit()
                        }
                    }
                }

                Button("Clear API key", role: .destructive) { engine.clearConsoleCredential() }
                    .controlSize(.small)
            }
        }
    }
}

/// The disclosure that must be read before a token path becomes active.
struct RiskPanel: View {
    let note: String
    @Binding var accepted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This puts your Anthropic account at risk", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).bold()
                .foregroundStyle(.red)
            Text(note)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("I understand and want to use this anyway", isOn: $accepted)
                .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.35), lineWidth: 1))
    }
}

struct Tag: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color) { self.text = text; self.color = color }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .kerning(0.5)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Appearance

struct AppearanceTab: View {
    @ObservedObject var engine: Engine

    private var colourExplanation: String {
        switch engine.preferences.colorMode {
        case .adaptive:
            return "Green below 60%, amber to 85%, red above — on both the gauge and the number."
        case .monochrome:
            return "No colour at all: the gauge and number follow the menu bar's own tint. Tidy, but 95% looks the same as 5%."
        case .accent:
            return "Your system accent colour at every level, so the gauge shows the amount but not the urgency."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Menu bar style").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)],
                              alignment: .leading, spacing: 10) {
                        ForEach(MenuBarStyle.allCases) { style in
                            StylePreview(style: style, engine: engine)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Show", selection: $engine.preferences.menuBarMetric) {
                        ForEach(MenuBarMetric.allCases) { Text($0.label).tag($0) }
                    }
                    Text(engine.preferences.menuBarMetric.gaugeMeaning)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if engine.preferences.menuBarMetric == .model {
                        if engine.availableUsageRows.isEmpty {
                            Label("No model-specific limits reported yet. Anthropic only sends these for models your plan meters separately, and only after a session has made a request.",
                                  systemImage: "info.circle")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Picker("Model", selection: $engine.preferences.menuBarModel) {
                                ForEach(engine.availableUsageRows, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Usage rows in the panel").font(.headline)
                    if engine.availableUsageRows.isEmpty {
                        Text("The session and weekly windows always show. Model-specific rows — Fable, Sonnet, Opus — appear here once Anthropic reports a separate limit for them on your plan.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(engine.availableUsageRows, id: \.self) { row in
                            Toggle(isOn: Binding(
                                get: { !engine.preferences.hiddenUsageRows.contains(row) },
                                set: { shown in
                                    if shown { engine.preferences.hiddenUsageRows.remove(row) }
                                    else { engine.preferences.hiddenUsageRows.insert(row) }
                                }
                            )) {
                                HStack(spacing: 6) {
                                    Text(row).font(.callout)
                                    if let window = engine.quota?.scoped[row] {
                                        Text("\(Int(window.usedPercentage))% used")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                        Text("Only models Anthropic actually meters separately on your plan are listed. Torpor never invents a row.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Colour", selection: $engine.preferences.colorMode) {
                        ForEach(ColorMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(colourExplanation)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Reset countdown", selection: $engine.preferences.timeMarker) {
                        ForEach(TimeMarker.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!engine.preferences.menuBarMetric.hasResetWindow)
                    Text(engine.preferences.menuBarMetric.hasResetWindow
                         ? "A percentage on its own does not tell you whether to slow down. The countdown does. Reset times outside today carry their weekday."
                         : "Session memory has no reset window, so there is no countdown to show.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Hide from the menu bar when no session is running",
                           isOn: $engine.preferences.hideWhenIdle)
                        .font(.callout)
                    Text("Torpor stays running. Open it again from Spotlight or Finder to bring the icon back.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live preview").font(.caption).foregroundStyle(.secondary)
                    MenuBarPreview(engine: engine)
                    if engine.preferences.menuBarStyle == .bar {
                        Text("Two bars: usage on top, elapsed time underneath. If the top bar is shorter than the bottom one you are inside the pace your window can carry; if it is longer you are burning faster than the clock.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
        }
    }
}

/// A menu bar item rendered exactly as the menu bar draws it — gauge plus
/// coloured text — so the preview cannot disagree with the real thing.
struct MenuBarSample: NSViewRepresentable {
    let input: MenuBarRenderer.Input

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignLeft
        // Without this the view collapses to zero width inside a SwiftUI
        // stack whenever the image is nil, which is every text-only style.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = MenuBarRenderer.composite(input)
    }

    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        nsView.image?.size
    }
}

struct StylePreview: View {
    let style: MenuBarStyle
    @ObservedObject var engine: Engine

    private var isSelected: Bool { engine.preferences.menuBarStyle == style }

    var body: some View {
        Button {
            engine.preferences.menuBarStyle = style
        } label: {
            HStack(spacing: 8) {
                MenuBarSample(input: MenuBarRenderer.Input(
                    style: style,
                    colorMode: engine.preferences.colorMode,
                    marker: .none,
                    fraction: 0.68, percentText: "68%", resetsAt: nil,
                    sessionCount: 3, isStale: false, windowElapsed: 0.45))
                    .frame(height: 22)
                Text(style.label).font(.caption)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor).font(.caption)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The real status item, with the user's live data.
struct MenuBarPreview: View {
    @ObservedObject var engine: Engine

    var body: some View {
        HStack {
            MenuBarSample(input: engine.menuBarInput).frame(height: 22)
            Spacer()
            if engine.menuBarInput.fraction == nil {
                Text("no value yet — the gauge fills once usage data arrives")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Sessions

struct SessionsTab: View {
    @ObservedObject var engine: Engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch Torpor at login", isOn: $engine.preferences.launchAtLogin)
                        .font(.callout)
                        .disabled(!LoginItem.isAvailable)
                    if !LoginItem.isAvailable {
                        Text("Available once Torpor is run as an app bundle.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Group sessions by project folder", isOn: $engine.preferences.groupByProject)
                        .font(.callout)
                    Text("Sessions sharing a working directory are shown together. When every session in a group is idle, the group can be hibernated in one action.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Refresh").font(.headline)
                    LabeledStepper(title: "Poll processes every",
                                   value: $engine.preferences.pollSeconds,
                                   step: 1, range: 2...60, unit: "s")
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Revive").font(.headline)
                    Picker("Open sessions in", selection: $engine.preferences.launchTerminal) {
                        Text("Terminal").tag("Terminal")
                        Text("iTerm").tag("iTerm")
                    }
                    .pickerStyle(.segmented)
                    Text("Reviving opens a new window and runs the resume command. macOS will ask for Automation permission the first time.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Auto-hibernate idle sessions", isOn: $engine.preferences.autoHibernateEnabled)
                        .font(.callout)
                    if engine.preferences.autoHibernateEnabled {
                        LabeledStepper(title: "Idle longer than",
                                       value: $engine.preferences.autoHibernateIdleMinutes,
                                       step: 30, range: 30...1440, unit: "min")
                        LabeledStepper(title: "Holding at least",
                                       value: $engine.preferences.autoHibernateFootprintMB,
                                       step: 50, range: 100...4000, unit: "MB")
                        Label("Only sessions the registry explicitly reports as idle are eligible. Sessions with unknown status — including VS Code-hosted ones — are never touched automatically.",
                              systemImage: "shield.lefthalf.filled")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Notifications

struct NotificationsTab: View {
    @ObservedObject var engine: Engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Enable notifications", isOn: $engine.preferences.notificationsEnabled)
                    .font(.callout)

                Group {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Idle sessions").font(.headline)
                        LabeledStepper(title: "Notify when idle past",
                                       value: $engine.preferences.notifyIdleMinutes,
                                       step: 15, range: 5...480, unit: "min")
                        LabeledStepper(title: "…and holding at least",
                                       value: $engine.preferences.notifyIdleFootprintMB,
                                       step: 50, range: 50...4000, unit: "MB")
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quota").font(.headline)
                        LabeledStepper(title: "Warn at",
                                       value: $engine.preferences.notifyQuotaPercent,
                                       step: 5, range: 50...99, unit: "%")
                        Text("Each alert is sent at most once an hour and re-arms once the condition clears.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .disabled(!engine.preferences.notificationsEnabled)
                .opacity(engine.preferences.notificationsEnabled ? 1 : 0.45)
            }
            .padding(20)
        }
    }
}

// MARK: - About

struct AboutTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Torpor").font(.title2).bold()
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Session manager for Claude Code").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("What the numbers mean").font(.headline)
                    Bullet("Memory is phys_footprint, which includes pages macOS has compressed. RSS excludes them and understates an idle session by more than 10x.")
                    Bullet("Freezing stops CPU. It frees very little memory — macOS has usually already compressed 90% of an idle session. Hibernating frees the whole footprint.")
                    Bullet("Quota percentages come from Claude Code's own statusline payload unless you have chosen another source.")
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Project").font(.headline)
                    HStack(spacing: 8) {
                        LinkButton("Source", systemImage: "chevron.left.forwardslash.chevron.right",
                                   url: Links.repo)
                        LinkButton("Star", systemImage: "star", url: Links.star)
                        LinkButton("Report an issue", systemImage: "ladybug", url: Links.issues)
                        LinkButton("Discussions", systemImage: "bubble.left.and.bubble.right",
                                   url: Links.discussions)
                        LinkButton("Releases", systemImage: "shippingbox", url: Links.releases)
                    }
                    Text("Bug reports are especially useful: Torpor reads undocumented Claude Code internals, and upstream ships roughly six releases a week.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Built by \(Links.authorName)").font(.headline)
                    HStack(spacing: 8) {
                        LinkButton("yasser-shkeir.com", systemImage: "globe", url: Links.authorSite)
                        LinkButton("GitHub", systemImage: "chevron.left.forwardslash.chevron.right",
                                   url: Links.authorGitHub)
                        LinkButton("LinkedIn", systemImage: "person.crop.square",
                                   url: Links.authorLinkedIn)
                    }
                }

                Divider()
                Text("MIT licensed. Not affiliated with Anthropic. \"Claude\" is a trademark of Anthropic PBC.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }

    private func Bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").font(.caption).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A small labelled link that opens in the default browser.
struct LinkButton: View {
    let title: String
    let systemImage: String
    let url: URL

    init(_ title: String, systemImage: String, url: URL) {
        self.title = title
        self.systemImage = systemImage
        self.url = url
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(title, systemImage: systemImage).font(.caption)
        }
        .controlSize(.small)
        .help(url.absoluteString)
    }
}

/// Daily Console spend for the current month.
///
/// Drawn as bars rather than pulled in via Swift Charts: the package has no
/// other dependencies, and a dependency for one sparkline is not a trade worth
/// making in a menu bar utility.
struct DailyCostChart: View {
    let days: [ConsoleUsage.Day]

    private var peak: Double { max(days.map(\.costUSD).max() ?? 0, 0.01) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let spacing: CGFloat = 2
                let width = max(2, (geometry.size.width - spacing * CGFloat(max(days.count - 1, 0)))
                                / CGFloat(max(days.count, 1)))
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(days) { day in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor.opacity(day.costUSD > 0 ? 0.85 : 0.15))
                            .frame(width: width,
                                   height: max(2, geometry.size.height * day.costUSD / peak))
                            .help("\(day.date.formatted(date: .abbreviated, time: .omitted)): $\(String(format: "%.2f", day.costUSD))")
                    }
                }
                .frame(height: geometry.size.height, alignment: .bottom)
            }
            .frame(height: 44)

            HStack {
                Text(days.first?.date.formatted(date: .abbreviated, time: .omitted) ?? "")
                Spacer()
                Text("peak $\(String(format: "%.2f", peak))")
                Spacer()
                Text(days.last?.date.formatted(date: .abbreviated, time: .omitted) ?? "")
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}
