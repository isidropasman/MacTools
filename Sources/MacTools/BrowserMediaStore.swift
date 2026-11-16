import Combine
import Foundation

@MainActor
final class BrowserMediaStore: ObservableObject {
    struct Target: Equatable, Sendable {
        let clientID: UUID
        let tabID: Int
        let videoID: String
    }

    struct Snapshot: Decodable, Equatable, Sendable {
        let videoID: String
        let title: String
        let artist: String
        let duration: Double
        let position: Double
        let playbackRate: Double
        let isPlaying: Bool
        let isLive: Bool
        let isBuffering: Bool
        let canSeek: Bool
        let canGoPrevious: Bool
        let canGoNext: Bool

        var isValid: Bool {
            self.videoID.utf8.count == 11
                && self.videoID.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
                && !self.title.isEmpty && self.title.count <= 1000 && self.artist.count <= 300
                && self.duration.isFinite && self.duration >= 0
                && self.position.isFinite && self.position >= 0
                && self.playbackRate.isFinite && (0...16).contains(self.playbackRate)
        }
    }

    struct Playback: Equatable {
        let target: Target
        let snapshot: Snapshot
        let sampledAt: Date
        let startedAt: Date
    }

    enum Action: String, Encodable {
        case playPause, previous, next, seek, focus
    }

    struct Command: Encodable {
        let kind = "command"
        let id = UUID()
        let tabID: Int
        let videoID: String
        let action: Action
        let position: Double?
    }

    private struct Key: Hashable {
        let clientID: UUID
        let tabID: Int
    }

    @Published private(set) var playback: Playback?
    var onCommand: ((Target, Command) -> Void)?
    private var entries: [Key: Playback] = [:]
    private var timer: DispatchSourceTimer?

    func start() {
        guard self.timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in self?.expire() }
        timer.resume()
        self.timer = timer
    }

    @discardableResult
    func receive(_ snapshot: Snapshot, clientID: UUID, tabID: Int, now: Date = Date()) -> Bool {
        guard snapshot.isValid, (0...Int(Int32.max)).contains(tabID) else { return false }
        let key = Key(clientID: clientID, tabID: tabID)
        guard self.entries[key] != nil || self.entries.count < 256 else { return false }
        let previous = self.entries[key]
        let startedAt = snapshot.isPlaying && previous?.snapshot.isPlaying != true
            ? now : (previous?.startedAt ?? now)
        self.entries[key] = Playback(
            target: Target(clientID: clientID, tabID: tabID, videoID: snapshot.videoID),
            snapshot: snapshot, sampledAt: now, startedAt: startedAt
        )
        self.publish()
        return true
    }

    func remove(clientID: UUID, tabID: Int? = nil) {
        self.entries = self.entries.filter { key, _ in
            key.clientID != clientID || (tabID != nil && key.tabID != tabID)
        }
        self.publish()
    }

    func expire(now: Date = Date()) {
        self.entries = self.entries.filter { now.timeIntervalSince($0.value.sampledAt) < 15 }
        self.publish()
    }

    func send(_ action: Action, to target: Target, position: Double? = nil) {
        guard let entry = self.entries[Key(clientID: target.clientID, tabID: target.tabID)],
              entry.target == target, Date().timeIntervalSince(entry.sampledAt) < 15
        else { return }
        if action == .seek {
            guard entry.snapshot.canSeek, let position, position.isFinite,
                  position >= 0, position <= entry.snapshot.duration
            else { return }
        }
        if action == .previous && !entry.snapshot.canGoPrevious { return }
        if action == .next && !entry.snapshot.canGoNext { return }
        self.onCommand?(target, Command(tabID: target.tabID, videoID: target.videoID, action: action, position: position))
    }

    private func publish() {
        let playing = self.entries.values.filter { $0.snapshot.isPlaying }
            .max { $0.startedAt < $1.startedAt }
        let previous = self.playback.flatMap { self.entries[Key(clientID: $0.target.clientID, tabID: $0.target.tabID)] }
        let next = playing ?? previous ?? self.entries.values.max { $0.sampledAt < $1.sampledAt }
        if next != self.playback { self.playback = next }
    }
}
