import AppKit
import Combine
import Foundation

/// Expansion and tab live here rather than in the view, so the SwiftUI tree stays mounted and can
/// animate itself. Swapping the hosting view's rootView would restart every animation.
@MainActor
final class NotchState: ObservableObject {
    /// A brief, unrequested appearance: the notch telling you something instead of waiting to be asked.
    struct Peek: Equatable {
        let title: String
        let subtitle: String
        let symbol: String
        /// The cover is read at render time, not captured here: at the instant the track changes the
        /// new artwork has not downloaded yet, so a snapshot shows the previous song's cover.
        let usesArtwork: Bool
    }

    @Published var tab: NotchTab = .music
    /// Which display is showing the panel. One shared flag opened every screen at once.
    @Published var expandedScreen: CGDirectDisplayID?
    @Published var peek: Peek?
    @Published var peekScreen: CGDirectDisplayID?

    func isExpanded(on screen: CGDirectDisplayID) -> Bool { self.expandedScreen == screen }
    func peek(on screen: CGDirectDisplayID) -> Peek? { self.peekScreen == screen ? self.peek : nil }

    /// Hovering always wins over a peek, so the pointer never fights an animation it did not start.
    func isOpen(on screen: CGDirectDisplayID) -> Bool {
        self.isExpanded(on: screen) || self.peek(on: screen) != nil
    }

    func currentHeight(on screen: CGDirectDisplayID) -> CGFloat {
        if self.isExpanded(on: screen) { return self.contentHeight }
        return self.peek(on: screen) != nil ? Self.peekHeight : 0
    }

    /// Music is one compact row; the shelf needs an icon plus its filename, the agenda a list.
    var contentHeight: CGFloat {
        switch self.tab {
        case .music: return 132
        case .tasks: return 186
        case .calendar: return 180
        case .shelf: return 172
        }
    }

    static let peekHeight: CGFloat = 78
    /// The window is fixed at this size and never resized; only the content inside it grows.
    static let windowHeight: CGFloat = 190
    static let windowWidth: CGFloat = 500
}
