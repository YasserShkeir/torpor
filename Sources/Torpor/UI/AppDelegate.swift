import AppKit
import Combine
import SwiftUI

// AppKit delivers every delegate callback on the main thread, and Engine is
// main-actor isolated, so the whole controller lives on the main actor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private let engine = Engine()
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?
    private var clockTimer: Timer?
    /// Set when the user re-launches Torpor while the item is auto-hidden, so
    /// they always have a way back to Settings with no sessions running.
    private var revealedWhileIdle = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        redrawStatusItem()

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(engine: engine, openSettings: { [weak self] in
                self?.showSettings()
            })
        )

        engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the mutation lands, so defer a
                // tick to read the settled values.
                DispatchQueue.main.async { self?.redrawStatusItem() }
            }
            .store(in: &cancellables)

        // Countdown markers tick independently of the session poll, so the
        // "resets in 42m" text stays honest without polling processes faster.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.redrawStatusItem() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
        clockTimer?.invalidate()
    }

    /// Opening Torpor again while it is already running is the escape hatch
    /// from auto-hide: reveal the item and show the popover, rather than doing
    /// nothing and looking broken.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        revealedWhileIdle = true
        redrawStatusItem()
        if !popover.isShown { togglePopover() }
        return true
    }

    // MARK: - Status item

    private func redrawStatusItem() {
        guard let button = statusItem.button else { return }
        var input = engine.menuBarInput
        // Resolve colours in the menu bar's appearance rather than the app's:
        // dynamic NSColors bake in whatever is current when the image draws,
        // and the menu bar is dark over a dark wallpaper even in Light Mode.
        input.appearance = button.effectiveAppearance

        // With nothing running there is nothing worth a slot in the menu bar,
        // so the item disappears entirely. Re-launching Torpor (or opening it
        // from Spotlight) reveals it again — see applicationShouldHandleReopen.
        // Auto-hide is suppressed when the registry looks broken: "no sessions"
        // and "we could not parse any session" look identical from here, and
        // vanishing on an upstream format change is the worst possible failure.
        let idle = engine.sessions.isEmpty
        let mayHide = engine.preferences.hideWhenIdle && !engine.registryLooksBroken
        statusItem.isVisible = !mayHide || !idle || revealedWhileIdle
        if !idle { revealedWhileIdle = false }

        // The first column — bar (or level) above the time remaining — is the
        // image; the memory figure is the title, which the button centres
        // against the whole image. That is the two-column layout: nothing else
        // is needed, because a status item button lays out exactly one image
        // and one title. Both styles now draw an image, so there is no longer a
        // case where the item can come out zero-width: the Percentage style
        // draws "—" rather than nothing when there is no reading.
        button.image = MenuBarRenderer.image(input)
        button.imagePosition = .imageLeading
        // The run carries its own colour, because the memory figure is a
        // different quantity from the level and says so in green or orange.
        // Monochrome deliberately sets none: NSStatusBarButton tints its own
        // title and inverts it while the item is highlighted, and an explicit
        // labelColor defeated both, leaving the number dark on the highlighted
        // background with the popover open. The colour modes pay that price
        // knowingly — the colour is the whole point of them.
        button.attributedTitle = MenuBarRenderer.attributedTitle(input)

        // Data, not prose. Every line here is a number the item cannot show at
        // 22pt; what the bar and the white line *mean* is explained once, in
        // Settings, rather than on every hover.
        let count = engine.sessions.count
        var lines = [count == 0
            ? "No Claude Code sessions"
            : "\(count) session\(count == 1 ? "" : "s") · \(Fmt.bytes(engine.totalFootprint))"]
        // The exact level. The bar carries it as a fill and nothing else does
        // now that the trailing text is the memory figure, so without this line
        // a `.bar` user cannot read their percentage without opening the panel.
        if let percent = input.percentText {
            var line = "\(engine.preferences.menuBarMetric.label): \(percent) used"
            if let remaining = MenuBarRenderer.durationText(input) { line += " · \(remaining) left" }
            lines.append(line)
        }
        if let quota = engine.quota {
            // Whichever window the bar is *not* drawing, so one hover still
            // recovers both.
            switch engine.preferences.menuBarMetric {
            case .fiveHour:
                if let week = quota.sevenDay {
                    lines.append("Weekly limit: \(Int(week.usedPercentage))% used")
                }
            case .sevenDay:
                if let five = quota.fiveHour {
                    lines.append("5-hour limit: \(Int(five.usedPercentage))% used")
                }
            }
            // A dimmed bar has to say why, or it just looks like a rendering
            // bug: nothing has measured this since the timestamp shown.
            if input.isUnverified {
                lines.append("Last read \(Fmt.duration(quota.age)) ago — dimmed until a session refreshes it")
            }
        }
        // Only when it is not the total already on the first line.
        if let memory = input.memoryText, engine.preferences.memoryFigure == .reclaimable {
            lines.append("\(MemoryFigure.reclaimable.label): \(memory)")
        }
        let tooltip = lines.joined(separator: "\n")
        button.toolTip = tooltip

        button.setAccessibilityLabel("Torpor")
        button.setAccessibilityValue(tooltip.replacingOccurrences(of: "\n", with: ", "))
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Torpor is an .accessory app, so clicking the status item while
            // Terminal or VS Code is frontmost shows the popover without making
            // Torpor the *active* application. `makeKey()` alone does not fix
            // that: the first left-mouse-down inside an inactive app's window is
            // consumed activating it, and SwiftUI's Button does not override
            // `acceptsFirstMouse`. So every control in this panel silently ate
            // the user's first click, and Hibernate — which is deliberately two
            // clicks — read as needing three. Settings and the update prompt
            // already activate; this path was the one that didn't.
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            watchForOutsideClicks()
            // Present first, then refresh. Refreshing before showing meant the
            // popover could not appear until a full pass over the session
            // registry and every live process had finished.
            engine.refresh()
        }
    }

    private func watchForOutsideClicks() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        // NSPopover keeps its content view controller alive for the app's
        // lifetime, so SwiftUI @State survives closing. Without this, an armed
        // "Hibernate 4" confirmation is still armed hours later — one stray click
        // from ending four sessions, on a row that may have re-sorted under the
        // cursor in the meantime.
        engine.disarmConfirmations()
    }

    /// AppKit routes Cut/Copy/Paste through the Edit menu's key equivalents.
    /// With no main menu they never reach the first responder — and the Account
    /// tab's whole interaction is pasting a 200-character token into a
    /// SecureField, where right-click paste is commonly suppressed.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Torpor", action: #selector(showSettingsFromMenu), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let support = NSMenuItem(title: "Support Torpor", action: #selector(openSponsorPage), keyEquivalent: "")
        support.target = self
        appMenu.addItem(support)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Torpor",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    @objc private func showSettingsFromMenu() { showSettings() }

    @objc private func openSponsorPage() { NSWorkspace.shared.open(Links.sponsor) }

    // MARK: - Settings

    func showSettings() {
        popover.performClose(nil)
        engine.reconcileLoginItem()

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Torpor Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: SettingsView(engine: engine))
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
