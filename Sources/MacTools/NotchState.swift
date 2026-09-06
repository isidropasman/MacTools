import AppKit
import Combine
import Foundation
import SwiftUI

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
        var tint: Color = .white
    }

    @Published var tab: NotchTab = Settings.shared.rememberLastTab
        ? (Settings.shared.lastTab.flatMap(NotchTab.init(rawValue:)) ?? .home)
        : .home
    {
        didSet { Settings.shared.lastTab = self.tab.rawValue }
    }
    /// Which display is showing the panel. One shared flag opened every screen at once.
    @Published var expandedScreen: CGDirectDisplayID?
    @Published var peek: Peek?
    /// Set by the panel's AppKit drag destination so the SwiftUI content can react to it.
    @Published var dropTargeted = false
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

    /// One height for every tab. Growing and shrinking as you move between them made the panel
    /// feel like it was breathing at you.
    var contentHeight: CGFloat { 178 }

    static let peekHeight: CGFloat = 78
    /// The window is fixed at this size and never resized; only the content inside it grows.
    static let windowHeight: CGFloat = 190
    static let windowWidth: CGFloat = 520
}
