import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService`.
///
/// Only meaningful for a bundled, signed app — `SMAppService` has nothing to
/// register when the executable is run loose from `.build`, so the toggle
/// reports its real state rather than silently lying.
enum LoginItem {

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns the state actually achieved, which may differ from what was
    /// asked for if the user has denied it in System Settings.
    @discardableResult
    static func set(_ enabled: Bool) throws -> Bool {
        guard isAvailable else { return false }
        if enabled {
            try SMAppService.mainApp.register()
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
        return SMAppService.mainApp.status == .enabled
    }
}
