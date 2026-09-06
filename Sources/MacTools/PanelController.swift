import AppKit
import SwiftUI

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private var panel: KeyablePanel?
    private var keyMonitor: Any?
    private let model: HistoryModel
    private let onPick: (ClipItem) -> Void

    /// Captured so focus returns to whatever the user was typing in, making the follow-up Cmd+V land there.
    private var previousApp: NSRunningApplication?

    var onOpenSettings: (() -> Void)?

    init(model: HistoryModel, onPick: @escaping (ClipItem) -> Void) {
        self.model = model
        self.onPick = onPick
        super.init()
    }

    /// An NSPanel cannot miniaturize, so the yellow button hides instead of leaving a dead control.
    /// Close is routed here too, so focus returns to the app the user came from.
    @objc private func hideFromTitlebar() {
        self.hide()
    }

    var isVisible: Bool { self.panel?.isVisible ?? false }

    func toggle() {
        if self.isVisible { self.hide() } else { self.show() }
    }

    func show() {
        self.previousApp = NSWorkspace.shared.frontmostApplication
        self.model.reset()

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let panel = self.panel ?? self.makePanel()
        self.panel = panel

        let size = NSSize(width: PanelController.width, height: 460)
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.08,
            width: size.width,
            height: size.height
        ), display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        self.installKeyMonitor()
    }

    func hide() {
        self.removeKeyMonitor()
        self.panel?.orderOut(nil)
        self.previousApp?.activate()
        self.previousApp = nil
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelController.width, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // The history is the last thing that should end up in a shared screen.
        panel.sharingType = Settings.hideFromCaptureNow ? .none : .readOnly
        panel.delegate = self

        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton] {
            panel.standardWindowButton(button)?.target = self
            panel.standardWindowButton(button)?.action = #selector(self.hideFromTitlebar)
        }

        let root = HistoryView(
            model: self.model,
            onPick: { [weak self] item in self?.pick(item) },
            onCopy: { [weak self] item in self?.copyOnly(item) },
            onOpenSettings: { [weak self] in
                self?.hide()
                self?.onOpenSettings?()
            }
        )
        panel.contentView = NSHostingView(rootView: root)
        return panel
    }

    static let width: CGFloat = 560

    private func pick(_ item: ClipItem) {
        self.onPick(item)
        let target = self.previousApp
        self.hide()
        if Settings.shared.pasteOnPick {
            Paster.paste(into: target)
        }
    }

    /// Copy closes too, so the next keystroke can be the paste. The short delay exists only so the
    /// checkmark registers as feedback; closing instantly would make the copy feel unconfirmed.
    private func copyOnly(_ item: ClipItem) {
        self.onPick(item)
        self.model.flashCopied(item.id)

        let target = self.previousApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, self.isVisible else { return }
            self.hide()
            if Settings.shared.pasteOnPick {
                Paster.paste(into: target)
            }
        }
    }

    /// A dropdown that survives a click elsewhere feels stuck. Alerts (rename, clear all) take key
    /// status themselves, so they must not count as dismissal.
    func windowDidResignKey(_ notification: Notification) {
        guard NSApp.modalWindow == nil, !self.model.previewing else { return }
        self.hide()
    }

    private func installKeyMonitor() {
        self.removeKeyMonitor()
        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        self.keyMonitor = nil
    }

    /// Returns true when the event was consumed, keeping it out of the search field.
    private func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)

        // Cmd+1…9 grabs the Nth row without arrowing to it.
        if command, let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1 ... 9).contains(digit) {
            let index = digit - 1
            guard self.model.items.indices.contains(index) else { return true }
            self.model.selection = index
            self.pick(self.model.items[index])
            return true
        }

        // Space previews, but only when it would not interrupt typing a search.
        if event.keyCode == 49, self.model.query.isEmpty {
            self.model.togglePreview()
            return true
        }

        switch event.keyCode {
        case 53: // Escape
            if self.model.previewing { self.model.previewing = false } else { self.hide() }
            return true
        case 36, 76: // Return, Enter
            if let item = model.selectedItem { self.pick(item) }
            return true
        case 125: // Down
            self.model.move(by: 1)
            return true
        case 126: // Up
            self.model.move(by: -1)
            return true
        case 121: // Page Down
            self.model.move(by: 10)
            return true
        case 116: // Page Up
            self.model.move(by: -10)
            return true
        case 51 where command: // Cmd+Delete
            self.model.deleteSelected()
            return true
        case 35 where command: // Cmd+P
            self.model.togglePin()
            return true
        case 2 where command: // Cmd+D
            self.model.toggleFavorite()
            return true
        default:
            return false
        }
    }
}
