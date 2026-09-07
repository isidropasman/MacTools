import AppKit
import Combine
import SwiftUI

/// A logo without shipping an image picker: SF Symbols tint with the project colour, scale to any
/// size and cost one string in the catalogue.
enum ProjectSymbols {
    static let all = [
        "circle.fill", "briefcase.fill", "chart.line.uptrend.xyaxis", "dollarsign.circle.fill",
        "cart.fill", "megaphone.fill", "person.2.fill", "building.2.fill",
        "hammer.fill", "wrench.and.screwdriver.fill", "chevron.left.forwardslash.chevron.right",
        "cpu", "server.rack", "paintbrush.fill", "pencil.and.ruler.fill", "camera.fill",
        "book.fill", "graduationcap.fill", "airplane", "house.fill", "heart.fill", "star.fill",
        "bolt.fill", "flame.fill", "leaf.fill", "globe.americas.fill", "puzzlepiece.fill",
        "target", "flag.fill", "gearshape.fill",
    ]
}

enum ProjectPalette {
    static let order = ["azul", "violeta", "verde", "naranja", "rosa", "turquesa", "amarillo", "rojo"]

    static let colors: [String: Color] = [
        "azul": .blue, "violeta": .purple, "verde": .green, "naranja": .orange,
        "rosa": .pink, "turquesa": .teal, "amarillo": .yellow, "rojo": .red,
    ]
}

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

    var priorityLabel: String? { self.priority.flatMap { TaskParser.priorityNames[$0] } }

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

    struct Project: Codable, Equatable {
        var sections: [String] = []
        var color: String?
        var symbol: String?
        /// Filename inside the logos folder. A real logo wins over the SF Symbol.
        var logo: String?
    }

    /// Projects used to exist only as a side effect of some task mentioning them, so an empty
    /// project could not be created and a rename had nowhere to live. This is the catalogue.
    @Published private(set) var catalog: [String: Project] = [:]

    private let url = Store.supportDirectory.appendingPathComponent("tasks.json")
    private let catalogURL = Store.supportDirectory.appendingPathComponent("projects.json")
    private var logoCache: [String: NSImage] = [:]
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
        self.add(TaskParser.parse(input))
    }

    @discardableResult
    func add(_ parsed: TaskParser.Parsed) -> TodoTask? {
        guard !parsed.title.isEmpty else { return nil }

        let task = TodoTask(parsed: parsed)
        self.tasks.append(task)
        self.save()
        self.notifier.schedule(task)
        return task
    }

    /// Editing reparses the whole line, so every field can change at once, including the reminder.
    func update(_ task: TodoTask, with input: String) {
        self.update(task, with: TaskParser.parse(input))
    }

    func update(_ task: TodoTask, with parsed: TaskParser.Parsed) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
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

    /// The catalogue plus anything a task mentions, so typing "#nuevo" still works without
    /// registering it first.
    var projects: [String] {
        Array(Set(self.tasks.compactMap(\.project)).union(self.catalog.keys)).sorted()
    }

    func sections(of project: String) -> [String] {
        let used = Set(self.tasks.filter { $0.project == project }.compactMap(\.section))
        return Array(used.union(self.catalog[project]?.sections ?? [])).sorted()
    }

    // MARK: - Managing the catalogue

    func addProject(_ name: String) {
        let name = Self.normalize(name)
        guard !name.isEmpty, self.catalog[name] == nil else { return }
        self.catalog[name] = Project()
        self.saveCatalog()
    }

    func renameProject(_ old: String, to new: String) {
        let new = Self.normalize(new)
        guard !new.isEmpty, new != old else { return }
        var merged = self.catalog[new] ?? Project()
        merged.sections = Array(Set(merged.sections + (self.catalog[old]?.sections ?? [])))
        merged.color = merged.color ?? self.catalog[old]?.color
        merged.symbol = merged.symbol ?? self.catalog[old]?.symbol
        merged.logo = merged.logo ?? self.catalog[old]?.logo
        self.catalog[new] = merged
        self.catalog[old] = nil
        for index in self.tasks.indices where self.tasks[index].project == old {
            self.tasks[index].project = new
        }
        self.save()
        self.saveCatalog()
    }

    /// Deleting a project leaves its tasks alone but unfiled; losing a task to a bookkeeping change
    /// would be a far worse surprise than an untagged row.
    func removeProject(_ name: String) {
        self.removeLogoFile(of: name)
        self.logoCache.removeValue(forKey: name)
        self.catalog[name] = nil
        for index in self.tasks.indices where self.tasks[index].project == name {
            self.tasks[index].project = nil
            self.tasks[index].section = nil
        }
        self.save()
        self.saveCatalog()
    }

    func addSection(_ name: String, to project: String) {
        let name = Self.normalize(name)
        guard !name.isEmpty else { return }
        var entry = self.catalog[project] ?? Project()
        guard !entry.sections.contains(name) else { return }
        entry.sections.append(name)
        self.catalog[project] = entry
        self.saveCatalog()
    }

    func renameSection(_ old: String, to new: String, in project: String) {
        let new = Self.normalize(new)
        guard !new.isEmpty, new != old else { return }
        var entry = self.catalog[project] ?? Project()
        entry.sections = entry.sections.filter { $0 != old } + [new]
        self.catalog[project] = entry
        for index in self.tasks.indices where self.tasks[index].project == project && self.tasks[index].section == old {
            self.tasks[index].section = new
        }
        self.save()
        self.saveCatalog()
    }

    func removeSection(_ name: String, from project: String) {
        var entry = self.catalog[project] ?? Project()
        entry.sections = entry.sections.filter { $0 != name }
        self.catalog[project] = entry
        for index in self.tasks.indices where self.tasks[index].project == project && self.tasks[index].section == name {
            self.tasks[index].section = nil
        }
        self.save()
        self.saveCatalog()
    }

    static let logoDirectory = Store.supportDirectory.appendingPathComponent("logos", isDirectory: true)

    /// Re-encoded to PNG at 256pt instead of copied as-is: it normalises every format NSImage can
    /// read and keeps a 4000px export from sitting in the support folder.
    @discardableResult
    func setLogo(from source: URL, for project: String) -> Bool {
        guard let image = NSImage(contentsOf: source) else { return false }

        let side: CGFloat = 256
        let ratio = image.size.width > 0 ? image.size.height / image.size.width : 1
        let target = ratio > 1
            ? NSSize(width: side / ratio, height: side)
            : NSSize(width: side, height: side * ratio)

        let resized = NSImage(size: target)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target))
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return false }

        try? FileManager.default.createDirectory(
            at: Self.logoDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let name = UUID().uuidString + ".png"
        guard (try? png.write(to: Self.logoDirectory.appendingPathComponent(name), options: .atomic)) != nil
        else { return false }

        self.removeLogoFile(of: project)
        var entry = self.catalog[project] ?? Project()
        entry.logo = name
        self.catalog[project] = entry
        self.logoCache.removeValue(forKey: project)
        self.saveCatalog()
        return true
    }

    func removeLogo(for project: String) {
        self.removeLogoFile(of: project)
        var entry = self.catalog[project] ?? Project()
        entry.logo = nil
        self.catalog[project] = entry
        self.logoCache.removeValue(forKey: project)
        self.saveCatalog()
    }

    private func removeLogoFile(of project: String) {
        guard let name = catalog[project]?.logo else { return }
        try? FileManager.default.removeItem(at: Self.logoDirectory.appendingPathComponent(name))
    }

    func logo(of project: String?) -> NSImage? {
        guard let project else { return nil }
        if let cached = logoCache[project] { return cached }
        guard let name = catalog[project]?.logo,
              let image = NSImage(contentsOf: Self.logoDirectory.appendingPathComponent(name))
        else { return nil }
        self.logoCache[project] = image
        return image
    }

    func setSymbol(_ symbol: String?, for project: String) {
        var entry = self.catalog[project] ?? Project()
        entry.symbol = symbol
        self.catalog[project] = entry
        self.saveCatalog()
    }

    func symbol(of project: String?) -> String {
        project.flatMap { self.catalog[$0]?.symbol } ?? "circle.fill"
    }

    func setColor(_ color: String?, for project: String) {
        var entry = self.catalog[project] ?? Project()
        entry.color = color
        self.catalog[project] = entry
        self.saveCatalog()
    }

    /// Unnamed projects still need to look different from each other, so the default comes from the
    /// name and stays put instead of shifting as the list grows.
    func color(of project: String?) -> Color {
        guard let project else { return .blue }
        if let named = catalog[project]?.color, let color = ProjectPalette.colors[named] { return color }
        let index = abs(project.hashValue) % ProjectPalette.order.count
        return ProjectPalette.colors[ProjectPalette.order[index]] ?? .blue
    }

    /// A space would split the token in two and silently drop the tail.
    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
    }

    func taskCount(project: String, section: String? = nil) -> Int {
        self.tasks.filter { !$0.done && $0.project == project && (section == nil || $0.section == section) }.count
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
        for directory in TaskSuggestions.appDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name + ".app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func load() {
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? JSONDecoder().decode([TodoTask].self, from: data) {
            self.tasks = decoded
        }
        if let data = try? Data(contentsOf: self.catalogURL) {
            if let decoded = try? JSONDecoder().decode([String: Project].self, from: data) {
                self.catalog = decoded
            } else if let legacy = try? JSONDecoder().decode([String: [String]].self, from: data) {
                self.catalog = legacy.mapValues { Project(sections: $0) }
            }
        }
    }

    private func saveCatalog() {
        guard let data = try? JSONEncoder().encode(self.catalog) else { return }
        try? data.write(to: self.catalogURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.catalogURL.path)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(self.tasks) else { return }
        try? data.write(to: self.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
    }
}
