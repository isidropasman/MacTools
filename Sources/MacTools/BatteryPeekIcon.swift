import SwiftUI

struct BatteryPeekIcon: View {
    let percent: Int
    var tint: Color = .white

    var body: some View {
        Canvas { context, _ in
            let body = CGRect(x: 0.5, y: 0.5, width: 20, height: 11)
            context.stroke(
                Path(roundedRect: body, cornerRadius: 2.5),
                with: .color(.white.opacity(0.65)), lineWidth: 1
            )
            context.fill(
                Path(roundedRect: CGRect(x: 22, y: 4, width: 1.5, height: 4), cornerRadius: 0.75),
                with: .color(.white.opacity(0.65))
            )
            let fraction = CGFloat(min(max(self.percent, 0), 100)) / 100
            if fraction > 0 {
                context.fill(
                    Path(roundedRect: CGRect(x: 2.5, y: 2.5, width: 16 * fraction, height: 7), cornerRadius: 1),
                    with: .color(self.tint.opacity(0.9))
                )
            }
        }
        .frame(width: 24, height: 12)
        .accessibilityLabel("Batería \(self.percent)%")
    }
}
