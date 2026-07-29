import AppKit
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

    /// Whether Sparkle checks on a schedule. Seeded from Sparkle, which honours
    /// `SUEnableAutomaticChecks` only on first launch and remembers the user's
    /// choice after that — so this must never write on the way in.
    @Published var automaticallyChecks = true {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    private var controller: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()

    /// Nil when running unbundled — `swift run` has no Info.plist, so Sparkle
    /// has no feed URL and no public key and must not be started.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            // Without the public key Sparkle downloads and extracts an update
            // and only then rejects it, so the whole cost is paid before the
            // failure is visible.
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
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

    init(starting: Bool = true) {
        super.init()
        guard Self.isAvailable else {
            canCheck = false
            lastCheckDescription = "Updates are only available in a built app bundle."
            return
        }
        // Starting Sparkle reaches the network and can put a window on screen,
        // which the side-effect-free CLI paths must not do.
        guard starting else { canCheck = false; return }
        // startingUpdater: true schedules the background check itself, honouring
        // SUScheduledCheckInterval from Info.plist.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: self)
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
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.automaticallyChecks = value }
            .store(in: &cancellables)
    }

    /// Explicit "Check for Updates…". Sparkle owns the whole UI from here —
    /// found/not-found, release notes, download progress, and the relaunch.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}

/// Torpor is `LSUIElement`: no Dock icon to bounce, and a scheduled update
/// window opens behind whatever the user is working in unless the app is
/// activated first. `@preconcurrency` because Sparkle's protocol is a plain
/// Objective-C one and this type is main-actor isolated.
extension Updater: @preconcurrency SPUStandardUserDriverDelegate {

    /// Sparkle only consults the two methods below when this is true.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle keeps showing the update. Returning false makes *this* delegate
    /// responsible for surfacing it, and there is no in-app badge to surface it
    /// with — scheduled updates would simply never be seen.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    /// A user-initiated check already has the app active; a scheduled one does
    /// not, and its window would open behind the user's work.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}
