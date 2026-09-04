#!/usr/bin/swift
// Renders the Token Usage app icon into App/Resources/Assets.xcassets/AppIcon.appiconset.
//
// The icon is drawn in code so it can be regenerated at any size without a
// design-tool dependency: a dark rounded tile on the standard macOS icon grid
// (824pt of a 1024pt canvas) carrying two concentric gauge arcs — the outer
// for Claude, the inner for Codex — mirroring the two rows in the dropdown.
//
//   swift scripts/make-icon.swift

import AppKit
import Foundation

let canvas: CGFloat = 1024
let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")

func draw(in ctx: CGContext, size: CGFloat) {
    let s = size / canvas
    ctx.scaleBy(x: s, y: s)

    // Tile — the macOS grid leaves a 100pt margin on each side.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 1),
            CGColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Subtle inner highlight along the top edge.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.setLineWidth(6)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
    ctx.strokePath()
    ctx.restoreGState()

    // Gauges: a 270° sweep opening downward, like a speedometer.
    let center = CGPoint(x: 512, y: 500)
    let startAngle = CGFloat.pi * 1.25          // bottom-left
    let sweep = CGFloat.pi * 1.5                // clockwise to bottom-right

    func arc(radius: CGFloat, width: CGFloat, fraction: CGFloat, color: CGColor, track: CGColor) {
        ctx.setLineCap(.round)
        ctx.setLineWidth(width)

        ctx.setStrokeColor(track)
        ctx.addArc(center: center, radius: radius, startAngle: startAngle,
                   endAngle: startAngle - sweep, clockwise: true)
        ctx.strokePath()

        ctx.setStrokeColor(color)
        ctx.addArc(center: center, radius: radius, startAngle: startAngle,
                   endAngle: startAngle - sweep * fraction, clockwise: true)
        ctx.strokePath()
    }

    let track = CGColor(red: 1, green: 1, blue: 1, alpha: 0.10)
    // Claude — outer, warm.
    arc(radius: 290, width: 72, fraction: 0.66,
        color: CGColor(red: 0.85, green: 0.47, blue: 0.24, alpha: 1), track: track)
    // Codex — inner, cool.
    arc(radius: 186, width: 72, fraction: 0.30,
        color: CGColor(red: 0.30, green: 0.78, blue: 0.68, alpha: 1), track: track)

    // Needle hub: a small dot so the gauges read as one instrument.
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    ctx.fillEllipse(in: CGRect(x: center.x - 34, y: center.y - 34, width: 68, height: 68))
}

func render(pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    draw(in: ctx, size: CGFloat(pixels))
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// Every slot macOS asks for, so actool has nothing to synthesise.
let slots: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
var images: [[String: String]] = []
for slot in slots {
    let name = "icon_\(slot.points)x\(slot.points)@\(slot.scale)x.png"
    try render(pixels: slot.points * slot.scale, to: iconset.appendingPathComponent(name))
    images.append([
        "filename": name,
        "idiom": "mac",
        "scale": "\(slot.scale)x",
        "size": "\(slot.points)x\(slot.points)",
    ])
}
let contents: [String: Any] = [
    "images": images,
    "info": ["author": "xcode", "version": 1],
]
let json = try JSONSerialization.data(
    withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]
)
try json.write(to: iconset.appendingPathComponent("Contents.json"))
print("Wrote \(slots.count) icons to \(iconset.path)")
