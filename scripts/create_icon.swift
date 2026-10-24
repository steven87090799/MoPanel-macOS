// SPDX-License-Identifier: GPL-3.0-or-later
// Original geometric MoPanel mark, generated at build time with AppKit.
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/create_icon.swift <output.iconset>\n", stderr)
    exit(2)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let size = CGFloat(pixels)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("Bitmap allocation failed") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        let rect = NSRect(x: size * 0.08, y: size * 0.08, width: size * 0.84, height: size * 0.84)
        let plate = NSBezierPath(roundedRect: rect, xRadius: size * 0.20, yRadius: size * 0.20)
        NSColor(calibratedWhite: 0.075, alpha: 1).setFill()
        plate.fill()
        let mark = NSBezierPath()
        mark.lineWidth = size * 0.085
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        mark.move(to: NSPoint(x: size * 0.29, y: size * 0.32))
        mark.line(to: NSPoint(x: size * 0.29, y: size * 0.67))
        mark.line(to: NSPoint(x: size * 0.50, y: size * 0.44))
        mark.line(to: NSPoint(x: size * 0.71, y: size * 0.67))
        mark.line(to: NSPoint(x: size * 0.71, y: size * 0.32))
        NSColor(calibratedWhite: 0.96, alpha: 1).setStroke()
        mark.stroke()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
