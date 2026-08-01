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
    /// No colour of its own: everything is drawn in `labelColor`, resolved
    /// against the menu bar's own appearance. The right default for anyone who
    /// keeps a tidy menu bar.
    ///
    /// Drawn rather than template-rendered, which it used to be. A template
    /// image keeps only alpha, and that is irreconcilable with a white clock
    /// line over an opaque fill — see `MenuBarRenderer.image` for what that
    /// costs.
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

    /// What the white line across the bar means. The one thing on the item that
    /// nothing else can explain, so it survives where the other captions did
    /// not — `label` already says what the bar measures.
    static let markerMeaning =
        "White line = the clock. Fill behind it means you're on pace."
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

    /// Names the figure well enough to be the whole explanation. The captions
    /// that used to sit under this picker said the same thing at length.
    var label: String {
        switch self {
        case .total:       return "Memory used by all sessions"
        case .reclaimable: return "Memory you could reclaim"
        }
    }
}

/// Whether the status item carries a second row saying how long is left.
///
/// This used to choose *how* the clock was written: a duration, a wall-clock
/// reset time, or both, appended after the memory figure on the single row the
/// item had. The two-column layout answers that question itself — the second
/// row is a duration, because Claude's own usage screen says "Resets in 1 hr
/// 33 min" and because a bare "9:10 PM" beneath a bar is a timestamp with
/// nothing saying what it is a timestamp *of*. So `resetClock` and `both` no
/// longer name anything the renderer can draw.
///
/// What is left is a real choice: whether that row exists. It costs vertical
/// space, which forces a shorter bar and 9pt text, and a tidy menu bar is worth
/// something. `allCases` is therefore the two the layout can express, and that
/// is what Settings offers.
///
/// The two retired values are still decodable, and still round-trip, because
/// they are sitting in the preferences file of everyone who picked one — they
/// simply render as `remaining` now, and the moment the user touches the
/// setting it normalises. Anything unrecognised lands on `remaining` rather
/// than failing the decode, for the same reason `MenuBarMetric` does it:
/// landing on a sensible case is a migration we owe the user, not a corrupt
/// file for `Preferences.load` to recover from.
enum TimeMarker: String, Codable, CaseIterable, Identifiable {
    case none, remaining
    case resetClock, both
    var id: String { rawValue }

    static var allCases: [TimeMarker] { [.none, .remaining] }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TimeMarker(rawValue: raw) ?? .remaining
    }

    /// Every surviving value except `none` draws the same second row.
    var showsDuration: Bool { self != .none }

    var label: String {
        switch self {
        case .none: return "Off"
        // Named for what is drawn, not for the raw value: a file still saying
        // `resetClock` gets the duration, and says so.
        default:    return "Time remaining"
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

        /// Whether the clock line belongs on this gauge at all. It does not
        /// when there is no reading to pace against, and `windowElapsed` is
        /// nil whenever the elapsed fraction is not the elapsed fraction of
        /// *this* bar's own window.
        var showsTimeMarker: Bool {
            style == .bar && fraction != nil && windowElapsed != nil
        }
    }

    // MARK: - Geometry
    //
    // Measured rather than guessed. `NSStatusBar.system.thickness` is 22, the
    // status item button's bounds are 22pt tall, and its cell's `imageScaling`
    // is `.scaleNone` — so an image is drawn at its natural size and clipped
    // past 22pt rather than shrunk to fit. 20 leaves a point of clearance above
    // and below, which is what two stacked rows need and still sits inside the
    // budget. Everything below is laid out against that 20, top down.

    static let height: CGFloat = 20

    /// Height of a whole composited item — the image plus the 2pt of breathing
    /// room the status item leaves above and below it. Previews frame
    /// themselves against this so they cannot quietly clip what the menu bar
    /// does not.
    static var compositeHeight: CGFloat { height + 4 }

    /// Minimum width of the gauge, and so of the first column in the `.bar`
    /// style.
    ///
    /// Wider than any duration the 5-hour window can produce — "4h 59m" is the
    /// longest at 33.7pt in `durationFont` — so on the default metric this
    /// column is a constant width and only the memory figure moves the item.
    /// The weekly window can spend its last day reading "23h 59m", which is
    /// 39.5pt; the column widens to hold it rather than letting the caption
    /// overhang the bar it belongs to. Sizing for that case permanently would
    /// cost every 5-hour user 8pt of menu bar for a string they never see.
    private static let barWidth: CGFloat = 36
    private static let trackHeight: CGFloat = 6
    /// How far the clock line stands proud of the track, top and bottom. The
    /// overhang is what makes it read as a deliberate mark rather than a chip
    /// out of the bar, and it is what carries the position where the bar is
    /// still empty.
    private static let markerOverhang: CGFloat = 2
    private static let topInset: CGFloat = 0.5
    private static let bottomInset: CGFloat = 1

    /// The one font the memory figure is drawn in.
    ///
    /// Monospaced digits so a changing memory figure does not shuffle the
    /// item's width on every update. Computed rather than a stored static
    /// because `NSFont` is not Sendable.
    static var titleFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }

    /// The second row. 9pt is small, and deliberately so: it is the price of
    /// fitting two rows inside 22pt without clipping either. Monospaced digits
    /// again, so a ticking countdown does not jitter under the bar.
    static var durationFont: NSFont { .monospacedDigitSystemFont(ofSize: 9, weight: .regular) }

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

    /// The second column: the memory figure, and nothing else.
    ///
    /// The level and the countdown used to live here too, strung after it on
    /// one row. Both have moved into the image, because the layout stacks them
    /// above the duration and `NSStatusBarButton` can place exactly one image
    /// and one title — so anything that has to sit *above* something else has
    /// to be drawn, not titled.
    ///
    /// Still a list of runs rather than a plain string because the figure
    /// carries a colour of its own, and because a nil colour means "no colour
    /// of your own": `NSStatusBarButton` tints its own title and inverts it
    /// while the item is highlighted, and an explicit `labelColor` defeats
    /// both, so Monochrome asks for none. That inversion is now the only part
    /// of the item still following the menu bar automatically — see `image` —
    /// which is precisely why it is worth keeping. `composite` has no button to
    /// defer to and substitutes `labelColor`.
    static func titleRuns(_ input: Input) -> [(text: String, color: NSColor?)] {
        // Deliberately not dimmed alongside a stale quota. This figure is
        // measured on this Mac on this tick; it is fresh however old the usage
        // snapshot beside it happens to be.
        //
        // Monochrome is enforced here rather than trusted from the caller.
        // `memoryTint` already returns nil for it, but a hand-built Input that
        // hard-codes a colour must not be able to put green in a menu bar the
        // user asked to keep colourless.
        guard let memory = input.memoryText else { return [] }
        return [(memory, input.colorMode == .monochrome ? nil : input.memoryColor)]
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

    /// The second row: how long is left in this window, as a duration.
    ///
    /// A duration rather than a wall-clock reset time because that is the unit
    /// the question is asked in — Claude's own usage screen says "Resets in
    /// 1 hr 33 min" — and because a bare "9:10 PM" sitting under a bar names an
    /// hour without saying what happens at it. Nil once the window has run out,
    /// which is the same moment `isExpired` starts dimming the fill.
    static func durationText(_ input: Input) -> String? {
        guard input.marker.showsDuration, let resets = input.resetsAt else { return nil }
        let remaining = resets.timeIntervalSinceNow
        return remaining > 0 ? Fmt.duration(remaining) : nil
    }

    /// Colour for the level, so the number in the Percentage style carries the
    /// same signal as the bar does in the other one. Without it that style —
    /// which draws no gauge at all — had no colour anywhere and 95% looked
    /// exactly like 5%.
    static func levelColor(_ input: Input) -> NSColor {
        let base = tint(for: input.fraction, mode: input.colorMode)
        // A stale reading is dimmed rather than recoloured: the level is still
        // the last known level, we just cannot vouch for it — and a window
        // whose reset time has passed cannot be vouched for either, however
        // recent the snapshot.
        return input.isUnverified ? base.withAlphaComponent(0.55) : base
    }

    /// Colour for the duration row.
    ///
    /// Deliberately not the level colour, which is what the countdown used to
    /// take when it was a run of trailing text. This is a caption under the
    /// gauge, not a second reading of it, and 9pt of dark red on a menu bar is
    /// the least legible thing this item could contain. Dimmed with the rest of
    /// the column when the snapshot cannot be vouched for.
    private static func durationColor(_ input: Input) -> NSColor {
        .labelColor.withAlphaComponent(input.isUnverified ? 0.45 : 0.85)
    }

    /// The status item's gauge and coloured text composited into one image,
    /// drawn by the same code the status item uses.
    ///
    /// Close, not identical. NSStatusBarButton lays out image and title with
    /// its own metrics, so the 2pt inset and the 6pt gap here are this
    /// function's approximation of them — nothing outside AppKit can read the
    /// real ones. The *image* is now exact, because it is the same image the
    /// button gets and nothing tints it any more. What a preview still cannot
    /// show is the button's highlighted state, which no code outside AppKit can
    /// draw and no screenshot can capture without Screen Recording permission.
    /// Good enough to choose a style and a colour by; not a pixel reference,
    /// and callers must not claim it is one.
    ///
    /// The Appearance preview used to show only the gauge, with the text next
    /// to it as a separate uncoloured SwiftUI `Text`. That meant text-only
    /// styles previewed as nothing at all, and no preview ever showed the
    /// colour it was previewing.
    static func composite(_ input: Input, background: NSColor = .clear) -> NSImage {
        let column = image(input)
        // Every run gets a colour here: there is no status item button to hand
        // an uncoloured run to, and drawing one with no foregroundColor at all
        // would land it in whatever the graphics context happened to be set to.
        let text = assemble(titleRuns(input), substituting: .labelColor)
        let textSize = text.length == 0 ? .zero : text.size()
        let width = max(column.size.width + textSize.width + 6, 24)
        let size = NSSize(width: width, height: compositeHeight)

        return NSImage(size: size, flipped: false) { rect in
            // Same reason as image(): dynamic colours resolve when this handler
            // runs, against whichever appearance is current then.
            (input.appearance ?? NSAppearance.currentDrawing())
                .performAsCurrentDrawingAppearance {
                if background != .clear {
                    background.setFill()
                    rect.fill()
                }
                column.draw(at: NSPoint(x: 2, y: 2), from: .zero,
                            operation: .sourceOver, fraction: 1)
                if text.length > 0 {
                    // Centred against the whole of the first column, not against
                    // either of its rows — which is exactly what the status item
                    // button does with a title beside a taller image.
                    text.draw(at: NSPoint(x: 2 + column.size.width,
                                          y: 2 + (height - textSize.height) / 2))
                }
            }
            return true
        }
    }

    // MARK: - Drawing

    /// The first column, as the status item's image: the gauge (or the level)
    /// on top, and how long is left beneath it.
    ///
    /// Two rows, because `NSStatusBarButton` places one image and one title
    /// side by side and nothing else — so a row that has to sit *under* another
    /// row cannot be a title, it has to be drawn. The memory figure stays a
    /// title, and the button centres it against this whole image, which is what
    /// makes it the second column.
    ///
    /// Never template-rendered, in any mode. That is the deliberate cost of the
    /// white clock line: a template image keeps only alpha, so an opaque white
    /// line over an opaque fill is literally the same pixel and the mark
    /// vanished exactly when usage overtook the clock. Drawing Monochrome in
    /// `labelColor` explicitly buys a real white line, and pays for it twice:
    /// this image no longer inverts when the status item is click-highlighted,
    /// and no longer follows a menu bar tint by itself. `input.appearance`
    /// recovers the second of those — the caller hands us the menu bar's own
    /// appearance, so `labelColor` still resolves against it — but nothing
    /// recovers the first. The memory figure beside it is still a button title
    /// and still inverts; the clock line's dark edge is what keeps this half
    /// legible when the highlight lands under it.
    static func image(_ input: Input) -> NSImage {
        let duration = durationText(input)
        let durationWidth = duration.map { textWidth($0, font: durationFont) } ?? 0
        let topWidth = input.style == .bar
            ? barWidth
            : textWidth(input.percentText ?? "—", font: titleFont) + 2
        let width = max(topWidth, durationWidth + 2)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // A dynamic NSColor resolves when this handler runs, against the
            // app's appearance rather than the menu bar's — which is dark over
            // a dark wallpaper even in Light Mode.
            (input.appearance ?? NSAppearance.currentDrawing())
                .performAsCurrentDrawingAppearance {
                // With a second row the first one sits at the top of the item;
                // with the row switched off there is nothing to make room for
                // and it centres instead.
                let stacked = duration != nil

                switch input.style {
                case .bar:
                    let fillColor = tint(for: input.fraction, mode: input.colorMode)
                    // A reading we cannot vouch for is dimmed. The clock line is
                    // not — see drawTimeMarker.
                    let strength: CGFloat = input.isUnverified ? 0.45 : 1
                    let trackY = stacked
                        ? height - topInset - markerOverhang - trackHeight
                        : (height - trackHeight) / 2
                    let track = CGRect(x: 2, y: trackY, width: width - 4, height: trackHeight)
                    drawBar(context: context, track: track,
                            fraction: input.fraction,
                            // Track derived from the fill rather than labelColor
                            // so the two always agree, whatever the mode.
                            trackColor: fillColor.withAlphaComponent(0.22),
                            fillColor: fillColor.withAlphaComponent(strength),
                            radius: trackHeight / 2)

                    if input.fraction == nil {
                        // An empty track is also exactly what 0% looks like. The
                        // dash says "nothing measured yet", in the same
                        // vocabulary as the Percentage style's "—".
                        context.setFillColor(fillColor.withAlphaComponent(0.55).cgColor)
                        context.fill(CGRect(x: track.midX - 3, y: track.midY - 0.75,
                                            width: 6, height: 1.5))
                    } else if input.showsTimeMarker, let elapsed = input.windowElapsed {
                        drawTimeMarker(context: context, track: track, elapsed: elapsed)
                    }

                case .percentage:
                    // "—" rather than an empty row: this style has no gauge, so
                    // with no reading it would otherwise draw a zero-width item
                    // indistinguishable from Torpor having failed to launch.
                    let capTop = stacked ? height - topInset
                                         : (height + titleFont.capHeight) / 2
                    draw(input.percentText ?? "—", font: titleFont,
                         color: levelColor(input), width: width,
                         baseline: capTop - titleFont.capHeight)
                }

                if let duration {
                    draw(duration, font: durationFont, color: durationColor(input),
                         width: width, baseline: bottomInset)
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The clock, as a solid white line standing proud of the bar at both ends.
    ///
    /// Pure white at alpha 1, composited over the fill: the same mark the
    /// popover's own bars already draw, and no longer a hole punched through
    /// with `destinationOut`. The hole existed to survive template rendering,
    /// which keeps only alpha; it is gone with the template.
    ///
    /// The faint dark edge behind it is not a hedge on the white — the line
    /// itself never blends with anything. It is there because white needs
    /// something dark next to it to be a *line* rather than an absence: over a
    /// Monochrome fill, which is `labelColor` and therefore near-white on a
    /// dark menu bar; over the pale rounded rect the system paints under a
    /// highlighted status item, which this image no longer inverts against; and
    /// over the barely-tinted empty track in a light menu bar. All three are
    /// cases where a bare white line would disappear.
    ///
    /// Not dimmed with a stale reading, unlike the fill it sits on. The
    /// previous mark was, on the argument that a mark advancing against a
    /// frozen fill reads as "you are burning fast" — but the clock is the one
    /// quantity here that has not gone stale: it is derived from a reset time
    /// and the current date, and a reset time does not move within its window.
    /// The dimmed fill and dimmed duration carry the staleness instead.
    private static func drawTimeMarker(context: CGContext, track: CGRect, elapsed: Double) {
        let lineWidth: CGFloat = 2
        let edgeWidth: CGFloat = 3
        // Keep the whole mark on the track: half of it hanging past a rounded
        // cap reads as a chipped bar rather than as a mark.
        let margin = Double((edgeWidth / 2) / max(track.width, 1))
        let position = min(max(elapsed, margin), 1 - margin)
        let centre = track.minX + track.width * CGFloat(position)

        context.setFillColor(NSColor(white: 0, alpha: 0.35).cgColor)
        context.fill(CGRect(x: centre - edgeWidth / 2,
                            y: track.minY - markerOverhang,
                            width: edgeWidth,
                            height: track.height + markerOverhang * 2))
        context.setFillColor(NSColor(white: 1, alpha: 1).cgColor)
        context.fill(CGRect(x: centre - lineWidth / 2,
                            y: track.minY - markerOverhang + 0.5,
                            width: lineWidth,
                            height: track.height + markerOverhang * 2 - 1))
    }

    /// One row of text, centred in the column with its baseline at `baseline`.
    ///
    /// Positioned by baseline rather than by the line box, because the line box
    /// reserves descender space that none of this text uses — every duration
    /// Fmt produces ("45m", "1h 33m", "6d 23h") and every level ("87%", "—")
    /// is descender-free — and reserving it is the difference between two rows
    /// fitting inside 20pt and being clipped.
    private static func draw(_ text: String, font: NSFont, color: NSColor,
                             width: CGFloat, baseline: CGFloat) {
        let attributed = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color])
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: ((width - size.width) / 2).rounded(),
                                    y: baseline + font.descender))
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
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
