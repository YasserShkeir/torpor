import Combine
import Foundation

/// Formatting helpers shared by the UI.
enum Fmt {
    static func bytes(_ value: UInt64) -> String {
        let mb = Double(value) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 {
            let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        let d = Int(s / 86_400), h = Int(s.truncatingRemainder(dividingBy: 86_400) / 3600)
        return h > 0 ? "\(d)d \(h)h" : "\(d)d"
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1e3) }
        return "\(n)"
    }
}

@MainActor
final class Engine: ObservableObject {

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var hibernated: [HibernatedSession] = []
    @Published private(set) var quota: QuotaSnapshot?
    @Published private(set) var tokens: [String: TokenTotals] = [:]
    @Published private(set) var statuslineState: StatuslineInstaller.State = .notInstalled
    @Published private(set) var lastError: String?
    /// Non-error feedback for an action that succeeded but did something worth
    /// mentioning — reviving into a new window rather than the original tab.
    @Published private(set) var lastNotice: String?
    @Published private(set) var credits = CreditBalance()
    @Published private(set) var console: ConsoleUsage?
    @Published private(set) var accountStatus: AccountStatus = .init()
    /// True while a bulk hibernate is in flight, so the UI can disable the
    /// buttons rather than let a second click race the first.
    @Published private(set) var isBusyWithBatch = false
    /// Registry files exist but none decoded — almost certainly an upstream
    /// format change. Surfaces a banner, and suppresses auto-hide so the app
    /// can never silently vanish from the menu bar on an upstream break.
    @Published private(set) var registryLooksBroken = false
    /// Bumped whenever every armed confirmation should be dropped. Views key
    /// their local `confirming` state off this, so closing the popover can
    /// disarm state that SwiftUI would otherwise keep alive for the app's
    /// lifetime (NSPopover retains its content view controller).
    @Published private(set) var confirmationGeneration = 0
    @Published var preferences = Preferences() {
        didSet {
            preferences.save()
            if oldValue.pollSeconds != preferences.pollSeconds { start() }
            if oldValue.launchAtLogin != preferences.launchAtLogin {
                applyLaunchAtLogin()
            }
        }
    }

    private func applyLaunchAtLogin() {
        do {
            let achieved = try LoginItem.set(preferences.launchAtLogin)
            if achieved != preferences.launchAtLogin, LoginItem.isAvailable {
                lastError = "macOS did not apply the login-item change. Check Login Items in System Settings."
            }
        } catch {
            lastError = "Could not update launch at login: \(error.localizedDescription)"
        }
    }

    struct AccountStatus {
        var connected = false
        var detail = "Not connected"
        var subscriptionType: String?
        var lastFetch: Date?
        var lastFetchError: String?
        var claudeCodeCredentialsAvailable = false
    }

    private let store = HibernationStore()
    private let scanner = TranscriptScanner()
    private let notifier = Notifier()
    private let api = UsageAPI()
    private var timer: Timer?
    private var isFetching = false

    // MARK: - Totals

    var totalFootprint: UInt64 { sessions.reduce(0) { $0 + $1.totalFootprint } }

    /// Footprint held by sessions that have been idle past the notification
    /// threshold — the number that actually answers "what would I get back?".
    var reclaimableFootprint: UInt64 {
        let cutoff = max(0, preferences.notifyIdleMinutes) * 60
        return sessions
            .filter { ($0.idleFor ?? 0) >= cutoff }
            .reduce(0) { $0 + $1.totalFootprint }
    }

    var weekTokens: TokenTotals {
        tokens.values.reduce(TokenTotals(), +)
    }

    // MARK: - Grouping

    /// Sessions for one working directory.
    struct ProjectGroup: Identifiable {
        var path: String
        var name: String
        var sessions: [Session]
        var id: String { path }

        var totalFootprint: UInt64 { sessions.reduce(0) { $0 + $1.totalFootprint } }

        /// Count of every status actually present, keyed by its registry value.
        ///
        /// Counting only busy/idle/nil silently dropped rows: the registry also
        /// emits `shell` (observed live), so a group of three showed "2 idle"
        /// above three sessions. A histogram surfaces future values —
        /// `compacting`, `waiting` — instead of making them disappear.
        var statusCounts: [String: Int] {
            sessions.reduce(into: [:]) { counts, session in
                counts[session.declaredStatus ?? "unknown", default: 0] += 1
            }
        }

        var busyCount: Int { statusCounts["busy"] ?? 0 }
        var idleCount: Int { statusCounts["idle"] ?? 0 }
        var unknownCount: Int { sessions.count - busyCount - idleCount }

        /// Every session here is explicitly idle. Sessions whose status the
        /// registry does not report — the VS Code entrypoint omits it — are not
        /// treated as idle, so a group containing one is never offered for a
        /// bulk hibernate.
        var allIdle: Bool {
            !sessions.isEmpty && sessions.allSatisfy { $0.declaredStatus == "idle" }
        }

    }

    /// Sessions grouped by working directory, busiest group first.
    ///
    /// Keyed on the full path rather than the folder name: two checkouts can
    /// share a basename, and silently merging them would offer to hibernate
    /// sessions the user never saw.
    var groupedSessions: [ProjectGroup] { Engine.group(sessions: sessions) }

    /// Pure grouping, so listing commands can use it without constructing an
    /// Engine (which starts timers and can terminate processes).
    nonisolated static func group(sessions: [Session]) -> [ProjectGroup] {
        var order: [String] = []
        var buckets: [String: [Session]] = [:]
        for session in sessions {
            if buckets[session.cwd] == nil { order.append(session.cwd) }
            buckets[session.cwd, default: []].append(session)
        }

        // Disambiguate identical folder names by including the parent.
        var nameCounts: [String: Int] = [:]
        for path in order {
            nameCounts[URL(fileURLWithPath: path).lastPathComponent, default: 0] += 1
        }

        return order.map { path in
            let url = URL(fileURLWithPath: path)
            let base = url.lastPathComponent
            let name = (nameCounts[base] ?? 0) > 1
                ? "\(url.deletingLastPathComponent().lastPathComponent)/\(base)"
                : base
            return ProjectGroup(path: path, name: name, sessions: buckets[path] ?? [])
        }
        .sorted { a, b in
            if (a.busyCount > 0) != (b.busyCount > 0) { return a.busyCount > 0 }
            return a.totalFootprint > b.totalFootprint
        }
    }

    // MARK: - Lifecycle

    init() {
        preferences = Preferences.load()
        notifier.requestAuthorization()
        refresh()
        start()
    }

    func start() {
        timer?.invalidate()
        let interval = max(2, preferences.pollSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Refresh

    func refresh() {
        let result = SessionRegistry.loadDetailed()
        var loaded = result.sessions
        for index in loaded.indices {
            loaded[index].isFrozen = SessionControl.isStopped(loaded[index].pid)
        }
        sessions = loaded
        registryLooksBroken = result.looksBroken

        store.reload()
        // A session resumed outside Torpor — the user typing `claude --resume`
        // themselves — would otherwise sit in both lists forever, offering a
        // Revive button that opens a second terminal on the same conversation.
        let live = Set(loaded.map(\.sessionId))
        for record in store.sessions where live.contains(record.sessionId) {
            store.remove(sessionId: record.sessionId)
        }
        hibernated = store.sessions

        // The statusline snapshot is always read: it costs nothing and it is
        // the fallback whenever a live fetch is unavailable or rate limited.
        let local = QuotaReader.read()
        if quota == nil || preferences.authMode == .statusline || (local?.age ?? .infinity) < (quota?.age ?? .infinity) {
            quota = local ?? quota
        }
        statuslineState = StatuslineInstaller.currentState()
        accountStatus.claudeCodeCredentialsAvailable = CredentialStore.claudeCodeCredentialsPresent()
        refreshAccountStatus()

        if preferences.liveFetchPermitted { Task { await fetchLive() } }

        // Transcript scanning is incremental, so this stays cheap even against
        // a 1.3 GB corpus: only bytes appended since the last pass are parsed.
        for session in loaded {
            tokens[session.sessionId] = scanner.totals(cwd: session.cwd,
                                                       sessionId: session.sessionId)
        }
        // Drop state for sessions that have ended, so neither the scanner's
        // caches nor the "tokens across open sessions" total grow forever.
        tokens = tokens.filter { live.contains($0.key) }
        scanner.prune(keeping: live)

        evaluateNotifications()
        if preferences.autoHibernateEnabled { runAutoHibernate() }
    }

    // MARK: - Actions

    func freeze(_ session: Session) {
        perform { try SessionControl.freeze(session: session) }
    }

    func thaw(_ session: Session) {
        perform { try SessionControl.thaw(session: session) }
    }

    /// Hibernate one session.
    ///
    /// The idle check lives here rather than only in the view: the UI renders
    /// from a snapshot up to one poll old, and a session can start working
    /// between the render and the click. Every other route to this signal —
    /// group hibernate, auto-hibernate — already guards the same way.
    func hibernate(_ session: Session) {
        guard session.declaredStatus == "idle" else {
            lastError = "\(session.projectName) is no longer idle — not ending it."
            refresh()
            return
        }
        isBusyWithBatch = true
        Task {
            let freed = await SessionControl.hibernate(sessions: [session], store: store)
            isBusyWithBatch = false
            lastError = freed.isEmpty
                ? "Could not hibernate \(session.projectName): its command line could not be read, so it would not be restorable."
                : nil
            refresh()
        }
    }

    /// Hibernate every session that is idle past the notification threshold —
    /// the set the header's "Reclaim N" button describes.
    func hibernateIdleSessions() {
        let cutoff = max(0, preferences.notifyIdleMinutes) * 60
        let targets = sessions.filter {
            $0.declaredStatus == "idle" && ($0.idleFor ?? 0) >= cutoff
        }
        guard !targets.isEmpty else {
            lastError = "Nothing is idle enough to reclaim right now."
            return
        }
        isBusyWithBatch = true
        Task {
            let freed = await SessionControl.hibernate(sessions: targets, store: store)
            isBusyWithBatch = false
            let bytes = freed.reduce(UInt64(0)) { $0 + $1.reclaimedBytes }
            lastNotice = freed.isEmpty ? nil
                : "Hibernated \(freed.count) session\(freed.count == 1 ? "" : "s"), freeing \(Fmt.bytes(bytes))."
            lastError = freed.count < targets.count
                ? "\(targets.count - freed.count) session\(targets.count - freed.count == 1 ? "" : "s") could not be ended."
                : nil
            refresh()
        }
    }

    /// Hibernate every session in a project group.
    ///
    /// Guarded to explicitly-idle sessions even though the UI only offers the
    /// button for an all-idle group: state can change between the render and
    /// the click, and terminating a session that just started working would be
    /// unrecoverable from the user's point of view.
    func hibernateGroup(_ group: ProjectGroup) {
        let targets = group.sessions.filter { $0.declaredStatus == "idle" }
        guard !targets.isEmpty else {
            lastError = "Those sessions are no longer idle."
            return
        }
        isBusyWithBatch = true
        Task {
            let freed = await SessionControl.hibernate(sessions: targets, store: store)
            isBusyWithBatch = false
            if freed.count < targets.count {
                lastError = "Hibernated \(freed.count) of \(targets.count) sessions; the rest could not be captured."
            } else {
                lastError = nil
            }
            refresh()
        }
    }

    func revive(_ record: HibernatedSession) {
        do {
            let outcome = try SessionControl.revive(
                record, terminal: preferences.launchTerminal, store: store)
            switch outcome {
            case let .originalTab(app):
                lastError = nil
                lastNotice = "Reopened \(record.name) in its original \(app) tab."
            case let .newWindow(app):
                lastError = nil
                lastNotice = Self.newWindowReason(for: record, app: app)
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func forget(_ record: HibernatedSession) {
        store.remove(sessionId: record.sessionId)
        hibernated = store.sessions
    }

    func installStatusline() {
        perform { try StatuslineInstaller.install() }
    }

    func uninstallStatusline() {
        perform { try StatuslineInstaller.uninstall() }
    }

    private func perform(_ work: @escaping () throws -> Void) {
        do {
            try work()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    // MARK: - Account

    /// Version string used for the client header when the token path is active.
    /// Taken from a live session so it tracks whatever is actually installed.
    private var clientVersion: String {
        sessions.map(\.version).filter { $0 != "unknown" }
            .max { $0.compare($1, options: .numeric) == .orderedAscending } ?? "2.1.0"
    }

    private func refreshAccountStatus() {
        switch preferences.authMode {
        case .statusline:
            let installed = statuslineState == .installed
            accountStatus.connected = installed
            accountStatus.detail = installed
                ? "Reading usage from the Claude Code statusline"
                : "Statusline shim not installed"
        case .cliCredentials, .pastedToken:
            if !preferences.acknowledgedTokenRisk {
                accountStatus.connected = false
                accountStatus.detail = "Waiting for you to accept the account-risk notice"
            } else if let token = CredentialStore.subscriptionToken() {
                accountStatus.connected = !token.isExpired
                accountStatus.subscriptionType = token.subscriptionType
                accountStatus.detail = token.isExpired
                    ? "Token expired — reconnect"
                    : "Connected" + (token.subscriptionType.map { " · \($0)" } ?? "")
            } else {
                accountStatus.connected = false
                accountStatus.detail = "No token stored"
            }
        case .consoleAPIKey:
            let hasKey = CredentialStore.consoleKey() != nil
            accountStatus.connected = hasKey
            accountStatus.detail = hasKey ? "Console API key stored" : "No API key stored"
        }
    }

    /// Live fetch, guarded so overlapping polls never stack up requests against
    /// an endpoint that rate limits aggressively.
    private func fetchLive() async {
        // Set before the first await: `api.canFetch` is an actor hop and thus a
        // real suspension point, so checking it first lets the poll timer and
        // the Refresh button both pass and fire two concurrent requests at an
        // endpoint this app warns carries ban risk.
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        guard await api.canFetch else { return }

        do {
            switch preferences.authMode {
            case .cliCredentials, .pastedToken:
                guard let token = CredentialStore.subscriptionToken() else { return }
                let (snapshot, balance) = try await api.fetchSubscription(
                    token: token, clientVersion: clientVersion)
                quota = snapshot
                credits = balance
            case .consoleAPIKey:
                guard let key = CredentialStore.consoleKey() else { return }
                console = try await api.fetchConsole(adminKey: key)
            case .statusline:
                return
            }
            accountStatus.lastFetch = Date()
            accountStatus.lastFetchError = nil
        } catch {
            // A refusal is expected traffic here, not a failure state worth
            // shouting about — the statusline snapshot keeps the UI populated.
            accountStatus.lastFetchError = error.localizedDescription
        }
    }

    /// Says *why* the session came back in a new window rather than its old
    /// tab. "The tab is gone" and "your terminal has no scripting API" are
    /// different facts and only one of them is the user's doing.
    private static func newWindowReason(for record: HibernatedSession, app: String) -> String {
        guard let tty = record.tty else {
            return "Opened \(record.name) in a new \(app) window. Its original terminal had no tty to return to."
        }
        if ProcProbe.ttyIsLive(tty) {
            return "Opened \(record.name) in a new \(app) window. Its original tab (\(tty)) is still open, but that terminal — VS Code's integrated terminal, or another without a scripting API — can't be targeted from outside. Terminal and iTerm can."
        }
        return "Opened \(record.name) in a new \(app) window. Its original tab (\(tty)) was closed."
    }

    func disarmConfirmations() {
        confirmationGeneration &+= 1
    }

    func forceRefreshAccount() {
        Task { await fetchLive() }
    }

    func connectWithClaudeCLI() {
        perform {
            _ = try CredentialStore.importFromClaudeCode()
            self.preferences.authMode = .cliCredentials
        }
        forceRefreshAccount()
    }

    func saveSubscriptionToken(_ raw: String) {
        perform {
            try CredentialStore.storeSubscriptionToken(raw)
            self.preferences.authMode = .pastedToken
        }
        forceRefreshAccount()
    }

    func saveConsoleKey(_ key: String) {
        perform {
            try CredentialStore.storeConsoleKey(key)
            self.preferences.consoleUsageEnabled = true
        }
        forceRefreshAccount()
    }

    /// Clear only the subscription token. Split from the Console key because a
    /// single shared `disconnect()` meant rotating an API key also destroyed
    /// the user's subscription credential.
    func clearSubscriptionCredential() {
        CredentialStore.clearSubscriptionToken()
        if preferences.authMode == .cliCredentials || preferences.authMode == .pastedToken {
            preferences.authMode = .statusline
        }
        preferences.acknowledgedTokenRisk = false
        credits = CreditBalance()
        refresh()
    }

    func clearConsoleCredential() {
        CredentialStore.clearConsoleKey()
        preferences.consoleUsageEnabled = false
        if preferences.authMode == .consoleAPIKey { preferences.authMode = .statusline }
        console = nil
        refresh()
    }

    // MARK: - Menu bar

    /// What the status item should draw right now.
    var menuBarInput: MenuBarRenderer.Input {
        var fraction: Double?
        var resets: Date?
        var windowLength: TimeInterval?

        switch preferences.menuBarMetric {
        case .fiveHour:
            fraction = quota?.fiveHour.map { $0.usedPercentage / 100 }
            resets = quota?.fiveHour?.resetsAt
            windowLength = 5 * 3600
        case .sevenDay:
            fraction = quota?.sevenDay.map { $0.usedPercentage / 100 }
            resets = quota?.sevenDay?.resetsAt
            windowLength = 7 * 86_400
        case .highest:
            let five = quota?.fiveHour.map { ($0, 5.0 * 3600) }
            let week = quota?.sevenDay.map { ($0, 7.0 * 86_400) }
            let candidates = [five, week].compactMap { $0 }
            if let top = candidates.max(by: { $0.0.usedPercentage < $1.0.usedPercentage }) {
                fraction = top.0.usedPercentage / 100
                resets = top.0.resetsAt
                windowLength = top.1
            }
        case .memory:
            // Scale against a quarter of installed RAM. A hardcoded 4 GB pinned
            // the gauge permanently full on any machine already past it, so
            // hibernating 2 GB produced no visible change at all.
            let installed = Double(ProcessInfo.processInfo.physicalMemory)
            let denominator = max(installed / 4, 1_073_741_824)
            fraction = min(Double(totalFootprint) / denominator, 1)
        }

        let percentText: String?
        if preferences.menuBarMetric == .memory {
            percentText = totalFootprint > 0 ? Fmt.bytes(totalFootprint) : nil
        } else if let fraction {
            percentText = "\(Int((fraction * 100).rounded()))%"
        } else {
            percentText = nil
        }

        // Anthropic publishes the window structure (rolling 5-hour, weekly) but
        // not a start timestamp, so elapsed is derived from the reset time and
        // the known window length.
        var elapsed: Double?
        if let resets, let windowLength, windowLength > 0 {
            let remaining = resets.timeIntervalSinceNow
            if remaining > 0, remaining <= windowLength {
                elapsed = 1 - (remaining / windowLength)
            }
        }

        return .init(style: preferences.menuBarStyle,
                     colorMode: preferences.colorMode,
                     marker: preferences.timeMarker,
                     fraction: fraction,
                     percentText: percentText,
                     resetsAt: resets,
                     sessionCount: sessions.count,
                     isStale: quota?.isStale ?? false,
                     windowElapsed: elapsed)
    }

    // MARK: - Rules

    private func evaluateNotifications() {
        guard preferences.notificationsEnabled else { return }

        let idleCutoff = preferences.notifyIdleMinutes * 60
        let footprintCutoff = UInt64(max(0, preferences.notifyIdleFootprintMB) * 1_048_576)

        for session in sessions {
            guard let idle = session.idleFor, idle >= idleCutoff,
                  session.totalFootprint >= footprintCutoff else {
                notifier.clear(key: "idle-\(session.sessionId)")
                continue
            }
            notifier.post(
                key: "idle-\(session.sessionId)",
                title: "\(session.projectName) has been idle \(Fmt.duration(idle))",
                body: "Holding \(Fmt.bytes(session.totalFootprint)) across \(session.childCount + 1) processes. Hibernate to reclaim it."
            )
        }

        guard let quota, !quota.isStale else { return }
        let threshold = preferences.notifyQuotaPercent

        if let five = quota.fiveHour, five.usedPercentage >= threshold {
            notifier.post(
                key: "quota-5h",
                title: "Session limit \(Int(five.usedPercentage))% used",
                body: five.resetsAt.map { "Resets in \(Fmt.duration($0.timeIntervalSinceNow))." }
                    ?? "Current 5-hour window."
            )
        } else {
            notifier.clear(key: "quota-5h")
        }

        if let week = quota.sevenDay, week.usedPercentage >= threshold {
            notifier.post(
                key: "quota-7d",
                title: "Weekly limit \(Int(week.usedPercentage))% used",
                body: week.resetsAt.map { "Resets in \(Fmt.duration($0.timeIntervalSinceNow))." }
                    ?? "Current weekly window."
            )
        } else {
            notifier.clear(key: "quota-7d")
        }
    }

    /// Opt-in policy: hibernate sessions that are both very idle and expensive.
    ///
    /// Only ever touches sessions the registry explicitly reports as `idle`.
    /// A session whose status is unknown — the VS Code entrypoint omits the
    /// field entirely — is never auto-hibernated, because we cannot tell
    /// whether it is mid-task.
    private func runAutoHibernate() {
        let idleCutoff = preferences.autoHibernateIdleMinutes * 60
        let footprintCutoff = UInt64(max(0, preferences.autoHibernateFootprintMB) * 1_048_576)

        for session in sessions {
            guard session.declaredStatus == "idle",
                  let idle = session.idleFor, idle >= idleCutoff,
                  session.totalFootprint >= footprintCutoff,
                  !session.isFrozen else { continue }

            do {
                let record = try SessionControl.hibernate(session: session, store: store)
                notifier.post(
                    key: "auto-\(record.sessionId)",
                    title: "Hibernated \(record.name)",
                    body: "Idle \(Fmt.duration(idle)) — reclaimed \(Fmt.bytes(record.reclaimedBytes)). Revive it from the menu bar."
                )
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
