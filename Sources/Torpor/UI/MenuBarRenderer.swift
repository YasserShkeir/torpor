import AppKit

// MARK: - Appearance options

/// Menu bar presentations.
///
/// No app logo. A menu bar is scarce horizontal space and a brand mark buys the
/// user nothing there — every style shows the number or the gauge and nothing
/// else. The logo lives in the popover, the Settings window and the Dock.
enum MenuBarStyle: String, Codable, CaseIterable, Identifiable {
    case percentage, bar
    var id: String { rawValue }

    var label: String {
        switch self {
        case .percentage: return "Percentage"
        case .bar:        return "Progress bar"
        }
    }
}

enum ColorMode: String, Codable, CaseIterable, Identifiable {
    /// Green below 60%, amber to 85%, red above — matches the menu bar's own
    /// conventions for "you should look at this".
    case adaptive
    /// Pure template rendering: follows the menu bar's tint, never draws colour.
    /// The right default for anyone who keeps a tidy menu bar.
    case monochrome
    /// Single accent colour regardless of level.
    case accent
    var id: String { rawValue }

    var label: String {
        switch self {
        case .adaptive: return "Adaptive"
        case .monochrome: return "Monochrome"
        case .accent: return "Accent"
        }
    }
}

/// Which quota window the bar measures.
///
/// A window and nothing else. This picker used to also offer memory, one
/// model's weekly limit and "whichever is highest", which meant the same 34pt
/// gauge in the same three colours could be a share of your installed RAM or a
/// share of a rate limit, with nothing on screen saying which — and a bar for
/// memory answers a question nobody asks. The status item is now always one
/// window's bar with one memory figure beside it; this chooses the window, and
/// `MemoryFigure` chooses the figure.
enum MenuBarMetric: String, Codable, CaseIterable, Identifiable {
    case fiveHour, sevenDay
    var id: String { rawValue }

    /// Anything unrecognised is the 5-hour window.
    ///
    /// `memory`, `highest` and `model` were real choices in shipped builds, so
    /// those three strings are sitting in the preferences file of everyone who
    /// picked one. `Preferences.load` would recover from the decode failure by
    /// restoring the key to its default and retrying, but only as a side effect
    /// of its corrupt-file machinery — and losing a setting to a rename is a
    /// migration we owe the user, not a corrupt file.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MenuBarMetric(rawValue: raw) ?? .fiveHour
    }

    var label: String {
        switch self {
        // "Session" elsewhere in Torpor means a Claude Code process, so the
        // rate-limit window is never called one here.
        case .fiveHour: return "5-hour limit"
        case .sevenDay: return "Weekly limit (all models)"
        }
    }

    /// What the gauge is a proportion *of*. A bar with no label is only
    /// meaningful if the user has been told what fills it — a memory figure
    /// beside a half-full bar otherwise invites the reasonable question "half
    /// of what?", which is exactly the confusion this redesign removes.
    var gaugeMeaning: String {
        switch self {
        case .fiveHour:
            return "The bar is your rolling 5-hour limit: how much of this window you have used."
        case .sevenDay:
            return "The bar is your weekly limit across all models: how much of this week you have used."
        }
    }

    /// What the notch across the bar means, for the tooltip. The same sentence
    /// for both cases now — every window this enum offers has a clock to pace
    /// against, which is the whole reason `hasResetWindow` is gone.
    var markerMeaning: String {
        "The notch is the clock. Fill short of it means you are inside the pace this window can carry; past it means you are ahead of the clock."
    }
}

/// Which memory figure sits to the right of the bar.
///
/// Two numbers, one slot, and the colour says which one you are looking at
/// rather than how alarmed to be: green is "here is the total", orange is
/// "this much is reclaimable" — the same orange the popover's Reclaim button
/// already uses. Both are always drawn the same way, so switching between them
/// changes the number and its colour and nothing about the layout.
enum MemoryFigure: String, Codable, CaseIterable, Identifiable {
    /// Everything every Claude Code session is holding.
    case total
    /// Only what hibernating the idle sessions would give back.
    case reclaimable
    var id: String { rawValue }

    var label: String {
        switch self {
        case .total:       return "Memory used by all sessions"
        case .reclaimable: return "Memory you could reclaim"
        }
    }

    /// What the trailing figure is, for the tooltip and the Settings caption.
    ///
    /// Deliberately says nothing about colour or about which side of the item
    /// it lands on: Monochrome draws no colour, and the Percentage style draws
    /// no bar to be beside.
    var meaning: String {
        switch self {
        case .total:
            return "The memory figure is everything your Claude Code sessions are holding right now, compressed pages included."
        case .reclaimable:
            return "The memory figure is what hibernating the sessions idle past your threshold would give back."
        }
    }

    /// How that figure is drawn, which depends on the colour mode.
    func colourNote(_ mode: ColorMode) -> String {
        guard mode != .monochrome else {
            return "Monochrome draws it in the menu bar's own tint, like everything else — the figure is still whichever one you picked."
        }
        switch self {
        case .total:
            return "Drawn green, because it is a total rather than a warning."
        case .reclaimable:
            return "Drawn orange — the same orange as the Reclaim button in the panel."
        }
    }
}

/// A percentage on its own does not tell you whether to slow down; the reset
/// time does. Offered three ways because which one is useful depends on whether
/// you think in "how long have I got" or "when does it come back".
enum TimeMarker: String, Codable, CaseIterable, Identifiable {
    case none, remaining, resetClock, both
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:       return "Off"
        case .remaining:  return "Time remaining"
        case .resetClock: return "Reset time"
        case .both:       return "Both"
        }
    }
}

// MARK: - Renderer

/// Draws the status item.
///
/// Everything here is drawn rather than composed from SF Symbols, because the
/// gauge styles need a fill proportional to a value and the menu bar has a hard
/// 22pt height budget that symbol scaling does not respect predictably.
enum MenuBarRenderer {

    struct Input {
        var style: MenuBarStyle
        var colorMode: ColorMode
        var marker: TimeMarker
        /// 0…1, or nil when there is no value to show (no quota yet).
        var fraction: Double?
        /// The exact level, e.g. "87%". Drawn only by the Percentage style —
        /// the bar carries the level already, so repeating it as a number
        /// beside the memory figure would put two numbers where one belongs.
        /// Still read for the tooltip, which is where `.bar` users recover it.
        var percentText: String?
        /// The trailing memory figure, already formatted. Nil when there is
        /// nothing to report.
        var memoryText: String?
        /// Colour for that figure. Nil means "no colour of its own": the status
        /// item leaves it to the menu bar's tint, which is what Monochrome
        /// wants. Never derived from a threshold — see `memoryTint`.
        var memoryColor: NSColor?
        var resetsAt: Date?
        var sessionCount: Int
        var isStale: Bool
        /// 0…1 through the window that `fraction` measures, or nil when that
        /// window is unknown or the metric has none. Never another window's
        /// clock — see showsTimeMarker.
        var windowElapsed: Double?
        /// The appearance to resolve colours in. The menu bar has its own — it
        /// is dark over a dark wallpaper even in Light Mode — and a dynamic
        /// NSColor bakes in whichever appearance is current when the drawing
        /// handler runs, which is the app's. Nil means "whatever is current",
        /// which is what a preview drawn inside a window wants.
        var appearance: NSAppearance?

        /// A window whose reset time has passed describes a window that no
        /// longer exists: the snapshot's own timestamp can still look fresh
        /// while the numbers in it are last window's.
        var isExpired: Bool { resetsAt.map { $0 <= Date() } ?? false }

        /// Anything we cannot vouch for is drawn dimmed rather than
        /// recoloured — the level is still the last known level.
        var isUnverified: Bool { isStale || isExpired }

        /// Whether the clock notch belongs on this gauge at all. It does not
        /// when there is no reading to pace against, and `windowElapsed` is
        /// nil whenever the elapsed fraction is not the elapsed fraction of
        /// *this* bar's own window.
        var showsTimeMarker: Bool {
            style == .bar && fraction != nil && windowElapsed != nil
        }
    }

    static let height: CGFloat = 18

    /// The one font the trailing text is drawn in, wherever it is drawn.
    ///
    /// Monospaced digits so a ticking countdown and a changing memory figure do
    /// not shuffle the item's width on every update. Computed rather than a
    /// stored static because `NSFont` is not Sendable.
    static var titleFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }

    /// Colour for a fill level, honouring the chosen mode.
    static func tint(for fraction: Double?, mode: ColorMode) -> NSColor {
        switch mode {
        case .monochrome:
            return .labelColor
        case .accent:
            return .controlAccentColor
        case .adaptive:
            guard let fraction else { return .labelColor }
            switch fraction {
            case ..<0.60: return .systemGreen
            case ..<0.85: return .systemOrange
            default:      return .systemRed
            }
        }
    }

    /// Colour for the trailing memory figure.
    ///
    /// Tied to *which figure it is*, never to a threshold: green means "here is
    /// the total", orange means "this much is reclaimable", which is the same
    /// orange the popover already uses for reclaimable memory. Nil under
    /// Monochrome, whose entire purpose is a menu bar with no colour in it —
    /// callers draw the run in the menu bar's own tint instead.
    static func memoryTint(for figure: MemoryFigure, mode: ColorMode) -> NSColor? {
        guard mode != .monochrome else { return nil }
        switch figure {
        case .total:       return .systemGreen
        case .reclaimable: return .systemOrange
        }
    }

    /// The trailing text, run by run, in draw order.
    ///
    /// Runs rather than one string because two unrelated quantities now sit
    /// side by side: the level takes the gauge's tint, the memory figure takes
    /// green or orange by which figure it is. One `foregroundColor` for the
    /// whole title could only ever be right about one of them — which is how
    /// the layout this replaced came to draw a memory bar in quota colours.
    ///
    /// A nil colour means "no colour of your own". `NSStatusBarButton` tints
    /// its own title and inverts it while the item is highlighted, and an
    /// explicit `labelColor` defeats both, so Monochrome asks for none;
    /// `composite` has no button to defer to and substitutes `labelColor`.
    static func titleRuns(_ input: Input) -> [(text: String, color: NSColor?)] {
        let level: NSColor? = (input.colorMode == .monochrome && !input.isUnverified)
            ? nil : titleColor(input)

        var runs: [(text: String, color: NSColor?)] = []
        // Only the style that draws no gauge shows the number. In `.bar` the
        // exact percentage lives in the tooltip instead.
        if input.style == .percentage, let percent = input.percentText {
            runs.append((percent, level))
        }
        if let memory = input.memoryText {
            // Deliberately not dimmed alongside a stale quota. This figure is
            // measured on this Mac on this tick; it is fresh however old the
            // usage snapshot beside it happens to be.
            //
            // Monochrome is enforced here rather than trusted from the caller.
            // `memoryTint` already returns nil for it, but a hand-built Input
            // that hard-codes a colour must not be able to put green in a menu
            // bar the user asked to keep colourless.
            runs.append((memory, input.colorMode == .monochrome ? nil : input.memoryColor))
        }
        if let countdown = countdown(input) {
            runs.append((countdown, level))
        }
        return runs
    }

    /// The trailing text with no colour information, for accessibility and for
    /// callers that only need to know whether there is anything to draw.
    static func title(_ input: Input) -> String {
        let joined = titleRuns(input).map(\.text).joined(separator: " ")
        return joined.isEmpty ? "" : " \(joined)"
    }

    /// The trailing text as the status item should set it.
    static func attributedTitle(_ input: Input) -> NSAttributedString {
        assemble(titleRuns(input), substituting: nil)
    }

    /// One attributed string from the runs. `substituting` is the colour a run
    /// that asked for none is given — nil to leave it unset.
    private static func assemble(_ runs: [(text: String, color: NSColor?)],
                                 substituting fallback: NSColor?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: titleFont]
            if let colour = run.color ?? fallback { attributes[.foregroundColor] = colour }
            // Each run carries its own leading space, so the first one gives
            // the whole title the gap it needs from the gauge.
            out.append(NSAttributedString(string: " \(run.text)", attributes: attributes))
        }
        return out
    }

    /// The countdown run, or nil when there is no window or none was asked for.
    private static func countdown(_ input: Input) -> String? {
        guard let resets = input.resetsAt, input.marker != .none else { return nil }
        let remaining = resets.timeIntervalSinceNow
        switch input.marker {
        case .remaining:
            return remaining > 0 ? Fmt.duration(remaining) : nil
        case .resetClock:
            return clock(resets)
        case .both:
            return remaining > 0 ? "\(Fmt.duration(remaining)) · \(clock(resets))" : clock(resets)
        case .none:
            return nil
        }
    }

    /// A reset timestamp, with a day attached whenever it is not today.
    ///
    /// The weekly window resets up to seven days out, and rendering that as a
    /// bare "07:00" is unreadable — it names an hour without saying which of
    /// seven mornings. Time alone is only unambiguous within today.
    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        let calendar = Calendar.autoupdatingCurrent

        if calendar.isDateInToday(date) {
            formatter.setLocalizedDateFormatFromTemplate("j:mm")
        } else if let week = calendar.date(byAdding: .day, value: 7, to: Date()), date < week {
            // Within the coming week a weekday name is enough and stays short.
            formatter.setLocalizedDateFormatFromTemplate("EEE j:mm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("d MMM j:mm")
        }
        return formatter.string(from: date)
    }

    /// The status item image for the chosen style. Nil where the style is
    /// text-only, so the caller can omit the image rather than pad with a blank.
    static func image(_ input: Input) -> NSImage? {
        switch input.style {
        case .percentage: return nil
        case .bar:        return gauge(input, width: 34)
        }
    }

    /// Colour for the trailing text, so the number carries the same signal as
    /// the gauge. Without this the "Percentage" style — which draws no gauge at
    /// all — had no colour anywhere and 95% looked exactly like 5%.
    static func titleColor(_ input: Input) -> NSColor {
        let base = tint(for: input.fraction, mode: input.colorMode)
        // A stale reading is dimmed rather than recoloured: the level is still
        // the last known level, we just cannot vouch for it — and a window
        // whose reset time has passed cannot be vouched for either, however
        // recent the snapshot.
        return input.isUnverified ? base.withAlphaComponent(0.55) : base
    }

    /// The status item's gauge and coloured text composited into one image,
    /// drawn by the same code the status item uses.
    ///
    /// Close, not identical. NSStatusBarButton lays out image and title with
    /// its own metrics and tints template content itself, so the 2pt inset,
    /// the 6pt gap and the exact Monochrome tone here are this function's
    /// approximation of them — nothing outside AppKit can read the real ones.
    /// Good enough to choose a style and a colour by; not a pixel reference,
    /// and callers must not claim it is one.
    ///
    /// The Appearance preview used to show only the gauge, with the text next
    /// to it as a separate uncoloured SwiftUI `Text`. That meant text-only
    /// styles previewed as nothing at all, and no preview ever showed the
    /// colour it was previewing.
    static func composite(_ input: Input, background: NSColor = .clear) -> NSImage {
        let gaugeImage = image(input)
        // Every run gets a colour here: there is no status item button to hand
        // an uncoloured run to, and drawing one with no foregroundColor at all
        // would land it in whatever the graphics context happened to be set to.
        let text = assemble(titleRuns(input), substituting: .labelColor)
        let textSize = text.length == 0 ? .zero : text.size()
        let width = max((gaugeImage?.size.width ?? 0) + textSize.width + 6, 24)
        let size = NSSize(width: width, height: height + 4)

        return NSImage(size: size, flipped: false) { rect in
            // Same reason as gauge(): dynamic colours resolve when this handler
            // runs, against whichever appearance is current then.
            (input.appearance ?? NSAppearance.currentDrawing())
                .performAsCurrentDrawingAppearance {
                if background != .clear {
                    background.setFill()
                    rect.fill()
                }
                var x: CGFloat = 2
                if let gaugeImage {
                    // Template images carry only alpha, so tint them the way the
                    // menu bar would rather than drawing them as transparent holes.
                    if gaugeImage.isTemplate {
                        let tinted = NSImage(size: gaugeImage.size, flipped: false) { inner in
                            gaugeImage.draw(in: inner)
                            NSColor.labelColor.set()
                            inner.fill(using: .sourceAtop)
                            return true
                        }
                        tinted.draw(at: NSPoint(x: x, y: 2), from: .zero,
                                    operation: .sourceOver, fraction: 1)
                    } else {
                        gaugeImage.draw(at: NSPoint(x: x, y: 2), from: .zero,
                                        operation: .sourceOver, fraction: 1)
                    }
                    x += gaugeImage.size.width
                }
                if text.length > 0 {
                    text.draw(at: NSPoint(x: x, y: 2 + (height - textSize.height) / 2))
                }
            }
            return true
        }
    }

    // MARK: - Drawing

    /// One bar, with a notch showing how far through the window you are.
    ///
    /// This replaced a two-bar layout, which was itself a replacement for a
    /// transparent notch. That first notch failed because it was cut only
    /// *inside* the bar, where an empty track and a hole look the same; the
    /// pips above and below are what fixes it. See drawTimeMarker for why the
    /// mark is a hole rather than a white line.
    private static func gauge(_ input: Input, width: CGFloat) -> NSImage {
        let size = NSSize(width: width, height: height)

        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // A dynamic NSColor resolves when this handler runs, against the
            // app's appearance rather than the menu bar's — which is dark over
            // a dark wallpaper even in Light Mode.
            (input.appearance ?? NSAppearance.currentDrawing())
                .performAsCurrentDrawingAppearance {
                let fillColor = tint(for: input.fraction, mode: input.colorMode)
                // A reading we cannot vouch for is dimmed, notch included: at
                // full strength the notch keeps advancing against a frozen
                // fill, and the widening gap reads as "you are burning fast"
                // when nothing has been measured since.
                let strength: CGFloat = input.isUnverified ? 0.45 : 1

                let track = CGRect(x: 2, y: rect.midY - 3.5, width: width - 4, height: 7)
                drawBar(context: context, track: track,
                        fraction: input.fraction,
                        // Track derived from the fill rather than labelColor so
                        // the two always agree, whatever the mode.
                        trackColor: fillColor.withAlphaComponent(0.22),
                        fillColor: fillColor.withAlphaComponent(strength),
                        radius: 3.5)

                if input.fraction == nil {
                    // An empty track is also exactly what 0% looks like. The
                    // dash says "nothing measured yet", in the same vocabulary
                    // as the Percentage style's "—".
                    context.setFillColor(fillColor.withAlphaComponent(0.55).cgColor)
                    context.fill(CGRect(x: track.midX - 3, y: track.midY - 0.75,
                                        width: 6, height: 1.5))
                } else if input.showsTimeMarker, let elapsed = input.windowElapsed {
                    drawTimeMarker(context: context, track: track, elapsed: elapsed,
                                   color: fillColor, strength: strength)
                }
            }
            return true
        }
        // Adaptive and accent draw real colour, so they must not be
        // template-rendered or the menu bar flattens them to one tone.
        image.isTemplate = (input.colorMode == .monochrome)
        return image
    }

    /// A gap punched through the bar at the elapsed-time position, with a pip
    /// standing proud above and below it.
    ///
    /// Alpha rather than colour, because Monochrome is template-rendered and a
    /// template image keeps only alpha: a white line over a full-alpha fill is
    /// the same pixel as the fill, so the mark disappeared exactly where it
    /// matters — once usage had overtaken the clock. A hole differs from the
    /// fill under any tint; the pips carry the position where the bar is empty
    /// and a hole would read as nothing.
    private static func drawTimeMarker(context: CGContext, track: CGRect,
                                       elapsed: Double, color: NSColor, strength: CGFloat) {
        let gapWidth: CGFloat = 2
        let overhang: CGFloat = 2.5
        // Keep the whole gap on the track: half of it hanging past a rounded
        // cap reads as a chipped bar rather than as a mark.
        let margin = Double((gapWidth / 2 + 1) / max(track.width, 1))
        let position = min(max(elapsed, margin), 1 - margin)
        let x = track.minX + track.width * CGFloat(position) - gapWidth / 2

        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.setFillColor(gray: 0, alpha: strength)
        context.fill(CGRect(x: x, y: track.minY, width: gapWidth, height: track.height))
        context.restoreGState()

        context.setFillColor(color.withAlphaComponent(strength).cgColor)
        context.fill(CGRect(x: x, y: track.maxY, width: gapWidth, height: overhang))
        context.fill(CGRect(x: x, y: track.minY - overhang, width: gapWidth, height: overhang))
    }


    /// Rounded track with a clipped proportional fill.
    private static func drawBar(context: CGContext, track: CGRect, fraction: Double?,
                                trackColor: NSColor, fillColor: NSColor, radius: CGFloat) {
        let shape = CGPath(roundedRect: track, cornerWidth: radius,
                           cornerHeight: radius, transform: nil)
        context.addPath(shape)
        context.setFillColor(trackColor.cgColor)
        context.fillPath()

        guard let fraction, fraction > 0 else { return }
        // Clip and fill a plain rect so the fill inherits the track's rounded
        // left cap instead of becoming a circle at low values.
        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.setFillColor(fillColor.cgColor)
        context.fill(CGRect(x: track.minX, y: track.minY,
                            width: max(2, track.width * min(max(fraction, 0), 1)),
                            height: track.height))
        context.restoreGState()
    }
}
