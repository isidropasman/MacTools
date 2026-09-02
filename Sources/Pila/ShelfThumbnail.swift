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

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .all
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            Task { @MainActor in
                guard let self else { return }
                self.pending.remove(url.path)
                guard let representation else { return }
                self.images[url.path] = NSImage(cgImage: representation.cgImage, size: size)
            }
        }
    }

    func forget(_ url: URL) {
        self.images.removeValue(forKey: url.path)
    }
}
