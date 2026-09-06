import AppKit

extension NSImage {
    /// Average colour of the artwork, used to tint the player. Downscaling to a single pixel is
    /// the cheapest way to get it and runs off the main thread.
    func averageColor(completion: @escaping (NSColor?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let context = CGContext(
                      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let data = context.data else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let pixel = data.bindMemory(to: UInt8.self, capacity: 4)
            var color = NSColor(
                srgbRed: CGFloat(pixel[0]) / 255,
                green: CGFloat(pixel[1]) / 255,
                blue: CGFloat(pixel[2]) / 255,
                alpha: 1
            )
            // Album art is often near-black; lift it so the tint stays visible on a black panel.
            if let bright = color.usingColorSpace(.sRGB) {
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                bright.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                color = NSColor(hue: h, saturation: min(1, s * 1.25), brightness: max(0.55, b), alpha: 1)
            }
            DispatchQueue.main.async { completion(color) }
        }
    }
}
