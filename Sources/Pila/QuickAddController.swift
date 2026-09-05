import AppKit
import SwiftUI

/// A key-capable window for capturing a task, opened by hotkey or from the notch.
@MainActor
final class QuickAddController: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private var editing: TodoTask?
    private let tasks: TaskStore
    private var previousApp: NSRunningApplication?

    init(tasks: TaskStore) {
        self.tasks = tasks
        super.init()
    }

    func toggle() {
        if self.window?.isVisible == true { self.hide() } else { self.show() }
    }

    func show(editing task: TodoTask? = nil) {
        self.previousApp = NSWorkspace.shared.frontmostApplication
        self.editing = task

        // Rebuilt each time so the field starts from the right content instead of stale state.
        self.window?.orderOut(nil)
        let panel = self.makeWindow()
        self.window = panel

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.midY - panel.frame.height / 2 + visible.height * 0.12
            ))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        self.window?.orderOut(nil)
        self.previousApp?.activate()
        self.previousApp = nil
    }

    private func makeWindow() -> NSPanel {
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 130),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.sharingType = Settings.hideFromCaptureNow ? .none : .readOnly
        panel.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        let hosting = NSHostingView(rootView: QuickAddView(tasks: self.tasks, editing: self.editing) { [weak self] in
            self?.hide()
        })
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        // Esc closes without adding anything.
        panel.contentView?.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self
        ))
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        guard NSApp.modalWindow == nil else { return }
        self.hide()
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        self.orderOut(nil)
    }
}
