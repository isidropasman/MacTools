import AppKit
import Combine

/// Reads and controls playback through each player's AppleScript dictionary.
/// Apple closed MediaRemote to third parties, and the usual workaround ships a private framework
/// plus a perl bridge. AppleScript covers Spotify and Music with no private API and no vendored blob.
@MainActor
final class MediaController: ObservableObject {
    struct Track: Equatable {
        var player: String
        var title: String
        var artist: String
        var album: String
        var isPlaying: Bool
        var artworkURL: String?
        var duration: Double
        var position: Double
        /// Spotify's dictionary has no playlist property, so this only fills in for Music.
        var playlist: String?
    }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var appIcon: NSImage?
    @Published private(set) var tint: NSColor?

    /// Position is sampled every couple of seconds; the view interpolates from here so the bar
    /// moves smoothly without polling AppleScript once a second.
    private(set) var sampledAt = Date()

    var elapsed: Double {
        guard let track else { return 0 }
        guard track.isPlaying else { return track.position }
        return min(track.duration, track.position + Date().timeIntervalSince(self.sampledAt))
    }

    private var timer: DispatchSourceTimer?
    private var artworkURL: String?

    private enum Player: String, CaseIterable {
        case spotify = "Spotify"
        case music = "Music"

        /// Music.app exposes artwork as raw data, not a URL, so only Spotify fills that field.
        var script: String {
            switch self {
            case .spotify:
                return """
                if application "Spotify" is running then
                  tell application "Spotify"
                    if player state is stopped then return "stopped"
                    set t to current track
                    return (player state as text) & "\\n" & (name of t) & "\\n" & (artist of t) & "\\n" & (album of t) & "\\n" & (artwork url of t) & "\\n" & ((duration of t) div 1000) & "\\n" & ((player position) as integer) & "\\n"
                  end tell
                end if
                return ""
                """
            case .music:
                return """
                if application "Music" is running then
                  tell application "Music"
                    if player state is stopped then return "stopped"
                    set t to current track
                    set pl to ""
                    try
                      set pl to name of current playlist
                    end try
                    return (player state as text) & "\\n" & (name of t) & "\\n" & (artist of t) & "\\n" & (album of t) & "\\n" & "" & "\\n" & ((duration of t) as integer) & "\\n" & ((player position) as integer) & "\\n" & pl
                  end tell
                end if
                return ""
                """
            }
        }
    }

    func start() {
        self.refresh()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        self.timer?.cancel()
        self.timer = nil
    }

    // MARK: - Controls

    func playPause() { self.control("playpause") }
    func next() { self.control("next track") }
    func previous() { self.control("previous track") }

    /// Both Spotify and Music accept `set player position to <seconds>`.
    func seek(to seconds: Double) {
        guard let player = track?.player else { return }
        let value = Int(max(0, seconds.rounded()))
        _ = Self.run("""
        if application "\(player)" is running then
          tell application "\(player)" to set player position to \(value)
        end if
        """)

        // Reflect it right away, otherwise the bar snaps back until the next poll lands.
        if var current = self.track {
            current.position = Double(value)
            self.track = current
            self.sampledAt = Date()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    private func control(_ command: String) {
        guard let player = track?.player else { return }
        _ = Self.run("""
        if application "\(player)" is running then
          tell application "\(player)" to \(command)
        end if
        """)
        // Spotify needs a beat before the new state is readable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refresh() }
    }

    // MARK: - Polling

    private func refresh() {
        for player in Player.allCases {
            guard let output = Self.run(player.script), !output.isEmpty, output != "stopped" else { continue }

            let parts = output.components(separatedBy: "\n")
            guard parts.count >= 4 else { continue }

            func field(_ index: Int) -> String { parts.count > index ? parts[index] : "" }

            // AppleScript formats numbers with the system decimal separator, and es_AR uses a comma,
            // which Double(_:) rejects. Normalise before parsing.
            func number(_ index: Int) -> Double {
                Double(field(index).replacingOccurrences(of: ",", with: ".")) ?? 0
            }

            let next = Track(
                player: player.rawValue,
                title: parts[1],
                artist: parts[2],
                album: parts[3],
                isPlaying: parts[0].lowercased().contains("playing"),
                artworkURL: field(4).isEmpty ? nil : field(4),
                duration: number(5),
                position: number(6),
                playlist: field(7).isEmpty ? nil : field(7)
            )
            self.sampledAt = Date()
            if next != self.track { self.track = next }
            self.loadArtworkIfNeeded(next.artworkURL)
            self.loadAppIconIfNeeded(player.rawValue)
            return
        }

        if self.track != nil {
            self.track = nil
            self.artwork = nil
            self.artworkURL = nil
            self.appIcon = nil
            self.tint = nil
        }
    }

    /// Brings the player forward, which is what tapping the track is asking for.
    func openPlayer() {
        guard let player = track?.player else { return }
        for path in ["/Applications/\(player).app", "/System/Applications/\(player).app"]
        where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
    }

    /// The real app icon beats bundling a trademarked logo, and it stays correct if the app rebrands.
    private func loadAppIconIfNeeded(_ player: String) {
        guard self.appIcon == nil || self.track?.player != player else { return }
        for path in ["/Applications/\(player).app", "/System/Applications/\(player).app"]
        where FileManager.default.fileExists(atPath: path) {
            self.appIcon = NSWorkspace.shared.icon(forFile: path)
            return
        }
    }

    private func loadArtworkIfNeeded(_ urlString: String?) {
        guard self.artworkURL != urlString else { return }
        self.artworkURL = urlString

        guard let urlString, let url = URL(string: urlString) else {
            self.artwork = nil
            self.tint = nil
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            Task { @MainActor in
                guard self?.artworkURL == urlString else { return }
                self?.artwork = image
                image.averageColor { color in
                    guard self?.artworkURL == urlString else { return }
                    self?.tint = color
                }
            }
        }.resume()
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil { return nil }
        return result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
