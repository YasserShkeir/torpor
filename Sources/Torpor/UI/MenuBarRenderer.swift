import AppKit

// MARK: - Appearance options

/// Menu bar presentations.
///
/// No app logo. A menu bar is scarce horizontal space and a brand mark buys the
/// user nothing there — every style shows the number or the gauge and nothing
/// else. The logo lives in the popover, the Settings window and the Dock.
enum MenuBarStyle: String, Codable, CaseIterable, Identifiable {
    case percentage, bar, battery
    var id: String { rawValue }

    var label: String {
        switch self {
        case .percentage: return "Percentage"
        case .bar:        return "Progress bar"
        case .battery:    return "Battery"
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
        case .fiveHour: return "Session (5-hour)"
        case .sevenDay: return "Week (all models)"
        case .highest:  return "Whichever is highest"
        case .model:    return "A specific model"
        case .memory:   return "Session memory"
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

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: date)
    }

    /// The status item image for the chosen style. Nil where the style is
    /// text-only, so the caller can omit the image rather than pad with a blank.
    static func image(_ input: Input) -> NSImage? {
        switch input.style {
        case .percentage: return nil
        case .bar:        return gauge(input, width: 34)
        case .battery:    return battery(input)
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
    private static func glyph(_ input: Input) -> NSImage {
        let size = NSSize(width: height, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let center = CGPoint(x: rect.midX, y: rect.midY)

            let spokes = 8
            let outer = rect.height * 0.46
            let inner = outer * 0.20
            let halfWidth = outer * 0.20
            let tipWidth = outer * 0.055

            let burst = CGMutablePath()
            for index in 0..<spokes {
                let angle = (CGFloat(index) / CGFloat(spokes)) * 2 * .pi - .pi / 2
                let tip = index.isMultiple(of: 2) ? outer : outer * 0.74
                let transform = CGAffineTransform(translationX: center.x, y: center.y)
                    .rotated(by: angle)
                let waist = inner + (tip - inner) * 0.5

                burst.move(to: CGPoint(x: inner, y: -halfWidth), transform: transform)
                burst.addQuadCurve(to: CGPoint(x: tip, y: -tipWidth),
                                   control: CGPoint(x: waist, y: -halfWidth * 0.62),
                                   transform: transform)
                burst.addArc(center: CGPoint(x: tip, y: 0), radius: tipWidth,
                             startAngle: -.pi / 2, endAngle: .pi / 2,
                             clockwise: false, transform: transform)
                burst.addQuadCurve(to: CGPoint(x: inner, y: halfWidth),
                                   control: CGPoint(x: waist, y: halfWidth * 0.62),
                                   transform: transform)
                burst.closeSubpath()
            }
            let hub = outer * 0.30
            burst.addEllipse(in: CGRect(x: center.x - hub, y: center.y - hub,
                                        width: hub * 2, height: hub * 2))

            context.addPath(burst)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()

            // If the item is still shown with nothing running, fade it rather
            // than draw a full-strength mark for zero sessions.
            if input.sessionCount == 0 {
                context.setBlendMode(.destinationIn)
                context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
                context.fill(rect)
                context.setBlendMode(.normal)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Horizontal track with a proportional fill and a pace marker.
    private static func gauge(_ input: Input, width: CGFloat) -> NSImage {
        let size = NSSize(width: width, height: height)
        let fillColor = tint(for: input.fraction, mode: input.colorMode)

        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            let track = CGRect(x: 2, y: rect.midY - 3.5, width: width - 4, height: 7)
            let radius: CGFloat = 3.5

            context.addPath(CGPath(roundedRect: track, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
            context.setFillColor(NSColor.labelColor.withAlphaComponent(0.18).cgColor)
            context.fillPath()

            if let fraction = input.fraction, fraction > 0 {
                let clamped = min(max(fraction, 0), 1)
                // Never render a sliver so thin it reads as empty.
                let filled = max(track.height, track.width * clamped)
                let fillRect = CGRect(x: track.minX, y: track.minY,
                                      width: filled, height: track.height)
                context.addPath(CGPath(roundedRect: fillRect, cornerWidth: radius,
                                       cornerHeight: radius, transform: nil))
                context.setFillColor(fillColor.withAlphaComponent(input.isStale ? 0.45 : 1).cgColor)
                context.fillPath()
            }

            drawPaceTick(context: context, track: track, elapsed: input.windowElapsed)
            return true
        }
        // Adaptive and accent modes draw real colour, so they must not be
        // template-rendered or the menu bar will flatten them to one tone.
        image.isTemplate = (input.colorMode == .monochrome)
        return image
    }

    /// A tick showing how far through the reset window you are.
    ///
    /// This is what turns a percentage into a decision. 60% used means nothing
    /// on its own; 60% used with 30% of the window elapsed means you are
    /// burning at twice the pace the window can carry. Fill to the left of the
    /// tick is ahead of schedule, fill past it is behind.
    private static func drawPaceTick(context: CGContext, track: CGRect, elapsed: Double?) {
        guard let elapsed, elapsed > 0.01, elapsed < 0.99 else { return }
        let x = track.minX + track.width * CGFloat(min(max(elapsed, 0), 1))
        let tick = CGRect(x: x - 0.75, y: track.minY - 2, width: 1.5, height: track.height + 4)
        context.addPath(CGPath(roundedRect: tick, cornerWidth: 0.75,
                               cornerHeight: 0.75, transform: nil))
        context.setFillColor(NSColor.labelColor.withAlphaComponent(0.75).cgColor)
        context.fillPath()
    }

    /// Battery outline with proportional charge.
    private static func battery(_ input: Input) -> NSImage {
        let size = NSSize(width: 30, height: height)
        let fillColor = tint(for: input.fraction, mode: input.colorMode)

        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            let body = CGRect(x: 1, y: rect.midY - 5.5, width: 23, height: 11)
            let outline = CGPath(roundedRect: body, cornerWidth: 3, cornerHeight: 3, transform: nil)
            context.addPath(outline)
            context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.55).cgColor)
            context.setLineWidth(1.2)
            context.strokePath()

            // Terminal nub.
            let nub = CGRect(x: body.maxX + 1, y: rect.midY - 2.2, width: 2, height: 4.4)
            context.addPath(CGPath(roundedRect: nub, cornerWidth: 1, cornerHeight: 1, transform: nil))
            context.setFillColor(NSColor.labelColor.withAlphaComponent(0.55).cgColor)
            context.fillPath()

            if let fraction = input.fraction {
                let inset = body.insetBy(dx: 2, dy: 2)
                let clamped = min(max(fraction, 0), 1)
                let width = max(1.5, inset.width * clamped)
                let charge = CGRect(x: inset.minX, y: inset.minY, width: width, height: inset.height)
                context.addPath(CGPath(roundedRect: charge, cornerWidth: 1.5,
                                       cornerHeight: 1.5, transform: nil))
                context.setFillColor(fillColor.withAlphaComponent(input.isStale ? 0.45 : 1).cgColor)
                context.fillPath()

                drawPaceTick(context: context, track: inset, elapsed: input.windowElapsed)
            }
            return true
        }
        image.isTemplate = (input.colorMode == .monochrome)
        return image
    }
}
