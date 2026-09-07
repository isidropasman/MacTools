import AppKit
import SwiftUI

/// Dragging used to be a SwiftUI DragGesture that called setFrameOrigin on every
/// change — that repositions the window a frame behind the cursor and stutters.
/// performDrag hands the whole drag to the window server, which is what makes it
/// track the mouse exactly. Cost: mouse handling has to live in AppKit, so the
/// SwiftUI content below is purely visual and never sees events.
final class PetContainerView: NSView {
    var onTap: () -> Void = {}

    private var dragging = false

    init(content: some View, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Swallow hits for the hosting view so clicks and drags always land here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { dragging = false }

    override func mouseDragged(with event: NSEvent) {
        dragging = true
        window?.performDrag(with: event)
        // performDrag runs its own event loop and returns once the mouse is up.
        if let origin = window?.frame.origin {
            UserDefaults.standard.set(NSStringFromPoint(origin), forKey: "petOrigin")
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging { onTap() }
        dragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Mostrar u ocultar la lista",
                                action: #selector(triggerTap), keyEquivalent: "l")
        toggle.keyEquivalentModifierMask = [.option, .command]
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Iniciar con el sistema",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.state = LoginItem.isEnabled ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Salir", action: #selector(NSApp.terminate(_:)),
                              keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.option, .command]
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func triggerTap() { onTap() }

    @objc private func toggleLoginItem() { LoginItem.toggle() }
}
