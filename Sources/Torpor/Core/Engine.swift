import AppKit
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
    /// Why the hibernation store could not be read, when it could not be.
    ///
    /// An unreadable store is not an empty one, and the difference matters more
    /// here than anywhere else in the app: each record holds the only copy of
    /// the argv a revive rebuilds from. Reporting "nothing hibernated" would
    /// tell someone their sessions are gone at the exact moment they are not.
    @Published private(set) var hibernationLoadFailure: String?
    @Published private(set) var quota: QuotaSnapshot?
    /// The two sources are kept apart and merged into `quota` on every write.
    /// The statusline snapshot refreshes whenever a session draws its prompt
    /// but reports only the windows Claude Code sends; the API snapshot is the
    /// only source of the other model-scoped rows and of credits context.
    private var statuslineQuota: QuotaSnapshot?
    private var apiQuota: QuotaSnapshot?
    @Published private(set) var tokens: [String: TokenTotals] = [:]
    /// Cost and context-window occupancy per session, straight from Claude
    /// Code's own figures. Keyed by session id and pruned to live sessions on
    /// every refresh.
    @Published private(set) var sessionUsage: [String: SessionUsage] = [:]
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
    /// Session ids being hibernated right now.
    ///
    /// The reconcile loop below drops any record whose session is live again,
    /// which is how a session revived outside Torpor stops appearing twice. But
    /// a session being hibernated is *still live* for the whole SIGTERM grace
    /// period, and the poll timer is shorter than that grace period, so the
    /// loop was deleting the record the hibernate had just written — taking the
    /// captured argv with it. Anything mid-flight is exempt.
    private var inFlightHibernations: Set<String> = []
    /// Registry files exist but none decoded — almost certainly an upstream
    /// format change. Surfaces a banner, and suppresses auto-hide so the app
    /// can never silently vanish from the menu bar on an upstream break.
    @Published private(set) var registryLooksBroken = false
    /// Bumped whenever every armed confirmation should be dropped. Views key
    /// their local `confirming` state off this, so closing the popover can
    /// disarm state that SwiftUI would otherwise keep alive for the app's
    /// lifetime (NSPopover retains its content view controller).
    @Published private(set) var confirmationGeneration = 0
    /// When a live fetch is next permitted. The endpoint is rate limited to one
    /// call every few minutes, so Refresh was otherwise a silent no-op for
    /// anywhere from five minutes to an hour, with nothing on screen changing.
    @Published private(set) var nextFetchAllowed: Date = .distantPast
    /// Sparkle owns the update UI end to end, so the engine only needs to hold
    /// the controller and expose it to the About tab.
    let updater: Updater
    /// `updater` is a nested ObservableObject held as a plain `let`, so its
    /// own @Published changes never reach a view observing the Engine — the
    /// About tab would keep showing "never checked" after a check completed.
    private var updaterRepublish: AnyCancellable?
    private var saveTask: Task<Void, Never>?

    @Published var preferences = Preferences() {
        didSet {
            // A read-only engine must not write preferences or re-register the
            // login item: --render-live sweeps every menu-bar metric through
            // this property just to draw them.
            guard sideEffects else { return }
            // Coalesced: the didSet fires on every repeat-key tick of a stepper,
            // and each save is a synchronous pretty-printed encode plus atomic
            // write on the main actor.
            saveTask?.cancel()
            let snapshot = preferences
            saveTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                snapshot.save()
                _ = self
            }
            if oldValue.pollSeconds != preferences.pollSeconds { start() }
            if oldValue.launchAtLogin != preferences.launchAtLogin {
                applyLaunchAtLogin()
            }
        }
    }

    /// Adopt whatever launchd actually reports.
    ///
    /// `LoginItem.isEnabled` existed and was called from nowhere, so revoking
    /// the login item in System Settings left the toggle showing ON forever
    /// while Torpor never re-registered.
    func reconcileLoginItem() {
        guard LoginItem.isAvailable else { return }
        let actual = LoginItem.isEnabled
        if actual != preferences.launchAtLogin { preferences.launchAtLogin = actual }
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
        var lastFetch: Date?
        var lastFetchError: String?
        /// Which mode produced `lastFetchError`, so it can be dropped when the
        /// user switches away rather than following them to a source that
        /// never fetches and therefore can never clear it.
        var errorMode: AuthMode?
        var claudeCodeCredentialsAvailable = false
    }

    private let store = HibernationStore()
    /// One store for the whole engine: freeze, thaw and the poll-time sweep all
    /// read and write the same file, and separate instances would each hold a
    /// stale copy and overwrite the others.
    private let frozenStore = FrozenStore()
    private let scanner = TranscriptScanner()
    /// In-flight token scan, cancelled when a newer refresh supersedes it.
    private var scanTask: Task<Void, Never>?
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
        // Must match what the Reclaim button will actually hibernate. Filtering
        // on idle *time* alone advertised sessions the action then skipped: one
        // long-idle session whose status is `busy` or absent produced a header
        // reading "Reclaim 3.1 GB", a confirm reading "Hibernate 0", and
        // nothing freed.
        return sessions
            .filter { $0.declaredStatus == "idle" && ($0.idleFor ?? 0) >= cutoff }
            .reduce(0) { $0 + $1.totalFootprint }
    }

    /// Model-scoped weekly windows the server has actually reported, sorted.
    /// Only these can be shown or selected — Torpor never invents a row for a
    /// model Anthropic has not sent a limit for.
    var availableUsageRows: [String] {
        (quota?.scoped.keys).map { Array($0).sorted() } ?? []
    }

    /// Rows the user has chosen to see, in display order.
    var visibleScopedRows: [(name: String, window: QuotaSnapshot.Window)] {
        guard let quota else { return [] }
        return quota.scoped
            .filter { !preferences.hiddenUsageRows.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { (name: $0.key, window: $0.value) }
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

    /// When false, `refresh()` reads state and computes nothing that acts:
    /// no notifications, no auto-hibernate, no live fetch, no store pruning,
    /// no login-item reconcile. For CLI commands that only need to render.
    private let sideEffects: Bool

    init(sideEffects: Bool = true) {
        self.sideEffects = sideEffects
        // Sparkle's scheduled updater is a side effect: without this, rendering
        // a screenshot started a background update check.
        updater = Updater(starting: sideEffects)
        preferences = Preferences.load()
        updaterRepublish = updater.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        guard sideEffects else { refresh(); return }
        // Bring an installed shim up to the current format before anything
        // reads what it writes. Without this an existing user keeps last
        // release's script, which never emits the cost, context or per-session
        // fields, so those stay empty for them forever. No-op when the shim is
        // absent or already current.
        StatuslineInstaller.refreshIfStale()
        reconcileLoginItem()
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
        // The scan outlives the engine otherwise. A CLI command builds an
        // engine, refreshes once and exits — but refresh() starts a pass over
        // every open session's transcript tree, which is minutes of file I/O on
        // a large corpus, and the process cannot leave until it ends.
        scanTask?.cancel()
        scanTask = nil
        // Flush anything the coalescing window was still holding. A read-only
        // engine never scheduled one and must not write preferences at all.
        saveTask?.cancel()
        if sideEffects { preferences.save() }
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
        if sideEffects {
            for record in store.sessions
            where live.contains(record.sessionId) && !inFlightHibernations.contains(record.sessionId) {
                // Opportunistic prune: a failed write must not abort the whole
                // refresh, and the next poll will try again.
                try? store.remove(sessionId: record.sessionId)
            }
            // Recover frozen subtrees whose session has since died. Nothing in
            // the session list refers to them, so there is no button that could
            // reach a SIGSTOPped MCP server reparented to launchd.
            SessionControl.sweepFrozen(store: frozenStore)
        }
        hibernated = store.sessions
        hibernationLoadFailure = store.loadFailure

        // The statusline snapshot is always read: it costs nothing and it is
        // the fallback whenever a live fetch is unavailable or rate limited.
        // `?? statuslineQuota` keeps the last good read when the snapshot file
        // is transiently unreadable.
        statuslineQuota = QuotaReader.read() ?? statuslineQuota
        quota = Self.merged(statusline: statuslineQuota, api: apiQuota)
        statuslineState = StatuslineInstaller.currentState()
        accountStatus.claudeCodeCredentialsAvailable =
            sideEffects && CredentialStore.claudeCodeCredentialsPresent()
        if let mode = accountStatus.errorMode, mode != preferences.authMode {
            accountStatus.lastFetchError = nil
            accountStatus.errorMode = nil
        }
        // Reconcile with launchd rather than trusting our own stored flag: the
        // user can revoke a login item in System Settings, and the toggle would
        // otherwise keep claiming it is on. Never on a read-only engine —
        // assigning the flag re-registers the login item.
        if sideEffects { reconcileLoginItem() }
        // Reads the Keychain, which is not a read a headless process can make.
        // `SecItemCopyMatching` asks for authorisation through a GUI dialog
        // whenever the item's ACL does not match the calling binary — and it
        // stops matching on every rebuild, because the ACL pins a cdhash. A
        // `.prohibited` CLI process cannot draw that dialog and cannot dismiss
        // it, so `--render-live` blocked forever inside Security with nothing
        // on screen. Only an engine that owns a UI may ask.
        if sideEffects { refreshAccountStatus() }

        if sideEffects, preferences.liveFetchPermitted { Task { await fetchLive() } }

        // Drop state for sessions that have ended, so neither the scanner's
        // caches nor the "tokens across open sessions" total grow forever.
        tokens = tokens.filter { live.contains($0.key) }
        // One small file per live session — the same cost class as
        // QuotaReader.read(), so it belongs on the main refresh path rather
        // than in the off-actor scan. `live` must be the real set: an empty one
        // deliberately prunes nothing, because it means "we could not enumerate
        // sessions", not "nothing is running".
        sessionUsage = QuotaReader.sessionUsage(live: live)
        rescanTokens(sessions: loaded, live: live)

        guard sideEffects else { return }
        evaluateNotifications()
        if preferences.autoHibernateEnabled { runAutoHibernate() }
    }

    /// One quota view from two sources, merged per window rather than by
    /// replacement.
    ///
    /// Whichever snapshot was captured most recently wins each window it
    /// reports, but rows only the other source produces are kept. Replacing
    /// wholesale meant any session drawing its statusline erased every
    /// model-scoped row that exists only on the API path.
    nonisolated static func merged(statusline: QuotaSnapshot?,
                                   api: QuotaSnapshot?) -> QuotaSnapshot? {
        guard let statusline else { return api }
        guard let api else { return statusline }
        let (fresh, stale) = statusline.capturedAt >= api.capturedAt
            ? (statusline, api) : (api, statusline)
        // A carried-over window whose reset time has passed describes a period
        // that has already ended — drop it rather than show it as current.
        func live(_ window: QuotaSnapshot.Window?) -> QuotaSnapshot.Window? {
            guard let window, (window.resetsAt ?? .distantFuture) > Date() else { return nil }
            return window
        }
        var scoped = stale.scoped.compactMapValues(live)
        scoped.merge(fresh.scoped) { _, new in new }
        return QuotaSnapshot(fiveHour: fresh.fiveHour ?? live(stale.fiveHour),
                             sevenDay: fresh.sevenDay ?? live(stale.sevenDay),
                             scoped: scoped,
                             capturedAt: fresh.capturedAt,
                             sourceSessionId: fresh.sourceSessionId ?? stale.sourceSessionId)
    }

    /// Token totals, computed off the main actor and published when they land.
    ///
    /// This used to run inline in `refresh()`, which `AppDelegate` calls before
    /// presenting the popover — so opening the menu bar item waited on a
    /// filesystem pass over every open session's transcript tree. Warm that is
    /// a few hundred file opens; cold it is the whole corpus. The numbers now
    /// arrive a moment after the popover does, which is the right trade: they
    /// are a spend readout, not something you act on in the first frame.
    ///
    /// Superseding scans cancel their predecessor, so holding the popover open
    /// through several poll ticks cannot pile up overlapping passes.
    private func rescanTokens(sessions: [Session], live: Set<String>) {
        // Cancelling is a request, not a stop: the scan is actor work doing
        // synchronous file I/O, so a superseded one keeps running until it
        // reaches its next cancellation check. Starting another regardless
        // meant every poll enqueued more than it withdrew, and the cooperative
        // pool spawned a thread per blocked call to compensate — 64 of them
        // after a day, with the main actor starved and the popover dead.
        //
        // So: ask the old one to stop, and do not start a new one until it
        // has. Skipping a scan costs a poll's worth of staleness in a spend
        // readout; not skipping it cost the whole app.
        guard scanTask == nil else {
            scanTask?.cancel()
            return
        }
        let scanner = self.scanner
        // The body inherits this actor, so the flag can be cleared inline. It
        // used to be a `defer` that spawned a second Task to hop back here,
        // which deadlocked every CLI path: those run the engine inside
        // `MainActor.assumeIsolated`, so the main thread is *inside* the actor
        // and no queued hop can ever run.
        scanTask = Task { [weak self] in
            var fresh: [String: TokenTotals] = [:]
            for session in sessions {
                if Task.isCancelled { break }
                fresh[session.sessionId] = await scanner.totals(
                    cwd: session.cwd, sessionId: session.sessionId)
            }
            if !Task.isCancelled {
                await scanner.prune(keeping: live)
                self?.tokens = fresh
            }
            // Cleared on every exit, cancelled included. An early `return` here
            // used to leave it set, and the guard above then refused every
            // later scan for the life of the process.
            self?.scanTask = nil
        }
    }

    // MARK: - Actions

    func freeze(_ session: Session) {
        perform { try SessionControl.freeze(session: session, store: self.frozenStore) }
    }

    func thaw(_ session: Session) {
        perform { try SessionControl.thaw(session: session, store: self.frozenStore) }
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
        // A poll-tick auto-hibernate may already be running against this very
        // session. Both would capture and terminate it, and whichever finished
        // first would clear the in-flight mark, letting the next poll's prune
        // delete the record — the only copy of the captured argv — from under
        // the other.
        guard !inFlightHibernations.contains(session.sessionId) else { return }
        isBusyWithBatch = true
        inFlightHibernations.insert(session.sessionId)
        Task {
            let (freed, failures) = await SessionControl.hibernate(sessions: [session], store: store)
            inFlightHibernations.remove(session.sessionId)
            isBusyWithBatch = false
            // The real reason, not a guess. A session refused for an inline
            // --mcp-config is not one whose command line could not be read.
            lastError = freed.isEmpty
                ? (failures.first?.error.localizedDescription
                   ?? "Could not hibernate \(session.projectName).")
                : nil
            refresh()
        }
    }

    /// Hibernate every session that is idle past the notification threshold —
    /// the set the header's "Reclaim N" button describes.
    func hibernateIdleSessions() {
        let cutoff = max(0, preferences.notifyIdleMinutes) * 60
        // Anything already being hibernated is dropped, not hibernated twice.
        let targets = sessions.filter {
            $0.declaredStatus == "idle" && ($0.idleFor ?? 0) >= cutoff
                && !inFlightHibernations.contains($0.sessionId)
        }
        guard !targets.isEmpty else {
            lastError = "Nothing is idle enough to reclaim right now."
            return
        }
        isBusyWithBatch = true
        inFlightHibernations.formUnion(targets.map(\.sessionId))
        Task {
            let (freed, failures) = await SessionControl.hibernate(sessions: targets, store: store)
            inFlightHibernations.subtract(targets.map(\.sessionId))
            isBusyWithBatch = false
            let bytes = freed.reduce(UInt64(0)) { $0 + $1.reclaimedBytes }
            lastNotice = freed.isEmpty ? nil
                : "Hibernated \(freed.count) session\(freed.count == 1 ? "" : "s"), freeing \(Fmt.bytes(bytes))."
            lastError = Self.batchFailureMessage(freed: freed.count,
                                                 attempted: targets.count,
                                                 failures: failures)
            refresh()
        }
    }

    /// One sentence for a partial batch, naming the first real reason rather
    /// than asserting a cause. "Could not be ended" is a count, not a
    /// diagnosis; the store and the capture step both have specific errors.
    private static func batchFailureMessage(
        freed: Int, attempted: Int,
        failures: [(session: Session, error: any Error)]) -> String? {
        guard freed < attempted else { return nil }
        let missed = attempted - freed
        let plural = missed == 1 ? "" : "s"
        guard let first = failures.first else {
            return "\(missed) session\(plural) could not be ended."
        }
        let detail = first.error.localizedDescription
        return missed == 1
            ? "Could not hibernate \(first.session.projectName): \(detail)"
            : "\(missed) session\(plural) could not be ended. \(first.session.projectName): \(detail)"
    }

    /// Hibernate every session in a project group.
    ///
    /// Guarded to explicitly-idle sessions even though the UI only offers the
    /// button for an all-idle group: state can change between the render and
    /// the click, and terminating a session that just started working would be
    /// unrecoverable from the user's point of view.
    func hibernateGroup(_ group: ProjectGroup) {
        let targets = group.sessions.filter {
            $0.declaredStatus == "idle" && !inFlightHibernations.contains($0.sessionId)
        }
        guard !targets.isEmpty else {
            lastError = "Those sessions are no longer idle."
            return
        }
        isBusyWithBatch = true
        inFlightHibernations.formUnion(targets.map(\.sessionId))
        Task {
            let (freed, failures) = await SessionControl.hibernate(sessions: targets, store: store)
            inFlightHibernations.subtract(targets.map(\.sessionId))
            isBusyWithBatch = false
            lastError = Self.batchFailureMessage(freed: freed.count,
                                                 attempted: targets.count,
                                                 failures: failures)
            refresh()
        }
    }

    func revive(_ record: HibernatedSession) {
        revive(record, destination: .automatic)
    }

    /// A new terminal window, because that is what was asked for — offered
    /// beside Revive for the sessions whose own tab cannot be reached, where
    /// the automatic answer is a handoff rather than a window.
    func reviveInNewWindow(_ record: HibernatedSession) {
        revive(record, destination: .newWindow)
    }

    private func revive(_ record: HibernatedSession,
                        destination: SessionControl.ReviveDestination) {
        do {
            let outcome = try SessionControl.revive(
                record, terminal: preferences.launchTerminal, destination: destination)
            lastError = nil
            lastNotice = SessionControl.notice(for: outcome, record: record)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// The command revive would run, on the clipboard, without reviving.
    ///
    /// Worth having even for a session whose tab *is* reachable: it is how
    /// someone checks what Torpor is about to run before trusting it with a
    /// session. The CLI has had this as `--resume-command` all along.
    func copyResumeCommand(_ record: HibernatedSession) {
        SessionControl.copyCommand(for: record)
        lastError = nil
        lastNotice = "Copied the command for \(record.name) to the clipboard."
    }

    func forget(_ record: HibernatedSession) {
        // Surfaced rather than swallowed: a forget that silently fails to write
        // leaves the row on screen after the next refresh, which reads as the
        // button not working.
        do {
            try store.remove(sessionId: record.sessionId)
            lastError = nil
        } catch {
            lastError = "Could not forget \(record.name): \(error.localizedDescription)"
        }
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

    private func refreshAccountStatus() {
        switch preferences.authMode {
        case .statusline:
            // Five installer states used to collapse into two sentences, and
            // "connected" was set purely from "the shim path is in
            // settings.json" — so a fresh install, or an API-key account whose
            // payload carries no rate_limits, showed a green seal forever while
            // the popover said "No usage data yet" on the same screen.
            switch statuslineState {
            case .installed:
                let snapshot = QuotaReader.read()
                accountStatus.connected = snapshot != nil
                if let snapshot {
                    accountStatus.detail = snapshot.isStale
                        ? "Read \(Fmt.duration(snapshot.age)) ago — refreshes only while a session draws its statusline"
                        : "Reading usage from Claude Code · \(Fmt.duration(snapshot.age)) ago"
                } else if QuotaReader.payloadExists {
                    accountStatus.detail = "Claude Code sent no plan limits — only Pro and Max accounts have them"
                } else {
                    accountStatus.detail = "Set up — waiting for a session to draw its statusline"
                }
            case .needsRepair:
                accountStatus.connected = false
                accountStatus.detail = "Usage reporting isn't running — repair it below"
            case .foreign:
                accountStatus.connected = false
                accountStatus.detail = "You already have a statusline — Torpor hasn't been added to it"
            case let .settingsUnreadable(why):
                accountStatus.connected = false
                accountStatus.detail = "Can't read ~/.claude/settings.json — \(why)"
            case .notInstalled:
                accountStatus.connected = false
                accountStatus.detail = "Usage reporting not set up yet"
            }

        case .cliCredentials, .pastedToken:
            if !preferences.acknowledgedRiskModes.contains(preferences.authMode) {
                accountStatus.connected = false
                accountStatus.detail = "Accept the risk notice to connect"
            } else if let token = CredentialStore.subscriptionToken() {
                if token.isExpired {
                    accountStatus.connected = false
                    accountStatus.detail = "Token expired — reconnect"
                } else if accountStatus.lastFetch != nil, accountStatus.lastFetchError == nil {
                    // Evidence, not existence. A bare pasted string has no
                    // expiry, so `!isExpired` was true for the word "test".
                    accountStatus.connected = true
                    accountStatus.detail = "Connected" + (token.subscriptionType.map { " · \($0)" } ?? "")
                } else {
                    accountStatus.connected = false
                    accountStatus.detail = "Token stored — not yet verified"
                }
            } else {
                accountStatus.connected = false
                accountStatus.detail = "No token stored"
            }

        case .consoleAPIKey:
            if CredentialStore.consoleKey() == nil {
                accountStatus.connected = false
                accountStatus.detail = "No API key stored"
            } else if accountStatus.lastFetch != nil, accountStatus.lastFetchError == nil {
                accountStatus.connected = true
                accountStatus.detail = "Console spend is loading"
            } else {
                accountStatus.connected = false
                accountStatus.detail = "API key stored — not yet verified"
            }
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
        guard await api.canFetch else {
            nextFetchAllowed = await api.nextFetchDate
            return
        }

        do {
            switch preferences.authMode {
            case .cliCredentials, .pastedToken:
                // Belt and braces: no network call on this path without consent,
                // whichever caller got us here.
                guard preferences.acknowledgedRiskModes.contains(preferences.authMode),
                      let token = CredentialStore.subscriptionToken(
                        refreshingFromClaudeCode: preferences.authMode == .cliCredentials)
                else { return }
                let (snapshot, balance) = try await api.fetchSubscription(token: token)
                apiQuota = snapshot
                quota = Self.merged(statusline: statuslineQuota, api: apiQuota)
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
            accountStatus.errorMode = preferences.authMode
        }
        nextFetchAllowed = await api.nextFetchDate
    }

    func disarmConfirmations() {
        confirmationGeneration &+= 1
    }

    // MARK: - Updates

    var installKind: Updater.InstallKind { Updater.installKind }
    var currentVersionString: String { Updater.currentVersion }

    func forceRefreshAccount() {
        // The consent flag gated only the poll loop, so withdrawing consent
        // left this button still sending a bearer token to the endpoint the
        // app itself warns can get an account banned.
        guard preferences.liveFetchPermitted else {
            lastError = "Accept the account-risk notice before Torpor will contact Anthropic."
            return
        }
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

    /// Why the usage panel is empty, in the user's terms.
    ///
    /// The old text said "install the shim" unconditionally, which is wrong
    /// once it *is* installed — and permanently unachievable advice for an
    /// API-key, Bedrock or Vertex account, which has no plan quota to report
    /// and would otherwise be told to wait for data that will never arrive.
    var usageEmptyExplanation: String {
        guard preferences.authMode == .statusline else { return accountStatus.detail }
        switch statuslineState {
        case .notInstalled:
            return "Torpor reads your limits from Claude Code's statusline. No credentials, no network calls."
        case .needsRepair:
            return "The script Claude Code points at is missing or somewhere it can't run it. Repair it in Settings."
        case .foreign:
            return "You already have a statusline. Torpor runs alongside it — install from Settings."
        case .settingsUnreadable:
            return "Can't read ~/.claude/settings.json. Fix or move that file, then try again."
        case .installed:
            return QuotaReader.payloadExists
                ? "Claude Code sent no plan limits. Only Pro and Max accounts have them."
                : "Set up. Numbers arrive the next time a session draws its statusline."
        }
    }

    /// Why the session list is empty, in the user's terms.
    ///
    /// `registryLooksBroken` already suppresses auto-hide, but nothing ever
    /// said so on screen: an upstream change to the session-file format read
    /// as "you have nothing running" while sessions were plainly running.
    var sessionsEmptyExplanation: String {
        registryLooksBroken
            ? "Claude Code's session format has probably changed. Freeze and hibernate are unavailable until Torpor can read it again."
            : "Nothing running. Sessions appear here as soon as you start one."
    }

    /// Whether a subscription token is on disk, regardless of consent state —
    /// so the delete button can be shown even after consent is withdrawn.
    var hasStoredSubscriptionToken: Bool { CredentialStore.subscriptionToken() != nil }
    var hasStoredConsoleKey: Bool { CredentialStore.consoleKey() != nil }

    /// Clear only the subscription token. Split from the Console key because a
    /// single shared `disconnect()` meant rotating an API key also destroyed
    /// the user's subscription credential.
    func clearSubscriptionCredential() {
        CredentialStore.clearSubscriptionToken()
        if preferences.authMode == .cliCredentials || preferences.authMode == .pastedToken {
            preferences.authMode = .statusline
        }
        preferences.acknowledgedRiskModes = []
        credits = CreditBalance()
        // Drop everything the deleted token fetched — including the model-scoped
        // rows only that path produces. The statusline snapshot needs no
        // credentials and survives; the refresh() below recomputes `quota`.
        apiQuota = nil
        accountStatus.lastFetch = nil
        accountStatus.lastFetchError = nil
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
    ///
    /// Always the same shape: one quota window as a bar, one memory figure
    /// beside it. The preferences choose which window and which figure, not
    /// whether either is there — so no setting can produce a layout the user
    /// has to re-learn, and the bar is never a share of something that has no
    /// share to be.
    var menuBarInput: MenuBarRenderer.Input {
        let window: QuotaSnapshot.Window?
        let windowLength: TimeInterval

        switch preferences.menuBarMetric {
        case .fiveHour:
            window = quota?.fiveHour
            windowLength = 5 * 3600
        case .sevenDay:
            window = quota?.sevenDay
            windowLength = 7 * 86_400
        }

        let fraction = window.map { $0.usedPercentage / 100 }
        let resets = window?.resetsAt
        let percentText = fraction.map { "\(Int(($0 * 100).rounded()))%" }

        // Straight from the engine's own totals — never recomputed here, so the
        // figure in the menu bar and the figure on the Reclaim button cannot
        // disagree about what is idle.
        let bytes: UInt64
        switch preferences.memoryFigure {
        case .total:       bytes = totalFootprint
        case .reclaimable: bytes = reclaimableFootprint
        }
        // With nothing running there is no figure to give: "0 MB" beside a
        // quota bar is a number that can never change and answers nothing. With
        // sessions running, a reclaimable zero is real information — it means
        // nothing has been idle long enough yet — so it is shown.
        let memoryText = sessions.isEmpty ? nil : Fmt.bytes(bytes)

        // Anthropic publishes the window structure (rolling 5-hour, weekly) but
        // not a start timestamp, so elapsed is derived from the reset time and
        // the known window length.
        func elapsedFraction(resets: Date?, length: TimeInterval) -> Double? {
            guard let resets, length > 0 else { return nil }
            let remaining = resets.timeIntervalSinceNow
            guard remaining > 0, remaining <= length else { return nil }
            return 1 - (remaining / length)
        }

        // Strictly this bar's own window. The white line is drawn across the
        // fill, and the duration under it counts the same window down, so
        // borrowing another window's clock would put two unrelated quantities
        // in one column and read as pace information about a bar that has no
        // pace.
        let elapsed = elapsedFraction(resets: resets, length: windowLength)

        return .init(style: preferences.menuBarStyle,
                     colorMode: preferences.colorMode,
                     marker: preferences.timeMarker,
                     fraction: fraction,
                     percentText: percentText,
                     memoryText: memoryText,
                     memoryColor: MenuBarRenderer.memoryTint(for: preferences.memoryFigure,
                                                             mode: preferences.colorMode),
                     resetsAt: resets,
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
                title: "\(session.projectName) idle \(Fmt.duration(idle))",
                body: "Holding \(Fmt.bytes(session.totalFootprint)). Hibernate to reclaim it."
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
                  !session.isFrozen,
                  // Hibernating is now async, so the poll timer can fire again
                  // — and the user can click Hibernate — while this one is
                  // still in its SIGTERM grace period. Two overlapping
                  // hibernates of one session race to remove the record.
                  !inFlightHibernations.contains(session.sessionId) else { continue }

            inFlightHibernations.insert(session.sessionId)
            // Deliberately not setting isBusyWithBatch: several auto-hibernates
            // can be in flight at once and would race the flag back to false,
            // and that flag exists to disable buttons the user could
            // double-click, not to describe background work.
            Task {
                defer { inFlightHibernations.remove(session.sessionId) }
                do {
                    let record = try await SessionControl.hibernate(session: session, store: store)
                    guard preferences.notificationsEnabled else { return }
                    notifier.post(
                        key: "auto-\(record.sessionId)",
                        title: "Hibernated \(record.name)",
                        body: "Idle \(Fmt.duration(idle)) · \(Fmt.bytes(record.reclaimedBytes)) reclaimed. Revive from the menu bar."
                    )
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
    }
}
