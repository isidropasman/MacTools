import AppKit

enum NotchGeometry {
    /// The notch cutout in screen coordinates, or nil on displays without one (external monitors).
    static func rect(on screen: NSScreen) -> NSRect? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return nil }

        let width = screen.frame.width - left.width - right.width
        guard width > 0 else { return nil }

        return NSRect(
            x: screen.frame.minX + left.width,
            y: screen.frame.maxY - screen.safeAreaInsets.top,
            width: width,
            height: screen.safeAreaInsets.top
        )
    }

    static func hasNotch(_ screen: NSScreen) -> Bool {
        self.rect(on: screen) != nil
    }

    /// `NSRect.contains` excludes the max edge, and at the top of the screen the pointer clamps to
    /// exactly that edge, so a strict containment test never matched. Anything above the anchor's
    /// bottom edge and within its columns counts as being on the notch.
    static func pointerIsOnNotch(_ pointer: NSPoint, anchor: NSRect, slack: CGFloat = 6) -> Bool {
        pointer.x >= anchor.minX - slack
            && pointer.x <= anchor.maxX + slack
            && pointer.y >= anchor.minY - slack
    }

    /// Screens without a cutout get a synthetic one at the top centre, so an external monitor
    /// still has somewhere for the panel to hang from.
    static func anchor(on screen: NSScreen, syntheticWidth: CGFloat = 185, syntheticHeight: CGFloat = 32) -> NSRect {
        if let real = self.rect(on: screen) { return real }
        return NSRect(
            x: screen.frame.midX - syntheticWidth / 2,
            y: screen.frame.maxY - syntheticHeight,
            width: syntheticWidth,
            height: syntheticHeight
        )
    }
}
