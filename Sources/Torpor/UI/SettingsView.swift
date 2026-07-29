import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                AccountTab(engine: engine)
                    .tabItem { Label("Account", systemImage: "person.badge.key") }
                AppearanceTab(engine: engine)
                    .tabItem { Label("Appearance", systemImage: "paintbrush") }
                SessionsTab(engine: engine)
                    .tabItem { Label("Sessions", systemImage: "square.stack.3d.up") }
                NotificationsTab(engine: engine)
                    .tabItem { Label("Notifications", systemImage: "bell") }
                AboutTab(engine: engine)
                    .tabItem { Label("About", systemImage: "info.circle") }
            }

            // Every failing action in this window — Install, Repair, Remove,
            // Connect, Save token, Save key, launch-at-login — routed its error
            // into `lastError`, which only the popover rendered. And opening
            // Settings closes the popover, so those messages were unreachable
            // by construction.
            if let error = engine.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            } else if let notice = engine.lastNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
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

    private var refreshHelp: String {
        if !engine.preferences.liveFetchPermitted {
            return "Accept the account-risk notice first."
        }
        let wait = engine.nextFetchAllowed.timeIntervalSinceNow
        if wait > 0 {
            return "Anthropic rate-limits this endpoint. Next refresh available in \(Fmt.duration(wait))."
        }
        return "Ask Anthropic for current usage."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard

                VStack(alignment: .leading, spacing: 10) {
                    Text("Usage source").font(.headline)
                    Text("Where Torpor reads your plan limits from. These are mutually exclusive.")
                        .font(.caption2).foregroundStyle(.secondary)
                    ForEach(AuthMode.allCases.filter { $0 != .consoleAPIKey }) { option in
                        sourceRow(option)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Console spend").font(.headline)
                        Tag("Org accounts only", color: .secondary)
                    }
                    Toggle("Show Anthropic Console billing", isOn: Binding(
                        get: { engine.preferences.consoleUsageEnabled },
                        set: { on in
                            engine.preferences.consoleUsageEnabled = on
                            engine.preferences.authMode = on ? .consoleAPIKey
                                : (engine.preferences.authMode == .consoleAPIKey ? .statusline : engine.preferences.authMode)
                        }
                    ))
                    .font(.callout)
                    Text("Adds a spend panel. It cannot change the usage gauges — Console billing and your subscription limits are separate ledgers, and the Admin API is unavailable to individual accounts.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                detailForSelectedMode()
            }
            .padding(20)
        }
        // The settings window is created once and kept, so @State survives
        // closing it: a token pasted but not saved stayed in memory and was
        // prefilled next time — in cleartext if the eye had been toggled.
        .onDisappear {
            pastedToken = ""
            consoleKey = ""
            showToken = false
        }
        .onChange(of: mode) { showToken = false }
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
                    .disabled(!engine.preferences.liveFetchPermitted
                              || Date() < engine.nextFetchAllowed)
                    .help(refreshHelp)
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
                            Tag("Allowed by Anthropic", color: .green)
                        } else {
                            Tag("Can get you banned", color: .red)
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
                Text("Usage reporter for Claude Code").font(.headline)
                Text("Torpor installs a small script as your Claude Code statusline. Claude Code hands that script your 5-hour and weekly usage percentages every time your prompt redraws; the script saves them for Torpor and then runs whatever statusline you already had, so your prompt looks exactly the same. If you had no statusline, it prints a minimal one — the model name and the current folder.")
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
                            Text("You already have a statusline").font(.caption)
                            Text(command).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Install (keeps yours)") { engine.installStatusline() }
                    case .needsRepair:
                        VStack(alignment: .leading) {
                            Text("Usage reporting isn't running").font(.caption).foregroundStyle(.orange)
                            Text("An earlier version installed the script to a folder whose name contains a space, which Claude Code can't execute — so no usage numbers have been arriving. Repair moves it and keeps any statusline you had.")
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
                Text("settings.json is copied to Application Support, timestamped, before Torpor changes it — on install and on remove alike.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

        case .cliCredentials, .pastedToken:
            VStack(alignment: .leading, spacing: 12) {
                RiskPanel(
                    note: mode.riskNote ?? "",
                    accepted: Binding(
                        get: { engine.preferences.acknowledgedRiskModes.contains(mode) },
                        set: { accepted in
                            if accepted { engine.preferences.acknowledgedRiskModes.insert(mode) }
                            else { engine.preferences.acknowledgedRiskModes.remove(mode) }
                        }
                    )
                )

                if engine.preferences.acknowledgedRiskModes.contains(mode) {
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

                }

                // Deliberately outside the consent block. It used to live
                // inside it, so unticking the risk box hid the only way to
                // delete the token it had just stopped consenting to.
                if engine.hasStoredSubscriptionToken {
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Disconnect and delete the stored token", role: .destructive) {
                            engine.clearSubscriptionCredential()
                        }
                        .controlSize(.small)
                        Text("Torpor switches back to reading usage from the Claude Code statusline, and you'll need to accept the risk notice again to reconnect.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .consoleAPIKey:
            VStack(alignment: .leading, spacing: 10) {
                Text("Console API key").font(.headline)
                Text("Adds Anthropic Console spend: month-to-date cost, a daily chart and a per-model breakdown. This is the path Anthropic documents for third-party tools. It does not change the usage gauges — Console billing and your subscription limits are separate ledgers.")
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
                    .disabled(!engine.hasStoredConsoleKey)
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
            Toggle("I accept the risk — show me the connection options", isOn: $accepted)
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
            return engine.preferences.menuBarMetric == .memory
                ? "Green below 60%, amber to 85%, red above — measured against your Mac's total RAM, so this usually stays green unless Claude Code is dominating the machine."
                : "Green below 60%, amber to 85%, red above — on both the gauge and the number."
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
                            // menuBarModel defaults to "" and is never pruned
                            // when the server stops reporting a row, so without
                            // this the Picker shows a blank selection and the
                            // menu bar reads "no model set".
                            .onAppear {
                                if !engine.availableUsageRows.contains(engine.preferences.menuBarModel) {
                                    engine.preferences.menuBarModel = engine.availableUsageRows.first ?? ""
                                }
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Rows shown when you click the menu bar icon").font(.headline)
                    if engine.availableUsageRows.isEmpty {
                        Text("The 5-hour and weekly windows always show. A per-model bar (Fable, Opus, Sonnet) needs Anthropic to send a separate limit for that model, and the statusline payload does not carry one. Only the token-based sources above receive model-scoped limits. Until then the panel shows your model split by tokens read from your own transcripts, which is spend rather than quota.")
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
                         ? "A percentage on its own does not tell you whether to slow down. The countdown does. Reset times later this week carry their weekday; anything further out carries the date."
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
                        Text(engine.preferences.menuBarMetric.hasResetWindow
                             ? "The white line marks how far through the window you are. Fill short of the line means you are inside the pace your window can carry; fill past it means you are burning faster than the clock."
                             : "The bar is memory as a share of RAM. The white line marks how far through your quota window you are — a different measurement, shown here only because the clock is useful regardless.")
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
                Text("no value yet — this fills once usage data arrives")
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
                    Text("Torpor itself").font(.headline)
                    Toggle("Launch Torpor at login", isOn: $engine.preferences.launchAtLogin)
                        .font(.callout)
                        .disabled(!LoginItem.isAvailable)
                    Text(LoginItem.isAvailable
                         ? "A session monitor that only runs when you remember to open it can't notice something went idle three days ago."
                         : "Available once Torpor is run as an app bundle.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Hide from the menu bar when no session is running",
                           isOn: $engine.preferences.hideWhenIdle)
                        .font(.callout)
                    Text("Torpor stays running. Open it again from Spotlight or Finder to bring the icon back. Always suppressed if the session list stops parsing, so the app can't vanish at the moment something has gone wrong.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                    Text("Update rate").font(.headline)
                    LabeledStepper(title: "Check sessions every",
                                   value: $engine.preferences.pollSeconds,
                                   step: 1, range: 2...60, unit: "s")
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Reopening a hibernated session").font(.headline)
                    Text("Hibernate ends a session's processes and frees their memory; the conversation is saved and Revive reopens it. Freeze only pauses CPU and frees very little.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Open sessions in", selection: $engine.preferences.launchTerminal) {
                        Text("Terminal").tag("Terminal")
                        Text("iTerm").tag("iTerm")
                    }
                    .pickerStyle(.segmented)
                    Text("Only Terminal and iTerm can be driven from outside on macOS, so those are the two choices. Sessions started anywhere else still hibernate and revive fine — they just reopen in the app selected here.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Torpor first tries to reopen a session in the exact Terminal or iTerm tab it was ended in — that tab is usually still open at a prompt, so your window layout survives, and this setting is not used. It applies only when that tab can't be reached: it was closed, the app isn't running, or the session ran somewhere Torpor can't script, such as VS Code's built-in terminal. macOS asks for Automation permission the first time.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Idle threshold").font(.headline)
                    LabeledStepper(title: "Treat a session as idle after",
                                   value: $engine.preferences.notifyIdleMinutes,
                                   step: 15, range: 5...480, unit: "min")
                    Text("Used by idle notifications and by the Reclaim button in the menu bar panel — that button hibernates every session Claude Code reports as idle for longer than this. Auto-hibernate below has its own, separate threshold.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Auto-hibernate idle sessions — ends them without asking", isOn: $engine.preferences.autoHibernateEnabled)
                        .font(.callout)
                    // Outside the `if` on purpose: this used to appear only
                    // after enabling, so at the moment of the decision the
                    // label was the only text on screen and it said nothing
                    // about ending processes.
                    Label("Hibernating ends the session's processes to reclaim their memory. Torpor does not ask first, and posts a notification when it does. The conversation is saved and reopens in one click. Sessions that are working, frozen, or whose status Torpor cannot read — including VS Code-hosted ones — are never touched.",
                          systemImage: "shield.lefthalf.filled")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if engine.preferences.autoHibernateEnabled {
                        LabeledStepper(title: "Idle longer than",
                                       value: $engine.preferences.autoHibernateIdleMinutes,
                                       step: 30, range: 30...1440, unit: "min")
                        LabeledStepper(title: "…and using at least",
                                       value: $engine.preferences.autoHibernateFootprintMB,
                                       step: 50, range: 100...4000, unit: "MB")
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
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Enable notifications", isOn: $engine.preferences.notificationsEnabled)
                        .font(.callout)
                    Text("Torpor also needs permission in System Settings › Notifications. If alerts never arrive, check there first — this switch cannot override it.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Group {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Idle sessions").font(.headline)
                        LabeledStepper(title: "Notify when an idle session holds at least",
                                       value: $engine.preferences.notifyIdleFootprintMB,
                                       step: 50, range: 50...4000, unit: "MB")
                        Text("How long counts as idle is set on the Sessions tab, because the same threshold drives the Reclaim button.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Usage limits").font(.headline)
                        LabeledStepper(title: "Warn when a limit passes",
                                       value: $engine.preferences.notifyQuotaPercent,
                                       step: 5, range: 50...99, unit: "%")
                        Text("Checked against your 5-hour and weekly windows separately, so each can alert on its own. Model-specific limits and memory don't trigger this.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
    @ObservedObject var engine: Engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Torpor").font(.title2).bold()
                        Text("Version \(engine.currentVersionString)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Session manager for Claude Code").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("What the numbers mean").font(.headline)
                    Bullet("Torpor counts the memory a session actually costs your Mac, including pages macOS has compressed to save space. Activity Monitor's default column leaves those out, which can make an idle session look more than ten times smaller than it is — and that hidden memory is exactly what hibernating gives back.")
                    Bullet("Freeze pauses a session's processes so they use no CPU — useful for a runaway session, but it barely dents memory, because macOS has usually already compressed most of an idle session. Hibernate ends the session and gives back all of its memory.")
                    Bullet("Usage percentages come from Claude Code's own statusline. If you have chosen another source, Torpor shows whichever reading is more recent.")
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Updates").font(.headline)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("You're on \(engine.currentVersionString).").font(.caption)
                            if let last = engine.updater.lastCheckDescription {
                                Text(last).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Check for Updates…") { engine.updater.checkForUpdates() }
                            .controlSize(.small)
                            .disabled(!engine.updater.canCheck)
                    }
                    Text(engine.installKind.note)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Torpor checks once a day and asks before installing anything. Updates are verified against a signing key built into this app — macOS can't vouch for Torpor, so Torpor vouches for its own updates. Because it isn't notarised, macOS treats each update as a new app and will ask again for Terminal and Keychain permission.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
