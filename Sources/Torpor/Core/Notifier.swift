import Foundation
import UserNotifications

/// User-facing alerts.
///
/// `UNUserNotificationCenter` only works from a properly bundled, signed app.
/// When Torpor is run unbundled (say, straight out of `swift run` during
/// development) it silently fails, so we fall back to AppleScript's
/// `display notification`, which has no such requirement.
final class Notifier {

    private var authorized = false
    private var lastFired: [String: Date] = [:]
    /// Never nag about the same thing more than once an hour.
    private let cooldown: TimeInterval = 3600

    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                DispatchQueue.main.async { self?.authorized = granted }
            }
    }

    /// Post a notification, de-duplicated by `key`.
    func post(key: String, title: String, body: String) {
        if let last = lastFired[key], Date().timeIntervalSince(last) < cooldown { return }
        lastFired[key] = Date()

        if authorized, Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        } else {
            fallback(title: title, body: body)
        }
    }

    /// Reset the cooldown for a key, so a condition that clears and returns
    /// notifies again rather than being suppressed for the rest of the hour.
    func clear(key: String) {
        lastFired.removeValue(forKey: key)
    }

    private func fallback(title: String, body: String) {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = "display notification \"\(escape(body))\" with title \"\(escape(title))\""
        DispatchQueue.global(qos: .utility).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }
}
