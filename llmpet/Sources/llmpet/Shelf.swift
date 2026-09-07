import Foundation

/// Pins and dismissals. A dismissal is remembered together with the activity
/// timestamp it was made at, so hiding a finished session is not the same as
/// muting it forever — the moment it does something new it comes back.
struct Shelf {
    private static let pinnedKey = "pinnedSessions"
    private static let dismissedKey = "dismissedSessions"

    static var pinned: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: pinnedKey) }
    }

    private static var dismissed: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: dismissedKey) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: dismissedKey) }
    }

    static func togglePin(_ id: String) {
        var next = pinned
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        pinned = next
    }

    static func dismiss(_ session: LLMSession) {
        var next = dismissed
        next[session.id] = session.lastActivity.timeIntervalSince1970
        // Keep the map from growing without bound across months of use.
        if next.count > 500 {
            let keep = next.sorted { $0.value > $1.value }.prefix(300)
            next = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        dismissed = next
    }

    static func isHidden(_ session: LLMSession) -> Bool {
        guard let at = dismissed[session.id] else { return false }
        return session.lastActivity.timeIntervalSince1970 <= at
    }
}
