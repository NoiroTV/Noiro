#!/usr/bin/env swift

import AppKit
import Foundation

private enum AssetError: Error, CustomStringConvertible {
    case usage
    case unreadable(String)
    case bitmap
    case encoding(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: generate-noiro-assets.swift <square-master.png> <transparent-glyph.png> <app-icon-set> <tv-brand-assets>"
        case .unreadable(let path):
            return "could not read image: \(path)"
        case .bitmap:
            return "could not create bitmap context"
        case .encoding(let path):
            return "could not encode PNG: \(path)"
        }
    }
}

private func load(_ path: String) throws -> NSImage {
    guard let image = NSImage(contentsOfFile: path) else { throw AssetError.unreadable(path) }
    return image
}

private func rectForAspectFill(image: NSImage, canvas: NSSize) -> NSRect {
    let scale = max(canvas.width / image.size.width, canvas.height / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    return NSRect(
        x: (canvas.width - size.width) / 2,
        y: (canvas.height - size.height) / 2,
        width: size.width,
        height: size.height
    )
}

private func rectForAspectFit(image: NSImage, inside bounds: NSRect) -> NSRect {
    let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    return NSRect(
        x: bounds.midX - size.width / 2,
        y: bounds.midY - size.height / 2,
        width: size.width,
        height: size.height
    )
}

private func render(
    width: Int,
    height: Int,
    opaque: Bool,
    draw: (NSRect) -> Void
) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: width * 4,
        bitsPerPixel: 32
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw AssetError.bitmap
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let canvas = NSRect(x: 0, y: 0, width: width, height: height)
    (opaque ? NSColor(calibratedWhite: 0.015, alpha: 1) : NSColor.clear).setFill()
    canvas.fill()
    draw(canvas)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    let encodedBitmap: NSBitmapImageRep
    if opaque {
        guard let source = bitmap.cgImage,
              let flattened = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ), let output = ({
                flattened.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
                return flattened.makeImage()
              })() else { throw AssetError.bitmap }
        encodedBitmap = NSBitmapImageRep(cgImage: output)
    } else {
        encodedBitmap = bitmap
    }
    guard let data = encodedBitmap.representation(using: .png, properties: [:]) else {
        throw AssetError.bitmap
    }
    return data
}

private func write(_ data: Data, to path: String) throws {
    do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    catch { throw AssetError.encoding(path) }
}

private func gradient(in canvas: NSRect) {
    let gradient = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.01, green: 0.01, blue: 0.025, alpha: 1), 0),
        (NSColor(calibratedRed: 0.055, green: 0.025, blue: 0.12, alpha: 1), 0.58),
        (NSColor(calibratedRed: 0.015, green: 0.02, blue: 0.055, alpha: 1), 1)
    )
    gradient?.draw(in: canvas, angle: 0)
}

private func makeIcon(master: NSImage, size: Int, path: String) throws {
    try write(render(width: size, height: size, opaque: true) { canvas in
        master.draw(in: rectForAspectFill(image: master, canvas: canvas.size),
                    from: .zero, operation: .sourceOver, fraction: 1)
    }, to: path)
}

private func makeTVBack(width: Int, height: Int, path: String) throws {
    try write(render(width: width, height: height, opaque: true) { gradient(in: $0) }, to: path)
}

private func makeTVFront(glyph: NSImage, width: Int, height: Int, path: String) throws {
    try write(render(width: width, height: height, opaque: false) { canvas in
        let inset = canvas.insetBy(dx: canvas.width * 0.18, dy: canvas.height * 0.12)
        glyph.draw(in: rectForAspectFit(image: glyph, inside: inset),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }, to: path)
}

private func makeTopShelf(glyph: NSImage, width: Int, height: Int, path: String) throws {
    try write(render(width: width, height: height, opaque: true) { canvas in
        gradient(in: canvas)
        let glyphBounds = NSRect(
            x: canvas.width * 0.09,
            y: canvas.height * 0.12,
            width: canvas.width * 0.34,
            height: canvas.height * 0.76
        )
        glyph.draw(in: rectForAspectFit(image: glyph, inside: glyphBounds),
                   from: .zero, operation: .sourceOver, fraction: 1)

        let title = NSAttributedString(string: "NOIRO", attributes: [
            .font: NSFont.systemFont(ofSize: canvas.height * 0.18, weight: .heavy),
            .foregroundColor: NSColor.white,
            .kern: canvas.height * 0.018
        ])
        let subtitle = NSAttributedString(string: "YOUR MEDIA. YOUR SCREEN.", attributes: [
            .font: NSFont.systemFont(ofSize: canvas.height * 0.055, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.78, alpha: 1),
            .kern: canvas.height * 0.006
        ])
        title.draw(at: NSPoint(x: canvas.width * 0.47, y: canvas.height * 0.52))
        subtitle.draw(at: NSPoint(x: canvas.width * 0.475, y: canvas.height * 0.39))
    }, to: path)
}

do {
    guard CommandLine.arguments.count == 5 else { throw AssetError.usage }
    let master = try load(CommandLine.arguments[1])
    let glyph = try load(CommandLine.arguments[2])
    let appSet = CommandLine.arguments[3]
    let tvSet = CommandLine.arguments[4]

    let iconFiles: [(String, Int)] = [
        ("ios_1024.png", 1024),
        ("mac_16.png", 16), ("mac_16@2x.png", 32),
        ("mac_32.png", 32), ("mac_32@2x.png", 64),
        ("mac_128.png", 128), ("mac_128@2x.png", 256),
        ("mac_256.png", 256), ("mac_256@2x.png", 512),
        ("mac_512.png", 512), ("mac_512@2x.png", 1024)
    ]
    for (name, size) in iconFiles {
        try makeIcon(master: master, size: size, path: "\(appSet)/\(name)")
    }

    try makeTVBack(width: 400, height: 240,
                   path: "\(tvSet)/App Icon.imagestack/Back.imagestacklayer/Content.imageset/tv_bg_400.png")
    try makeTVFront(glyph: glyph, width: 400, height: 240,
                    path: "\(tvSet)/App Icon.imagestack/Front.imagestacklayer/Content.imageset/tv_glyph_400.png")
    try makeTVBack(width: 1280, height: 768,
                   path: "\(tvSet)/App Icon - App Store.imagestack/Back.imagestacklayer/Content.imageset/tv_bg_1280.png")
    try makeTVFront(glyph: glyph, width: 1280, height: 768,
                    path: "\(tvSet)/App Icon - App Store.imagestack/Front.imagestacklayer/Content.imageset/tv_glyph_1280.png")
    try makeTopShelf(glyph: glyph, width: 1920, height: 720,
                     path: "\(tvSet)/Top Shelf Image.imageset/tv_topshelf.png")
    try makeTopShelf(glyph: glyph, width: 2320, height: 720,
                     path: "\(tvSet)/Top Shelf Image Wide.imageset/tv_topshelf_wide.png")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
