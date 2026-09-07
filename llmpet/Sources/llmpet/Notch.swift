import AppKit

/// Geometry of the notch, so the list can unfold from it instead of just
/// appearing. On Macs without a notch everything still works — the "notch"
/// collapses to a narrow strip at top centre, which is the same animation.
enum Notch {
    static func width(on screen: NSScreen?) -> CGFloat {
        guard let screen else { return fallbackWidth }
        // auxiliaryTopLeftArea/RightArea are the usable menu-bar strips beside
        // the notch; what's left between them is the notch itself.
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return fallbackWidth }

        let gap = right.minX - left.maxX
        return gap > 1 ? gap : fallbackWidth
    }

    static func hasNotch(_ screen: NSScreen?) -> Bool {
        (screen?.safeAreaInsets.top ?? 0) > 0
    }

    /// Top-centre of the screen, just under the menu bar.
    static func anchor(on screen: NSScreen?, size: NSSize) -> CGPoint {
        let frame = screen?.frame ?? NSScreen.main?.frame ?? .zero
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        return CGPoint(x: frame.midX - size.width / 2, y: visible.maxY - size.height)
    }

    private static let fallbackWidth: CGFloat = 180
}
