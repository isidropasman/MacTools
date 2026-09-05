import AppKit
import Combine
import SwiftUI

/// Hover target over the cutout. The window is always full size, so while collapsed this view has
/// to refuse every point outside the cutout, otherwise a 460x190 invisible panel would swallow
/// clicks on the menu bar underneath it.
private final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    /// Region that counts as "the notch" while collapsed, in this view's coordinates.
    var notchRect: NSRect = .zero {
        didSet { self.updateTrackingAreas() }
    }
    /// Same region in screen coordinates. A tracking area can fire from further out than its rect
    /// suggests, so entering is confirmed against the real pointer position before opening.
    var triggerScreenRect: NSRect = .zero
    var slack: CGFloat = 6
    var expanded = false {
        didSet { self.updateTrackingAreas() }
    }

    private var tracking: NSTrackingArea?

    private var activeRect: NSRect {
        self.expanded ? self.bounds : self.notchRect
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { self.removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: self.activeRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        self.addTrackingArea(area)
        self.tracking = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = self.convert(point, from: self.superview)
        guard self.activeRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func mouseEntered(with event: NSEvent) {
        guard self.expanded
            || NotchGeometry.pointerIsOnNotch(NSEvent.mouseLocation, trigger: self.triggerScreenRect, slack: self.slack)
        else { return }
        self.onEnter?()
    }

    override func mouseExited(with event: NSEvent) { self.onExit?() }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchController {
    private struct Surface {
        let panel: NotchPanel
        let hover: HoverView
        let screen: NSScreen
    }

    /// One surface per display. Screens with no cutout get a synthetic anchor from NotchGeometry.
    private var surfaces: [Surface] = []
    private var collapseTask: Task<Void, Never>?
    private var expandTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    /// Seeded on first sample so launching the app does not fire a peek for whatever was already on.
    private var lastTrackKey: String?
    private var lastCharging: Bool?
    private var cancellables = Set<AnyCancellable>()

    private let media: MediaController
    private let shelf: ShelfStore
    private let battery: BatteryMonitor
    private let calendar: CalendarManager
    private let state = NotchState()
    private let thumbnails = ShelfThumbnails()
    private let tasks: TaskStore
    var onQuickAdd: (() -> Void)?
    var onEditTask: ((TodoTask) -> Void)?

    init(media: MediaController, shelf: ShelfStore, battery: BatteryMonitor, calendar: CalendarManager, tasks: TaskStore) {
        self.tasks = tasks
        self.media = media
        self.shelf = shelf
        self.battery = battery
        self.calendar = calendar
    }

    func install() {
        self.rebuild()

        // Plugging in or unplugging a display invalidates every panel's geometry.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &self.cancellables)

        self.observePeeks()

        Settings.shared.captureVisibilityChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                let type: NSWindow.SharingType = Settings.hideFromCaptureNow ? .none : .readOnly
                for surface in self?.surfaces ?? [] { surface.panel.sharingType = type }
            }
            .store(in: &self.cancellables)

        self.state.$expandedScreen
            .receive(on: RunLoop.main)
            .sink { [weak self] expandedScreen in
                for surface in self?.surfaces ?? [] {
                    surface.hover.expanded = NotchGeometry.displayID(of: surface.screen) == expandedScreen
                }
            }
            .store(in: &self.cancellables)
    }

    /// A peek is the notch talking first: a new song, the charger going in or out.
    private func observePeeks() {
        self.media.$track
            .receive(on: RunLoop.main)
            .sink { [weak self] track in
                guard let self, let track else { return }
                let key = "\(track.title)|\(track.artist)"
                defer { self.lastTrackKey = key }

                // First sample only seeds the baseline; announcing it would fire on every launch.
                guard Settings.peekOnTrackChangeNow else { return }
                guard let previous = self.lastTrackKey, previous != key, track.isPlaying else { return }
                self.peek(NotchState.Peek(
                    title: track.title,
                    subtitle: track.artist,
                    symbol: "music.note",
                    usesArtwork: true
                ))
            }
            .store(in: &self.cancellables)

        self.battery.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] battery in
                guard let self, let battery else { return }
                defer { self.lastCharging = battery.isCharging }

                guard let previous = self.lastCharging, previous != battery.isCharging else { return }
                self.peek(NotchState.Peek(
                    title: battery.isCharging ? "Cargando" : "Sin cargador",
                    subtitle: "\(battery.percent)%" + (battery.detail.map { " · \($0)" } ?? ""),
                    symbol: battery.symbol,
                    usesArtwork: false
                ))
            }
            .store(in: &self.cancellables)
    }

    private func peek(_ peek: NotchState.Peek) {
        // Hovering wins: never yank the panel out from under a pointer that is already using it.
        guard self.state.expandedScreen == nil else { return }

        self.peekTask?.cancel()
        self.state.peekScreen = NotchGeometry.displayID(of: NSScreen.main ?? NSScreen.screens[0])
        self.state.peek = peek
        self.peekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2600))
            guard !Task.isCancelled else { return }
            self?.state.peek = nil
        }
    }

    private func rebuild() {
        for surface in self.surfaces { surface.panel.orderOut(nil) }
        self.state.expandedScreen = nil
        self.surfaces = NSScreen.screens.map { self.makeSurface(for: $0) }
    }

    private func makeSurface(for screen: NSScreen) -> Surface {
        let anchor = NotchGeometry.anchor(on: screen)
        let size = NSSize(width: NotchState.windowWidth, height: NotchState.windowHeight)

        // Fixed frame, set once. Resizing an NSWindow per frame forces a full SwiftUI relayout at
        // every step, which is what made the expansion stutter.
        let frame = NSRect(
            x: anchor.midX - size.width / 2,
            y: anchor.maxY - size.height,
            width: size.width,
            height: size.height
        )

        let panel = NotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = Settings.hideFromCaptureNow ? .none : .readOnly

        let container = HoverView(frame: NSRect(origin: .zero, size: size))
        let trigger = NotchGeometry.trigger(on: screen)
        container.notchRect = NSRect(
            x: trigger.minX - frame.minX,
            y: trigger.minY - frame.minY,
            width: trigger.width,
            height: trigger.height
        )
        container.triggerScreenRect = trigger
        container.slack = NotchGeometry.slack(on: screen)
        container.onEnter = { [weak self] in self?.expand(on: screen) }
        container.onExit = { [weak self] in self?.scheduleCollapse() }

        let hosting = NSHostingView(rootView: NotchView(
            media: self.media,
            shelf: self.shelf,
            battery: self.battery,
            state: self.state,
            calendar: self.calendar,
            thumbnails: self.thumbnails,
            tasks: self.tasks,
            notchHeight: anchor.height,
            notchWidth: anchor.width,
            screenID: NotchGeometry.displayID(of: screen),
            onDropTargeted: { [weak self] active in
                if active { self?.expand(on: screen) }
            },
            onQuickAdd: { [weak self] in self?.onQuickAdd?() },
            onEditTask: { [weak self] task in self?.onEditTask?(task) }
        ))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        panel.contentView = container
        panel.orderFrontRegardless()

        return Surface(panel: panel, hover: container, screen: screen)
    }

    /// Brushing past the notch on the way to the menu bar should not open it, so opening waits
    /// for the pointer to actually settle there.
    private func expand(on screen: NSScreen) {
        self.collapseTask?.cancel()
        let id = NotchGeometry.displayID(of: screen)
        guard self.state.expandedScreen != id, self.expandTask == nil else { return }

        self.expandTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, let self else { return }
            self.expandTask = nil
            guard self.pointerIsOnTrigger(of: screen) else { return }
            self.peekTask?.cancel()
            self.state.peek = nil
            // Only the display holding the pointer opens; the others stay shut.
            self.state.expandedScreen = id
        }
    }

    private func pointerIsOnTrigger(of screen: NSScreen) -> Bool {
        NotchGeometry.pointerIsOnNotch(
            NSEvent.mouseLocation,
            trigger: NotchGeometry.trigger(on: screen),
            slack: NotchGeometry.slack(on: screen)
        )
    }

    /// A grace period keeps the panel open while the pointer crosses its own edge.
    private func scheduleCollapse() {
        self.expandTask?.cancel()
        self.expandTask = nil
        self.collapseTask?.cancel()
        self.collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.state.expandedScreen = nil
        }
    }
}
