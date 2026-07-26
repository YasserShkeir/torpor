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
        let rowHeight: CGFloat = 34
        let labelWidth: CGFloat = 110
        let columnWidth: CGFloat = 150
        let headerHeight: CGFloat = 26
        let width = labelWidth + columnWidth * CGFloat(modes.count)
        let height = headerHeight + rowHeight * CGFloat(styles.count)

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

            for (row, style) in styles.enumerated() {
                let y = height - headerHeight - rowHeight * CGFloat(row + 1)
                NSString(string: style.label).draw(
                    at: NSPoint(x: 8, y: y + 10), withAttributes: title)

                for (column, mode) in modes.enumerated() {
                    let x = labelWidth + columnWidth * CGFloat(column)
                    let input = MenuBarRenderer.Input(
                        style: style, colorMode: mode, marker: .remaining,
                        fraction: 0.87, percentText: "87%",
                        resetsAt: Date().addingTimeInterval(4_200),
                        sessionCount: 4, isStale: false,
                        windowElapsed: 0.55)

                    // Composite is what the menu bar actually draws, so the
                    // sheet cannot disagree with the real item.
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

    private static func write(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw PreviewError.encodeFailed
        }
        try png.write(to: url)
    }
}
