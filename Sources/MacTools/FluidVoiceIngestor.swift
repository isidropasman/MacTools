import Foundation

/// Pulls dictations straight out of FluidVoice's own history so they are captured even though
/// FluidVoice restores the clipboard after pasting (Clipboard Paste mode), which the watcher would miss.
final class FluidVoiceIngestor {
    private struct Entry: Decodable {
        let id: String
        let timestamp: Double
        let processedText: String
        let appName: String
    }

    private static let appID = "com.FluidApp.app" as CFString
    private static let historyKey = "TranscriptionHistoryEntries" as CFString
    private static let saveEnabledKey = "SaveTranscriptionHistory" as CFString

    private let store: Store
    private let onChange: (Bool) -> Void
    private var timer: DispatchSourceTimer?

    private(set) var isHistoryDisabled = false

    /// Every id already stored. Without this the ingestor asked SQLite once per dictation, every
    /// three seconds, forever: 44 queries a cycle at the time this was written, growing with use.
    private var knownIDs: Set<String> = []

    init(store: Store, onChange: @escaping (Bool) -> Void) {
        self.store = store
        self.onChange = onChange
    }

    func start() {
        self.knownIDs = self.store.externalIDs()
        self.ingest()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.ingest() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        self.timer?.cancel()
        self.timer = nil
    }

    private func ingest() {
        CFPreferencesAppSynchronize(Self.appID)

        // Absent key means the default (true) applies; only an explicit false disables history.
        if let raw = CFPreferencesCopyAppValue(Self.saveEnabledKey, Self.appID) as? Bool {
            self.isHistoryDisabled = !raw
        } else {
            self.isHistoryDisabled = false
        }

        // Reported every cycle so the banner tracks FluidVoice even when nothing new arrives.
        guard Settings.ingestDictationsNow else {
            DispatchQueue.main.async { self.onChange(false) }
            return
        }

        guard let data = CFPreferencesCopyAppValue(Self.historyKey, Self.appID) as? Data,
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            DispatchQueue.main.async { self.onChange(false) }
            return
        }

        var inserted = false
        for entry in entries.reversed() {
            guard !self.knownIDs.contains(entry.id) else { continue }
            let text = entry.processedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // FluidVoice encodes Date as seconds since 2001-01-01, not since the Unix epoch.
            let date = Date(timeIntervalSinceReferenceDate: entry.timestamp)
            if self.store.upsertText(
                entry.processedText,
                source: .fluidvoice,
                sourceApp: entry.appName,
                externalID: entry.id,
                at: date
            ) {
                inserted = true
            }
            // Marked either way: a duplicate by content still claims the id, and retrying it every
            // cycle is exactly the loop this cache exists to kill.
            self.knownIDs.insert(entry.id)
        }

        DispatchQueue.main.async { self.onChange(inserted) }
    }
}
