import AppKit
import Foundation

enum ClipKind: String {
    case text
    case image
}

enum ClipSource: String {
    case clipboard
    case fluidvoice
}

struct ClipItem: Identifiable, Equatable {
    let id: Int64
    let kind: ClipKind
    let text: String?
    let imagePath: String?
    let thumbPath: String?
    let source: ClipSource
    let sourceApp: String?
    let byteSize: Int64
    let pinned: Bool
    let favorite: Bool
    let createdAt: Date
    let updatedAt: Date
    let title: String?

    var preview: String {
        if let title, !title.isEmpty { return title }
        switch self.kind {
        case .text:
            let collapsed = (self.text ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.count > 140 ? String(collapsed.prefix(140)) + "…" : collapsed
        case .image:
            return "Imagen \(ByteCountFormatter.string(fromByteCount: self.byteSize, countStyle: .file))"
        }
    }

    /// Whole minutes under an hour, whole hours under a day. Seconds are noise in a history list.
    var age: String {
        let seconds = max(0, Date().timeIntervalSince(self.updatedAt))
        switch seconds {
        case ..<60: return "ahora"
        case ..<3600: return "\(Int(seconds / 60)) min"
        case ..<86400: return "\(Int(seconds / 3600)) h"
        default: return "\(Int(seconds / 86400)) d"
        }
    }

    var thumbnail: NSImage? {
        guard let thumbPath else { return nil }
        return NSImage(contentsOfFile: thumbPath)
    }
}
