import AppKit
import Carbon.HIToolbox

/// Carbon's RegisterEventHotKey is the one way to get system-wide shortcuts
/// without asking for Accessibility permission — NSEvent's global monitor would
/// need it, which is a lot to ask for a couple of toggles.
///
/// This also has to exist because the app is LSUIElement and never becomes
/// active: a keyEquivalent on a context-menu item is decoration, and plain ⌘Q
/// is never delivered to us at all.
final class Hotkey {
    static let shared = Hotkey()

    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    /// `key` is a kVK_* code, `modifiers` a Carbon mask (optionKey, cmdKey, ...).
    func register(key: Int, modifiers: Int, id: UInt32, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        actions[id] = action

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key), UInt32(modifiers),
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs.append(ref)
        } else {
            NSLog("llmpet: no pude registrar el atajo \(id): \(status)")
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.signature == Hotkey.signature else { return noErr }
            DispatchQueue.main.async { Hotkey.shared.actions[pressed.id]?() }
            return noErr
        }, 1, &type, nil, nil)
    }

    private static let signature: OSType = 0x4C4C4D50  // 'LLMP'
}

enum HotkeyID {
    static let toggle: UInt32 = 1
    static let quit: UInt32 = 2
}
