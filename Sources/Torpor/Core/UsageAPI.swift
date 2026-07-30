import Foundation

/// Usage credits and overage, which are separate ledgers from plan limits.
struct CreditBalance: Codable, Equatable {
    /// Pay-as-you-go credit remaining, in USD.
    var remainingUSD: Double?
    /// One-time / promotional credit remaining, in USD.
    var oneTimeRemainingUSD: Double?
    var oneTimeExpiresAt: Date?
    /// Whether the account is currently spending overage rather than plan quota.
    var usingExtraUsage: Bool = false

    var hasAnything: Bool {
        remainingUSD != nil || oneTimeRemainingUSD != nil || usingExtraUsage
    }
}

/// Anthropic Console spend, from the documented Admin API.
struct ConsoleUsage: Codable, Equatable {
    struct Day: Codable, Equatable, Identifiable {
        var date: Date
        var costUSD: Double
        var id: Date { date }
    }
    var monthToDateUSD: Double = 0
    var days: [Day] = []
    var byModel: [String: Double] = [:]
    var fetchedAt: Date = Date()
}

/// Network client.
///
/// Rate limiting is the design constraint, not an edge case. Anthropic's own
/// client falls back to an hour-old cached snapshot when the usage call fails,
/// and third-party trackers gate refreshes behind multi-minute cooldowns because
/// 429s are routine. Torpor therefore treats a refusal as normal: it honours
/// `Retry-After`, backs off exponentially, and never retries in a loop.
actor UsageAPI {

    enum APIError: LocalizedError {
        case notConfigured
        case unauthorized
        case rateLimited(retryAfter: TimeInterval)
        case http(status: Int, body: String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "No credentials configured for this source."
            case .unauthorized:
                return "Credentials were rejected. The token may have expired — reconnect in Settings."
            case let .rateLimited(retryAfter):
                return "Anthropic is rate limiting usage requests. Retrying in \(Fmt.duration(retryAfter))."
            case let .http(status, body):
                return "Request failed (HTTP \(status)). \(body.prefix(200))"
            case let .malformed(detail):
                return "Unexpected response shape: \(detail)"
            }
        }
    }

    /// Minimum spacing between live calls, regardless of the UI poll interval.
    private let minimumInterval: TimeInterval = 300
    private var nextAllowedFetch = Date.distantPast
    private var consecutiveFailures = 0

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Whether a live call is permitted right now.
    var canFetch: Bool { Date() >= nextAllowedFetch }
    var nextFetchDate: Date { nextAllowedFetch }

    private func scheduleNext(after interval: TimeInterval? = nil) {
        let base = interval ?? minimumInterval
        // Exponential backoff on repeated failure, capped at an hour.
        let penalty = min(pow(2, Double(consecutiveFailures)) * 60, 3600)
        nextAllowedFetch = Date().addingTimeInterval(max(base, consecutiveFailures > 0 ? penalty : base))
    }

    // MARK: - Subscription usage (undocumented)

    /// How Torpor identifies itself to Anthropic. Honestly.
    ///
    /// This used to send `claude-code/<version>`, scraped from the installed
    /// CLI so the request would pass for the first-party client. That is the
    /// pattern Anthropic's anti-spoofing work targeted, and the bans that
    /// followed were for traffic pretending to be something it wasn't.
    ///
    /// Verified against the live endpoint on 2026-07-30: it answers 200 to a
    /// request that says plainly what it is. The disguise bought nothing and
    /// was the whole risk, so it is gone.
    static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return "Torpor/\(version ?? "dev") (+https://github.com/YasserShkeir/torpor)"
    }

    /// Fetch plan utilisation using a subscription OAuth token.
    ///
    /// Reads your own usage with your own credential. Still an endpoint
    /// Anthropic does not document, so it is never called unless the user has
    /// chosen this source.
    func fetchSubscription(token: SubscriptionToken) async throws -> (QuotaSnapshot, CreditBalance) {
        guard canFetch else { throw APIError.rateLimited(retryAfter: nextAllowedFetch.timeIntervalSinceNow) }
        guard !token.isExpired else { throw APIError.unauthorized }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        try check(response, data: data)

        consecutiveFailures = 0
        scheduleNext()
        return try Self.parseSubscription(data)
    }

    /// `resets_at` arrives as RFC3339 with six fractional digits and a
    /// `+00:00` offset. `ISO8601DateFormatter` without `.withFractionalSeconds`
    /// returns nil for it outright, and with the option set it still only
    /// accepts up to three, so the fraction is trimmed before the second
    /// attempt rather than losing the whole timestamp over sub-millisecond
    /// precision nothing here needs.
    private static func timestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }

        // Trim to milliseconds: 00:00:00.464888+00:00 -> 00:00:00.464+00:00
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "+" || $0 == "Z" || $0 == "-" }) {
            let trimmed = text[..<dot] + text[dot...].prefix(4) + text[end...]
            return fractional.date(from: String(trimmed))
        }
        return nil
    }

    /// Tolerant decoding: the payload is undocumented and its shape has changed
    /// more than once, so anything unrecognised degrades to "absent" rather
    /// than failing the whole refresh.
    nonisolated static func parseSubscription(_ data: Data) throws -> (QuotaSnapshot, CreditBalance) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.malformed("not a JSON object")
        }

        func window(_ any: Any?) -> QuotaSnapshot.Window? {
            guard let dict = any as? [String: Any] else { return nil }
            // `percent` is how entries in `limits` carry it, and it arrives as a
            // JSON integer where the top-level windows use a fractional
            // `utilization`. NSNumber covers both without a second cast.
            let percentKeys = ["utilization", "percent", "used_percentage",
                               "usedPercentage", "percent_used"]
            guard let percent = percentKeys
                .compactMap({ (dict[$0] as? NSNumber)?.doubleValue }).first else { return nil }
            var resets: Date?
            for key in ["resets_at", "resetsAt", "reset_at"] {
                if let seconds = dict[key] as? NSNumber {
                    let value = seconds.doubleValue
                    resets = Date(timeIntervalSince1970: value > 1e11 ? value / 1000 : value)
                    break
                }
                if let text = dict[key] as? String {
                    resets = Self.timestamp(text)
                    break
                }
            }
            return .init(usedPercentage: percent, resetsAt: resets)
        }

        var scoped: [String: QuotaSnapshot.Window] = [:]
        // Model-scoped rows have arrived three ways across three shapes of this
        // payload, and the server still sends the older keys as nulls, so all
        // three are read rather than the newest alone.
        for (key, value) in root where key.hasPrefix("seven_day_") {
            let name = String(key.dropFirst("seven_day_".count))
                .replacingOccurrences(of: "_", with: " ").capitalized
            if let w = window(value) { scoped[name] = w }
        }
        // The live shape, captured 2026-07-30: a `limits` array whose entries are
        // {kind, group, percent, resets_at, scope}. The model name is nested at
        // scope.model.display_name — there is no `name` or `model` string on the
        // entry itself, which is why an earlier reading of this array found
        // nothing and the per-model rows never appeared.
        var sessionWindow: QuotaSnapshot.Window?
        var weeklyWindow: QuotaSnapshot.Window?
        for limit in (root["limits"] as? [[String: Any]]) ?? [] {
            guard let w = window(limit) else { continue }
            switch limit["kind"] as? String {
            case "session":
                sessionWindow = w
            case "weekly_all":
                weeklyWindow = w
            case "weekly_scoped":
                let scope = limit["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = (model?["display_name"] as? String)
                    ?? (model?["id"] as? String)
                guard let name, !name.isEmpty else { continue }
                scoped[name] = w
            default:
                continue
            }
        }

        let snapshot = QuotaSnapshot(
            fiveHour: window(root["five_hour"]) ?? window(root["fiveHour"]) ?? sessionWindow,
            sevenDay: window(root["seven_day"]) ?? window(root["sevenDay"]) ?? weeklyWindow,
            scoped: scoped,
            capturedAt: Date(),
            sourceSessionId: nil
        )

        var credits = CreditBalance()
        for key in ["extra_usage", "usage_credits", "credits"] {
            guard let dict = root[key] as? [String: Any] else { continue }
            credits.remainingUSD = ["remaining_usd", "balance_usd", "remaining"]
                .compactMap { dict[$0] as? Double }.first
            credits.usingExtraUsage = (dict["enabled"] as? Bool)
                ?? (dict["active"] as? Bool) ?? credits.usingExtraUsage
        }
        if let oneTime = root["one_time_credit"] as? [String: Any] {
            credits.oneTimeRemainingUSD = ["remaining_usd", "remaining"]
                .compactMap { oneTime[$0] as? Double }.first
            if let expiry = oneTime["expires_at"] as? Double {
                credits.oneTimeExpiresAt = Date(timeIntervalSince1970: expiry > 1e11 ? expiry / 1000 : expiry)
            }
        }

        if snapshot.fiveHour == nil, snapshot.sevenDay == nil, scoped.isEmpty {
            throw APIError.malformed("no recognisable rate limit windows")
        }
        return (snapshot, credits)
    }

    // MARK: - Console usage (documented Admin API)

    /// Anthropic Console spend. Requires an Admin API key and only covers
    /// Console (API-billed) organisations — it says nothing about Pro/Max
    /// subscription limits, and the UI must not imply otherwise.
    func fetchConsole(adminKey: String) async throws -> ConsoleUsage {
        guard canFetch else { throw APIError.rateLimited(retryAfter: nextAllowedFetch.timeIntervalSinceNow) }

        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
        components.queryItems = [
            .init(name: "starting_at", value: formatter.string(from: startOfMonth)),
            .init(name: "ending_at", value: formatter.string(from: now)),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "limit", value: "31"),
            // Without this the buckets come back aggregated with no `model`
            // key, so `byModel` stayed empty and the per-model breakdown the
            // UI advertises rendered nothing at all.
            .init(name: "group_by[]", value: "model"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(adminKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        try check(response, data: data)

        consecutiveFailures = 0
        scheduleNext()
        return try parseConsole(data)
    }

    private func parseConsole(_ data: Data) throws -> ConsoleUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["data"] as? [[String: Any]] else {
            throw APIError.malformed("no data array in cost report")
        }
        let iso = ISO8601DateFormatter()
        var usage = ConsoleUsage()

        for bucket in buckets {
            let stamp = (bucket["starting_at"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            var dayTotal = 0.0
            for result in (bucket["results"] as? [[String: Any]]) ?? [] {
                // `amount` arrives as either a number or a decimal string.
                let amount: Double
                if let value = result["amount"] as? Double { amount = value }
                else if let text = result["amount"] as? String { amount = Double(text) ?? 0 }
                else { continue }
                dayTotal += amount
                if let model = result["model"] as? String {
                    usage.byModel[model, default: 0] += amount
                }
            }
            usage.days.append(.init(date: stamp, costUSD: dayTotal))
            usage.monthToDateUSD += dayTotal
        }
        usage.days.sort { $0.date < $1.date }
        return usage
    }

    // MARK: - Transport

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.malformed("non-HTTP response")
            }
            return (data, http)
        } catch let error as APIError {
            throw error
        } catch {
            consecutiveFailures += 1
            scheduleNext()
            throw error
        }
    }

    private func check(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401, 403:
            consecutiveFailures += 1
            scheduleNext(after: 900)
            throw APIError.unauthorized
        case 429:
            consecutiveFailures += 1
            let header = response.value(forHTTPHeaderField: "Retry-After")
            let retryAfter = header.flatMap(Double.init) ?? 300
            scheduleNext(after: max(retryAfter, minimumInterval))
            throw APIError.rateLimited(retryAfter: retryAfter)
        default:
            consecutiveFailures += 1
            scheduleNext()
            throw APIError.http(status: response.statusCode,
                                body: String(decoding: data, as: UTF8.self))
        }
    }
}
