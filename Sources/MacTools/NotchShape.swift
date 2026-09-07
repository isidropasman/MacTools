import SwiftUI

/// The panel is not a rounded rectangle. The top corners curve *inward* so the body flows out of
/// the bezel, and only the bottom corners bulge outward. Without the inward top curve the panel
/// reads as a box taped under the screen edge.
///
/// Radii match boring.notch's: 19/24 expanded, 6/14 collapsed.
struct NotchShape: Shape {
    var topRadius: CGFloat = 19
    var bottomRadius: CGFloat = 24

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(self.topRadius, self.bottomRadius) }
        set {
            self.topRadius = newValue.first
            self.bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Concave shoulder on the left.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + self.topRadius, y: rect.minY + self.topRadius),
            control: CGPoint(x: rect.minX + self.topRadius, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.minX + self.topRadius, y: rect.maxY - self.bottomRadius))

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + self.topRadius + self.bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + self.topRadius, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - self.topRadius - self.bottomRadius, y: rect.maxY))

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - self.topRadius, y: rect.maxY - self.bottomRadius),
            control: CGPoint(x: rect.maxX - self.topRadius, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - self.topRadius, y: rect.minY + self.topRadius))

        // Concave shoulder on the right.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - self.topRadius, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}
