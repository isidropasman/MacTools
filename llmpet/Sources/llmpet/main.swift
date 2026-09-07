import AppKit
import Combine
import Carbon.HIToolbox
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private func makePanel(size: NSSize) -> FloatingPanel {
    let panel = FloatingPanel(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isMovableByWindowBackground = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    return panel
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    private var petPanel: FloatingPanel!
    private var listPanel: FloatingPanel!
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var cancellable: AnyCancellable?
    private let listener = LocalListener()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(
            at: FileSource.dir, withIntermediateDirectories: true)

        petPanel = makePanel(size: PetAsset.panelSize)
        petPanel.contentView = PetContainerView(
            content: PetView(store: store)) { [weak self] in self?.toggleList() }
        petPanel.setFrameOrigin(savedOrigin())
        petPanel.orderFrontRegardless()

        listPanel = makePanel(size: NSSize(width: listWidth, height: 100))
        rebuildList()

        // Keep the open list sized to its contents as sessions come and go.
        cancellable = store.$sessions.sink { [weak self] _ in
            guard let self, self.listPanel.isVisible else { return }
            DispatchQueue.main.async { self.layoutList() }
        }
        // Collapsing a section changes the content height without touching the
        // store, and @AppStorage writes land here.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.listPanel.isVisible else { return }
            self.layoutList()
        }

        // The list is anchored to the pet, so it has to follow while you drag.
        // performDrag runs its own event loop; the move notification still lands
        // on the main runloop during it, which keeps the two visually attached.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: petPanel, queue: .main
        ) { [weak self] _ in
            guard let self, self.listPanel.isVisible else { return }
            self.layoutList()
        }

        // ⌥⌘L toggles the list from anywhere, so you never have to find the pet
        // on screen first — and Esc closes it when it is open.
        Hotkey.shared.register(key: kVK_ANSI_L, modifiers: optionKey | cmdKey,
                               id: HotkeyID.toggle) { [weak self] in self?.toggleList() }
        // ⌥⌘Q quits. Plain ⌘Q cannot work: an LSUIElement app is never the active
        // app, so the key never reaches it.
        Hotkey.shared.register(key: kVK_ANSI_Q, modifiers: optionKey | cmdKey,
                               id: HotkeyID.quit) { NSApp.terminate(nil) }

        listener.start()
        store.start()
    }

    /// The hosting view is reused across show/hide, so onAppear would fire only
    /// once and the unfold would play a single time. Rebuilding it per open is
    /// what makes the animation run every time.
    private func rebuildList() {
        listPanel.contentView = FirstMouseHostingView(
            rootView: SessionListView(
                store: store,
                onOpen: { [weak self] session in
                    // Close first: the list is a key-capable panel, and dismissing
                    // it after the activation made focus bounce back mid-raise.
                    self?.hideList()
                    self?.store.open(session)
                },
                collapsedWidth: Notch.width(on: petPanel.screen)
            ))
    }

    private func savedOrigin() -> CGPoint {
        // One-time move to the notch when the unfold landed, so an existing
        // install actually gets the behaviour instead of only new ones.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "movedToNotch") {
            defaults.set(true, forKey: "movedToNotch")
            defaults.removeObject(forKey: "petOrigin")
        }

        if let raw = defaults.string(forKey: "petOrigin") {
            let saved = NSPointFromString(raw)
            // Ignore a position left behind by a screen that is no longer attached.
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -40, dy: -40).contains(saved) }) {
                return saved
            }
        }
        // Default home is under the notch, so the list unfolds out of it. Still
        // draggable — drag it elsewhere and the animation simply plays from there.
        return Notch.anchor(on: NSScreen.main, size: PetAsset.panelSize)
    }

    private func toggleList() {
        if listPanel.isVisible { hideList() } else { showList() }
    }

    private func layoutList() {
        guard let content = listPanel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = max(content.fittingSize.height, 44)
        let pet = petPanel.frame
        let screen = petPanel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(screen.minX + 8, pet.midX - listWidth / 2), screen.maxX - listWidth - 8)
        let below = pet.minY - height - 6
        let y = below < screen.minY ? min(pet.maxY + 6, screen.maxY - height) : below
        let target = NSRect(x: x, y: y, width: listWidth, height: height)

        // Compare the whole frame, not just the height. Checking height alone
        // meant dragging the pet with the list open never moved the list, and the
        // two drifted apart on screen.
        guard !listPanel.frame.equalTo(target) else { return }
        listPanel.setFrame(target, display: true)
    }

    private func showList() {
        store.setDetailsVisible(true)
        rebuildList()
        layoutList()
        listPanel.orderFrontRegardless()
        listPanel.makeKey()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in self?.hideList() }

        // Local, not global: the list panel is key while open, so Esc arrives
        // here without needing Accessibility permission.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Esc
            self?.hideList()
            return nil
        }
    }

    private func hideList() {
        store.setDetailsVisible(false)
        listPanel.orderOut(nil)
        for monitor in [outsideClickMonitor, escapeMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        outsideClickMonitor = nil
        escapeMonitor = nil
    }
}

if CommandLine.arguments.contains("--check") { runSelfCheck() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
