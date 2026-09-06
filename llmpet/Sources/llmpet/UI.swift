import AppKit
import SwiftUI

let petSize: CGFloat = 76

/// A custom pet.png is almost never square, so the panel takes the image's own
/// aspect ratio — otherwise the character sits letterboxed inside a square and
/// reads as "a box with a picture in it".
enum PetAsset {
    static let image = NSImage(contentsOfFile: NSHomeDirectory() + "/.llmpet/pet.png")

    static var aspect: CGFloat {
        guard let image, image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
    }

    static var panelSize: NSSize {
        NSSize(width: petSize * aspect + 14, height: petSize + 14)
    }
}

struct PetView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        ZStack(alignment: .topTrailing) {
            petImage
                .frame(width: petSize * PetAsset.aspect, height: petSize)

            if store.readyCount > 0 {
                Text("\(store.readyCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(
                        Circle()
                            .fill(.green)
                            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.35), radius: 2)
                    )
                    .offset(x: 5, y: -5)
            }
        }
        .frame(width: PetAsset.panelSize.width, height: PetAsset.panelSize.height,
               alignment: .center)
    }

    @ViewBuilder
    private var petImage: some View {
        if let custom = PetAsset.image {
            Image(nsImage: custom)
                .resizable()
                .scaledToFit()
                // The shadow follows the alpha, so a cut-out character keeps its
                // silhouette instead of looking pasted on.
                .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
        } else {
            DefaultPet()
        }
    }
}

let listWidth: CGFloat = 320

struct SessionListView: View {
    @ObservedObject var store: SessionStore
    let onOpen: (LLMSession) -> Void
    /// Width the panel unfolds *from*: the notch, so the list reads as coming out
    /// of it rather than appearing on top of it.
    var collapsedWidth: CGFloat = 180

    @AppStorage("collapsedSections") private var collapsedRaw = ""
    @State private var unfolded = false

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: ",").map(String.init))
    }

    private func toggle(_ state: SessionState) {
        var next = collapsed
        if next.contains(state.rawValue) { next.remove(state.rawValue) }
        else { next.insert(state.rawValue) }
        collapsedRaw = next.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.sessions.isEmpty {
                Text("Sin sesiones")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            ForEach(store.sections, id: \.state) { section in
                SectionHeader(
                    title: section.title,
                    count: section.sessions.count,
                    state: section.state,
                    isCollapsed: collapsed.contains(section.state.rawValue)
                ) { toggle(section.state) }

                if !collapsed.contains(section.state.rawValue) {
                    ForEach(section.sessions) { session in
                        SessionRow(
                            session: session,
                            isPinned: Shelf.pinned.contains(session.id),
                            action: { onOpen(session) },
                            onPin: { store.togglePin(session) },
                            onDismiss: { store.dismiss(session) }
                        )
                    }
                }
            }
            if !store.projectUsage.isEmpty {
                Divider().padding(.top, 5)
                ProjectUsageFooter(projects: store.projectUsage, total: store.totalUsage)
            }
        }
        .frame(width: listWidth)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        // Unfold out of the notch. Scaling rather than animating the frame keeps
        // the view's layout size constant, so the panel can still be measured
        // and positioned normally while the animation plays inside it.
        .scaleEffect(x: unfolded ? 1 : collapsedWidth / listWidth,
                     y: unfolded ? 1 : 0.02,
                     anchor: .top)
        .opacity(unfolded ? 1 : 0)
        .onAppear {
            // The window is placed first; animating on the next runloop pass
            // means the spring starts from the collapsed state, not mid-flight.
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.74)) {
                    unfolded = true
                }
            }
        }
        .onDisappear { unfolded = false }
    }
}

private struct ProjectUsageFooter: View {
    let projects: [(name: String, usage: TokenUsage)]
    let total: TokenUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("TOKENS POR PROYECTO")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                Text(formatTokens(total.billable))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.bottom, 2)

            ForEach(projects.prefix(5), id: \.name) { project in
                HStack {
                    Text(project.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Text(formatTokens(project.usage.billable))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 5)
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    let state: SessionState
    let isCollapsed: Bool
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .foregroundStyle(.secondary)
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(state == .ready ? .primary : .secondary)
                .tracking(0.5)
            Text("\(count)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 3)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
    }
}

private struct SessionRow: View {
    let session: LLMSession
    let isPinned: Bool
    let action: () -> Void
    let onPin: () -> Void
    let onDismiss: () -> Void

    @State private var hovering = false

    /// "vancouver · Claude · cloud" — where it lives and what is running in it.
    private var subtitle: String {
        [session.context, session.agent, session.origin]
            .compactMap { $0 }
            .reduce(into: [String]()) { parts, part in
                if !part.isEmpty, !parts.contains(part) { parts.append(part) }
            }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 9) {
            stateMark.frame(width: 12)
            SourceIcon(session: session)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                    }
                    Text(session.title)
                        .font(.system(size: 12,
                                      weight: session.state == .ready ? .bold : .regular))
                        .foregroundStyle(session.state == .seen ? .secondary : .primary)
                        .lineLimit(1)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)

            if hovering {
                Button(action: onPin) {
                    Image(systemName: isPinned ? "pin.slash" : "pin")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isPinned ? "Desanclar" : "Anclar")

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Sacar de la lista hasta que tenga actividad nueva")
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(rightLabel)
                    .font(.system(size: 9, weight: session.state == .working ? .semibold : .regular))
                    .foregroundStyle(session.state == .working
                        ? Color.green : Color.primary.opacity(0.4))
                if let tokens = session.tokens, tokens.billable > 0 {
                    Text(formatTokens(tokens.billable))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.09) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }

    /// Working sessions answer "how long has it been at it", everything else
    /// answers "how long since it last did anything".
    private var rightLabel: String {
        if session.state == .working, let since = session.activeSince {
            return "▶ " + relativeAge(since)
        }
        return relativeAge(session.lastActivity)
    }

    @ViewBuilder
    private var stateMark: some View {
        switch session.state {
        case .working:
            ProgressView().controlSize(.mini).scaleEffect(0.65)
        case .ready:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .error:
            Circle().fill(.red).frame(width: 8, height: 8)
        case .seen:
            Circle().fill(.secondary.opacity(0.4)).frame(width: 8, height: 8)
        }
    }
}

private func relativeAge(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 60 { return "ahora" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86400)d"
}

/// Borderless panels are not key when the click lands, so AppKit swallows the
/// first mouse event unless the view opts in. Without this list rows never fire.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
