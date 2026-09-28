// Generates Resources/AppIcon.icns for DynamicBar.
//
//   swiftc -O -o /tmp/makeicon scripts/tools/make-icon.swift && /tmp/makeicon
//
// Draws a rounded-square gradient tile with a "menu bar + sliding panel" glyph.

import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    // Rounded tile with vertical gradient.
    let inset = size * 0.06
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.235
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [
        NSColor(calibratedRed: 0.36, green: 0.60, blue: 1.00, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.82, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
    }
    context.restoreGState()

    // Menu bar strip.
    let barHeight = size * 0.10
    let barRect = CGRect(x: inset, y: size - inset - barHeight, width: size - inset * 2, height: barHeight)
    context.saveGState()
    context.addPath(CGPath(roundedRect: barRect, cornerWidth: barHeight / 2.6, cornerHeight: barHeight / 2.6, transform: nil))
    context.setFillColor(NSColor.white.withAlphaComponent(0.28).cgColor)
    context.fillPath()
    context.restoreGState()

    // Sliding panel: a rounded card hanging from the centre of the bar.
    let panelWidth = size * 0.50
    let panelHeight = size * 0.34
    let panelRect = CGRect(
        x: (size - panelWidth) / 2,
        y: size - inset - barHeight - panelHeight + size * 0.02,
        width: panelWidth,
        height: panelHeight
    )
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(CGPath(roundedRect: panelRect, cornerWidth: size * 0.055, cornerHeight: size * 0.055, transform: nil))
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()
    context.restoreGState()

    // Three list lines inside the panel.
    let lineHeight = size * 0.030
    let lineWidths: [CGFloat] = [0.34, 0.26, 0.30]
    context.setFillColor(NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.82, alpha: 0.85).cgColor)
    for (index, factor) in lineWidths.enumerated() {
        let y = panelRect.maxY - size * 0.075 - CGFloat(index) * size * 0.075
        let lineRect = CGRect(x: panelRect.minX + size * 0.055, y: y, width: size * factor, height: lineHeight)
        context.addPath(CGPath(roundedRect: lineRect, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
        context.fillPath()
    }

    image.unlockFocus()
    return image
}

func pngData(size: CGFloat) -> Data? {
    let image = drawIcon(size: size)
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let data = pngData(size: variant.pixels) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
if process.terminationStatus == 0 {
    print("wrote \(output.path)")
} else {
    FileHandle.standardError.write(Data("iconutil failed with \(process.terminationStatus)\n".utf8))
    exit(1)
}
