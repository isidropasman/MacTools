import AppKit
import Foundation

/// Claude Desktop persists each Claude Code session it runs as
/// ~/Library/Application Support/Claude/claude-code-sessions/<org>/<user>/local_*.json
/// with a title, cwd and lastActivityAt — so those sessions are visible after all.
///
/// Regular chat conversations in the same app are NOT here: they live server-side
/// behind a webview, and nothing on disk says whether one is streaming.
struct ClaudeDesktopSource: SessionSource {
    private static let root = NSHomeDirectory()
        + "/Library/Application Support/Claude/claude-code-sessions"

    /// No field says "running", but the CLI transcript is appended to while the
    /// model streams, so a transcript touched seconds ago means it is working.
    private let workingWindow: TimeInterval = 20
    private let maxAge: TimeInterval = 24 * 3600

    func poll(includeTokens: Bool) -> [LLMSession] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: Self.root) else { return [] }

        var out: [LLMSession] = []
        for case let relative as String in walker {
            let name = (relative as NSString).lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }

            let path = Self.root + "/" + relative
            guard let data = fm.contents(atPath: path),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  raw["isArchived"] as? Bool != true,
                  let id = raw["sessionId"] as? String
            else { continue }

            // lastActivityAt is milliseconds since epoch.
            let millis = raw["lastActivityAt"] as? Double ?? 0
            let activity = Date(timeIntervalSince1970: millis / 1000)
            guard Date().timeIntervalSince(activity) < maxAge else { continue }

            let cliID = raw["cliSessionId"] as? String ?? ""
            let streaming = TranscriptIndex.shared.lastWrite(sessionID: cliID)
                .map { Date().timeIntervalSince($0) < workingWindow } ?? false

            let cwd = raw["cwd"] as? String ?? ""
            out.append(LLMSession(
                id: "claude-desktop:" + id,
                title: raw["title"] as? String ?? "Sin título",
                source: "claude-desktop",
                context: cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                state: streaming ? .working : .seen,
                openURL: nil,  // no known deep link; clicking just raises the app
                appPath: "/Applications/Claude.app",
                faviconURL: nil,
                tabID: nil,
                lastActivity: activity,
                activeSince: streaming ? activity : nil,
                tokens: includeTokens ? TranscriptIndex.shared.usage(sessionID: cliID) : nil,
                agent: "Claude Code",
                origin: "Claude Desktop"
            ))
        }
        return out
    }
}
