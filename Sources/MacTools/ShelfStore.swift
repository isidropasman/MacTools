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
            // A directory needs its execute bit or nothing can traverse it, including the delete
            // that empties the shelf.
            let isDirectory = (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            try? FileManager.default.setAttributes(
                [.posixPermissions: isDirectory ? 0o700 : 0o600],
                ofItemAtPath: destination.path
            )
            self.reload()
            return true
        } catch {
            return false
        }
    }

    func remove(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
        self.reload()
    }

    func clear() {
        // Sweeps the folder rather than the list: anything the list failed to show still has to go.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        for item in contents {
            // Folders copied by older builds landed without their execute bit, which made them
            // impossible to traverse and so impossible to delete.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: item.path)
            try? FileManager.default.removeItem(at: item)
        }
        self.reload()
    }

    var totalBytes: Int64 {
        self.items.reduce(0) { total, url in
            Int64((try? url.resourceValues(forKeys: [.totalFileSizeKey]).totalFileSize) ?? 0) + total
        }
    }

    static func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}
