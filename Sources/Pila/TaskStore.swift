import AppKit
import Combine

struct TodoTask: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var project: String?
    var type: String?
    var app: String?
    var due: Date?
    var done: Bool
    var createdAt: Date

    init(parsed: TaskParser.Parsed) {
        self.id = UUID()
        self.title = parsed.title
        self.project = parsed.project
        self.type = parsed.type
        self.app = parsed.app
        self.due = parsed.due
        self.done = false
        self.createdAt = Date()
    }

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
                default: return lhs.createdAt > rhs.createdAt
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
