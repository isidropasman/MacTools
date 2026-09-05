import AppKit
import Combine

struct TodoTask: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var project: String?
    var section: String?
    var type: String?
    var app: String?
    var priority: Int?
    var due: Date?
    var done: Bool
    var createdAt: Date

    init(parsed: TaskParser.Parsed) {
        self.id = UUID()
        self.title = parsed.title
        self.project = parsed.project
        self.section = parsed.section
        self.type = parsed.type
        self.app = parsed.app
        self.priority = parsed.priority
        self.due = parsed.due
        self.done = false
        self.createdAt = Date()
    }

    /// Round-trips back into the input so editing starts from exactly what produced the task.
    var asInput: String {
        var parts = [self.title]
        if let project {
            parts.append("#" + project + (self.section.map { "/" + $0 } ?? ""))
        }
        if let app { parts.append("@" + app) }
        if let type { parts.append("!" + type) }
        if let priority { parts.append("p\(priority)") }
        if let due {
            let formatter = DateFormatter()
            formatter.dateFormat = Calendar.current.isDateInToday(due) ? "HH:mm" : "'mañana' HH:mm"
            if Calendar.current.isDateInToday(due) || Calendar.current.isDateInTomorrow(due) {
                parts.append(formatter.string(from: due))
            }
        }
        return parts.joined(separator: " ")
    }

    var priorityLabel: String? { self.priority.map { "p\($0)" } }

    var isOverdue: Bool {
        guard let due, !self.done else { return false }
        return due < Date()
    }

    var dueLabel: String? {
        guard let due else { return nil }
        let minutes = Int(due.timeIntervalSinceNow / 60)
        if minutes < 0 { return "vencida" }
        if minutes < 60 { return "en \(minutes) min" }
        if Calendar.current.isDateInToday(due) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: due)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInTomorrow(due) ? "'mañana' HH:mm" : "dd/MM HH:mm"
        return formatter.string(from: due)
    }
}

/// A few dozen rows with no search: a JSON file is the whole feature, where a second SQLite table
/// would be a connection, a schema and a migration path for nothing.
@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TodoTask] = []

    private let url = Store.supportDirectory.appendingPathComponent("tasks.json")
    private let notifier = TaskNotifier()

    init() {
        self.load()
        self.notifier.requestAuthorization()

        // Pending reminders live in the notification centre, which is emptied when the app quits.
        // Without this every deadline was silently lost on relaunch.
        for task in self.tasks where !task.done {
            self.notifier.schedule(task)
        }
    }

    var pending: [TodoTask] {
        self.tasks
            .filter { !$0.done }
            .sorted { lhs, rhs in
                // Anything with a deadline outranks anything without one.
                switch (lhs.due, rhs.due) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    // No deadline on either: priority decides, then recency.
                    let lp = lhs.priority ?? 9
                    let rp = rhs.priority ?? 9
                    return lp == rp ? lhs.createdAt > rhs.createdAt : lp < rp
                }
            }
    }

    @discardableResult
    func add(_ input: String) -> TodoTask? {
        let parsed = TaskParser.parse(input)
        guard !parsed.title.isEmpty else { return nil }

        let task = TodoTask(parsed: parsed)
        self.tasks.append(task)
        self.save()
        self.notifier.schedule(task)
        return task
    }

    /// Editing reparses the whole line, so every field can change at once, including the reminder.
    func update(_ task: TodoTask, with input: String) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let parsed = TaskParser.parse(input)
        guard !parsed.title.isEmpty else { return }

        var updated = self.tasks[index]
        updated.title = parsed.title
        updated.project = parsed.project
        updated.section = parsed.section
        updated.type = parsed.type
        updated.app = parsed.app
        updated.priority = parsed.priority
        updated.due = parsed.due
        self.tasks[index] = updated

        self.notifier.cancel(task)
        self.notifier.schedule(updated)
        self.save()
    }

    /// Projects are whatever you have used, so the list maintains itself and never drifts.
    var projects: [String] {
        Array(Set(self.tasks.compactMap(\.project))).sorted()
    }

    func sections(of project: String) -> [String] {
        Array(Set(self.tasks.filter { $0.project == project }.compactMap(\.section))).sorted()
    }

    var types: [String] {
        Array(Set(self.tasks.compactMap(\.type))).sorted()
    }

    func toggle(_ task: TodoTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        self.tasks[index].done.toggle()
        if self.tasks[index].done { self.notifier.cancel(task) }
        self.save()
    }

    func remove(_ task: TodoTask) {
        self.tasks.removeAll { $0.id == task.id }
        self.notifier.cancel(task)
        self.save()
    }

    func clearDone() {
        for task in self.tasks where task.done { self.notifier.cancel(task) }
        self.tasks.removeAll { $0.done }
        self.save()
    }

    /// Resolves "@Keynote" to a real application, so the row can show its icon and open it.
    static func appURL(named name: String) -> URL? {
        for directory in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name + ".app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: self.url),
              let decoded = try? JSONDecoder().decode([TodoTask].self, from: data)
        else { return }
        self.tasks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(self.tasks) else { return }
        try? data.write(to: self.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
    }
}
