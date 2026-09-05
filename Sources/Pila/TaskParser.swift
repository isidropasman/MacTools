import Foundation

/// One line in, structure out. A form with six fields would be "customisable" and unusable; the
/// tokens keep every field optional and reachable without leaving the keyboard.
///
///   Revisar el deck #plexo @Keynote !review en 25m
enum TaskParser {
    struct Parsed: Equatable {
        var title: String
        var project: String?
        /// "#plexo/code" splits into project and section.
        var section: String?
        var type: String?
        var app: String?
        var priority: Int?
        var due: Date?
    }

    /// p1 is the one you do now, p3 the one you might. Anything else stays part of the title.
    static let priorityTokens = ["p1": 1, "p2": 2, "p3": 3]

    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> Parsed {
        var project: String?
        var section: String?
        var type: String?
        var app: String?
        var priority: Int?
        var words: [String] = []

        for token in input.split(separator: " ") {
            let text = String(token)
            if let level = Self.priorityTokens[text.lowercased()] {
                priority = level
                continue
            }
            switch text.first {
            case "#" where text.count > 1:
                let body = String(text.dropFirst())
                let parts = body.split(separator: "/", maxSplits: 1)
                project = String(parts[0])
                section = parts.count > 1 ? String(parts[1]) : nil
            case "!" where text.count > 1: type = String(text.dropFirst())
            case "@" where text.count > 1: app = String(text.dropFirst())
            default: words.append(text)
            }
        }

        let (title, due) = self.extractDue(from: words.joined(separator: " "), now: now, calendar: calendar)

        return Parsed(
            title: title.trimmingCharacters(in: .whitespaces),
            project: project,
            section: section,
            type: type,
            app: app,
            priority: priority,
            due: due
        )
    }

    /// Recognised, in order: "en 25m" / "en 2h", "mañana 9:00", "hoy 18:30", "9:00".
    /// Anything unrecognised stays in the title rather than being silently eaten.
    private static func extractDue(from text: String, now: Date, calendar: Calendar) -> (String, Date?) {
        let lower = text.lowercased()

        // Relative: en 25m, en 2h, en 90 min
        if let range = lower.range(of: #"\ben (\d+)\s*(m|min|minutos?|h|hs?|horas?)\b"#, options: .regularExpression) {
            let chunk = String(lower[range])
            let digits = chunk.filter(\.isNumber)
            if let amount = Int(digits) {
                let isHours = chunk.contains("h")
                let due = now.addingTimeInterval(TimeInterval(amount * (isHours ? 3600 : 60)))
                return (self.removing(range, from: text), due)
            }
        }

        // Absolute: [mañana|hoy] HH:MM, or a bare HH:MM meaning today (tomorrow once it is past).
        if let range = lower.range(of: #"\b(mañana|manana|hoy)?\s*(\d{1,2}):(\d{2})\b"#, options: .regularExpression) {
            let chunk = String(lower[range])
            let parts = chunk.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if parts.count == 2 {
                var components = calendar.dateComponents([.year, .month, .day], from: now)
                components.hour = parts[0]
                components.minute = parts[1]

                if var due = calendar.date(from: components) {
                    if chunk.contains("mañana") || chunk.contains("manana") {
                        due = calendar.date(byAdding: .day, value: 1, to: due) ?? due
                    } else if due <= now {
                        // A time already past today means the next one, not one in the past.
                        due = calendar.date(byAdding: .day, value: 1, to: due) ?? due
                    }
                    return (self.removing(range, from: text), due)
                }
            }
        }

        return (text, nil)
    }

    private static func removing(_ range: Range<String.Index>, from text: String) -> String {
        let lower = text.lowercased()
        guard let start = lower.distance(from: lower.startIndex, to: range.lowerBound) as Int?,
              let end = lower.distance(from: lower.startIndex, to: range.upperBound) as Int?
        else { return text }

        var result = Array(text)
        result.removeSubrange(start ..< end)
        return String(result).replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
