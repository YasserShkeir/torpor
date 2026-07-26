#!/usr/bin/env swift
//
// Generates Resources/AppIcon.icns from the same geometry as Resources/icon.svg.
//
//   swift scripts/make-icon.swift
//
// Drawn with CoreGraphics rather than rasterising the SVG because macOS ships no
// SVG rasteriser, and adding one as a build dependency for a single asset is a
// poor trade. Geometry constants below mirror the SVG one-for-one.
//
// The mark is an eleven-spoke radial burst in a warm coral palette, so Torpor
// reads as part of the Claude tooling family. Spoke lengths alternate, which is
// what gives the mark life without making it look damaged. It is deliberately
// *evocative* of Claude's mark rather than a copy: Anthropic polices its
// trademarks and this app is not affiliated with them.
//
import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry (canvas is 1024; all values scale proportionally)

let canvas: CGFloat = 1024
let plateInset: CGFloat = 92          // squircle padding
let plateRadius: CGFloat = 189        // 22.5% corner radius

let spokeCount = 11
let innerRadius: CGFloat = 58         // where spokes emerge from the hub
let outerRadius: CGFloat = 288        // tip of a long spoke
let shortSpokeFactor: CGFloat = 0.74  // every other spoke is drawn shorter
let spokeHalfWidth: CGFloat = 44      // half-thickness at the hub
let tipHalfWidth: CGFloat = 11        // half-thickness at the tip (rounded, not sharp)
let hubRadius: CGFloat = 68

/// Spokes alternate long and short. Dimming a contiguous group to suggest
/// "some sessions are asleep" was tried and rejected: three faded petals in a
/// row read as damage to the mark rather than as meaning.
func spokeTip(_ index: Int) -> CGFloat {
    index.isMultiple(of: 2) ? outerRadius : outerRadius * shortSpokeFactor
}

// Coral plate, matching the warm end of Claude's palette.
let plateTop = CGColor(red: 0.878, green: 0.494, blue: 0.353, alpha: 1)   // #E07E5A
let plateBottom = CGColor(red: 0.760, green: 0.365, blue: 0.231, alpha: 1) // #C25D3B

/// One petal: symmetric taper from hub to a rounded tip.
func appendSpoke(_ path: CGMutablePath, index: Int) {
    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    let angle = (CGFloat(index) / CGFloat(spokeCount)) * 2 * .pi - .pi / 2
    let tip = spokeTip(index)
    let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
    let waist = innerRadius + (tip - innerRadius) * 0.5

    path.move(to: CGPoint(x: innerRadius, y: -spokeHalfWidth), transform: transform)
    path.addQuadCurve(to: CGPoint(x: tip, y: -tipHalfWidth),
                      control: CGPoint(x: waist, y: -spokeHalfWidth * 0.62),
                      transform: transform)
    path.addArc(center: CGPoint(x: tip, y: 0), radius: tipHalfWidth,
                startAngle: -.pi / 2, endAngle: .pi / 2,
                clockwise: false, transform: transform)
    path.addQuadCurve(to: CGPoint(x: innerRadius, y: spokeHalfWidth),
                      control: CGPoint(x: waist, y: spokeHalfWidth * 0.62),
                      transform: transform)
    path.closeSubpath()
}

func drawBurst(into context: CGContext, color: CGColor) {
    let center = CGPoint(x: canvas / 2, y: canvas / 2)

    // One combined path filled once. Filling petal-by-petal would show a seam
    // at every overlap the moment the fill is anything but fully opaque.
    let burst = CGMutablePath()
    for index in 0..<spokeCount { appendSpoke(burst, index: index) }
    // Hub joins the petals into one mark rather than eleven shapes.
    burst.addEllipse(in: CGRect(x: center.x - hubRadius, y: center.y - hubRadius,
                                width: hubRadius * 2, height: hubRadius * 2))
    context.addPath(burst)
    context.setFillColor(color)
    context.fillPath()
}

func draw(into context: CGContext, size: CGFloat) {
    let s = size / canvas
    context.saveGState()
    context.scaleBy(x: s, y: s)

    let plate = CGRect(x: plateInset, y: plateInset,
                       width: canvas - plateInset * 2,
                       height: canvas - plateInset * 2)
    context.saveGState()
    context.addPath(CGPath(roundedRect: plate, cornerWidth: plateRadius,
                           cornerHeight: plateRadius, transform: nil))
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [plateTop, plateBottom] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: plate.minX, y: plate.maxY),
                               end: CGPoint(x: plate.maxX, y: plate.minY),
                               options: [])
    context.restoreGState()

    drawBurst(into: context, color: CGColor(red: 1, green: 0.985, blue: 0.975, alpha: 1))

    context.restoreGState()
}

func render(size: Int) -> Data {
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create bitmap context at \(size)px")
    }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    draw(into: context, size: CGFloat(size))

    guard let image = context.makeImage() else { fatalError("no image at \(size)px") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed at \(size)px")
    }
    return png
}

// MARK: - Emit iconset

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int, Int)] = [
    ("16x16", 16, 1), ("16x16", 16, 2),
    ("32x32", 32, 1), ("32x32", 32, 2),
    ("128x128", 128, 1), ("128x128", 128, 2),
    ("256x256", 256, 1), ("256x256", 256, 2),
    ("512x512", 512, 1), ("512x512", 512, 2),
]

for (base, points, scale) in variants {
    let suffix = scale == 2 ? "@2x" : ""
    try render(size: points * scale)
        .write(to: iconset.appendingPathComponent("icon_\(base)\(suffix).png"))
}

try render(size: 1024).write(to: resources.appendingPathComponent("icon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path,
                      "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
print("Wrote Resources/AppIcon.icns and Resources/icon-1024.png")
