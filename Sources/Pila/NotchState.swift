import Combine
import Foundation

/// Expansion and tab live here rather than in the view, so the SwiftUI tree stays mounted and can
/// animate itself. Swapping the hosting view's rootView would restart every animation.
@MainActor
final class NotchState: ObservableObject {
    @Published var tab: NotchTab = .music
    @Published var expanded = false

    /// Music is one compact row; the shelf needs an icon plus its filename, the agenda a list.
    var contentHeight: CGFloat {
        switch self.tab {
        case .music: return 132
        case .calendar: return 180
        case .shelf: return 172
        }
    }

    /// The window is fixed at this size and never resized; only the content inside it grows.
    static let windowHeight: CGFloat = 190
    static let windowWidth: CGFloat = 500
}
