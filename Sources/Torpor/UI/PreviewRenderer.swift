import AppKit
import SwiftUI

/// Offscreen rendering of the UI to PNG.
///
/// Exists so the interface can be reviewed and diffed without a screen
/// recording permission or a human clicking the status item — useful in
/// development and in CI, where there is no one to look at a menu bar.
@MainActor
enum PreviewRenderer {

    /// Contact sheet of every menu bar style against every colour mode.
    static func menuBarSheet(to url: URL) throws {
        let styles = MenuBarStyle.allCases
        let modes = ColorMode.allCases
        // The states that break the drawing, not just the one that works: fill
        // past the notch is where a marker drawn in colour vanished under
        // template rendering, and no-reading is where an empty bar used to be
        // indistinguishable from 0%.
        //
        // The memory figure alternates between the two figures rather than
        // doubling the row count: what has to be visible is that green and
        // orange both survive every style and every colour mode, and that the
        // figure does *not* dim alongside a stale quota reading.
        let readings: [(label: String, fraction: Double?, percent: String?,
                        elapsed: Double?, stale: Bool,
                        figure: MemoryFigure, memory: String)] = [
            ("past the notch", 0.87, "87%", 0.55, false, .total, "1.24 GB"),
            ("behind it", 0.30, "30%", 0.55, false, .reclaimable, "412 MB"),
            ("stale", 0.87, "87%", 0.55, true, .total, "1.24 GB"),
            ("no reading", nil, nil, nil, false, .reclaimable, "412 MB"),
        ]
        let rows = styles.flatMap { style in readings.map { reading in (style, reading) } }
        let rowHeight: CGFloat = 34
        let labelWidth: CGFloat = 230
        // Wide enough for the longest item the redesign can produce: bar,
        // memory figure and countdown. At 150 the columns overlapped.
        let columnWidth: CGFloat = 210
        let headerHeight: CGFloat = 26
        let width = labelWidth + columnWidth * CGFloat(modes.count)
        let height = headerHeight + rowHeight * CGFloat(rows.count)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            let title: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            func body(_ colour: NSColor) -> [NSAttributedString.Key: Any] {
                [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: colour]
            }

            for (column, mode) in modes.enumerated() {
                let x = labelWidth + columnWidth * CGFloat(column)
                NSString(string: mode.label).draw(
                    at: NSPoint(x: x, y: height - headerHeight + 7), withAttributes: title)
            }

            for (row, entry) in rows.enumerated() {
                let (style, reading) = entry
                let y = height - headerHeight - rowHeight * CGFloat(row + 1)
                NSString(string: "\(style.label) · \(reading.label) · \(reading.figure.rawValue)").draw(
                    at: NSPoint(x: 8, y: y + 10), withAttributes: title)

                for (column, mode) in modes.enumerated() {
                    let x = labelWidth + columnWidth * CGFloat(column)
                    let input = MenuBarRenderer.Input(
                        style: style, colorMode: mode, marker: .remaining,
                        fraction: reading.fraction, percentText: reading.percent,
                        memoryText: reading.memory,
                        memoryColor: MenuBarRenderer.memoryTint(for: reading.figure, mode: mode),
                        resetsAt: Date().addingTimeInterval(4_200),
                        sessionCount: 4, isStale: reading.stale,
                        windowElapsed: reading.elapsed)

                    // Composite is the status item's own drawing code, so the
                    // sheet cannot drift from it.
                    let item = MenuBarRenderer.composite(input)
                    item.draw(at: NSPoint(x: x, y: y + 6), from: .zero,
                              operation: .sourceOver, fraction: 1)
                }
            }
            return true
        }
        try write(image, to: url)
    }

    /// Render a SwiftUI view hierarchy at a fixed size.
    ///
    /// Uses `ImageRenderer` rather than `NSHostingView.cacheDisplay`: the latter
    /// silently omits SwiftUI text, producing a picture with the layout and the
    /// colours but none of the words — which looks like a working render right
    /// up until you try to read it.
    static func view<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let renderer = ImageRenderer(content:
            view.frame(width: size.width, height: size.height)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage else { throw PreviewError.noBitmap }
        try write(image, to: url)
    }

    enum PreviewError: LocalizedError {
        case noBitmap, encodeFailed
        var errorDescription: String? {
            switch self {
            case .noBitmap: return "Could not create a bitmap for the view."
            case .encodeFailed: return "PNG encoding failed."
            }
        }
    }

    /// Rasterise at Retina scale.
    ///
    /// `tiffRepresentation` of a block-based NSImage renders the handler once
    /// at 1x, which is the one scale that cannot answer the question the sheet
    /// exists to answer — whether a 2pt notch and a 1.5pt dash survive on the
    /// display anyone actually has.
    private static func write(_ image: NSImage, to url: URL, scale: CGFloat = 2) throws {
        let size = image.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw PreviewError.noBitmap }
        // Point size smaller than pixel size is what makes this a 2x rep
        // rather than a large 1x one.
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw PreviewError.encodeFailed
        }
        try png.write(to: url)
    }
}
