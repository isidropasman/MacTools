import AppKit

enum MenuBarIcon {
    /// Drawn rather than shipped as an asset: SPM has no asset catalog, and a template image
    /// lets macOS tint it for light and dark menu bars automatically.
    static func make() -> NSImage {
        let size = NSSize(width: 17, height: 15)
        let image = NSImage(size: size, flipped: false) { _ in
            let sheetSize = NSSize(width: 10.5, height: 7.5)
            let stepX: CGFloat = 3.0
            let stepY: CGFloat = 2.6

            for index in 0 ..< 3 {
                let offset = CGFloat(index)
                let rect = NSRect(
                    x: 0.75 + stepX * offset,
                    y: 1.0 + stepY * offset,
                    width: sheetSize.width,
                    height: sheetSize.height
                )
                let path = NSBezierPath(roundedRect: rect, xRadius: 2.0, yRadius: 2.0)

                if index < 2 {
                    // Knock the lower sheets out of the one above so the cascade stays legible at 15pt.
                    NSColor.black.setStroke()
                    path.lineWidth = 1.3
                    path.stroke()
                } else {
                    NSColor.black.setFill()
                    path.fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
