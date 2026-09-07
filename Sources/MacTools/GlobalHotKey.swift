import Carbon.HIToolbox
import Foundation

/// Carbon's RegisterEventHotKey needs no Accessibility permission, unlike a CGEventTap.
/// That keeps MacTools permission-free, so an ad-hoc signature changing on every rebuild costs nothing.
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextIdentifier: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private let identifier: UInt32
    private var hotKeyRef: EventHotKeyRef?

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        Self.installEventHandlerIfNeeded()

        self.identifier = Self.nextIdentifier
        Self.nextIdentifier += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D54_6C73), id: self.identifier)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }

        self.hotKeyRef = ref
        Self.handlers[self.identifier] = handler
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        Self.handlers.removeValue(forKey: self.identifier)
    }

    private static func installEventHandlerIfNeeded() {
        guard self.eventHandler == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            if let handler = GlobalHotKey.handlers[hotKeyID.id] {
                DispatchQueue.main.async(execute: handler)
            }
            return noErr
        }, 1, &spec, nil, &self.eventHandler)
    }
}
