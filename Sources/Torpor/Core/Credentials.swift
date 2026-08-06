import Foundation
import Security

/// Where Torpor gets its usage numbers.
///
/// These are not equivalent choices and the UI must not present them as if they
/// were. See `riskNote` — it is rendered next to each option at the point of
/// selection, not buried in a help page.
enum AuthMode: String, Codable, CaseIterable, Identifiable {
    /// Documented, credential-free. Claude Code hands the statusline a payload
    /// containing `rate_limits`; Torpor tees it to a file.
    case statusline
    /// The OAuth token Claude Code stores in the login Keychain, reused to call
    /// the undocumented subscription usage endpoint.
    case cliCredentials
    /// The same thing, pasted by hand.
    case pastedToken
    /// A Console API key against the documented Admin usage/cost endpoints.
    case consoleAPIKey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .statusline:     return "Claude Code statusline"
        case .cliCredentials: return "Connect with Claude CLI"
        case .pastedToken:    return "Paste subscription token"
        case .consoleAPIKey:  return "Console API key"
        }
    }

    /// One line each. These sit in a radio list where the user is comparing
    /// them, so they say what differs — not how each one works.
    var summary: String {
        switch self {
        case .statusline:
            return "5-hour and weekly usage. No credentials, no network. Pro and Max plans only."
        case .cliCredentials:
            return "Adds per-model rows and credits. Reuses Claude Code's Keychain credential, refresh token included."
        case .pastedToken:
            return "The same, for a token you paste yourself."
        case .consoleAPIKey:
            return "Month-to-date spend, daily chart, per-model cost. Org accounts only."
        }
    }

    /// Nil where there is nothing to warn about. Never suppress this in the UI.
    ///
    /// Short, but not shortened past the four facts the decision needs: the
    /// endpoint is undocumented, the credential is theirs, the terms forbid it,
    /// and the consequence is theirs too.
    var riskNote: String? {
        switch self {
        case .statusline, .consoleAPIKey:
            return nil
        case .cliCredentials, .pastedToken:
            return """
            Torpor reads an endpoint Anthropic does not document, using your own OAuth \
            credential. Anthropic's terms reserve OAuth for their own apps and forbid \
            third parties routing requests through Pro or Max credentials. Any \
            consequence lands on your account, not Torpor's.

            Torpor identifies itself honestly, and sends at most one request every five \
            minutes while this source is selected.
            """
        }
    }

    var isSanctioned: Bool { riskNote == nil }
}

/// Thin Keychain wrapper over `kSecClassGenericPassword`.
enum Keychain {

    enum KeychainError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            switch self {
            case let .status(code):
                let message = SecCopyErrorMessageString(code, nil) as String? ?? "code \(code)"
                return "Keychain error: \(message)"
            }
        }
    }

    static func set(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update if present, insert otherwise.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw KeychainError.status(updateStatus) }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    }

    static func get(service: String, account: String? = nil) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(service: String, account: String? = nil) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        SecItemDelete(query as CFDictionary)
    }
}

/// A subscription OAuth token plus what we know about it.
struct SubscriptionToken {
    var accessToken: String
    var expiresAt: Date?
    var subscriptionType: String?

    var isExpired: Bool { expiresWithin(0) }

    /// Whether this token dies within `seconds`. A token with no expiry in it
    /// is taken at face value, since a pasted one carries none.
    func expiresWithin(_ seconds: TimeInterval) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(seconds)
    }
}

/// Remembers what the Keychain returned, for the life of the process.
///
/// Reading a secret runs the item's ACL check, and any read can therefore raise
/// a password dialog. `refreshAccountStatus()` did one on every poll tick — a
/// secret read, thirty seconds apart, purely to render a status string — so
/// whenever a dialog was due it was due again half a minute later. Nothing on
/// that path needs a fresh read: it asks only whether a token exists and when it
/// expires, and neither changes without going through the setters below, which
/// invalidate this.
///
/// A stable Developer ID keeps the grant for Torpor's *own* item across builds,
/// so this is no longer the difference between prompting and not. It is the
/// difference between asking once and asking on a timer.
///
/// Lock-guarded rather than actor-isolated, matching `HibernationStore`: the
/// Keychain read happens outside the lock, so a prompt the user leaves on
/// screen cannot wedge anything else.
private final class CredentialCache: @unchecked Sendable {
    private let lock = NSLock()
    /// Double optional throughout: the outer layer is "have we looked yet",
    /// the inner is what we found. Caching the misses matters as much as
    /// caching the hits, or the no-token case re-queries on every tick.
    private var subscription: SubscriptionToken??
    private var console: String??

    func cachedSubscription() -> SubscriptionToken?? { lock.withLock { subscription } }
    func rememberSubscription(_ value: SubscriptionToken?) {
        lock.withLock { subscription = .some(value) }
    }

    func cachedConsole() -> String?? { lock.withLock { console } }
    func rememberConsole(_ value: String?) { lock.withLock { console = .some(value) } }

    /// Set when an unattended re-import failed, which in practice means the
    /// user dismissed the Keychain dialog. Only an explicit action clears it.
    private var autoImportBlocked = false
    func importIsBlocked() -> Bool { lock.withLock { autoImportBlocked } }
    func blockAutoImport() { lock.withLock { autoImportBlocked = true } }
    func unblockAutoImport() { lock.withLock { autoImportBlocked = false } }

    func forget() { lock.withLock { subscription = nil; console = nil } }
}

/// Reads and stores Torpor's own credentials, and imports Claude Code's.
enum CredentialStore {

    private static let service = "dev.torpor.Torpor"
    private static let subscriptionAccount = "subscription-token"
    private static let consoleAccount = "console-api-key"

    /// The Keychain item Claude Code writes its OAuth credentials into.
    private static let claudeCodeService = "Claude Code-credentials"

    private static let cache = CredentialCache()

    /// Drop the remembered credentials, so the next read goes to the Keychain.
    /// Every setter and every clear calls this; nothing else needs to.
    static func invalidateCache() { cache.forget() }

    // MARK: - Torpor's own storage

    static func storeSubscriptionToken(_ raw: String) throws {
        try Keychain.set(raw.trimmingCharacters(in: .whitespacesAndNewlines),
                         service: service, account: subscriptionAccount)
        invalidateCache()
    }

    static func subscriptionToken() -> SubscriptionToken? {
        if let remembered = cache.cachedSubscription() { return remembered }
        let value = readSubscriptionToken()
        cache.rememberSubscription(value)
        return value
    }

    /// The uncached read. Only `subscriptionToken()` should call this: every
    /// call here is a potential password prompt.
    private static func readSubscriptionToken() -> SubscriptionToken? {
        // `try?` already flattens the optional Keychain.get returns.
        guard let raw = try? Keychain.get(service: service, account: subscriptionAccount),
              !raw.isEmpty else { return nil }
        // Stored either as a bare token or as the JSON blob we imported.
        if raw.hasPrefix("{"), let parsed = parseClaudeCodeCredentials(raw) { return parsed }
        return SubscriptionToken(accessToken: raw, expiresAt: nil, subscriptionType: nil)
    }

    /// The stored token, re-imported from Claude Code if ours has gone stale.
    ///
    /// Importing takes a *copy* of Claude Code's credential, and that copy is
    /// dead within hours: the access token here lasted about eight, while
    /// Claude Code silently refreshes its own and carries on. So the imported
    /// copy expires, `fetchSubscription` refuses before it makes a request, and
    /// the per-model rows never arrive again after the first day. The symptom
    /// is indistinguishable from the feature not working.
    ///
    /// Rather than implement the OAuth refresh grant, take the fresh copy from
    /// the process that is already maintaining one. Only for `.cliCredentials`:
    /// a pasted token has no upstream to re-read, so it stays as given and
    /// expires honestly.
    static func subscriptionToken(refreshingFromClaudeCode: Bool) -> SubscriptionToken? {
        let stored = subscriptionToken()
        guard refreshingFromClaudeCode else { return stored }
        // A token about to expire mid-request is no more use than an expired one.
        if let stored, !stored.expiresWithin(60) { return stored }

        // Reading Claude Code's item can raise a Keychain dialog at any moment,
        // and not only on the first run: Claude Code *rewrites* that item every
        // time it rotates its token, and a rewritten item carries a fresh ACL
        // that does not list Torpor. So "Always Allow" cannot stick, by
        // construction — the item the grant was made against no longer exists.
        //
        // The loop that produced was the bug. `try?` swallowed a dismissal and
        // returned the expired token, the request 401'd, and the poll came back
        // five minutes later and asked again. Dismiss once, get asked every five
        // minutes indefinitely. One unattended attempt is worth making, because
        // it is silent whenever the ACL does happen to allow it; a second one
        // after a refusal is just nagging.
        guard !cache.importIsBlocked() else { return stored }
        do {
            return try importFromClaudeCode()
        } catch {
            cache.blockAutoImport()
            return stored
        }
    }

    /// Whether an automatic renewal is currently held back by a refusal, so the
    /// UI can offer the reconnect rather than leaving the user with rows that
    /// silently stopped updating.
    static var automaticImportBlocked: Bool { cache.importIsBlocked() }

    /// Let the next renewal ask again. Only ever called for something the user
    /// actively did — pressing Refresh, or Connect.
    static func allowImportPrompt() { cache.unblockAutoImport() }

    static func clearSubscriptionToken() {
        Keychain.delete(service: service, account: subscriptionAccount)
        invalidateCache()
    }

    static func storeConsoleKey(_ key: String) throws {
        try Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines),
                         service: service, account: consoleAccount)
        invalidateCache()
    }

    static func consoleKey() -> String? {
        if let remembered = cache.cachedConsole() { return remembered }
        let key = try? Keychain.get(service: service, account: consoleAccount)
        let value = (key?.isEmpty == false) ? key : nil
        cache.rememberConsole(value)
        return value
    }

    static func clearConsoleKey() {
        Keychain.delete(service: service, account: consoleAccount)
        invalidateCache()
    }

    // MARK: - Import from Claude Code

    /// Whether Claude Code's Keychain item exists at all. Checked without
    /// reading the secret, so it does not trigger a consent prompt.
    static func claudeCodeCredentialsPresent() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeService,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    /// Import Claude Code's OAuth token.
    ///
    /// macOS shows a consent dialog the first time, because the item belongs to
    /// another application. That prompt is the "opens a window to auth" step —
    /// it is the system asking whether Torpor may use your Claude credentials,
    /// and declining it is a valid answer.
    static func importFromClaudeCode() throws -> SubscriptionToken {
        guard let raw = try Keychain.get(service: claudeCodeService), !raw.isEmpty else {
            throw ImportError.notFound
        }
        guard let token = parseClaudeCodeCredentials(raw) else {
            throw ImportError.unrecognisedFormat
        }
        try Keychain.set(raw, service: service, account: subscriptionAccount)
        // `Keychain.set` writes through the private helper rather than the
        // caching setter, so the fresh copy has to be published here — the
        // re-import path exists precisely because the cached one went stale.
        cache.rememberSubscription(token)
        // A read that got through is also the answer to whatever refusal
        // blocked the last one.
        cache.unblockAutoImport()
        return token
    }

    enum ImportError: LocalizedError {
        case notFound, unrecognisedFormat
        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No Claude Code credentials found in your Keychain. Sign in with `claude` in a terminal first."
            case .unrecognisedFormat:
                return "Claude Code's credential format has changed and Torpor could not read it."
            }
        }
    }

    /// Claude Code stores `{"claudeAiOauth": {accessToken, expiresAt, …}}`.
    /// Decoded defensively: the shape is undocumented and has changed before.
    private static func parseClaudeCodeCredentials(_ raw: String) -> SubscriptionToken? {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Accept either the nested shape or a flat one.
        let container = (root["claudeAiOauth"] as? [String: Any]) ?? root

        let tokenKeys = ["accessToken", "access_token", "token"]
        guard let token = tokenKeys.compactMap({ container[$0] as? String })
            .first(where: { !$0.isEmpty }) else { return nil }

        var expires: Date?
        for key in ["expiresAt", "expires_at"] {
            if let millis = container[key] as? Double {
                // Heuristic: values past ~year 2300 in seconds are milliseconds.
                expires = Date(timeIntervalSince1970: millis > 1e11 ? millis / 1000 : millis)
                break
            }
        }

        let subscription = ["subscriptionType", "subscription_type"]
            .compactMap { container[$0] as? String }.first

        return SubscriptionToken(accessToken: token,
                                 expiresAt: expires,
                                 subscriptionType: subscription)
    }
}
