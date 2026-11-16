import AppKit
import Combine
import SwiftUI

/// Hover target over the cutout. The window is always full size, so while collapsed this view has
/// to refuse every point outside the cutout, otherwise a 520x190 invisible panel would swallow
/// clicks on the menu bar underneath it.
private final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    /// While a file is being dragged the whole panel accepts it. Outside a drag the view still has
    /// to refuse every point beyond the cutout, or it would swallow clicks on the menu bar.
    var dragging = false {
        didSet { self.updateTrackingAreas() }
    }
    var onDropTargeted: ((Bool) -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    var peekRect: NSRect = .zero {
        didSet { self.updateTrackingAreas() }
    }

    /// Region that counts as "the notch" while collapsed, in this view's coordinates.
    var notchRect: NSRect = .zero {
        didSet { self.updateTrackingAreas() }
    }
    var slack: CGFloat = 6
    var expanded = false {
        didSet { self.updateTrackingAreas() }
    }

    private var tracking: NSTrackingArea?
    private var pointerInside = false
    private let expandedHeight: CGFloat

    init(frame frameRect: NSRect, expandedHeight: CGFloat) {
        self.expandedHeight = expandedHeight
        super.init(frame: frameRect)
        self.registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        self.onDropTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        self.onDropTargeted?(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        self.onDropTargeted?(false)
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        self.onDropFiles?(urls)
        return true
    }

    private var activeRect: NSRect {
        if self.dragging { return self.bounds }
        if self.expanded {
            return NSRect(
                x: self.bounds.minX, y: self.bounds.maxY - self.expandedHeight,
                width: self.bounds.width, height: self.expandedHeight
            )
        }
        return self.peekRect.isEmpty ? self.notchRect : self.notchRect.union(self.peekRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard self.tracking?.rect != self.activeRect else { return }
        self.pointerInside = false
        if let tracking { self.removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: self.activeRect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
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
        let point = self.window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? event.locationInWindow
        self.updateHover(at: self.convert(point, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        self.updateHover(at: self.convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        // AppKit can deliver an exit from the compact music region after the panel expanded.
        self.updatePointer(at: NSEvent.mouseLocation)
    }

    func updatePointer(at screenPoint: NSPoint) {
        guard let window = self.window else { return }
        self.updateHover(at: self.convert(window.convertPoint(fromScreen: screenPoint), from: nil))
    }

    private func updateHover(at point: NSPoint) {
        let rect = self.activeRect
        let ignoresMouse = !rect.contains(point)
        if let window = self.window, window.ignoresMouseEvents != ignoresMouse {
            // A nil view hit test alone does not release the window's capture of browser clicks.
            window.ignoresMouseEvents = ignoresMouse
        }
        let inside = self.expanded || self.dragging
            ? point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
            : NotchGeometry.pointerIsOnNotch(point, trigger: self.notchRect, slack: self.slack)
        guard inside != self.pointerInside else { return }
        self.pointerInside = inside
        if inside { self.onEnter?() }
        else { self.onExit?() }
    }
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
    private var musicPeek: NotchState.Peek?
    private var transientPeek: NotchState.Peek?
    private var batteryEvents = BatteryMonitor.EventTracker()
    private var pendingBatteryPeek: NotchState.Peek?
    private var cancellables = Set<AnyCancellable>()
    private var dragMonitor: Any?
    private var pointerMonitor: Any?
    private var armedDisplay: CGDirectDisplayID?

    private let media: MediaController
    private let notifications = NotificationMonitor()
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

    /// The surface whose drop strip the pointer is over, if any. Open panels take the whole frame.
    private func surfaceUnderDrag(at point: NSPoint) -> Surface? {
        self.surfaces.first { surface in
            let id = NotchGeometry.displayID(of: surface.screen)
            if self.state.expandedScreen == id { return surface.panel.frame.contains(point) }
            let trigger = NotchGeometry.trigger(on: surface.screen)
            // The whole width of the panel at menu-bar height: aiming a dragged file at the cutout
            // exactly is hard, and nothing under that strip accepts drops anyway.
            return NSRect(
                x: surface.panel.frame.minX,
                y: trigger.minY - 12,
                width: surface.panel.frame.width,
                height: trigger.height + 12
            ).contains(point)
        }
    }

    private func setDragArmed(_ surface: Surface?) {
        let id = surface.map { NotchGeometry.displayID(of: $0.screen) }
        guard id != self.armedDisplay else { return }
        self.armedDisplay = id

        for other in self.surfaces {
            other.hover.dragging = NotchGeometry.displayID(of: other.screen) == id
        }
        self.updatePointerTargets()

        guard let surface else {
            self.state.dropTargeted = false
            self.scheduleCollapse()
            return
        }
        self.collapseTask?.cancel()
        self.state.tab = .shelf
        self.state.expandedScreen = NotchGeometry.displayID(of: surface.screen)
    }

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
            self.transientPeek = nil
            if self.state.peekScreen != id { self.state.peek = nil }
            self.state.expandedScreen = id
        }
    }

    /// Anything that hands you off to another app should get out of the way on the way out.
    func collapse() {
        self.expandTask?.cancel()
        self.expandTask = nil
        self.collapseTask?.cancel()
        self.state.expandedScreen = nil
        self.updateVisiblePeek()
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

        self.pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.updatePointerTargets()
        }

        // A collapsed panel has to refuse hit tests outside the cutout or it eats clicks on the
        // menu bar, and AppKit finds drag destinations by hit testing — so a dragged file never
        // reached it. This watches the drag from outside and opens the door only while one is
        // actually over the strip.
        self.dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) {
            [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseUp {
                self.setDragArmed(nil)
                return
            }
            guard NSPasteboard(name: .drag).canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) else { return }
            self.setDragArmed(self.surfaceUnderDrag(at: NSEvent.mouseLocation))
        }


        // Plugging in or unplugging a display invalidates every panel's geometry.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &self.cancellables)

        self.observePeeks()
        self.notifications.start()

        self.notifications.$current
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                guard let notification else {
                    if self.transientPeek?.notificationID != nil {
                        self.peekTask?.cancel()
                        self.transientPeek = nil
                        self.updateVisiblePeek()
                    }
                    return
                }

                self.peek(NotchState.Peek(
                    title: notification.title,
                    subtitle: notification.message.isEmpty ? notification.applicationName : notification.message,
                    symbol: "bell.badge.fill",
                    usesArtwork: false,
                    notificationID: notification.id,
                    icon: notification.icon
                ), duration: 5000)
            }
            .store(in: &self.cancellables)

        self.state.$peek
            .combineLatest(self.state.$peekScreen)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updatePeekTargets() }
            .store(in: &self.cancellables)

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
                self?.updatePointerTargets()
            }
            .store(in: &self.cancellables)
    }

    /// A peek is the notch talking first: a new song, the charger going in or out.
    private func observePeeks() {
        self.media.$track
            .receive(on: RunLoop.main)
            .sink { [weak self] track in
                guard let self else { return }
                let musicPeek: NotchState.Peek?
                if let track, track.isPlaying {
                    musicPeek = NotchState.Peek(
                        title: track.title,
                        subtitle: track.artist,
                        symbol: "music.note",
                        usesArtwork: true
                    )
                } else {
                    musicPeek = nil
                }
                guard self.musicPeek != musicPeek else {
                    self.updateVisiblePeek()
                    return
                }
                self.musicPeek = musicPeek
                self.updateVisiblePeek()
            }
            .store(in: &self.cancellables)

        self.battery.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] battery in
                guard let self, let battery else { return }
                guard let event = self.batteryEvents.update(battery) else { return }
                self.peek(.battery(battery, event: event), duration: 5000)
            }
            .store(in: &self.cancellables)
    }

    /// Confirms a capture where the task now lives, so the quick add can close without leaving you
    /// wondering whether it took.
    func announce(_ task: TodoTask, on screen: NSScreen?) {
        // Two items at most: the strip only has half a panel and a long line just truncates.
        var detail: [String] = []
        if let due = task.dueLabel { detail.append(due) }
        if let project = task.project { detail.append(project) }
        else if let type = task.type { detail.append(type) }

        self.peek(
            NotchState.Peek(
                title: task.title,
                subtitle: detail.isEmpty ? "Tarea agregada" : detail.joined(separator: " · "),
                symbol: "checkmark.circle.fill",
                usesArtwork: false,
                tint: task.project.map { self.tasks.color(of: $0) } ?? .green
            ),
            on: screen,
            duration: 1500
        )
    }

    private func peek(_ peek: NotchState.Peek, on screen: NSScreen? = nil, duration: Int = 2600) {
        // Battery alerts wait for the user to close the panel instead of being lost on hover.
        guard self.state.expandedScreen == nil else {
            if peek.batteryStatus != nil { self.pendingBatteryPeek = peek }
            return
        }
        guard screen != nil || self.preferredPeekScreen != nil else { return }

        self.peekTask?.cancel()
        self.transientPeek = peek
        self.updateVisiblePeek(preferredScreen: screen)
        self.peekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(duration))
            guard !Task.isCancelled else { return }
            self?.transientPeek = nil
            self?.updateVisiblePeek()
        }
    }

    private func updateVisiblePeek(preferredScreen: NSScreen? = nil) {
        guard self.state.expandedScreen == nil else { return }
        if let pending = self.pendingBatteryPeek {
            self.pendingBatteryPeek = nil
            self.peek(pending, duration: 5000)
            return
        }
        guard let peek = self.transientPeek ?? self.musicPeek,
              let screen = preferredScreen ?? self.preferredPeekScreen
        else {
            if self.state.peek != nil { self.state.peek = nil }
            if self.state.peekScreen != nil { self.state.peekScreen = nil }
            return
        }
        let screenID = NotchGeometry.displayID(of: screen)
        if self.state.peekScreen != screenID { self.state.peekScreen = screenID }
        if self.state.peek != peek { self.state.peek = peek }
    }

    private var preferredPeekScreen: NSScreen? {
        if let main = NSScreen.main, NotchGeometry.hasNotch(main) { return main }
        return NSScreen.screens.first(where: NotchGeometry.hasNotch) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func rebuild() {
        self.expandTask?.cancel()
        self.expandTask = nil
        self.collapseTask?.cancel()
        for surface in self.surfaces { surface.panel.orderOut(nil) }
        self.state.expandedScreen = nil
        self.surfaces = NSScreen.screens.map { self.makeSurface(for: $0) }
        self.updateVisiblePeek()
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
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = Settings.hideFromCaptureNow ? .none : .readOnly

        let container = HoverView(frame: NSRect(origin: .zero, size: size), expandedHeight: self.state.contentHeight)
        let trigger = NotchGeometry.trigger(on: screen)
        container.notchRect = NSRect(
            x: trigger.minX - frame.minX,
            y: trigger.minY - frame.minY,
            width: trigger.width,
            height: trigger.height
        )
        container.slack = NotchGeometry.slack(on: screen)
        container.onEnter = { [weak self] in self?.expand(on: screen) }
        container.onExit = { [weak self] in self?.scheduleCollapse() }
        container.onDropTargeted = { [weak self] active in
            guard let self else { return }
            self.state.dropTargeted = active
        }
        container.onDropFiles = { [weak self] urls in
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
            hasPhysicalNotch: NotchGeometry.hasNotch(screen),
            screenID: NotchGeometry.displayID(of: screen),
            onQuickAdd: { [weak self] in self?.onQuickAdd?() },
            onEditTask: { [weak self] task in self?.onEditTask?(task) },
            onOpenSettings: { [weak self] in self?.onOpenSettings?() },
            onActivateNotification: { [weak self] id in self?.activateNotification(id: id) },
            onCollapse: { [weak self] in self?.collapse() }
        ))
        hosting.safeAreaRegions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        panel.contentView = container
        container.updatePointer(at: NSEvent.mouseLocation)
        panel.orderFrontRegardless()

        return Surface(panel: panel, hover: container, screen: screen)
    }

    private func updatePeekTargets() {
        for surface in self.surfaces {
            let id = NotchGeometry.displayID(of: surface.screen)
            guard let peek = self.state.peek(on: id) else {
                surface.hover.peekRect = .zero
                continue
            }
            let anchor = NotchGeometry.anchor(on: surface.screen)
            let layout = peek.layout(notchWidth: anchor.width, height: anchor.height)
            surface.hover.peekRect = layout.frame.offsetBy(
                dx: 0, dy: NotchState.windowHeight - anchor.height
            )
        }
        self.updatePointerTargets()
    }

    private func updatePointerTargets() {
        let point = NSEvent.mouseLocation
        let target = self.surfaces.firstIndex { surface in
            let frame = surface.panel.frame
            return point.x >= frame.minX && point.x <= frame.maxX
                && point.y >= frame.minY && point.y <= frame.maxY
        }
        // Exit the old display before entering the new one so it cannot cancel the new hover.
        for (index, surface) in self.surfaces.enumerated() where index != target {
            surface.hover.updatePointer(at: point)
        }
        if let target { self.surfaces[target].hover.updatePointer(at: point) }
    }

    private func activateNotification(id: String) {
        guard let notification = self.notifications.current, notification.id == id else { return }
        self.notifications.activate(notification)
        self.collapse()
    }

    /// Brushing past the notch on the way to the menu bar should not open it, so opening waits
    /// for the pointer to actually settle there.
    private func expand(on screen: NSScreen) {
        self.collapseTask?.cancel()
        let id = NotchGeometry.displayID(of: screen)
        guard self.state.expandedScreen != id, self.expandTask == nil else { return }

        let delay = NSApp.currentSystemPresentationOptions.contains(.fullScreen)
            ? max(Settings.shared.hoverDelay, 0.7)
            : Settings.shared.hoverDelay
        self.expandTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.expandTask = nil
            guard self.pointerIsOnTrigger(of: screen) else { return }
            self.peekTask?.cancel()
            self.transientPeek = nil
            if self.state.peekScreen != id { self.state.peek = nil }
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
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.state.expandedScreen = nil
            self?.updateVisiblePeek()
        }
    }
}
