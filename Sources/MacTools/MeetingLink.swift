import Foundation

/// Finds the video call in an event. Google puts Meet links in `url`, but plenty of invitations
/// only carry them in the location or buried in the notes, so all three are scanned.
enum MeetingLink {
    struct Match: Equatable {
        let url: URL
        let provider: String
    }

    private static let providers: [(host: String, name: String)] = [
        ("meet.google.com", "Meet"),
        ("zoom.us", "Zoom"),
        ("teams.microsoft.com", "Teams"),
        ("teams.live.com", "Teams"),
        ("whereby.com", "Whereby"),
        ("meet.jit.si", "Jitsi"),
        ("webex.com", "Webex"),
        ("chime.aws", "Chime"),
    ]

    static func find(in candidates: [String?]) -> Match? {
        for text in candidates.compactMap({ $0 }) where !text.isEmpty {
            // Splitting on whitespace and markup beats a regex here: invitation bodies are HTML
            // soup and the escaping rules get unreadable fast.
            let tokens = text.split(whereSeparator: { $0.isWhitespace || "<>\"'()[]".contains($0) })

            for token in tokens {
                let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
                guard trimmed.lowercased().hasPrefix("http"),
                      let url = URL(string: trimmed),
                      let host = url.host?.lowercased()
                else { continue }

                for provider in self.providers where host == provider.host || host.hasSuffix("." + provider.host) {
                    return Match(url: url, provider: provider.name)
                }
            }
        }
        return nil
    }
}
