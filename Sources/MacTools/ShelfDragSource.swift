import AppKit
import SwiftUI

struct ShelfDragSource: NSViewRepresentable {
    let url: URL
    let onDrop: () -> Void
    let onOpen: () -> Void
    let onRemove: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> ShelfDragSourceView {
        let view = ShelfDragSourceView()
        self.update(view)
        return view
    }

    func updateNSView(_ view: ShelfDragSourceView, context: Context) {
        self.update(view)
    }

    private func update(_ view: ShelfDragSourceView) {
        view.url = self.url
        view.onDrop = self.onDrop
        view.onOpen = self.onOpen
        view.onRemove = self.onRemove
        view.onHover = self.onHover
    }
}

final class ShelfDragSourceView: NSView, NSDraggingSource {
    var url = URL(fileURLWithPath: "/")
    var onDrop: (() -> Void)?
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var mouseDownPoint: NSPoint?
    private var dragSession: NSDraggingSession?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { self.removeTrackingArea(trackingArea) }
        let trackingArea = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        self.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) { self.onHover?(true) }
    override func mouseExited(with event: NSEvent) { self.onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            self.onOpen?()
            self.mouseDownPoint = nil
            return
        }
        self.mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard self.dragSession == nil,
              let mouseDownPoint,
              hypot(event.locationInWindow.x - mouseDownPoint.x, event.locationInWindow.y - mouseDownPoint.y) >= 4
        else { return }

        let item = NSDraggingItem(pasteboardWriter: self.url as NSURL)
        item.setDraggingFrame(self.bounds, contents: NSWorkspace.shared.icon(forFile: self.url.path))
        self.dragSession = self.beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        self.mouseDownPoint = nil
        self.dragSession = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(self.menuItem("Abrir", action: #selector(self.openFile)))
        menu.addItem(self.menuItem("Mostrar en Finder", action: #selector(self.showInFinder)))
        menu.addItem(.separator())
        menu.addItem(self.menuItem("Quitar del estante", action: #selector(self.removeFromShelf)))
        menu.popUp(positioning: nil, at: event.locationInWindow, in: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        self.dragSession = nil
        guard operation.contains(.copy) else { return }
        DispatchQueue.main.async { [weak self] in self?.onDrop?() }
    }

    @objc private func openFile() { self.onOpen?() }
    @objc private func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting([self.url]) }
    @objc private func removeFromShelf() { self.onRemove?() }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}
