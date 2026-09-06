import AppKit
import Combine
import SwiftUI

/// Hover target over the cutout. The window is always full size, so while collapsed this view has
/// to refuse every point outside the cutout, otherwise a 460x190 invisible panel would swallow
/// clicks on the menu bar underneath it.
private final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    /// While a file is being dragged the whole panel accepts it. Outside a drag the view still has
    /// to refuse every point beyond the cutout, or it would swallow clicks on the menu bar.
    var dragging = false {
        didSet { self.updateTrackingAreas() }
    }

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
        if self.expanded || self.dragging { return self.bounds }
        // A drag needs a slightly more forgiving target than a pointer does.
        return self.notchRect.insetBy(dx: -16, dy: -6)
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

/// Drops are handled by the window, not by a view. A view destination is found through hitTest,
/// and the hover view has to refuse everything outside the cutout so it does not eat clicks on the
/// menu bar, which meant a dragged file never reached it.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Region that accepts a drag while the panel is closed, in window coordinates.
    var closedDropRect: NSRect = .zero
    var isOpen: (() -> Bool)?
    var onDropTargeted: ((Bool) -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    private func accepts(_ sender: any NSDraggingInfo) -> Bool {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else { return false }
        // Closed, the panel is invisible: only the strip over the cutout may steal a drop from
        // whatever is underneath. Open, the whole panel is a target.
        return self.isOpen?() == true || self.closedDropRect.contains(sender.draggingLocation)
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard self.accepts(sender) else { return [] }
        self.onDropTargeted?(true)
        return .copy
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard self.accepts(sender) else { return [] }
        self.onDropTargeted?(true)
        return .copy
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        self.onDropTargeted?(false)
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        self.onDropTargeted?(false)
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        self.onDropFiles?(urls)
        return true
    }
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
    private let sessions: SessionStore
    var onQuickAdd: (() -> Void)?
    var onEditTask: ((TodoTask) -> Void)?
    var onOpenSettings: (() -> Void)?

    /// Opens straight onto a tab, which is what a per-tool shortcut is asking for.
    func show(_ tab: NotchTab) {
        self.state.tab = tab
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        else { return }
        self.collapseTask?.cancel()
        self.state.expandedScreen = NotchGeometry.displayID(of: screen)
    }

    /// Opens on the display holding the pointer, so the shortcut behaves like the hover does.
    func toggleUnderPointer() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        else { return }
        let id = NotchGeometry.displayID(of: screen)
        if self.state.expandedScreen == id {
            self.collapse()
        } else {
            self.expandTask?.cancel()
            self.expandTask = nil
            self.peekTask?.cancel()
            self.state.peek = nil
            self.state.expandedScreen = id
        }
    }

    /// Anything that hands you off to another app should get out of the way on the way out.
    func collapse() {
        self.expandTask?.cancel()
        self.expandTask = nil
        self.collapseTask?.cancel()
        self.state.expandedScreen = nil
    }

    init(media: MediaController, shelf: ShelfStore, battery: BatteryMonitor, calendar: CalendarManager, tasks: TaskStore, sessions: SessionStore) {
        self.tasks = tasks
        self.sessions = sessions
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

        self.state.$tab
            .combineLatest(self.state.$expandedScreen)
            .receive(on: RunLoop.main)
            .sink { [weak self] tab, expanded in
                // Token counts mean reading every transcript; only pay for it while they are on screen.
                self?.sessions.setDetailsVisible(tab == .sessions && expanded != nil)
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

    /// Confirms a capture where the task now lives, so the quick add can close without leaving you
    /// wondering whether it took.
    func announce(_ task: TodoTask, on screen: NSScreen?) {
        var detail: [String] = []
        if let project = task.project {
            detail.append(project + (task.section.map { " · " + $0 } ?? ""))
        }
        if let due = task.dueLabel { detail.append(due) }
        if let type = task.type { detail.append(type) }

        self.peek(
            NotchState.Peek(
                title: task.title,
                subtitle: detail.isEmpty ? "Tarea agregada" : detail.joined(separator: "  ·  "),
                symbol: "checkmark.circle.fill",
                usesArtwork: false,
                tint: task.project.map { self.tasks.color(of: $0) } ?? .green
            ),
            on: screen,
            duration: 1500
        )
    }

    private func peek(_ peek: NotchState.Peek, on screen: NSScreen? = nil, duration: Int = 2600) {
        // Hovering wins: never yank the panel out from under a pointer that is already using it.
        guard self.state.expandedScreen == nil else { return }

        self.peekTask?.cancel()
        self.state.peekScreen = NotchGeometry.displayID(of: screen ?? NSScreen.main ?? NSScreen.screens[0])
        self.state.peek = peek
        self.peekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(duration))
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
        panel.registerForDraggedTypes([.fileURL])
        // The full width of the strip level with the menu bar. Aiming a dragged file at the cutout
        // exactly is hard, and nothing under that strip accepts drops anyway.
        panel.closedDropRect = NSRect(
            x: 0,
            y: container.notchRect.minY - 12,
            width: size.width,
            height: container.notchRect.height + 12
        )
        panel.isOpen = { [weak self] in
            self?.state.expandedScreen == NotchGeometry.displayID(of: screen)
        }
        panel.onDropTargeted = { [weak self] active in
            guard let self else { return }
            guard self.state.dropTargeted != active else { return }
            self.state.dropTargeted = active
            container.dragging = active
            if active {
                self.collapseTask?.cancel()
                self.state.tab = .shelf
                self.state.expandedScreen = NotchGeometry.displayID(of: screen)
            } else {
                self.scheduleCollapse()
            }
        }
        panel.onDropFiles = { [weak self] urls in
            guard let self else { return }
            for url in urls { self.shelf.add(url) }
            self.state.tab = .shelf
            self.state.expandedScreen = NotchGeometry.displayID(of: screen)
        }

        let hosting = NSHostingView(rootView: NotchView(
            media: self.media,
            shelf: self.shelf,
            battery: self.battery,
            state: self.state,
            calendar: self.calendar,
            thumbnails: self.thumbnails,
            tasks: self.tasks,
            sessions: self.sessions,
            notchHeight: anchor.height,
            notchWidth: anchor.width,
            screenID: NotchGeometry.displayID(of: screen),
            onQuickAdd: { [weak self] in self?.onQuickAdd?() },
            onEditTask: { [weak self] task in self?.onEditTask?(task) },
            onOpenSettings: { [weak self] in self?.onOpenSettings?() },
            onCollapse: { [weak self] in self?.collapse() }
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
            try? await Task.sleep(for: .seconds(Settings.shared.hoverDelay))
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
