import AppKit
import SwiftUI

/// Capture and editing live in their own window: the notch panel refuses key status on purpose, so
/// a text field there can never be focused.
struct QuickAddView: View {
    @ObservedObject var tasks: TaskStore
    /// Non-nil when editing an existing task instead of creating one.
    let editing: TodoTask?
    let onDone: (TodoTask?) -> Void
    let onManageProjects: () -> Void

    @State private var input = ""
    @State private var selection = 0
    @State private var fields = TaskParser.Parsed()
    @State private var creating: Creating?

    /// Which field the inline "new value" row is filling in.
    private enum Creating: Equatable {
        case project
        case section(String)
        case type

        var placeholder: String {
            switch self {
            case .project: "Nombre del proyecto"
            case let .section(project): "Nueva secci\u{F3}n de " + project
            case .type: "Nombre del tipo"
            }
        }
    }
    @FocusState private var focused: Bool

    private var preview: TaskParser.Parsed { self.fields }
    private var suggestions: TaskSuggestions.Result? {
        TaskSuggestions.suggestions(for: self.input, store: self.tasks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: self.editing == nil ? "checklist" : "pencil")
                    .foregroundStyle(.secondary)
                TextField(self.editing == nil ? "¿Qué hay que hacer?" : "Editar tarea", text: self.$input)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused(self.$focused)
                    .onSubmit(self.commit)
                    .onChange(of: self.input) { _, _ in
                        self.selection = 0
                        self.liftTokens()
                    }
            }

            Divider()

            // The attribute bar never disappears. Hints that vanish the moment you type teach you
            // nothing and leave no way to change what you already set.
            if let creating {
                self.creationRow(creating)
            } else {
                self.attributeBar
            }

            if let suggestions, !suggestions.items.isEmpty {
                Divider()
                self.suggestionList(suggestions)
            }
        }
        .padding(18)
        .frame(width: 540)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
        .onAppear {
            if let editing {
                self.input = editing.title
                self.fields = TaskParser.Parsed(
                    title: editing.title,
                    project: editing.project,
                    section: editing.section,
                    type: editing.type,
                    app: editing.app,
                    priority: editing.priority,
                    due: editing.due
                )
            }
            self.focused = true
        }
        .background(KeyCatcher(
            onArrow: { delta in self.moveSelection(by: delta) },
            onTab: { self.acceptSuggestion() }
        ))
    }

    // MARK: - Suggestions

    private func suggestionList(_ result: TaskSuggestions.Result) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(result.items.prefix(5).enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Text(item.label).font(.system(size: 12, weight: .medium))
                    if let detail = item.detail {
                        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if index == self.selection {
                        Text("⇥").font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(
                    index == self.selection ? .regular.tint(.accentColor.opacity(0.6)) : .clear,
                    in: .rect(cornerRadius: 7)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    self.selection = index
                    self.acceptSuggestion()
                }
            }
        }
    }

    private func moveSelection(by delta: Int) {
        guard let count = suggestions?.items.prefix(5).count, count > 0 else { return }
        self.selection = max(0, min(count - 1, self.selection + delta))
    }

    private func acceptSuggestion() {
        guard let result = suggestions,
              let item = result.items.prefix(5).dropFirst(self.selection).first
        else { return }

        // Replaces the partial token in place rather than appending a duplicate.
        if let range = input.range(of: result.replacing, options: .backwards) {
            self.input.replaceSubrange(range, with: item.insert + " ")
            self.liftTokens()
        }
        self.focused = true
    }

    // MARK: - Creating a value without leaving the window

    /// A modal alert here fought the floating panel for key status and simply never appeared.
    private func creationRow(_ creating: Creating) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").font(.system(size: 11)).foregroundStyle(.blue)
            InlineField(placeholder: creating.placeholder) { value in
                let name = TaskStore.normalize(value)
                self.creating = nil
                guard !name.isEmpty else { return }
                switch creating {
                case .project:
                    self.tasks.addProject(name)
                    self.setProject(name, nil)
                case let .section(project):
                    self.tasks.addSection(name, to: project)
                    self.setProject(project, name)
                case .type:
                    self.set { $0.type = name }
                }
            } onCancel: {
                self.creating = nil
                self.focused = true
            }
        }
    }

    // MARK: - Attribute bar

    private var attributeBar: some View {
        HStack(alignment: .top, spacing: 6) {
            // Five filled chips no longer fit on one line, and a clipped chip is worse than a
            // second row.
            ChipFlow(spacing: 6, lineSpacing: 6) {
                self.projectControl
                self.appControl
                self.typeControl
                self.priorityControl
                self.timeControl
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\u{21A9}")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
        }
    }

    private var projectControl: some View {
        Menu {
            Button("Nuevo proyecto\u{2026}") { self.creating = .project }
            Button("Administrar proyectos\u{2026}", action: self.onManageProjects)
            if !self.tasks.projects.isEmpty { Divider() }
            ForEach(self.tasks.projects, id: \.self) { project in
                Menu(project) {
                    Button("Sin secci\u{F3}n") { self.setProject(project, nil) }
                    ForEach(self.tasks.sections(of: project), id: \.self) { section in
                        Button(section) { self.setProject(project, section) }
                    }
                    Divider()
                    Button("Nueva secci\u{F3}n\u{2026}") { self.creating = .section(project) }
                }
            }
            if self.preview.project != nil {
                Divider()
                Button("Quitar") { self.setProject(nil, nil) }
            }
        } label: {
            self.pill(
                self.preview.project.map { $0 + (self.preview.section.map { "/" + $0 } ?? "") } ?? "Proyecto",
                symbol: "number",
                active: self.preview.project != nil,
                tint: self.tasks.color(of: self.preview.project)
            )
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .chip(active: self.preview.project != nil, tint: self.tasks.color(of: self.preview.project))
    }

    private var appControl: some View {
        Menu {
            let running = Self.runningApps()
            if !running.isEmpty {
                ForEach(running, id: \.self) { app in
                    Button(app) { self.set { $0.app = app } }
                }
                Divider()
            }
            Menu("Todas las apps") {
                ForEach(TaskSuggestions.installedApps(), id: \.self) { app in
                    Button(app) { self.set { $0.app = app } }
                }
            }
            if self.preview.app != nil {
                Divider()
                Button("Quitar") { self.set { $0.app = nil } }
            }
        } label: {
            // An app icon is a bitmap the menu label refuses to shrink to symbol size, so its chip
            // came out taller than every other one. The real icon still shows on the task row.
            self.pill(self.preview.app ?? "App", symbol: "app", active: self.preview.app != nil, tint: .teal)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .chip(active: self.preview.app != nil, tint: Color.teal)
    }

    /// What is open right now is almost always what you mean, so it goes above the full list.
    private static func runningApps() -> [String] {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        return Array(Set(names)).sorted()
    }

    private var typeControl: some View {
        Menu {
            Button("Nuevo tipo\u{2026}") { self.creating = .type }
            Divider()
            ForEach(self.typeOptions, id: \.self) { type in
                Button(type) { self.set { $0.type = type } }
            }
            if self.preview.type != nil {
                Divider()
                Button("Quitar") { self.set { $0.type = nil } }
            }
        } label: {
            self.pill(
                self.preview.type ?? "Tipo",
                symbol: "tag",
                active: self.preview.type != nil,
                tint: TaskParser.typeTint(self.preview.type)
            )
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .chip(active: self.preview.type != nil, tint: TaskParser.typeTint(self.preview.type))
    }

    private var typeOptions: [String] {
        var options = self.tasks.types
        for fallback in ["bug", "review", "llamada", "admin"] where !options.contains(fallback) {
            options.append(fallback)
        }
        return options
    }

    private var priorityControl: some View {
        Menu {
            ForEach([1, 2, 3, 4], id: \.self) { level in
                Button(TaskParser.priorityNames[level] ?? "") { self.set { $0.priority = level } }
            }
            if self.preview.priority != nil {
                Divider()
                Button("Quitar") { self.set { $0.priority = nil } }
            }
        } label: {
            self.pill(
                self.preview.priority.flatMap { TaskParser.priorityNames[$0] } ?? "Prioridad",
                symbol: "flag",
                active: self.preview.priority != nil,
                tint: TaskParser.priorityTint(self.preview.priority)
            )
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .chip(active: self.preview.priority != nil, tint: TaskParser.priorityTint(self.preview.priority))
    }

    private var timeControl: some View {
        Menu {
            ForEach(Self.timeOptions, id: \.token) { option in
                Button(option.label) { self.setTime(option.token) }
            }
            if self.preview.due != nil {
                Divider()
                Button("Quitar") { self.setTime(nil) }
            }
        } label: {
            self.pill(
                self.preview.due.map { Self.when($0) } ?? "Cu\u{E1}ndo",
                symbol: "bell",
                active: self.preview.due != nil,
                tint: TaskParser.dueTint(self.preview.due)
            )
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .chip(active: self.preview.due != nil, tint: TaskParser.dueTint(self.preview.due))
    }

    private static let timeOptions: [(token: String, label: String)] = [
        ("en 15m", "en 15 minutos"),
        ("en 30m", "en 30 minutos"),
        ("en 1h", "en 1 hora"),
        ("en 3h", "en 3 horas"),
        ("hoy 18:00", "hoy 18:00"),
        ("ma\u{F1}ana 9:00", "ma\u{F1}ana 9:00"),
    ]

    private static let installedApps: [String] = [
        "Safari", "Google Chrome", "Arc", "Xcode", "Slack", "Notion", "Linear",
        "Figma", "Spotify", "Mail", "Terminal", "Finder",
    ].filter { TaskStore.appURL(named: $0) != nil }

    private func pill(_ text: String, symbol: String, active: Bool, tint: Color) -> some View {
        self.pill(text, icon: Image(systemName: symbol), active: active, tint: tint)
    }

    /// The label of a .borderlessButton menu keeps its text and icon but drops its background, so
    /// the colour capsule has to be applied to the menu itself, from the outside.
    private func pill(_ text: String, icon: Image, active: Bool, tint: Color) -> some View {
        HStack(spacing: 5) {
            icon.resizable().scaledToFit().frame(width: 12, height: 12)
            Text(text)
                .font(.system(size: 11, weight: active ? .medium : .regular))
                .lineLimit(1)
        }
        // An app icon is a bitmap with its own margins; without a fixed height its chip came out
        // taller than the ones built from SF Symbols.
        .frame(height: 14)
        .foregroundStyle(Self.ink(active: active, tint: tint))
    }

    private static func ink(active: Bool, tint: Color) -> AnyShapeStyle {
        active ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary)
    }

    private func set(_ change: (inout TaskParser.Parsed) -> Void) {
        change(&self.fields)
        self.focused = true
    }

    private func setProject(_ project: String?, _ section: String?) {
        self.fields.project = project
        self.fields.section = project == nil ? nil : section
        self.focused = true
    }

    // MARK: - Attributes live in the chips, not in the line

    /// Tokens are still the fastest way to type, but they belong in the chips once complete. A
    /// token only counts as finished when a space follows it, so "#pl" can still be autocompleted.
    private func liftTokens() {
        guard self.input.hasSuffix(" ") else { return }
        let parsed = TaskParser.parse(self.input)
        guard parsed.hasAttributes else { return }

        if let project = parsed.project {
            self.fields.project = project
            self.fields.section = parsed.section
        }
        if let type = parsed.type { self.fields.type = type }
        if let app = parsed.app { self.fields.app = app }
        if let priority = parsed.priority { self.fields.priority = priority }
        if let due = parsed.due { self.fields.due = due }
        self.input = parsed.title.isEmpty ? "" : parsed.title + " "
    }

    /// The presets go through the parser so "en 30m" means the same whether clicked or typed.
    private func setTime(_ token: String?) {
        self.fields.due = token.flatMap { TaskParser.parse("x " + $0).due }
        self.focused = true
    }

    private static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { formatter.dateFormat = "'hoy' HH:mm" }
        else if calendar.isDateInTomorrow(date) { formatter.dateFormat = "'mañana' HH:mm" }
        else { formatter.dateFormat = "d MMM HH:mm" }
        return formatter.string(from: date)
    }

    private func commit() {
        // Enter takes the highlighted suggestion first; you almost never mean to submit mid-token.
        if let suggestions, !suggestions.items.isEmpty {
            self.acceptSuggestion()
            return
        }
        var parsed = self.fields
        // Whatever is still mid-token in the line counts too, so Enter never drops a "#plexo".
        let typed = TaskParser.parse(self.input)
        parsed.title = typed.title
        if let project = typed.project {
            parsed.project = project
            parsed.section = typed.section
        }
        if let type = typed.type { parsed.type = type }
        if let app = typed.app { parsed.app = app }
        if let priority = typed.priority { parsed.priority = priority }
        if let due = typed.due { parsed.due = due }

        let saved: TodoTask?
        if let editing {
            self.tasks.update(editing, with: parsed)
            saved = nil
        } else {
            guard let task = tasks.add(parsed) else { return }
            saved = task
        }
        self.input = ""
        self.fields = TaskParser.Parsed()
        self.onDone(saved)
    }
}

/// Wraps chips onto a new line instead of pushing them off the window.
private struct ChipFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, used: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + self.lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + self.spacing
            used = max(used, x - self.spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(used, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + self.lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + self.spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private extension View {
    /// Solid colour when the field is set, plain glass when it is empty.
    /// Tinted like a Finder tag rather than a saturated badge: the colour identifies the value, it
    /// does not shout it.
    func chip(active: Bool, tint: Color) -> some View {
        self
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(active ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(.quaternary)))
            .overlay(Capsule().strokeBorder(active ? tint.opacity(0.4) : .white.opacity(0.1), lineWidth: 1))
    }
}

/// Its own view so @FocusState fires on appear instead of on the next render of the parent.
private struct InlineField: View {
    let placeholder: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(self.placeholder, text: self.$text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(self.$focused)
                .onSubmit { self.onCommit(self.text) }
            Button("Cancelar", action: self.onCancel)
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .onAppear { self.focused = true }
    }
}

/// Arrows and tab have to be caught before the text field consumes them.
private struct KeyCatcher: NSViewRepresentable {
    let onArrow: (Int) -> Void
    let onTab: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install(onArrow: self.onArrow, onTab: self.onTab)
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(onArrow: self.onArrow, onTab: self.onTab)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?

        func install(onArrow: @escaping (Int) -> Void, onTab: @escaping () -> Void) {
            self.remove()
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 125: onArrow(1); return nil
                case 126: onArrow(-1); return nil
                case 48: onTab(); return nil
                default: return event
                }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            self.monitor = nil
        }
    }
}
