import AppKit
import SwiftUI

/// A key-capable window for capturing a task, opened by hotkey or from the notch.
@MainActor
final class QuickAddController: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private var editing: TodoTask?
    private let tasks: TaskStore
    private var previousApp: NSRunningApplication?
    /// Fixed at open time so a later recentre cannot chase the pointer onto another display.
    private var targetScreen: NSScreen?

    var onManageProjects: (() -> Void)?
    /// Fires once the panel has landed on the notch, so the confirmation shows up there and not
    /// behind a window that is still on screen.
    var onTaskAdded: ((TodoTask, NSScreen?) -> Void)?

    /// Recentring during the flight would drag the panel back to the middle of the screen.
    private var flying = false

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

        // The screen under the pointer, not NSScreen.main: with an external display the key window
        // often lives on the other one, and the panel would open where you are not looking.
        let pointer = NSEvent.mouseLocation
        self.targetScreen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.center(panel)
    }

    private func center(_ panel: NSPanel) {
        guard let visible = targetScreen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: (visible.midX - panel.frame.width / 2).rounded(),
            y: (visible.midY - panel.frame.height / 2).rounded()
        ))
    }

    /// The task visibly goes where it now lives. Without it the panel just vanished and you had to
    /// open the notch to believe it had been saved.
    private func flyToNotch(with task: TodoTask) {
        guard let panel = window, let screen = targetScreen else {
            self.hide()
            return
        }
        self.flying = true

        let notch = NotchGeometry.anchor(on: screen)
        let landing = NSRect(x: notch.midX - 30, y: notch.maxY - 14, width: 60, height: 14)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(landing, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.flying = false
            panel.alphaValue = 1
            self.hide()
            self.onTaskAdded?(task, screen)
        }
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
        // The glass has to sit on the desktop, not on the panel's own opaque grey.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.sharingType = Settings.hideFromCaptureNow ? .none : .readOnly
        panel.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        // A hosting controller so the panel follows the content: the chip row wraps to a second
        // line once enough fields are set, and a fixed height would clip it.
        let hosting = NSHostingController(rootView: QuickAddView(
            tasks: self.tasks,
            editing: self.editing,
            onDone: { [weak self] task in
                if let task { self?.flyToNotch(with: task) } else { self?.hide() }
            },
            onManageProjects: { [weak self] in
                self?.hide()
                self?.onManageProjects?()
            }
        ))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting

        // Esc closes without adding anything.
        panel.contentView?.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self
        ))
        return panel
    }

    /// The hosting controller keeps resizing the window after it is ordered front, and again when
    /// the chip row wraps, so centring once at open time is always premature.
    func windowDidResize(_ notification: Notification) {
        guard !self.flying, let window, window.isVisible else { return }
        self.center(window)
    }

    /// Opening a menu or a popover from inside the panel makes it resign key. Hiding on that
    /// rebuilt the view from scratch, so whatever you then picked from the menu was applied to a
    /// window that no longer existed. Only losing the app entirely counts as dismissal.
    func windowDidResignKey(_ notification: Notification) {
        guard NSApp.modalWindow == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let window, window.isVisible else { return }
            guard !NSApp.isActive, NSApp.modalWindow == nil else { return }
            self.hide()
        }
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        self.orderOut(nil)
    }
}
