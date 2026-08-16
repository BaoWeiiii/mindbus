#!/usr/bin/env swift

import AppKit
import Darwin
import Foundation

enum RenderError: Error, CustomStringConvertible {
    case usage
    case unreadableImage(URL)
    case emptyImage
    case bitmapCreation
    case pngEncoding

    var description: String {
        switch self {
        case .usage:
            return "usage: swift scripts/render-menubar-icon.swift <source.png> <output.png>"
        case .unreadableImage(let url):
            return "cannot read image at \(url.path)"
        case .emptyImage:
            return "source image has no nontransparent pixels"
        case .bitmapCreation:
            return "cannot create output bitmap"
        case .pngEncoding:
            return "cannot encode PNG"
        }
    }
}

func sourceAlpha(_ image: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
    image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.alphaComponent ?? 0
}

func bilinearAlpha(
    _ image: NSBitmapImageRep,
    x: Double,
    y: Double,
    bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)
) -> CGFloat {
    let x0 = max(bounds.minX, min(bounds.maxX, Int(floor(x))))
    let y0 = max(bounds.minY, min(bounds.maxY, Int(floor(y))))
    let x1 = min(bounds.maxX, x0 + 1)
    let y1 = min(bounds.maxY, y0 + 1)
    let fx = CGFloat(x - Double(x0))
    let fy = CGFloat(y - Double(y0))

    let a00 = sourceAlpha(image, x: x0, y: y0)
    let a10 = sourceAlpha(image, x: x1, y: y0)
    let a01 = sourceAlpha(image, x: x0, y: y1)
    let a11 = sourceAlpha(image, x: x1, y: y1)
    let lower = a00 + (a10 - a00) * fx
    let upper = a01 + (a11 - a01) * fx
    return lower + (upper - lower) * fy
}

func strokeFold(
    on image: NSBitmapImageRep,
    alpha: CGFloat,
    width: CGFloat,
    lowerSegmentOnly: Bool
) throws {
    guard let graphics = NSGraphicsContext(bitmapImageRep: image) else {
        throw RenderError.bitmapCreation
    }
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.current = previous }

    graphics.compositingOperation = .destinationOut
    NSColor(deviceWhite: 1, alpha: alpha).setStroke()

    let path = NSBezierPath()
    path.move(to: NSPoint(x: 23.5, y: 18.0))
    path.curve(
        to: NSPoint(x: 36.7, y: 37.2),
        controlPoint1: NSPoint(x: 31.0, y: 24.8),
        controlPoint2: NSPoint(x: 34.8, y: 30.8)
    )
    if !lowerSegmentOnly {
        path.curve(
            to: NSPoint(x: 50.8, y: 51.7),
            controlPoint1: NSPoint(x: 39.0, y: 43.9),
            controlPoint2: NSPoint(x: 43.2, y: 48.9)
        )
    }
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
    graphics.flushGraphics()
}

func render(sourceURL: URL, outputURL: URL) throws {
    guard let source = NSBitmapImageRep(data: try Data(contentsOf: sourceURL)) else {
        throw RenderError.unreadableImage(sourceURL)
    }

    var minX = source.pixelsWide
    var minY = source.pixelsHigh
    var maxX = -1
    var maxY = -1
    for y in 0..<source.pixelsHigh {
        for x in 0..<source.pixelsWide where sourceAlpha(source, x: x, y: y) > 1.0 / 255.0 {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { throw RenderError.emptyImage }

    guard let output = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 80,
        pixelsHigh: 64,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw RenderError.bitmapCreation
    }

    // `NSBitmapImageRep.setColor(_:atX:y:)` silently no-ops when the receiver is a
    // `.deviceRGB` bitmap on this toolchain: the call reports success but a readback
    // via `colorAt` stays alpha 0 (confirmed with a minimal repro). Write raw
    // premultiplied RGBA bytes instead — deterministic and independent of AppKit's
    // legacy colorspace resolution for this pixel-poke API. The mark is pure black,
    // so premultiplication never changes the R/G/B bytes (0 × anything is still 0).
    guard let buffer = output.bitmapData else {
        throw RenderError.bitmapCreation
    }
    let bytesPerRow = output.bytesPerRow
    memset(buffer, 0, bytesPerRow * 64) // fully transparent canvas

    func writeBlack(alpha: CGFloat, x: Int, y: Int) {
        let offset = y * bytesPerRow + x * 4
        buffer[offset + 0] = 0
        buffer[offset + 1] = 0
        buffer[offset + 2] = 0
        buffer[offset + 3] = UInt8((max(0, min(1, alpha)) * 255).rounded())
    }

    let sourceWidth = maxX - minX + 1
    let sourceHeight = maxY - minY + 1
    for targetY in 0..<52 {
        for targetX in 0..<76 {
            let x = Double(minX) + (Double(targetX) + 0.5) * Double(sourceWidth) / 76.0 - 0.5
            let y = Double(minY) + (Double(targetY) + 0.5) * Double(sourceHeight) / 52.0 - 0.5
            let alpha = bilinearAlpha(
                source,
                x: x,
                y: y,
                bounds: (minX, minY, maxX, maxY)
            )
            writeBlack(alpha: alpha, x: targetX + 2, y: targetY + 6)
        }
    }

    try strokeFold(on: output, alpha: 0.48, width: 4.0, lowerSegmentOnly: false)
    try strokeFold(on: output, alpha: 0.76, width: 5.0, lowerSegmentOnly: true)

    guard let png = output.representation(using: .png, properties: [:]) else {
        throw RenderError.pngEncoding
    }
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
    )
    try png.write(to: outputURL, options: .atomic)
}

do {
    guard CommandLine.arguments.count == 3 else { throw RenderError.usage }
    try render(
        sourceURL: URL(fileURLWithPath: CommandLine.arguments[1]),
        outputURL: URL(fileURLWithPath: CommandLine.arguments[2])
    )
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
