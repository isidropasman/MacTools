import Foundation

/// Every Google account added through Internet Accounts reports its EKSource title as literally
/// "Google", so the source name cannot tell two work accounts apart. The account's own calendars
/// carry the address, and the user can always override the result by hand.
enum AccountLabels {
    private static let key = "CalendarAccountLabels"

    static func custom() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: self.key) as? [String: String] ?? [:]
    }

    static func setCustom(_ label: String, for sourceID: String) {
        var all = self.custom()
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { all.removeValue(forKey: sourceID) } else { all[sourceID] = trimmed }
        UserDefaults.standard.set(all, forKey: self.key)
    }

    /// Prefers the domain of any calendar named after an address; falls back to the source title.
    static func derive(sourceTitle: String, calendarTitles: [String]) -> String {
        for title in calendarTitles {
            guard let at = title.firstIndex(of: "@") else { continue }
            let domain = title[title.index(after: at)...]
            if let first = domain.split(separator: ".").first, first.count > 1 {
                return String(first)
            }
        }
        return sourceTitle
    }

    static func label(sourceID: String, sourceTitle: String, calendarTitles: [String]) -> String {
        self.custom()[sourceID] ?? self.derive(sourceTitle: sourceTitle, calendarTitles: calendarTitles)
    }
}
