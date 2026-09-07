import AppKit
import Carbon.HIToolbox
import Combine

extension Notification.Name {
    /// Jumps the settings window to the connector list from anywhere that mentions them.
    static let mactoolsShowAgents = Notification.Name("MacToolsShowAgents")
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let keyCode = "HotKeyCode"
        static let modifiers = "HotKeyModifiers"
        static let pasteOnPick = "PasteOnPick"
        static let maxImages = "MaxImages"
        static let maxTexts = "MaxTexts"
        static let maxImageGB = "MaxImageGB"
        static let ingestDictations = "IngestDictations"
        static let useNotch = "UseNotch"
        static let peekOnTrackChange = "PeekOnTrackChange"
        static let hideFromCapture = "HideFromCapture"
        static let hoverDelay = "HoverDelay"
        static let rememberLastTab = "RememberLastTab"
        static let welcomeShown = "WelcomeShown"
        static let language = "AppleLanguages"
        static let lastTab = "LastTab"
    }

    /// Fires when any shortcut changes so the app can re-register them.
    let hotKeyChanged = PassthroughSubject<Void, Never>()

    /// Bumped on every shortcut edit so SwiftUI redraws the rows.
    @Published private(set) var shortcutRevision = 0

    struct Shortcut: Equatable {
        var key: UInt32
        var modifiers: UInt32
    }

    func shortcut(for tool: Tool) -> Shortcut? {
        // The clipboard shortcut predates this table, so its original keys stay authoritative.
        if tool == .history {
            return Shortcut(key: self.keyCode, modifiers: self.modifiers)
        }
        if self.defaults.bool(forKey: Self.clearedKey(tool)) { return nil }
        guard let key = defaults.object(forKey: Self.shortcutKey(tool)) as? Int,
              let modifiers = defaults.object(forKey: Self.modifiersKey(tool)) as? Int
        else {
            return tool.defaultShortcut.map { Shortcut(key: $0.key, modifiers: $0.modifiers) }
        }
        return Shortcut(key: UInt32(key), modifiers: UInt32(modifiers))
    }

    func setShortcut(_ shortcut: Shortcut?, for tool: Tool) {
        if tool == .history {
            guard let shortcut else { return }
            self.keyCode = shortcut.key
            self.modifiers = shortcut.modifiers
            self.shortcutRevision += 1
            return
        }
        if let shortcut {
            self.defaults.set(Int(shortcut.key), forKey: Self.shortcutKey(tool))
            self.defaults.set(Int(shortcut.modifiers), forKey: Self.modifiersKey(tool))
            self.defaults.set(false, forKey: Self.clearedKey(tool))
        } else {
            self.defaults.set(true, forKey: Self.clearedKey(tool))
        }
        self.shortcutRevision += 1
        self.hotKeyChanged.send()
    }

    func display(_ shortcut: Shortcut) -> String {
        var parts = ""
        if shortcut.modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if shortcut.modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + Self.keyName(shortcut.key)
    }

    private static func shortcutKey(_ tool: Tool) -> String { "Shortcut.\(tool.rawValue).key" }
    private static func modifiersKey(_ tool: Tool) -> String { "Shortcut.\(tool.rawValue).modifiers" }
    private static func clearedKey(_ tool: Tool) -> String { "Shortcut.\(tool.rawValue).cleared" }

    @Published var keyCode: UInt32 {
        didSet {
            self.defaults.set(Int(self.keyCode), forKey: Key.keyCode)
            self.shortcutRevision += 1
            self.hotKeyChanged.send()
        }
    }

    @Published var modifiers: UInt32 {
        didSet { self.defaults.set(Int(self.modifiers), forKey: Key.modifiers); self.hotKeyChanged.send() }
    }

    @Published var pasteOnPick: Bool {
        didSet { self.defaults.set(self.pasteOnPick, forKey: Key.pasteOnPick) }
    }

    @Published var maxImages: Int {
        didSet { self.defaults.set(self.maxImages, forKey: Key.maxImages) }
    }

    /// The text history used to grow forever. 5000 entries is years of copying.
    @Published var maxTexts: Int {
        didSet { self.defaults.set(self.maxTexts, forKey: Key.maxTexts) }
    }

    @Published var maxImageGB: Double {
        didSet { self.defaults.set(self.maxImageGB, forKey: Key.maxImageGB) }
    }

    @Published var ingestDictations: Bool {
        didSet { self.defaults.set(self.ingestDictations, forKey: Key.ingestDictations) }
    }

    /// Hangs the panel off the notch instead of centring it. Ignored on displays without a notch.
    @Published var useNotch: Bool {
        didSet { self.defaults.set(self.useNotch, forKey: Key.useNotch) }
    }

    /// Off by default: a song changes far too often for the notch to announce every one of them.
    @Published var peekOnTrackChange: Bool {
        didSet { self.defaults.set(self.peekOnTrackChange, forKey: Key.peekOnTrackChange) }
    }

    /// Excludes the windows from screen capture. The clipboard holds whatever you copied, secrets
    /// included, so leaking it into a shared screen is worse than any UI complaint.
    @Published var hideFromCapture: Bool {
        didSet {
            self.defaults.set(self.hideFromCapture, forKey: Key.hideFromCapture)
            self.captureVisibilityChanged.send()
        }
    }

    /// How long the pointer has to settle on the cutout before the notch opens. Brushing past it
    /// on the way to the menu bar should not count.
    @Published var hoverDelay: Double {
        didSet { self.defaults.set(self.hoverDelay, forKey: Key.hoverDelay) }
    }

    @Published var rememberLastTab: Bool {
        didSet { self.defaults.set(self.rememberLastTab, forKey: Key.rememberLastTab) }
    }

    /// Overrides the app's language without touching the system one. AppleLanguages is read by
    /// the loader at launch, so a change only lands on the next start.
    var language: String {
        get { (self.defaults.stringArray(forKey: Key.language)?.first).map { String($0.prefix(2)) } ?? "" }
        set {
            if newValue.isEmpty {
                self.defaults.removeObject(forKey: Key.language)
            } else {
                self.defaults.set([newValue], forKey: Key.language)
            }
            self.objectWillChange.send()
        }
    }

    var welcomeShown: Bool {
        get { self.defaults.bool(forKey: Key.welcomeShown) }
        set { self.defaults.set(newValue, forKey: Key.welcomeShown) }
    }

    var lastTab: String? {
        get { self.defaults.string(forKey: Key.lastTab) }
        set { self.defaults.set(newValue, forKey: Key.lastTab) }
    }

    let captureVisibilityChanged = PassthroughSubject<Void, Never>()

    nonisolated static var hideFromCaptureNow: Bool {
        UserDefaults.standard.object(forKey: "HideFromCapture") as? Bool ?? true
    }

    private init() {
        let stored = self.defaults.object(forKey: Key.keyCode) as? Int
        self.keyCode = UInt32(stored ?? kVK_ANSI_V)
        self.modifiers = UInt32(self.defaults.object(forKey: Key.modifiers) as? Int ?? (cmdKey | shiftKey))
        self.pasteOnPick = self.defaults.object(forKey: Key.pasteOnPick) as? Bool ?? true
        self.maxImages = self.defaults.object(forKey: Key.maxImages) as? Int ?? 200
        self.maxTexts = self.defaults.object(forKey: Key.maxTexts) as? Int ?? 5000
        self.maxImageGB = self.defaults.object(forKey: Key.maxImageGB) as? Double ?? 2
        self.ingestDictations = self.defaults.object(forKey: Key.ingestDictations) as? Bool ?? true
        self.useNotch = self.defaults.object(forKey: Key.useNotch) as? Bool ?? true
        self.peekOnTrackChange = self.defaults.object(forKey: Key.peekOnTrackChange) as? Bool ?? false
        self.hideFromCapture = self.defaults.object(forKey: Key.hideFromCapture) as? Bool ?? true
        self.hoverDelay = self.defaults.object(forKey: Key.hoverDelay) as? Double ?? 0.16
        self.rememberLastTab = self.defaults.object(forKey: Key.rememberLastTab) as? Bool ?? true
    }

    var maxImageBytes: Int64 { Int64(self.maxImageGB * 1024 * 1024 * 1024) }

    // Background pollers cannot hop to the main actor just to read a flag; UserDefaults is thread-safe.
    nonisolated static var ingestDictationsNow: Bool {
        UserDefaults.standard.object(forKey: "IngestDictations") as? Bool ?? true
    }

    nonisolated static var peekOnTrackChangeNow: Bool {
        UserDefaults.standard.object(forKey: "PeekOnTrackChange") as? Bool ?? false
    }

    nonisolated static var maxTextsNow: Int {
        UserDefaults.standard.object(forKey: "MaxTexts") as? Int ?? 5000
    }

    nonisolated static var maxImagesNow: Int {
        UserDefaults.standard.object(forKey: "MaxImages") as? Int ?? 200
    }

    nonisolated static var maxImageBytesNow: Int64 {
        Int64((UserDefaults.standard.object(forKey: "MaxImageGB") as? Double ?? 2) * 1024 * 1024 * 1024)
    }

    var shortcutDisplay: String {
        var parts = ""
        if self.modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if self.modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if self.modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if self.modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + Self.keyName(self.keyCode)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Espacio"
        case kVK_Return: return "↩"
        case kVK_Escape: return "esc"
        case kVK_Tab: return "⇥"
        default: break
        }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "?" }
            var deadKeys: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeys, characters.count, &length, &characters
            )
            guard status == noErr, length > 0 else { return "?" }
            return String(utf16CodeUnits: characters, count: length).uppercased()
        }
    }
}
