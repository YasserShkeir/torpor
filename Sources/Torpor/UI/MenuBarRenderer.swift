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

/// Which number the menu bar shows when several are available.
enum MenuBarMetric: String, Codable, CaseIterable, Identifiable {
    case fiveHour, sevenDay, highest, model, memory
    var id: String { rawValue }

    var label: String {
        switch self {
        // "Session" elsewhere in Torpor means a Claude Code process. Using it
        // here for a rate-limit window put two unrelated meanings in one
        // five-item picker.
        case .fiveHour: return "5-hour limit"
        case .sevenDay: return "Weekly limit (all models)"
        case .highest:  return "Whichever limit is highest"
        case .model:    return "One model's weekly limit"
        case .memory:   return "Memory used by Claude Code"
        }
    }

    /// What the gauge is a proportion *of*. A bar with no label is only
    /// meaningful if the user has been told what fills it — "5.63 GB" beside a
    /// half-full bar otherwise invites the reasonable question "half of what?".
    var gaugeMeaning: String {
        switch self {
        case .fiveHour:
            return "Share of your rolling 5-hour limit used so far."
        case .sevenDay:
            return "Share of your weekly limit used so far, across all models."
        case .highest:
            return "Whichever of the 5-hour and weekly limits is further along."
        case .model:
            return "Share of this model's own weekly limit used so far."
        case .memory:
            return "Memory held by all Claude Code sessions, as a share of your Mac's total RAM. Memory never resets, so there is no countdown — but on the Progress bar style the lower bar keeps running, showing how far through your quota window you are."
        }
    }

    /// Whether the gauge carries the elapsed-time notch. Only windowed metrics
    /// have a clock to compare against.

    /// Windowed metrics reset; memory does not, so a countdown is meaningless.
    var hasResetWindow: Bool { self != .memory }
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
        var percentText: String?
        var resetsAt: Date?
        var sessionCount: Int
        var isStale: Bool
        /// 0…1 through the current reset window, or nil when unknown. Drawn as
        /// a tick on the gauge so usage can be read against elapsed time.
        var windowElapsed: Double?
    }

    static let height: CGFloat = 18

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

    /// The trailing text: percentage and/or countdown.
    ///
    /// Each style earns its place by showing something the others don't:
    /// `iconOnly` is silent, `percentage` is text with no mark, `bar` and
    /// `battery` let the gauge carry the number, and `compact` shows the number
    /// but drops the countdown.
    static func title(_ input: Input) -> String {
        var parts: [String] = []

        if let percent = input.percentText { parts.append(percent) }

        let marker = input.marker
        if let resets = input.resetsAt, marker != .none {
            let remaining = resets.timeIntervalSinceNow
            switch marker {
            case .remaining:
                if remaining > 0 { parts.append(Fmt.duration(remaining)) }
            case .resetClock:
                parts.append(clock(resets))
            case .both:
                if remaining > 0 { parts.append("\(Fmt.duration(remaining)) · \(clock(resets))") }
                else { parts.append(clock(resets)) }
            case .none:
                break
            }
        }

        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? "" : " \(joined)"
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
        // the last known level, we just cannot vouch for it.
        return input.isStale ? base.withAlphaComponent(0.55) : base
    }

    /// The complete status item — gauge and coloured text composited into one
    /// image, exactly as the menu bar draws it.
    ///
    /// The Appearance preview used to show only the gauge, with the text next
    /// to it as a separate uncoloured SwiftUI `Text`. That meant text-only
    /// styles previewed as nothing at all, and no preview ever showed the
    /// colour it was previewing.
    static func composite(_ input: Input, background: NSColor = .clear) -> NSImage {
        let gaugeImage = image(input)
        let text = title(input)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: titleColor(input),
        ]
        let textSize = text.isEmpty ? .zero : NSString(string: text).size(withAttributes: attributes)
        let width = max((gaugeImage?.size.width ?? 0) + textSize.width + 6, 24)
        let size = NSSize(width: width, height: height + 4)

        return NSImage(size: size, flipped: false) { rect in
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
            if !text.isEmpty {
                NSString(string: text).draw(
                    at: NSPoint(x: x, y: 2 + (height - textSize.height) / 2),
                    withAttributes: attributes)
            }
            return true
        }
    }

    // MARK: - Drawing

    /// Radial burst, matching the app icon.
    ///
    /// Simplified to 8 spokes rather than the icon's 11: at an 18pt menu bar
    /// size, eleven petals is roughly two pixels each and collapses into a
    /// grey smudge. Template-rendered so it follows the menu bar's own tint and
    /// inverts correctly in dark mode.

    private static func gauge(_ input: Input, width: CGFloat) -> NSImage {
        let size = NSSize(width: width, height: height)
        let fillColor = tint(for: input.fraction, mode: input.colorMode)

        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            let hasTime = input.windowElapsed != nil
            // With a time bar the pair is centred as a unit; without one the
            // usage bar sits on the centre line by itself.
            let usage = CGRect(x: 2,
                               y: hasTime ? rect.midY - 1 : rect.midY - 3,
                               width: width - 4, height: 6)
            drawBar(context: context, track: usage,
                    fraction: input.fraction,
                    // Track derived from the fill rather than labelColor: label
                    // colours resolve against the *app's* appearance inside an
                    // NSImage handler, not the menu bar's, so a light-appearance
                    // app drew a near-black track onto a dark menu bar.
                    trackColor: fillColor.withAlphaComponent(0.22),
                    fillColor: fillColor.withAlphaComponent(input.isStale ? 0.45 : 1),
                    radius: 3)

            if let elapsed = input.windowElapsed {
                let time = CGRect(x: 2, y: usage.minY - 5, width: width - 4, height: 3)
                drawBar(context: context, track: time,
                        fraction: elapsed,
                        trackColor: fillColor.withAlphaComponent(0.16),
                        // Deliberately not the usage colour: the time bar is a
                        // reference line, and colouring it by usage severity
                        // would imply the clock is the thing going wrong.
                        fillColor: NSColor.systemGray.withAlphaComponent(0.9),
                        radius: 1.5)
            }
            return true
        }
        // Adaptive and accent modes draw real colour, so they must not be
        // template-rendered or the menu bar will flatten them to one tone.
        image.isTemplate = (input.colorMode == .monochrome)
        return image
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

    /// Radial burst, matching the app icon.
    ///
    /// Simplified to 8 spokes rather than the icon's 11: at an 18pt menu bar
    /// size, eleven petals is roughly two pixels each and collapses into a
    /// grey smudge. Template-rendered so it follows the menu bar's own tint and
    /// inverts correctly in dark mode.
}
