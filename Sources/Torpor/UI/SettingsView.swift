import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: Engine
    @ObservedObject private var log = MessageLog.shared

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
            // by construction. It stays below the TabView because that is the
            // only place every tab can reach; each entry carries its own age so
            // an error raised on Account does not read as a comment on
            // whatever tab the user wandered to since.
            if !log.messages.isEmpty {
                Divider()
                MessageStrip(log: log, horizontalPadding: 20, showsDismissAll: true)
            }
        }
        .frame(width: 620, height: 520)
        .logsEngineMessages(engine)
    }
}

// MARK: - Account

struct AccountTab: View {
    @ObservedObject var engine: Engine
    @State private var pastedToken = ""
    @State private var consoleKey = ""
    @State private var showToken = false

    /// Which source the panel below is *describing*. Nil means the one in use.
    /// Clicking a radio used to commit outright, so reading a description you
    /// then rejected had already switched Torpor's usage source.
    @State private var highlighted: AuthMode?

    private var mode: AuthMode { engine.preferences.authMode }
    private var shown: AuthMode { highlighted ?? mode }

    /// Why Refresh is unavailable, or nil when it isn't — one source of truth
    /// for both the disabled state and the explanation beside it.
    private var refreshBlockedReason: String? {
        if !engine.preferences.liveFetchPermitted {
            return "Accept the risk notice first."
        }
        let wait = engine.nextFetchAllowed.timeIntervalSinceNow
        if wait > 0 {
            return "Rate-limited · \(Fmt.duration(wait))"
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard

                VStack(alignment: .leading, spacing: 10) {
                    Text("Usage source").font(.headline)
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
                    Text("A separate ledger from your plan limits — it can't change the gauges.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                detail(for: shown)
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
            highlighted = nil
        }
        // Both detail panels commit a mode of their own (Connect, Save token),
        // so the highlight has to resync or the panel would keep describing
        // the source the user just moved away from.
        .onChange(of: mode) {
            showToken = false
            highlighted = nil
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
            // Deliberately keyed off the committed mode, not the highlighted
            // one: Refresh acts on what is running, not on what is being read.
            if mode != .statusline {
                VStack(alignment: .trailing, spacing: 3) {
                    Button("Refresh") { engine.forceRefreshAccount() }
                        .disabled(refreshBlockedReason != nil)
                    // macOS suppresses tooltips on disabled controls, so the one
                    // thing needed in order to enable it was the one thing that
                    // could not be read.
                    if let reason = refreshBlockedReason {
                        Text(reason)
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 180, alignment: .trailing)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Highlight, then commit. Tapping a row used to write `authMode` outright,
    /// so reading what a source does switched Torpor onto it — and could blank
    /// the gauges — before the description had even been read.
    private func sourceRow(_ option: AuthMode) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                highlighted = option
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    // The radio keeps reflecting the committed mode only, so
                    // the glyph never claims a source Torpor is not using.
                    Image(systemName: mode == option ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(mode == option ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(option.label).font(.callout).foregroundStyle(.primary)
                            // "Can get you banned" described a version of this
                            // that forged a claude-code User-Agent. It doesn't
                            // any more, and overstating the risk is the same
                            // failure as understating it.
                            if option.isSanctioned {
                                Tag("Documented by Anthropic", color: .green)
                            } else {
                                Tag("Undocumented endpoint", color: .orange)
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
            .accessibilityHint("Shows how this source works. It is not used until you choose it.")
            // Reports which source is in use, not which is being read.
            .accessibilityAddTraits(mode == option ? [.isSelected] : [])

            // Sibling, not nested inside the row's own Button: a control inside
            // another button's label never receives the click.
            if shown == option, option != mode {
                Button("Use this source") {
                    engine.preferences.authMode = option
                    highlighted = nil
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(6)
        .background(shown == option ? Color.accentColor.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func detail(for shownMode: AuthMode) -> some View {
        switch shownMode {
        case .statusline:
            VStack(alignment: .leading, spacing: 10) {
                Text("Usage reporter for Claude Code").font(.headline)
                Text("A small script Claude Code runs when your prompt redraws. It saves your usage percentages, then runs whatever statusline you already had — your prompt looks the same. If you had none, it prints the model and folder.")
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
                            Text("The script Claude Code points at is missing, or sits somewhere it can't run it, so no numbers are arriving. Repair rewrites it and keeps whatever statusline you had.")
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
                Text("Your settings.json is backed up before every change.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

        case .cliCredentials, .pastedToken:
            VStack(alignment: .leading, spacing: 12) {
                // Consent is recorded per mode, and `liveFetchPermitted` also
                // requires that mode to be the selected one — so accepting the
                // notice while merely reading about a source cannot cause a
                // request. Anyone changing `liveFetchPermitted` later has to
                // keep that conjunction.
                RiskPanel(
                    note: shownMode.riskNote ?? "",
                    accepted: Binding(
                        get: { engine.preferences.acknowledgedRiskModes.contains(shownMode) },
                        set: { accepted in
                            if accepted { engine.preferences.acknowledgedRiskModes.insert(shownMode) }
                            else { engine.preferences.acknowledgedRiskModes.remove(shownMode) }
                        }
                    )
                )

                if engine.preferences.acknowledgedRiskModes.contains(shownMode) {
                    if shownMode == .cliCredentials {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Connect with Claude CLI").font(.headline)
                            Text(engine.accountStatus.claudeCodeCredentialsAvailable
                                 ? "Found in your Keychain. macOS will ask permission the first time."
                                 : "Nothing in your Keychain. Run `claude` and sign in first.")
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
                            Text("Kept in your login Keychain, never on disk in plain text. Sent only to api.anthropic.com.")
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
                        Text("Switches back to the statusline source.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .consoleAPIKey:
            VStack(alignment: .leading, spacing: 10) {
                Text("Console API key").font(.headline)
                // Anthropic's documented path for third-party tools, unlike the
                // two token sources — hence no risk panel on this one.
                Text("Month-to-date cost, a daily chart and a per-model breakdown. Needs an org account with Admin API access.")
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
            Toggle("I accept the risk", isOn: $accepted)
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
            // Not 9pt: this is the label that says "can get you banned", and
            // 9pt is below the smallest text style macOS itself defines.
            .font(.caption2).bold()
            .kerning(0.5)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Appearance

struct AppearanceTab: View {
    @ObservedObject var engine: Engine

    /// One line each. The pickers on this tab are named for what they do, so
    /// only the choices whose effect is invisible until you pick them — the
    /// colour rule, the white line — carry a caption at all.
    private var colourExplanation: String {
        switch engine.preferences.colorMode {
        case .adaptive:
            return "Green under 60%, amber to 85%, red above. The memory figure stays green, or orange when it is the reclaimable one."
        case .monochrome:
            return "The menu bar's own tint throughout, so 95% looks like 5%."
        case .accent:
            return "Your accent colour at every level: the amount, not the urgency."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pinned above the scroll, not merely first inside it: this
            // previews the controls below, and scrolling to the colour picker
            // took it off screen exactly while it was being changed.
            VStack(alignment: .leading, spacing: 6) {
                Text("Live preview").font(.caption).foregroundStyle(.secondary)
                MenuBarPreview(engine: engine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)

            Divider()

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
                        if engine.preferences.menuBarStyle == .bar {
                            Text("Hover the icon for the exact percentage.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    // No captions: each picker's label plus its selected value
                    // reads as the sentence the caption used to spell out —
                    // "Bar shows: 5-hour limit", "Figure shows: memory used by
                    // all sessions".
                    Picker("Bar shows", selection: $engine.preferences.menuBarMetric) {
                        ForEach(MenuBarMetric.allCases) { Text($0.label).tag($0) }
                    }

                    Picker("Figure shows", selection: $engine.preferences.memoryFigure) {
                        ForEach(MemoryFigure.allCases) { Text($0.label).tag($0) }
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
                        // Named for the slot rather than for the bar, because
                        // the Percentage style has no bar for it to be under.
                        Picker("Second row", selection: $engine.preferences.timeMarker) {
                            ForEach(TimeMarker.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        // The bar sentence only where there is a bar: the
                        // Percentage style draws the same second row with no
                        // white line to explain.
                        Text("Counts down to this window's reset."
                             + (engine.preferences.menuBarStyle == .bar
                                ? " " + MenuBarMetric.markerMeaning : ""))
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    // Everything above describes the status item; this describes
                    // the panel behind it. It used to sit in the middle of the
                    // item's own settings, between the metric picker and the
                    // colour picker.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Rows shown when you click the menu bar icon").font(.headline)
                        if engine.availableUsageRows.isEmpty {
                            Text("The 5-hour and weekly windows always show. Per-model rows (Fable, Opus, Sonnet) aren't in the statusline payload — only the token sources on the Account tab reach them.")
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
                            Text("Only models Anthropic meters separately on your plan are listed.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    // The single copy of this toggle. Sessions carried a second one
                    // bound to the same preference, with different explanatory
                    // text, so flipping either silently moved the other.
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Hide from the menu bar when no session is running",
                               isOn: $engine.preferences.hideWhenIdle)
                            .font(.callout)
                        Text("Torpor keeps running — reopen it from Spotlight to bring the icon back.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
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
                // Stand-in numbers, but the real layout: bar over the time
                // remaining, then the memory figure, in the colours the user's
                // current choices produce. A card that showed only the gauge
                // could not show what these two styles actually differ by —
                // and one that hard-coded `marker: .none` could not show the
                // second row at all, which is now half of the layout.
                MenuBarSample(input: MenuBarRenderer.Input(
                    style: style,
                    colorMode: engine.preferences.colorMode,
                    marker: engine.preferences.timeMarker,
                    fraction: 0.68, percentText: "68%",
                    memoryText: "1.24 GB",
                    memoryColor: MenuBarRenderer.memoryTint(
                        for: engine.preferences.memoryFigure,
                        mode: engine.preferences.colorMode),
                    resetsAt: Date().addingTimeInterval(5_580),
                    isStale: false, windowElapsed: 0.45))
                    .frame(height: MenuBarRenderer.compositeHeight)
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
            MenuBarSample(input: engine.menuBarInput)
                .frame(height: MenuBarRenderer.compositeHeight)
            Spacer()
            // Two halves, two reasons to be empty, so say which one is.
            if engine.menuBarInput.fraction == nil {
                Text("no limit reading yet — the bar fills once usage data arrives")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if engine.menuBarInput.memoryText == nil {
                Text("no sessions running — the memory figure appears when one starts")
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
                    // Only when the control is disabled: a greyed-out toggle
                    // with no explanation is the one that needs a caption.
                    if !LoginItem.isAvailable {
                        Text("Available once Torpor is run as an app bundle.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Group sessions by project folder", isOn: $engine.preferences.groupByProject)
                        .font(.callout)
                    Text("A group whose sessions are all idle can be hibernated in one click.")
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
                    Picker("Open sessions in", selection: $engine.preferences.launchTerminal) {
                        Text("Terminal").tag("Terminal")
                        Text("iTerm").tag("iTerm")
                    }
                    .pickerStyle(.segmented)
                    Text("Terminal and iTerm are the only terminals macOS lets Torpor script by tab, so only sessions from those come back where they left — and only while that tab is still open. macOS asks for Automation permission the first time. A session from VS Code, Cursor, Warp or Ghostty can't be typed into at all: reviving one copies its command and brings that app forward for you to paste, and this picker doesn't apply to it.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Idle threshold").font(.headline)
                    LabeledStepper(title: "Treat a session as idle after",
                                   value: $engine.preferences.notifyIdleMinutes,
                                   step: 15, range: 5...480, unit: "min")
                    Text("Used by idle notifications and the Hibernate idle button. Auto-hibernate has its own threshold below.")
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
                    Label("Ends idle sessions without asking, and notifies you. The conversation is saved and reopens in one click. Sessions that are working, frozen, or whose status Torpor can't read are never touched.",
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
                    Text("Also needs permission in System Settings › Notifications.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Group {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Idle sessions").font(.headline)
                        LabeledStepper(title: "Notify when an idle session holds at least",
                                       value: $engine.preferences.notifyIdleFootprintMB,
                                       step: 50, range: 50...4000, unit: "MB")
                        Text("How long counts as idle is set on the Sessions tab.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Usage limits").font(.headline)
                        LabeledStepper(title: "Warn when a limit passes",
                                       value: $engine.preferences.notifyQuotaPercent,
                                       step: 5, range: 50...99, unit: "%")
                        Text("The 5-hour and weekly windows alert separately. Per-model limits don't alert.")
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
                    Bullet("**Memory** is what a session really costs your Mac, compressed pages included. Activity Monitor leaves those out and can read ten times low.")
                    Bullet("**Freeze** stops CPU only. **Hibernate** ends the session and gives back all its memory.")
                    Bullet("**Usage** comes from Claude Code's statusline, or whichever source you picked on the Account tab.")
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
                    Text("Checks daily, asks before installing, and verifies each update against a key built into this app. Torpor is signed with a Developer ID and notarised, so the signing identity no longer changes between builds and macOS keeps the Terminal and Keychain permissions you already granted.")
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
                    Text("Bug reports are the useful thing: Torpor reads undocumented Claude Code internals, and upstream ships around six releases a week.")
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

    /// `LocalizedStringKey`, not `String`: only the key overload parses the
    /// markdown that bolds the term each bullet is about.
    private func Bullet(_ text: LocalizedStringKey) -> some View {
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
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
