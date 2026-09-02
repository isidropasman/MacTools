import AppKit
import Carbon.HIToolbox
import Combine

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let keyCode = "HotKeyCode"
        static let modifiers = "HotKeyModifiers"
        static let pasteOnPick = "PasteOnPick"
        static let maxImages = "MaxImages"
        static let maxImageGB = "MaxImageGB"
        static let ingestDictations = "IngestDictations"
        static let useNotch = "UseNotch"
    }

    /// Fires when the shortcut changes so the app can re-register it.
    let hotKeyChanged = PassthroughSubject<Void, Never>()

    @Published var keyCode: UInt32 {
        didSet { self.defaults.set(Int(self.keyCode), forKey: Key.keyCode); self.hotKeyChanged.send() }
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

    private init() {
        let stored = self.defaults.object(forKey: Key.keyCode) as? Int
        self.keyCode = UInt32(stored ?? kVK_ANSI_V)
        self.modifiers = UInt32(self.defaults.object(forKey: Key.modifiers) as? Int ?? (cmdKey | shiftKey))
        self.pasteOnPick = self.defaults.object(forKey: Key.pasteOnPick) as? Bool ?? true
        self.maxImages = self.defaults.object(forKey: Key.maxImages) as? Int ?? 200
        self.maxImageGB = self.defaults.object(forKey: Key.maxImageGB) as? Double ?? 2
        self.ingestDictations = self.defaults.object(forKey: Key.ingestDictations) as? Bool ?? true
        self.useNotch = self.defaults.object(forKey: Key.useNotch) as? Bool ?? true
    }

    var maxImageBytes: Int64 { Int64(self.maxImageGB * 1024 * 1024 * 1024) }

    // Background pollers cannot hop to the main actor just to read a flag; UserDefaults is thread-safe.
    nonisolated static var ingestDictationsNow: Bool {
        UserDefaults.standard.object(forKey: "IngestDictations") as? Bool ?? true
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
