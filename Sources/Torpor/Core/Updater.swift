import Combine
import Foundation
import Sparkle

/// In-app updates, via Sparkle 2.
///
/// This started as a hand-rolled poll of the GitHub Releases API that told the
/// user to go and download a zip. Two things were wrong with it.
///
/// First, every downloaded zip arrives carrying `com.apple.quarantine`, and
/// Torpor is ad-hoc signed, so Gatekeeper blocks it. With a link-based updater
/// the user repeats the override on *every release*. Sparkle's installer strips
/// quarantine from the replacement bundle, which makes that a one-time cost at
/// first install instead of a recurring tax.
///
/// Second, that code claimed conditional requests were free against GitHub's
/// 60/hour unauthenticated limit. They are not — a 304 decrements the budget
/// like any other response, and the budget is shared by IP, so an office behind
/// one NAT shares 60 checks an hour between everyone. The appcast is a static
/// file and has no rate limit at all.
///
/// **Trust.** Sparkle installs an update only if the archive carries an EdDSA
/// signature made by the private key matching `SUPublicEDKey` in Info.plist.
/// That check involves no Apple certificate and no Developer ID — `SUUpdateValidator`
/// accepts a valid archive signature on its own, which is why ad-hoc signing is
/// sufficient here and why this is *stronger* than what Gatekeeper currently
/// gives a downloaded Torpor build, which is nothing. The private key exists
/// only as a GitHub Actions secret.
///
/// **What this does not fix while Torpor is ad-hoc signed.** Every ad-hoc build
/// has a different code-signing identity, and macOS binds Automation and
/// Keychain grants to that identity. So the user is re-asked for Terminal
/// automation and Keychain access after each update. Only a Developer ID
/// certificate fixes that; it is the main reason to eventually buy one.
@MainActor
final class Updater: NSObject, ObservableObject {

    /// How this copy was installed. Advisory only — Sparkle and Homebrew do not
    /// fight, since Homebrew compares the installed bundle's version against the
    /// cask before doing anything.
    enum InstallKind {
        case homebrew, applications, elsewhere

        var note: String {
            switch self {
            case .homebrew:
                return "Installed with Homebrew. In-app updates work; `brew upgrade --cask torpor` also works."
            case .applications, .elsewhere:
                return "Torpor installs updates itself once you approve them."
            }
        }
    }

    @Published private(set) var canCheck = true
    @Published private(set) var lastCheckDescription: String?

    private var controller: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()

    /// Nil when running unbundled — `swift run` has no Info.plist, so Sparkle
    /// has no feed URL and no public key and must not be started.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    static var installKind: InstallKind {
        let caskrooms = ["/opt/homebrew/Caskroom/torpor", "/usr/local/Caskroom/torpor"]
        if caskrooms.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            return .homebrew
        }
        return Bundle.main.bundlePath.hasPrefix("/Applications") ? .applications : .elsewhere
    }

    override init() {
        super.init()
        guard Self.isAvailable else {
            canCheck = false
            lastCheckDescription = "Updates are only available in a built app bundle."
            return
        }
        // startingUpdater: true schedules the background check itself, honouring
        // SUScheduledCheckInterval from Info.plist.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        observe()
    }

    private func observe() {
        guard let updater = controller?.updater else { return }
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheck = value }
            .store(in: &cancellables)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .sink { [weak self] date in
                guard let date else { return }
                self?.lastCheckDescription =
                    "Last checked \(Fmt.duration(Date().timeIntervalSince(date))) ago"
            }
            .store(in: &cancellables)
    }

    /// Explicit "Check for Updates…". Sparkle owns the whole UI from here —
    /// found/not-found, release notes, download progress, and the relaunch.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    /// Whether Sparkle checks on a schedule. Mirrors `SUEnableAutomaticChecks`.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
