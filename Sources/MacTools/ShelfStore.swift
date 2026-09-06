import AppKit
import Combine

/// Files parked in the notch. Dropped files are copied in, so moving or deleting the original
/// does not empty the shelf.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [URL] = []

    static let directory = Store.supportDirectory.appendingPathComponent("shelf", isDirectory: true)

    init() {
        try? FileManager.default.createDirectory(
            at: Self.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.reload()
    }

    func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        self.items = contents.sorted { left, right in
            let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
    }

    @discardableResult
    func add(_ source: URL) -> Bool {
        var destination = Self.directory.appendingPathComponent(source.lastPathComponent)

        // Keep both when a name repeats instead of silently replacing the earlier file.
        var attempt = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            let name = ext.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(ext)"
            destination = Self.directory.appendingPathComponent(name)
            attempt += 1
        }

        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            self.reload()
            return true
        } catch {
            return false
        }
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        self.reload()
    }

    func clear() {
        for item in self.items { try? FileManager.default.removeItem(at: item) }
        self.reload()
    }

    static func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}
