import AppKit

/// Entry point.
///
/// Torpor runs as a menu bar accessory: no dock icon, no main window.
/// `LSUIElement` in Info.plist covers the bundled case; setting the activation
/// policy here keeps the behaviour correct when run unbundled during development.
@main
enum TorporApp {
    @MainActor
    static func main() {
        // Handle the scriptable surface before touching AppKit, so `--list`
        // and friends work over SSH and in scripts without a window server.
        if CLI.run(CommandLine.arguments) { return }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
