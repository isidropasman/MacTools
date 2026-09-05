import AppKit
import SwiftUI

/// Capture and editing live in their own window: the notch panel refuses key status on purpose, so
/// a text field there can never be focused.
struct QuickAddView: View {
    @ObservedObject var tasks: TaskStore
    /// Non-nil when editing an existing task instead of creating one.
    let editing: TodoTask?
    let onDone: () -> Void

    @State private var input = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var preview: TaskParser.Parsed { TaskParser.parse(self.input) }
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
                    .onChange(of: self.input) { _, _ in self.selection = 0 }
            }

            Divider()

            if let suggestions, !suggestions.items.isEmpty {
                self.suggestionList(suggestions)
            } else if self.input.isEmpty {
                self.hints
            } else {
                self.parsedPreview
            }
        }
        .padding(18)
        .frame(width: 480)
        .background(.regularMaterial)
        .onAppear {
            self.input = self.editing?.asInput ?? ""
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
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(index == self.selection ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
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
        }
        self.focused = true
    }

    // MARK: - Hints and preview

    private var hints: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Escribí la tarea y agregá lo que necesites:")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                self.hintChip("#proyecto", "agrupa")
                self.hintChip("#proy/sección", "subdivide")
                self.hintChip("@app", "la abre")
                self.hintChip("!tipo", "clasifica")
                self.hintChip("p1", "prioridad")
                self.hintChip("en 25m", "te avisa")
            }
        }
    }

    private func hintChip(_ token: String, _ meaning: String) -> some View {
        Button {
            self.input += (self.input.isEmpty ? "" : " ") + token
            self.focused = true
        } label: {
            VStack(spacing: 1) {
                Text(token).font(.system(size: 10, weight: .medium, design: .rounded))
                Text(meaning).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
        }
        .buttonStyle(.plain)
    }

    private var parsedPreview: some View {
        HStack(spacing: 6) {
            Text(self.preview.title.isEmpty ? "…" : self.preview.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            if let project = preview.project {
                self.chip("#" + project + (self.preview.section.map { "/" + $0 } ?? ""), .blue)
            }
            if let type = preview.type { self.chip("!" + type, .purple) }
            if let priority = preview.priority {
                self.chip("p\(priority)", priority == 1 ? .red : .orange)
            }
            if let app = preview.app {
                if let url = TaskStore.appURL(named: app) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().frame(width: 14, height: 14)
                } else {
                    self.chip("@" + app + " ?", .orange)
                }
            }
            Spacer(minLength: 4)
            if let due = preview.due {
                Label(Self.when(due), systemImage: "bell.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
            }
            Text("↩")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
        }
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.25)))
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
        if let editing {
            self.tasks.update(editing, with: self.input)
        } else {
            guard self.tasks.add(self.input) != nil else { return }
        }
        self.input = ""
        self.onDone()
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
