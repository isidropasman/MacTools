import AppKit
import SwiftUI

/// App icons come straight from the installed bundles, so Conductor looks like
/// Conductor and Chrome looks like Chrome without shipping any art.
/// Favicons are fetched once per URL and kept for the process lifetime.
final class IconCache: ObservableObject {
    static let shared = IconCache()

    private var apps: [String: NSImage] = [:]
    @Published private var favicons: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    func app(_ path: String?) -> NSImage? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        if let cached = apps[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        apps[path] = icon
        return icon
    }

    func favicon(_ url: String?) -> NSImage? {
        guard let url, let parsed = URL(string: url) else { return nil }
        if let cached = favicons[url] { return cached }
        guard !inFlight.contains(url) else { return nil }
        inFlight.insert(url)
        URLSession.shared.dataTask(with: parsed) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                self?.inFlight.remove(url)
                self?.favicons[url] = image
            }
        }.resume()
        return nil
    }
}

/// App icon with the site favicon tucked into the corner — "Chrome + ChatGPT".
struct SourceIcon: View {
    let session: LLMSession
    @ObservedObject private var cache = IconCache.shared

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            base.frame(width: 20, height: 20)

            if let favicon = cache.favicon(session.faviconURL) {
                Image(nsImage: favicon)
                    .resizable()
                    .frame(width: 11, height: 11)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 13, height: 13)
                    )
                    .offset(x: 4, y: 3)
            }
        }
        .frame(width: 24, height: 20)
    }

    @ViewBuilder
    private var base: some View {
        if let icon = cache.app(session.appPath) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: session.source == "chrome" ? "globe" : "terminal.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}

/// Original mascot, drawn in code so there's no asset to ship and no character
/// to borrow. Dropping a ~/.llmpet/pet.png replaces it wholesale.
struct DefaultPet: View {
    @Environment(\.colorScheme) private var scheme

    private var shell: Color { scheme == .dark ? Color(white: 0.22) : Color(white: 0.97) }
    private var ink: Color { scheme == .dark ? Color(white: 0.05) : Color(white: 0.12) }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.32)
                    .fill(shell)
                    .overlay(
                        RoundedRectangle(cornerRadius: s * 0.32)
                            .strokeBorder(ink.opacity(0.85), lineWidth: s * 0.045)
                    )
                    .shadow(color: .black.opacity(0.28), radius: s * 0.06, y: s * 0.03)

                // Visor with two highlights — reads as "eyes" at 64px.
                Capsule()
                    .fill(ink)
                    .frame(width: s * 0.58, height: s * 0.26)
                    .overlay(
                        HStack(spacing: s * 0.09) {
                            Circle().fill(.white.opacity(0.9)).frame(width: s * 0.07)
                            Circle().fill(.white.opacity(0.55)).frame(width: s * 0.05)
                        }
                        .offset(x: -s * 0.04, y: -s * 0.02)
                    )
                    .offset(y: -s * 0.02)

                // Antenna
                Circle()
                    .fill(.green)
                    .frame(width: s * 0.1)
                    .overlay(Circle().strokeBorder(ink.opacity(0.85), lineWidth: s * 0.03))
                    .offset(y: -s * 0.5)
            }
            .frame(width: s, height: s)
        }
    }
}
