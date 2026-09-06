import SwiftUI
import UniformTypeIdentifiers

enum NotchTab: String, CaseIterable, Identifiable {
    /// Music and the agenda share one screen: both are glance-sized and you almost always want to
    /// know what is playing and what is next at the same time.
    case home
    case tasks
    case sessions
    case shelf
    case config

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .home: return "Inicio"
        case .tasks: return "Tareas"
        case .sessions: return "Agentes"
        case .shelf: return "Archivos"
        case .config: return "Ajustes"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .tasks: return "checklist"
        case .sessions: return "cpu"
        case .shelf: return "tray.full"
        case .config: return "gearshape.fill"
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
    @ObservedObject var sessions: SessionStore
    /// Height of the physical cutout. Content must start below it or the camera housing eats it.
    let notchHeight: CGFloat
    /// Width of the cutout, so the strip beside it can carry content instead of being padding.
    let notchWidth: CGFloat
    let screenID: CGDirectDisplayID
    let onQuickAdd: () -> Void
    let onEditTask: (TodoTask) -> Void
    let onOpenSettings: () -> Void
    let onCollapse: () -> Void

    @ObservedObject private var settings = Settings.shared
    @Namespace private var tabNamespace
    /// Set while dragging the progress bar, so the bar follows the finger instead of the player.
    @State private var scrubFraction: Double?
    /// Tasks mid-celebration. The row stays on screen while it plays, then the store drops it.
    @State private var completing: Set<UUID> = []

    private var expanded: Bool { self.state.isExpanded(on: self.screenID) }
    private var isOpen: Bool { self.state.isOpen(on: self.screenID) }

    /// Radii grow with the panel: tight like the real cutout when closed, wide when open.
    private var shape: NotchShape {
        NotchShape(
            topRadius: self.isOpen ? 22 : 6,
            bottomRadius: self.isOpen ? 26 : 14
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Nothing is drawn while closed. Painting the cutout black looked fine in theory,
                // but the rounded shape never lines up with the real bezel and reads as a blob
                // hanging off the menu bar.
                // Flat black, not glass: the panel has to read as an extension of the bezel, and any
                // material lightens it enough to look like a window stuck under the menu bar. The
                // artwork's colour bleeds in from the left, which is the only thing that lifts it.
                ZStack {
                    Color.black
                    if let tint = media.tint, self.state.tab == .home {
                        RadialGradient(
                            colors: [Color(nsColor: tint).opacity(0.42), .clear],
                            center: UnitPoint(x: 0.12, y: 0.62),
                            startRadius: 0,
                            endRadius: NotchState.windowWidth * 0.62
                        )
                        .blur(radius: 34)
                    }
                }
                .opacity(self.isOpen ? 1 : 0)
                .animation(.easeInOut(duration: 0.5), value: self.media.tint)

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
            // No rim at all. What separates the panel from the desktop is the shadow under it,
            // which is also what stops it from looking like a flat rectangle taped to the screen.
            .shadow(color: .black.opacity(0.55), radius: 14, y: 5)
            .overlay(
                self.shape
                    .stroke(.white.opacity(0.5), lineWidth: 1)
                    .opacity(self.isOpen && self.state.dropTargeted ? 1 : 0)
            )
            // The window never resizes; this is the only thing that moves.
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: self.expanded)
            .animation(.spring(response: 0.34, dampingFraction: 0.8), value: self.state.peek)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: self.state.tab)

            Spacer(minLength: 0)
        }
        .frame(width: NotchState.windowWidth, height: NotchState.windowHeight, alignment: .top)
    }

    private var panelContent: some View {
        VStack(spacing: 8) {
            self.ears
            Group {
                switch self.state.tab {
                case .home: self.homeTab
                case .tasks: self.tasksTab
                case .sessions: self.sessionsTab
                case .shelf: self.shelfTab
                case .config: self.configTab
                }
            }
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The concave shoulders already inset the body by topRadius; the content needs its own
            // breathing room on top of that.
            .padding(.horizontal, 34)
        }
        .padding(.bottom, 12)
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(peek.tint)
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
            HStack(spacing: 8) {
                self.tabButton(.home)
                self.tabButton(.tasks)
                self.tabButton(.sessions)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 26)

            // The camera housing itself: nothing can be drawn here.
            Color.clear.frame(width: self.notchWidth)

            HStack(spacing: 8) {
                self.tabButton(.shelf)
                self.tabButton(.config)
                self.batteryBadge
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 26)
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
            Image(systemName: item.symbol)
                .font(.system(size: 11))
                .frame(width: 30, height: 24)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(0.16))
                            .matchedGeometryEffect(id: "activeTab", in: self.tabNamespace)
                    }
                }
                .foregroundStyle(.white.opacity(active ? 0.95 : 0.45))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    @ViewBuilder
    private var batteryBadge: some View {
        if let battery = battery.state {
            HStack(spacing: 4) {
                Text("\(battery.percent)%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(battery.percent < 15 ? AnyShapeStyle(Color.red) : AnyShapeStyle(.white.opacity(0.65)))
                Image(systemName: battery.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(battery.isCharging || battery.isCharged
                        ? AnyShapeStyle(Color.green)
                        : AnyShapeStyle(.white.opacity(0.65)))
            }
            .help(battery.detail ?? "Batería")
        }
    }

    // MARK: - Music

    @ViewBuilder
    // MARK: - Home

    private var homeTab: some View {
        HStack(alignment: .top, spacing: 12) {
            self.musicTab
                .frame(width: 254, alignment: .leading)

            self.agendaColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var agendaColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            self.weekStrip
            self.calendarTab
        }
    }

    /// The week around today, so the agenda underneath has something to hang off instead of being
    /// a bare list of times.
    private var weekStrip: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = (-2 ... 3).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }

        return HStack(alignment: .center, spacing: 0) {
            Text(Self.monthLabel(today))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 5)

            HStack(spacing: 5) {
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDateInToday(day)
                VStack(spacing: 2) {
                    Text(Self.weekdayLabel(day))
                        .font(.system(size: 7.5, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(isToday ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white.opacity(0.4)))
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 10, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? AnyShapeStyle(Color.white) : AnyShapeStyle(.white.opacity(0.65)))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(isToday ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear)))
                }
            }
            }
            // Each day takes the width it needs. Sharing the row equally blew every slot up to the
            // widest label and pushed the last day off the panel.
            Spacer(minLength: 0)
        }
        // A day sliced through the middle looks broken; the column simply ends.
        .clipped()
    }

    private static func monthLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM"
        // Spanish abbreviates September to "sept", four characters where every other month takes
        // three, and that one extra glyph is what pushed the last day off the strip.
        return String(formatter.string(from: date).prefix(3)).capitalized
    }

    private static func weekdayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        // Three letters, not the single initial: L M M J V S D has three ambiguous pairs.
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
            .replacingOccurrences(of: ".", with: "")
            .capitalized
    }

    // MARK: - Music

    @ViewBuilder
    private var musicTab: some View {
        if let track = media.track {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    self.media.openPlayer()
                    self.onCollapse()
                } label: {
                    self.artwork
                }
                .buttonStyle(.plain)
                .help("Abrir " + track.player)

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)

                    self.progress(track)
                        .frame(width: 130)
                        .padding(.top, 3)

                    Spacer(minLength: 0)

                    HStack(spacing: 14) {
                        self.control("backward.fill", size: 12) { self.media.previous() }
                        self.control(track.isPlaying ? "pause.fill" : "play.fill", size: 13) { self.media.playPause() }
                            .background(Circle().fill(.white.opacity(0.14)))
                        self.control("forward.fill", size: 12) { self.media.next() }
                    }
                    .frame(maxWidth: .infinity)
                }
                // Text column and artwork end on the same line, as in the reference.
                .frame(height: 112)
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
                            .frame(height: scrubbing ? 4 : 2)
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
                .frame(height: 8)

                HStack {
                    Text(Self.clock(fraction * track.duration))
                    Spacer()
                    Text(Self.clock(track.duration))
                }
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
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
        .frame(width: 112, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let icon = media.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .offset(x: 6, y: 6)
            }
        }
    }

    private func control(_ symbol: String, size: CGFloat = 15, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tasks

    @ViewBuilder
    private var tasksTab: some View {
        VStack(spacing: 6) {
            // Not a text field: the notch panel refuses key status on purpose, so anything typed
            // here would go nowhere. Capture happens in its own focusable window.
            Button(action: self.onQuickAdd) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 12))
                    Text("Nueva tarea").font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Text("⇧⌥T")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.14)))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .move(edge: .trailing).combined(with: .opacity)
                                ))
                        }
                    }
                }
            }
        }
    }

    /// The row plays the tick before the store drops it. Vanishing on click gave no sign that the
    /// right task got completed.
    private func complete(_ task: TodoTask) {
        guard !self.completing.contains(task.id) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
            _ = self.completing.insert(task.id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                self.tasks.toggle(task)
            }
            self.completing.remove(task.id)
        }
    }

    private func taskRow(_ task: TodoTask) -> some View {
        let done = self.completing.contains(task.id)
        return HStack(alignment: .top, spacing: 8) {
            Button { self.complete(task) } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white.opacity(0.45), lineWidth: 1)
                        .frame(width: 13, height: 13)
                        .opacity(done ? 0 : 1)

                    Circle()
                        .fill(.green)
                        .frame(width: done ? 15 : 4, height: done ? 15 : 4)
                        .opacity(done ? 1 : 0)

                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.black)
                        .scaleEffect(done ? 1 : 0.2)
                        .opacity(done ? 1 : 0)
                }
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The title gets the line to itself; the tags stack underneath so a long task no longer
            // has to compete with five chips for the same row.
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .strikethrough(done, color: .white.opacity(0.5))
                    .foregroundStyle(.white.opacity(done ? 0.4 : 1))

                if self.hasTags(task) {
                    HStack(spacing: 4) {
                        if let project = task.project {
                            self.chip(project + (task.section.map { " · " + $0 } ?? ""), tint: self.tasks.color(of: project))
                        }
                        if let type = task.type { self.chip(type, tint: TaskParser.typeTint(type)) }
                        if let priority = task.priorityLabel {
                            self.chip(priority, tint: TaskParser.priorityTint(task.priority))
                        }
                        if let due = task.dueLabel {
                            self.chip(due, tint: TaskParser.dueTint(task.due))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { self.onEditTask(task) }

            Spacer(minLength: 4)

            if let app = task.app, let url = TaskStore.appURL(named: app) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Abrir " + app)
            }
        }
        .foregroundStyle(.white)
        .opacity(done ? 0.55 : 1)
        .scaleEffect(done ? 0.97 : 1, anchor: .leading)
        .contextMenu {
            Button("Editar") { self.onEditTask(task) }
            Button("Eliminar", role: .destructive) { self.tasks.remove(task) }
        }
    }

    private func hasTags(_ task: TodoTask) -> Bool {
        task.project != nil || task.type != nil || task.priority != nil || task.due != nil
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background {
                Capsule().fill(tint.opacity(0.22))
                Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 0.5)
            }
            // Tinting the text instead of the fill keeps every chip legible on black, including the
            // yellow one that white type disappears into.
            .foregroundStyle(tint)
    }

    // MARK: - Calendar

    /// Half the panel wide, so the full-width row with its account badges and countdown does not
    /// fit: two lines per event, three events, and the rest is in the Calendar app.
    @ViewBuilder
    private var calendarTab: some View {
        switch self.calendar.access {
        case .granted:
            if self.calendar.events.isEmpty {
                VStack(spacing: 2) {
                    Text("Nada por delante")
                        .font(.system(size: 12, weight: .semibold))
                    Text(self.calendar.accounts.isEmpty
                        ? "Agregá tus cuentas en Ajustes del sistema"
                        : "Disfrutá el tiempo libre")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
            } else {
                // Scrolls instead of clipping: a row sliced in half looks like a bug, and the
                // fade at the bottom is what says there is more below.
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(self.calendar.events) { event in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(Color(nsColor: event.color))
                                .frame(width: 6, height: 6)

                            VStack(alignment: .leading, spacing: 0) {
                                Text(event.title)
                                    .font(.system(size: 11, weight: event.isNow ? .semibold : .regular))
                                    .lineLimit(1)
                                Text(event.timeLabel)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            if let meeting = event.meeting, event.isJoinable {
                                self.joinButton(meeting, prominent: true)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.85),
                            .init(color: .black.opacity(0), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .writeOnly:
            self.calendarNotice("El permiso quedó en «solo escritura». Cambialo a acceso completo en Ajustes → Privacidad → Calendarios.")
        case .denied:
            self.calendarNotice("Permiso de calendario denegado. Activalo en Ajustes del sistema.")
        case .unknown:
            VStack(alignment: .leading, spacing: 5) {
                Text("Ver tu agenda").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                Button("Dar permiso") { self.calendar.requestAccess() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func calendarNotice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Sessions

    /// llmpet's own window is gone: what it watched now lives here, so there is one place to look.
    /// Grouped by state, because "which one is waiting for me" is the only question you ever ask.
    @ViewBuilder
    private var sessionsTab: some View {
        let sections = self.sessions.sections
        if sections.isEmpty {
            VStack(spacing: 3) {
                Text("Nada corriendo")
                    .font(.system(size: 12, weight: .semibold))
                Text("Claude, Codex y Conductor aparecen acá cuando arrancan")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(sections, id: \.state) { section in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Self.stateTint(section.state))
                                .frame(width: 5, height: 5)
                            Text(section.title.uppercased())
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Self.stateTint(section.state).opacity(0.9))
                            Text("\(section.sessions.count)")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.3))
                            Spacer(minLength: 0)
                        }

                        VStack(spacing: 4) {
                            ForEach(section.sessions) { session in
                                self.sessionRow(session)
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            // A row sliced in half reads as a bug; the fade says there is more below.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.86),
                        .init(color: .black.opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private func sessionRow(_ session: LLMSession) -> some View {
        HStack(spacing: 8) {
            if let path = session.appPath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 15, height: 15)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(session.title)
                    .font(.system(size: 11, weight: session.state == .ready ? .semibold : .regular))
                    .lineLimit(1)
                Text([session.origin, session.context].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let tokens = session.tokens, tokens.billable > 0 {
                Text(Self.compact(tokens.billable))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }

            // "Working since" and "last said something" are different questions; while a turn is
            // running the first one is the one you care about.
            Text(Self.age(session))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(session.state == .working
                    ? AnyShapeStyle(Color.blue.opacity(0.9))
                    : AnyShapeStyle(.white.opacity(0.35)))
                .frame(minWidth: 34, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.leading, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            self.sessions.open(session)
            self.onCollapse()
        }
        .contextMenu {
            Button("Abrir") { self.sessions.open(session) }
            Button("Fijar arriba") { self.sessions.togglePin(session) }
            Button("Ocultar", role: .destructive) { self.sessions.dismiss(session) }
        }
    }

    private static func age(_ session: LLMSession) -> String {
        let reference = session.state == .working ? (session.activeSince ?? session.lastActivity) : session.lastActivity
        let seconds = Int(Date().timeIntervalSince(reference))
        if seconds < 60 { return "\(max(seconds, 0))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    private static func stateTint(_ state: SessionState) -> Color {
        switch state {
        case .ready: .green
        case .working: .blue
        case .error: .red
        case .seen: .gray
        }
    }

    private static func compact(_ value: Int) -> String {
        value >= 1_000_000 ? String(format: "%.1fM", Double(value) / 1_000_000)
            : value >= 1_000 ? "\(value / 1_000)k"
            : "\(value)"
    }

    // MARK: - Config

    private var configTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.toggleRow("Recordar la última pestaña", isOn: self.$settings.rememberLastTab)
            self.toggleRow("Avisar al cambiar de canción", isOn: self.$settings.peekOnTrackChange)
            self.toggleRow("Ocultar de capturas de pantalla", isOn: self.$settings.hideFromCapture)

            HStack(spacing: 8) {
                Text("Espera para abrir")
                    .font(.system(size: 11))
                Slider(value: self.$settings.hoverDelay, in: 0.05 ... 0.6)
                    .controlSize(.mini)
                    .frame(width: 130)
                Text(String(format: "%.2fs", self.settings.hoverDelay))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer(minLength: 0)

            Button {
                self.onCollapse()
                self.onOpenSettings()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 10))
                    Text("Todos los ajustes").font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.12)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The system switch renders desaturated here: the notch panel refuses key status by design, so
    /// AppKit paints its controls as an inactive window's. This one owns its colour.
    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 11))
                Spacer(minLength: 0)
                Capsule()
                    .fill(isOn.wrappedValue ? AnyShapeStyle(Color.green) : AnyShapeStyle(.white.opacity(0.16)))
                    .frame(width: 26, height: 15)
                    .overlay(alignment: isOn.wrappedValue ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: 11, height: 11)
                            .padding(2)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isOn.wrappedValue)
    }

    // MARK: - Shelf

    @ViewBuilder
    private var shelfTab: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !self.shelf.items.isEmpty {
                HStack(spacing: 6) {
                    Text("\(self.shelf.items.count) \(self.shelf.items.count == 1 ? "archivo" : "archivos")  ·  arrastralos afuera para copiarlos")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))

                    Spacer(minLength: 0)

                    Button("Vaciar") { self.shelf.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            if self.shelf.items.isEmpty {
                self.dropZone
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(self.shelf.items, id: \.path) { url in
                            ShelfChip(url: url, thumbnails: self.thumbnails) {
                                self.shelf.remove(url)
                                self.thumbnails.forget(url)
                            }
                        }
                        // Says the shelf still takes more without stealing a row from the files.
                        self.addHint
                    }
                    .padding(.horizontal, 1)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                .white.opacity(self.state.dropTargeted ? 0.55 : 0.16),
                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(self.state.dropTargeted ? 0.08 : 0))
            )
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: self.state.dropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                        .font(.system(size: 16))
                    Text(self.state.dropTargeted ? "Soltalos" : "Soltá archivos acá")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(self.state.dropTargeted ? 0.95 : 0.4))
            )
            .frame(height: 92)
            .animation(.easeOut(duration: 0.15), value: self.state.dropTargeted)
    }

    private var addHint: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                .white.opacity(self.state.dropTargeted ? 0.5 : 0.14),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(self.state.dropTargeted ? 0.8 : 0.3))
            )
            .frame(width: 46, height: 80)
    }

}

private struct ShelfChip: View {
    let url: URL
    @ObservedObject var thumbnails: ShelfThumbnails
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: self.thumbnails.thumbnail(for: self.url, size: CGSize(width: 52, height: 52))
                ?? ShelfStore.icon(for: self.url))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 52)

            // A fixed width truncated names that had room to spare. The chip takes what the name
            // needs, up to a ceiling, so short names stay narrow and long ones get the space.
            Text(self.url.lastPathComponent)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 40, maxWidth: 104)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(self.hovered ? 0.1 : 0))
        )
        .overlay(alignment: .topTrailing) {
            Button(action: self.onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .background(Circle().fill(.black.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .opacity(self.hovered ? 1 : 0)
            .offset(x: 3, y: -2)
        }
        .onHover { self.hovered = $0 }
        // Dragging out hands the real file to the destination app.
        .onDrag { NSItemProvider(contentsOf: self.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(self.url) }
        .contextMenu {
            Button("Abrir") { NSWorkspace.shared.open(self.url) }
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([self.url]) }
            Divider()
            Button("Quitar del estante", role: .destructive, action: self.onRemove)
        }
        .help(self.url.lastPathComponent + "  ·  doble clic abre, arrastralo afuera para copiarlo")
    }
}
