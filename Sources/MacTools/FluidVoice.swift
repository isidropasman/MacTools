import AppKit
import Foundation

/// FluidVoice stays a separate process: it carries the speech models and the audio pipeline, and
/// vendoring that would fork it away from upstream. What lives here is the control surface, so its
/// settings, its state and its updates are in the same place as everything else.
@MainActor
final class FluidVoiceControl: ObservableObject {
    static let bundleID = "com.FluidApp.app"
    static let appPath = "/Applications/FluidVoice.app"
    private static let repo = "altic-dev/FluidVoice"

    @Published private(set) var installedVersion: String?
    @Published private(set) var isRunning = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var checking = false
    @Published private(set) var checkError: String?

    private var timer: Timer?

    init() {
        self.refresh()
        // Cheap enough to just poll: two plist reads and a process lookup.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var isInstalled: Bool { self.installedVersion != nil }

    var hasUpdate: Bool {
        guard let installed = installedVersion, let latest = latestVersion else { return false }
        return Self.compare(latest, installed) == .orderedDescending
    }

    func refresh() {
        let version = Bundle(path: Self.appPath)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if self.installedVersion != version { self.installedVersion = version }

        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        if self.isRunning != running { self.isRunning = running }
    }

    func launch() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Self.appPath))
    }

    func quit() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID) {
            app.terminate()
        }
    }

    // MARK: - Settings

    /// FluidVoice reads its own defaults at launch, so a change lands on the next start. Writing
    /// them from here still beats hunting for the setting inside a second app.
    func string(_ key: String) -> String? {
        CFPreferencesCopyAppValue(key as CFString, Self.bundleID as CFString) as? String
    }

    func bool(_ key: String, default fallback: Bool = false) -> Bool {
        CFPreferencesCopyAppValue(key as CFString, Self.bundleID as CFString) as? Bool ?? fallback
    }

    func set(_ value: Any?, for key: String) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, Self.bundleID as CFString)
        CFPreferencesAppSynchronize(Self.bundleID as CFString)
        self.objectWillChange.send()
    }

    // MARK: - Updates

    func checkForUpdate() {
        guard !self.checking else { return }
        self.checking = true
        self.checkError = nil

        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                self.checking = false
                if let error {
                    self.checkError = error.localizedDescription
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String
                else {
                    self.checkError = "GitHub no contestó una versión"
                    return
                }
                self.latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            }
        }.resume()
    }

    func openReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(Self.repo)/releases/latest")!)
    }

    /// "1.6.10" is newer than "1.6.9"; a plain string compare says otherwise.
    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}
