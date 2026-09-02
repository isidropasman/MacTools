import AppKit
import Foundation

// Renders Pila.iconset. Run with: swift Tools/make-icon.swift <output-dir>

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./Pila.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func squircle(in rect: NSRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)
}

/// One sheet of the stack: a rounded card with a soft drop shadow.
func sheet(in rect: NSRect, radius: CGFloat, fill: NSColor, shadow: Bool) {
    if shadow {
        let context = NSGraphicsContext.current
        context?.saveGraphicsState()
        let dropShadow = NSShadow()
        dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        dropShadow.shadowBlurRadius = rect.width * 0.10
        dropShadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.045)
        dropShadow.set()
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        context?.restoreGraphicsState()
    } else {
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
}

func render(size: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)

    // macOS icons sit inside the canvas with breathing room rather than filling it edge to edge.
    let inset = size * 0.055
    let body = canvas.insetBy(dx: inset, dy: inset)

    let clip = squircle(in: body)
    clip.addClip()

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.38, green: 0.31, blue: 0.92, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.26, blue: 0.85, alpha: 1),
        NSColor(srgbRed: 0.72, green: 0.24, blue: 0.72, alpha: 1),
    ])
    gradient?.draw(in: body, angle: -68)

    // Subtle top-down sheen. A soft vertical wash reads as a lit surface; a curved blob reads as a smudge.
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.20),
        NSColor.white.withAlphaComponent(0.0),
    ])?.draw(in: body, angle: -90)

    // Three sheets cascading down-left by an even step, so the group reads as one stack.
    let sheetWidth = body.width * 0.48
    let sheetHeight = body.height * 0.30
    let radius = sheetWidth * 0.17
    let stepX = body.width * 0.052
    let stepY = body.height * 0.085

    // Centre the whole cascade, not the top sheet, so the mass sits on the canvas centre.
    let groupWidth = sheetWidth + stepX * 2
    let groupHeight = sheetHeight + stepY * 2
    let originX = body.midX - groupWidth / 2
    let originY = body.midY - groupHeight / 2

    let layers: [(alpha: CGFloat, index: CGFloat)] = [(0.42, 0), (0.68, 1), (1.0, 2)]
    for layer in layers {
        sheet(
            in: NSRect(
                x: originX + stepX * layer.index,
                y: originY + stepY * layer.index,
                width: sheetWidth,
                height: sheetHeight
            ),
            radius: radius,
            fill: NSColor.white.withAlphaComponent(layer.alpha),
            shadow: true
        )
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let data = render(size: variant.size) else {
        FileHandle.standardError.write("fallo \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: "\(outputDir)/\(variant.name).png"))
}

print("iconset escrito en \(outputDir) (\(variants.count) tamaños)")
