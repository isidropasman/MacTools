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

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    /// Where the panel hangs from. Screens without a cutout get a synthetic one at the top centre.
    static func anchor(on screen: NSScreen, syntheticWidth: CGFloat = 185, syntheticHeight: CGFloat = 32) -> NSRect {
        if let real = self.rect(on: screen) { return real }
        return NSRect(
            x: screen.frame.midX - syntheticWidth / 2,
            y: screen.frame.maxY - syntheticHeight,
            width: syntheticWidth,
            height: syntheticHeight
        )
    }

    /// Where hovering opens it. On a real notch that is the cutout, which the eye can aim at. On a
    /// monitor there is nothing to aim at, so it takes a deliberate push into the very top edge.
    static func trigger(on screen: NSScreen) -> NSRect {
        if let real = self.rect(on: screen) { return real }

        let width: CGFloat = 140
        let height: CGFloat = 4
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// `NSRect.contains` excludes the max edge, and at the top of the screen the pointer clamps to
    /// exactly that edge, so a strict containment test never matched. Anything above the trigger's
    /// bottom edge and within its columns counts.
    static func pointerIsOnNotch(_ pointer: NSPoint, trigger: NSRect, slack: CGFloat) -> Bool {
        pointer.x >= trigger.minX - slack
            && pointer.x <= trigger.maxX + slack
            && pointer.y >= trigger.minY - slack
    }

    /// A physical cutout forgives a few points; a synthetic one should not.
    static func slack(on screen: NSScreen) -> CGFloat {
        self.hasNotch(screen) ? 6 : 1
    }
}
