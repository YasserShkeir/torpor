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

    /// Fetch plan utilisation using a subscription OAuth token.
    ///
    /// This is the path documented in the UI as carrying account risk. It is
    /// never called unless the user has explicitly chosen it.
    func fetchSubscription(token: SubscriptionToken,
                           clientVersion: String) async throws -> (QuotaSnapshot, CreditBalance) {
        guard canFetch else { throw APIError.rateLimited(retryAfter: nextAllowedFetch.timeIntervalSinceNow) }
        guard !token.isExpired else { throw APIError.unauthorized }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(clientVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        try check(response, data: data)

        consecutiveFailures = 0
        scheduleNext()
        return try parseSubscription(data)
    }

    /// Tolerant decoding: the payload is undocumented and its shape has changed
    /// more than once, so anything unrecognised degrades to "absent" rather
    /// than failing the whole refresh.
    private func parseSubscription(_ data: Data) throws -> (QuotaSnapshot, CreditBalance) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.malformed("not a JSON object")
        }

        func window(_ any: Any?) -> QuotaSnapshot.Window? {
            guard let dict = any as? [String: Any] else { return nil }
            let percentKeys = ["utilization", "used_percentage", "usedPercentage", "percent_used"]
            guard let percent = percentKeys.compactMap({ dict[$0] as? Double }).first else { return nil }
            var resets: Date?
            for key in ["resets_at", "resetsAt", "reset_at"] {
                if let seconds = dict[key] as? Double {
                    resets = Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
                    break
                }
                if let text = dict[key] as? String {
                    resets = ISO8601DateFormatter().date(from: text)
                    break
                }
            }
            return .init(usedPercentage: percent, resetsAt: resets)
        }

        var scoped: [String: QuotaSnapshot.Window] = [:]
        // Model-scoped rows arrive either as top-level `seven_day_<model>` keys
        // or as a `limits` array of {name, …} objects.
        for (key, value) in root where key.hasPrefix("seven_day_") {
            let name = String(key.dropFirst("seven_day_".count))
                .replacingOccurrences(of: "_", with: " ").capitalized
            if let w = window(value) { scoped[name] = w }
        }
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let name = (limit["name"] as? String) ?? (limit["model"] as? String),
                      let w = window(limit) else { continue }
                scoped[name.capitalized] = w
            }
        }

        let snapshot = QuotaSnapshot(
            fiveHour: window(root["five_hour"]) ?? window(root["fiveHour"]),
            sevenDay: window(root["seven_day"]) ?? window(root["sevenDay"]),
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
