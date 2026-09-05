import SwiftUI
import UniformTypeIdentifiers

enum NotchTab: String, CaseIterable, Identifiable {
    case music
    case tasks
    case calendar
    case shelf

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .music: return "Música"
        case .tasks: return "Tareas"
        case .calendar: return "Agenda"
        case .shelf: return "Archivos"
        }
    }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .tasks: return "checklist"
        case .calendar: return "calendar"
        case .shelf: return "tray.full"
        }
    }
}

struct NotchView: View {
    @ObservedObject var media: MediaController
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var state: NotchState
    @ObservedObject var calendar: CalendarManager
    @ObservedObject var thumbnails: ShelfThumbnails
    @ObservedObject var tasks: TaskStore
    /// Height of the physical cutout. Content must start below it or the camera housing eats it.
    let notchHeight: CGFloat
    /// Width of the cutout, so the strip beside it can carry content instead of being padding.
    let notchWidth: CGFloat
    let screenID: CGDirectDisplayID
    let onDropTargeted: (Bool) -> Void

    @State private var dropActive = false
    @Namespace private var tabNamespace
    /// Set while dragging the progress bar, so the bar follows the finger instead of the player.
    @State private var scrubFraction: Double?
    @State private var taskInput = ""

    private var expanded: Bool { self.state.isExpanded(on: self.screenID) }
    private var isOpen: Bool { self.state.isOpen(on: self.screenID) }

    /// Radii grow with the panel: tight like the real cutout when closed, wide when open.
    private var shape: NotchShape {
        NotchShape(
            topRadius: self.isOpen ? 19 : 6,
            bottomRadius: self.isOpen ? 24 : 14
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Nothing is drawn while closed. Painting the cutout black looked fine in theory,
                // but the rounded shape never lines up with the real bezel and reads as a blob
                // hanging off the menu bar.
                Color.black.opacity(self.isOpen ? 1 : 0)

                // Always laid out at full width so nothing reflows mid-animation; the container
                // clips it. Swapping views with if/else instead would pop, not grow.
                self.panelContent
                    .frame(width: NotchState.windowWidth, height: self.state.contentHeight, alignment: .top)
                    .opacity(self.expanded ? 1 : 0)
                    .animation(.easeOut(duration: 0.18).delay(self.expanded ? 0.08 : 0), value: self.expanded)

                if let peek = state.peek(on: self.screenID), !self.expanded {
                    self.peekStrip(peek)
                        .frame(width: NotchState.windowWidth, height: NotchState.peekHeight, alignment: .top)
                        .transition(.opacity)
                }
            }
            .frame(
                width: self.isOpen ? NotchState.windowWidth : self.notchWidth,
                height: self.isOpen ? self.state.currentHeight(on: self.screenID) : self.notchHeight,
                alignment: .top
            )
            .clipShape(self.shape)
            .overlay(self.shape.stroke(.white.opacity(self.isOpen ? (self.dropActive ? 0.5 : 0.10) : 0), lineWidth: 1))
            // The window never resizes; this is the only thing that moves.
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: self.expanded)
            .animation(.spring(response: 0.34, dampingFraction: 0.8), value: self.state.peek)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: self.state.tab)

            Spacer(minLength: 0)
        }
        .frame(width: NotchState.windowWidth, height: NotchState.windowHeight, alignment: .top)
        .onDrop(of: [.fileURL], isTargeted: self.targetBinding) { providers in
            self.receive(providers)
        }
    }

    private var panelContent: some View {
        VStack(spacing: 8) {
            self.ears
            Group {
                switch self.state.tab {
                case .music: self.musicTab
                case .tasks: self.tasksTab
                case .calendar: self.calendarTab
                case .shelf: self.shelfTab
                }
            }
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The concave shoulders already inset the body by topRadius; the content needs its own
            // breathing room on top of that.
            .padding(.horizontal, 34)
        }
        .padding(.bottom, 14)
    }

    private var targetBinding: Binding<Bool> {
        Binding(
            get: { self.dropActive },
            set: { active in
                self.dropActive = active
                // Dragging a file in means the shelf is what you want to see.
                if active { self.state.tab = .shelf }
                self.onDropTargeted(active)
            }
        )
    }

    /// Deliberately not the full panel: a peek is a glance, so it shows one line and leaves.
    private func peekStrip(_ peek: NotchState.Peek) -> some View {
        HStack(spacing: 0) {
            Group {
                if peek.usesArtwork, let artwork = media.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(systemName: peek.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 26, height: 26)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)

            Color.clear.frame(width: self.notchWidth)

            VStack(alignment: .leading, spacing: 1) {
                Text(peek.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(peek.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
        }
        .foregroundStyle(.white)
        .padding(.top, self.notchHeight + 4)
        .padding(.horizontal, 34)
    }

    // MARK: - Ears

    /// The strip level with the cutout. The tabs live here, split around the camera housing, so the
    /// panel spends no row on them and the dead space beside the notch finally carries something.
    private var ears: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                self.tabButton(.music)
                self.tabButton(.tasks)
                self.tabButton(.calendar)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 30)

            // The camera housing itself: nothing can be drawn here.
            Color.clear.frame(width: self.notchWidth)

            HStack(spacing: 8) {
                self.tabButton(.shelf)
                self.batteryBadge
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 30)
        }
        .frame(height: self.notchHeight)
    }

    /// An icon when idle; the selected tab expands to carry its label. Two labelled pills would
    /// not fit in the 137pt of usable strip on each side of the cutout.
    private func tabButton(_ item: NotchTab) -> some View {
        let active = item == self.state.tab
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { self.state.tab = item }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: item.symbol).font(.system(size: 11))
                if active {
                    Text(item.title).font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, active ? 9 : 6)
            .padding(.vertical, 4)
            .background {
                if active {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .matchedGeometryEffect(id: "activeTab", in: self.tabNamespace)
                }
            }
            .foregroundStyle(.white.opacity(active ? 0.95 : 0.45))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    @ViewBuilder
    private var batteryBadge: some View {
        if let battery = battery.state {
            HStack(spacing: 3) {
                Image(systemName: battery.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(battery.isCharging || battery.isCharged
                        ? AnyShapeStyle(Color.green)
                        : AnyShapeStyle(.white.opacity(0.6)))
                Text("\(battery.percent)%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(battery.percent < 15 ? AnyShapeStyle(Color.red) : AnyShapeStyle(.white.opacity(0.6)))
            }
            .help(battery.detail ?? "Batería")
        }
    }

    // MARK: - Music

    @ViewBuilder
    private var musicTab: some View {
        if let track = media.track {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    self.artwork
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if let icon = media.appIcon {
                                Image(nsImage: icon).resizable().frame(width: 11, height: 11)
                            }
                            // Spotify exposes no playlist, so the album stands in for it.
                            Text(track.playlist ?? track.album)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        self.control("backward.fill") { self.media.previous() }
                        self.control(track.isPlaying ? "pause.fill" : "play.fill", size: 19) { self.media.playPause() }
                        self.control("forward.fill") { self.media.next() }
                    }
                }
                self.progress(track)
            }
            .foregroundStyle(.white)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                Text("Nada sonando").font(.footnote)
            }
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// Redrawn locally between AppleScript samples so the bar advances smoothly, and draggable
    /// to seek. While scrubbing the bar follows the pointer and ignores the sampled position.
    private func progress(_ track: MediaController.Track) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let live = track.duration > 0 ? min(1, max(0, self.media.elapsed / track.duration)) : 0
            let fraction = self.scrubFraction ?? live
            let scrubbing = self.scrubFraction != nil

            VStack(spacing: 3) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.18))
                            .frame(height: scrubbing ? 5 : 3)
                        Capsule()
                            .fill(self.media.tint.map { Color(nsColor: $0) } ?? .white.opacity(0.85))
                            .frame(width: geometry.size.width * fraction, height: scrubbing ? 5 : 3)
                        Circle()
                            .fill(.white)
                            .frame(width: scrubbing ? 10 : 0, height: scrubbing ? 10 : 0)
                            .offset(x: geometry.size.width * fraction - (scrubbing ? 5 : 0))
                    }
                    .frame(maxHeight: .infinity)
                    // The bar itself is 3pt tall; the grab area has to be finger-sized.
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard geometry.size.width > 0 else { return }
                                withAnimation(.easeOut(duration: 0.1)) {
                                    self.scrubFraction = min(1, max(0, value.location.x / geometry.size.width))
                                }
                            }
                            .onEnded { value in
                                guard geometry.size.width > 0, track.duration > 0 else { return }
                                let target = min(1, max(0, value.location.x / geometry.size.width))
                                self.media.seek(to: target * track.duration)
                                withAnimation(.easeOut(duration: 0.12)) { self.scrubFraction = nil }
                            }
                    )
                }
                .frame(height: 14)

                HStack {
                    Text(Self.clock(fraction * track.duration))
                    Spacer()
                    Text(Self.clock(track.duration))
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var artwork: some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image).resizable()
            } else {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5)))
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func control(_ symbol: String, size: CGFloat = 15, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tasks

    @ViewBuilder
    private var tasksTab: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Tarea  #proyecto @app !tipo en 25m", text: self.$taskInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .onSubmit {
                        self.tasks.add(self.taskInput)
                        self.taskInput = ""
                    }
            }
            .padding(.bottom, 2)

            if self.tasks.pending.isEmpty {
                Text("Sin tareas pendientes")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(self.tasks.pending) { task in
                            self.taskRow(task)
                        }
                    }
                }
            }
        }
    }

    private func taskRow(_ task: TodoTask) -> some View {
        HStack(spacing: 8) {
            Button { self.tasks.toggle(task) } label: {
                Image(systemName: "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)

            Text(task.title)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer(minLength: 4)

            if let project = task.project {
                self.chip("#" + project, tint: .blue)
            }
            if let type = task.type {
                self.chip("!" + type, tint: .purple)
            }
            if let app = task.app, let url = TaskStore.appURL(named: app) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Abrir " + app)
            }
            if let due = task.dueLabel {
                Text(due)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(task.isOverdue ? AnyShapeStyle(Color.red) : AnyShapeStyle(.white.opacity(0.5)))
            }
        }
        .foregroundStyle(.white)
        .contextMenu {
            Button("Eliminar", role: .destructive) { self.tasks.remove(task) }
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.25)))
            .foregroundStyle(.white.opacity(0.85))
    }

    // MARK: - Calendar

    @ViewBuilder
    private var calendarTab: some View {
        switch self.calendar.access {
        case .granted:
            if self.calendar.events.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.calendar.accounts.isEmpty ? "No hay cuentas de calendario" : "Nada más por hoy")
                        .font(.footnote)
                    if self.calendar.accounts.isEmpty {
                        Text("Agregá Google en Ajustes → Cuentas de Internet y aparece acá.")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(self.calendar.events) { event in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color(nsColor: event.color))
                                    .frame(width: 3, height: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.title)
                                        .font(.system(size: 12, weight: event.isNow ? .semibold : .regular))
                                        .lineLimit(1)
                                    HStack(spacing: 5) {
                                        Text(event.timeLabel)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.5))
                                        if let countdown = event.countdown {
                                            Text(countdown)
                                                .font(.system(size: 9))
                                                .foregroundStyle(.white.opacity(0.35))
                                        }
                                        ForEach(event.accounts, id: \.self) { account in
                                            Text(account)
                                                .font(.system(size: 9, weight: .medium))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(.white.opacity(0.12)))
                                                .foregroundStyle(.white.opacity(0.7))
                                        }
                                    }
                                }
                                Spacer(minLength: 0)
                                if let meeting = event.meeting {
                                    self.joinButton(meeting, prominent: event.isJoinable)
                                }
                                if event.isNow {
                                    Text("ahora")
                                        .font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(.white.opacity(0.16)))
                                }
                            }
                        }
                    }
                }
                .foregroundStyle(.white)
            }
        case .writeOnly:
            Text("El permiso quedó en «solo escritura» y no alcanza para leer. Cambialo a acceso completo en Ajustes → Privacidad → Calendarios.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .denied:
            Text("Permiso de calendario denegado. Activalo en Ajustes del sistema.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .unknown:
            HStack(spacing: 10) {
                Text("Ver tu agenda del día").font(.footnote).foregroundStyle(.white.opacity(0.6))
                Button("Dar permiso") { self.calendar.requestAccess() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Filled while the meeting is about to start or already running, outlined otherwise, so the
    /// one you are late for reads differently from the one at six.
    private func joinButton(_ meeting: MeetingLink.Match, prominent: Bool) -> some View {
        Button {
            NSWorkspace.shared.open(meeting.url)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "video.fill").font(.system(size: 9))
                Text("Unirse").font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white.opacity(0.12))))
            .foregroundStyle(.white.opacity(prominent ? 1 : 0.7))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Abrir \(meeting.provider)")
    }

    // MARK: - Shelf

    @ViewBuilder
    private var shelfTab: some View {
        if self.shelf.items.isEmpty {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    .white.opacity(self.dropActive ? 0.5 : 0.18),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
                .overlay(
                    HStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down")
                        Text("Soltá archivos acá").font(.footnote)
                    }
                    .foregroundStyle(.white.opacity(self.dropActive ? 0.9 : 0.45))
                )
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(self.shelf.items, id: \.path) { url in
                        ShelfChip(url: url, thumbnails: self.thumbnails) { self.shelf.remove(url); self.thumbnails.forget(url) }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func receive(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    self.shelf.add(url)
                    self.state.tab = .shelf
                }
            }
        }
        return accepted
    }
}

private struct ShelfChip: View {
    let url: URL
    @ObservedObject var thumbnails: ShelfThumbnails
    let onRemove: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: self.thumbnails.thumbnail(for: self.url, size: CGSize(width: 44, height: 44))
                ?? ShelfStore.icon(for: self.url))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
            Text(self.url.lastPathComponent)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 62)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(self.hovered ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if self.hovered {
                Button(action: self.onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { self.hovered = $0 }
        // Dragging out hands the real file to the destination app.
        .onDrag { NSItemProvider(contentsOf: self.url) ?? NSItemProvider() }
        .help(self.url.lastPathComponent)
    }
}
