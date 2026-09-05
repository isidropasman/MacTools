import AppKit
import SwiftUI

/// Capture lives in its own window because the notch panel refuses key status on purpose: if it
/// took focus on hover it would interrupt whatever you were typing. A text field there can never
/// be focused, which is why adding a task from the notch was impossible.
struct QuickAddView: View {
    @ObservedObject var tasks: TaskStore
    let onDone: () -> Void

    @State private var input = ""
    @FocusState private var focused: Bool

    private var preview: TaskParser.Parsed { TaskParser.parse(self.input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checklist").foregroundStyle(.secondary)
                TextField("¿Qué hay que hacer?", text: self.$input)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused(self.$focused)
                    .onSubmit(self.commit)
            }

            Divider()

            // The live read-back is what teaches the syntax: you see it work as you type, instead
            // of having to remember a format from a placeholder.
            if self.input.isEmpty {
                self.hints
            } else {
                self.parsedPreview
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(.regularMaterial)
        .onAppear { self.focused = true }
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Escribí la tarea y agregá lo que necesites:")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                self.hintChip("#proyecto", "agrupa")
                self.hintChip("@app", "la abre")
                self.hintChip("!tipo", "clasifica")
                self.hintChip("en 25m", "te avisa")
            }
        }
    }

    private func hintChip(_ token: String, _ meaning: String) -> some View {
        Button {
            self.input += (self.input.isEmpty ? "" : " ") + token + " "
            self.focused = true
        } label: {
            VStack(spacing: 1) {
                Text(token).font(.system(size: 11, weight: .medium, design: .rounded))
                Text(meaning).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
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

            if let project = preview.project { self.chip("#" + project, .blue) }
            if let type = preview.type { self.chip("!" + type, .purple) }
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
        guard self.tasks.add(self.input) != nil else { return }
        self.input = ""
        self.onDone()
    }
}
