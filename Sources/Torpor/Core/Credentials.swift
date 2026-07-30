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

    var summary: String {
        switch self {
        case .statusline:
            return "Reads the usage payload Claude Code already gives your statusline. No credentials, no network calls. Plan limits are only reported for Claude.ai Pro and Max accounts."
        case .cliCredentials:
            return "Copies the credentials Claude Code stored in your Keychain — including its refresh token — into Torpor's own Keychain item. macOS will ask your permission."
        case .pastedToken:
            return "For a token you already have. Stored in your login Keychain, never written to disk in plain text."
        case .consoleAPIKey:
            return "Anthropic Console spend: month-to-date cost, a daily chart and a per-model breakdown. Separate from your subscription limits, and needs an organisation account with Admin API access."
        }
    }

    /// Nil where there is nothing to warn about. Never suppress this in the UI.
    var riskNote: String? {
        switch self {
        case .statusline, .consoleAPIKey:
            return nil
        case .cliCredentials, .pastedToken:
            return """
            This reads your usage from an endpoint Anthropic does not document, using \
            your own OAuth credential. Anthropic's Claude Code terms say OAuth \
            authentication is intended for ordinary use of Claude Code and other native \
            Anthropic applications, and that third parties may not route requests through \
            Pro or Max plan credentials. Any consequence lands on your account, not \
            Torpor's.

            What Torpor does not do is pretend to be Claude Code. It used to send a \
            claude-code/<version> User-Agent copied from your installed CLI, which is \
            exactly what the January 2026 anti-spoofing safeguards were built to catch. \
            It now identifies itself as Torpor. The endpoint answers either way, so the \
            disguise only ever added risk.

            One request every five minutes at most, and only while this source is \
            selected.
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

/// Reads and stores Torpor's own credentials, and imports Claude Code's.
enum CredentialStore {

    private static let service = "dev.torpor.Torpor"
    private static let subscriptionAccount = "subscription-token"
    private static let consoleAccount = "console-api-key"

    /// The Keychain item Claude Code writes its OAuth credentials into.
    private static let claudeCodeService = "Claude Code-credentials"

    // MARK: - Torpor's own storage

    static func storeSubscriptionToken(_ raw: String) throws {
        try Keychain.set(raw.trimmingCharacters(in: .whitespacesAndNewlines),
                         service: service, account: subscriptionAccount)
    }

    static func subscriptionToken() -> SubscriptionToken? {
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
        guard let fresh = try? importFromClaudeCode() else { return stored }
        return fresh
    }

    static func clearSubscriptionToken() {
        Keychain.delete(service: service, account: subscriptionAccount)
    }

    static func storeConsoleKey(_ key: String) throws {
        try Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines),
                         service: service, account: consoleAccount)
    }

    static func consoleKey() -> String? {
        guard let key = try? Keychain.get(service: service, account: consoleAccount),
              !key.isEmpty else { return nil }
        return key
    }

    static func clearConsoleKey() {
        Keychain.delete(service: service, account: consoleAccount)
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
