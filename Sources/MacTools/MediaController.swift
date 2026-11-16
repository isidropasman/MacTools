import AppKit
import Combine

/// Native players use AppleScript; browser playback stays in its existing tab through the extension.
@MainActor
final class MediaController: ObservableObject {
    struct Track: Equatable, Sendable {
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
        var browserTarget: BrowserMediaStore.Target? = nil
        var playbackRate: Double = 1
        var isLive = false
        var isBuffering = false
        var canSeek = true
        var canGoPrevious = true
        var canGoNext = true
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
        guard track.isPlaying, !track.isBuffering else { return track.position }
        return min(track.duration, track.position + Date().timeIntervalSince(self.sampledAt) * track.playbackRate)
    }

    nonisolated static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var timer: DispatchSourceTimer?
    private var artworkURL: String?
    private var appIconPlayer: String?
    private let scriptQueue = DispatchQueue(label: "com.zent.mactools.media-scripts")
    private var isPolling = false
    private let browserMedia: BrowserMediaStore?
    private var browserSubscription: AnyCancellable?
    private var nativeTrack: Track?
    private var nativeSampledAt = Date()
    private var nativeStartedAt = Date.distantPast

    init(browserMedia: BrowserMediaStore? = nil) {
        self.browserMedia = browserMedia
        self.browserSubscription = browserMedia?.$playback
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.selectTrack() }
    }

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
        guard let track, track.canSeek, seconds.isFinite else { return }
        let value = min(track.duration, max(0, seconds))
        if let target = track.browserTarget {
            self.browserMedia?.send(.seek, to: target, position: value)
            return
        }
        let player = track.player
        self.runScript("""
        if application "\(player)" is running then
          tell application "\(player)" to set player position to \(Int(value.rounded()))
        end if
        """, refreshAfter: 0.3)

        // Reflect it right away, otherwise the bar snaps back until the next poll lands.
        if var current = self.track {
            current.position = value
            self.track = current
            self.sampledAt = Date()
        }
    }

    private func control(_ command: String) {
        guard let track else { return }
        if let target = track.browserTarget {
            let action: BrowserMediaStore.Action
            switch command {
            case "playpause": action = .playPause
            case "next track": action = .next
            case "previous track": action = .previous
            default: return
            }
            self.browserMedia?.send(action, to: target)
            return
        }
        let player = track.player
        self.runScript("""
        if application "\(player)" is running then
          tell application "\(player)" to \(command)
        end if
        """, refreshAfter: 0.35)
    }

    // MARK: - Polling

    private func refresh() {
        guard !self.isPolling else { return }
        self.isPolling = true
        let scripts = Player.allCases.map { (player: $0.rawValue, script: $0.script) }
        let scriptQueue = self.scriptQueue
        scriptQueue.async { [weak self] in
            let next = Self.readTrack(scripts)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPolling = false
                if next?.isPlaying == true && (self.nativeTrack?.isPlaying != true || self.nativeTrack?.player != next?.player) {
                    self.nativeStartedAt = Date()
                }
                self.nativeTrack = next
                self.nativeSampledAt = Date()
                self.selectTrack()
            }
        }
    }

    private func runScript(_ source: String, refreshAfter delay: TimeInterval) {
        let scriptQueue = self.scriptQueue
        scriptQueue.async { [weak self] in
            _ = Self.run(source)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    private func selectTrack() {
        let browser = self.browserMedia?.playback
        let browserWins = browser.map {
            $0.snapshot.isPlaying && (self.nativeTrack?.isPlaying != true || $0.startedAt >= self.nativeStartedAt)
        } ?? false
        if let browser, browserWins || (self.nativeTrack?.isPlaying != true && (self.track?.browserTarget != nil || self.nativeTrack == nil)) {
            let source = browser.snapshot
            self.apply(Track(
                player: "YouTube", title: source.title, artist: source.artist, album: "YouTube",
                isPlaying: source.isPlaying,
                artworkURL: "https://i.ytimg.com/vi/\(source.videoID)/hqdefault.jpg",
                duration: source.duration, position: source.position, playlist: nil,
                browserTarget: browser.target, playbackRate: source.playbackRate,
                isLive: source.isLive, isBuffering: source.isBuffering,
                canSeek: source.canSeek, canGoPrevious: source.canGoPrevious, canGoNext: source.canGoNext
            ), sampledAt: browser.sampledAt)
        } else {
            self.apply(self.nativeTrack, sampledAt: self.nativeSampledAt)
        }
    }

    private func apply(_ next: Track?, sampledAt: Date) {
        guard let next else {
            if self.track != nil {
                self.track = nil
                self.artwork = nil
                self.artworkURL = nil
                self.appIcon = nil
                self.appIconPlayer = nil
                self.tint = nil
            }
            return
        }
        self.sampledAt = sampledAt
        if next != self.track { self.track = next }
        self.loadArtworkIfNeeded(next.artworkURL)
        self.loadAppIconIfNeeded(next.player)
    }

    private nonisolated static func readTrack(_ scripts: [(player: String, script: String)]) -> Track? {
        var pausedTrack: Track?
        for (player, script) in scripts {
            guard let output = Self.run(script), !output.isEmpty, output != "stopped" else { continue }
            let parts = output.components(separatedBy: "\n")
            guard parts.count >= 4 else { continue }

            func field(_ index: Int) -> String { parts.count > index ? parts[index] : "" }
            func number(_ index: Int) -> Double {
                Double(field(index).replacingOccurrences(of: ",", with: ".")) ?? 0
            }
            let track = Track(
                player: player,
                title: parts[1],
                artist: parts[2],
                album: parts[3],
                isPlaying: parts[0].lowercased().contains("playing"),
                artworkURL: field(4).isEmpty ? nil : field(4),
                duration: number(5),
                position: number(6),
                playlist: field(7).isEmpty ? nil : field(7)
            )
            if track.isPlaying { return track }
            if pausedTrack == nil { pausedTrack = track }
        }
        return pausedTrack
    }

    /// Brings the player forward, which is what tapping the track is asking for.
    func openPlayer() {
        guard let track else { return }
        if let target = track.browserTarget {
            self.browserMedia?.send(.focus, to: target)
            return
        }
        let player = track.player
        for path in ["/Applications/\(player).app", "/System/Applications/\(player).app"]
        where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
    }

    /// The real app icon beats bundling a trademarked logo, and it stays correct if the app rebrands.
    private func loadAppIconIfNeeded(_ player: String) {
        guard self.appIconPlayer != player else { return }
        self.appIconPlayer = player
        self.appIcon = nil
        if player == "YouTube" {
            self.appIcon = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: "YouTube")
            return
        }
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

    private nonisolated static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil { return nil }
        return result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
