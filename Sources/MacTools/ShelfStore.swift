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
        guard self.items.contains(url) else { return }
        self.items.removeAll { $0 == url }

        Task { [weak self] in
            let removed = await Task.detached(priority: .utility) {
                Self.removeItem(at: url)
            }.value
            guard !removed else { return }
            self?.reload()
        }
    }

    func clear() {
        self.items = []
        let directory = Self.directory

        Task { [weak self] in
            let cleared = await Task.detached(priority: .utility) {
                Self.emptyDirectory(at: directory)
            }.value
            guard !cleared else { return }
            self?.reload()
        }
    }

    var totalBytes: Int64 {
        self.items.reduce(0) { total, url in
            Int64((try? url.resourceValues(forKeys: [.totalFileSizeKey]).totalFileSize) ?? 0) + total
        }
    }

    static func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    private nonisolated static func removeItem(at url: URL) -> Bool {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func emptyDirectory(at directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return false }

        var succeeded = true
        for item in contents {
            do {
                // Older builds copied folders without execute permission, preventing traversal.
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: item.path)
                try FileManager.default.removeItem(at: item)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }
}
