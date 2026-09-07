import AppKit
import QuickLookThumbnailing

/// Finder's own thumbnails. NSWorkspace.icon only returns the generic type icon, so a PDF looked
/// like "a PDF" instead of showing its first page.
@MainActor
final class ShelfThumbnails: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    private var pending: Set<String> = []

    func thumbnail(for url: URL, size: CGSize) -> NSImage? {
        if let cached = self.images[url.path] { return cached }
        self.request(url, size: size)
        return nil
    }

    private func request(_ url: URL, size: CGSize) {
        guard !self.pending.contains(url.path) else { return }
        self.pending.insert(url.path)

        // .all lets Quick Look answer with the file-type icon, which then gets scaled up and looks
        // mushy. Asking for a real thumbnail first, at twice the drawn size, keeps photos readable.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size.width * 2, height: size.height * 2),
            scale: scale,
            representationTypes: [.thumbnail, .lowQualityThumbnail, .icon]
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            Task { @MainActor in
                guard let self else { return }
                self.pending.remove(url.path)
                guard let representation else { return }
                // Quick Look answers inside the requested box but keeps the file's aspect ratio.
                // Forcing the square size onto it is what stretched every non-square thumbnail.
                let image = representation.cgImage
                let ratio = CGFloat(image.width) / CGFloat(image.height)
                let fitted = ratio > 1
                    ? CGSize(width: size.width, height: size.width / ratio)
                    : CGSize(width: size.height * ratio, height: size.height)
                self.images[url.path] = NSImage(cgImage: image, size: fitted)
            }
        }
    }

    func forget(_ url: URL) {
        self.images.removeValue(forKey: url.path)
    }
}
