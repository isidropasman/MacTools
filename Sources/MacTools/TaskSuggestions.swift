import Foundation

/// What to offer for the token the caret is sitting on. Static hints told you the syntax existed;
/// this completes it with your own projects and sections while you type.
@MainActor
enum TaskSuggestions {
    struct Suggestion: Identifiable, Equatable {
        let insert: String
        let label: String
        let detail: String?
        var id: String { self.insert + self.label }
    }

    struct Result: Equatable {
        /// The partial token being replaced, so accepting a suggestion swaps it in place.
        let replacing: String
        let items: [Suggestion]
    }

    static func suggestions(for input: String, store: TaskStore) -> Result? {
        guard let last = input.split(separator: " ", omittingEmptySubsequences: false).last else { return nil }
        let token = String(last)

        switch token.first {
        case "#":
            let body = token.dropFirst()
            // "#plexo/" asks for a section of plexo, not for another project.
            if let slash = body.firstIndex(of: "/") {
                let project = String(body[body.startIndex ..< slash])
                let partial = String(body[body.index(after: slash)...]).lowercased()
                let sections = store.sections(of: project).filter { partial.isEmpty || $0.lowercased().hasPrefix(partial) }
                return Result(replacing: token, items: sections.map {
                    Suggestion(insert: "#\(project)/\($0)", label: $0, detail: "sección de \(project)")
                })
            }
            let partial = String(body).lowercased()
            let projects = store.projects.filter { partial.isEmpty || $0.lowercased().hasPrefix(partial) }
            return Result(replacing: token, items: projects.map {
                let count = store.sections(of: $0).count
                return Suggestion(insert: "#\($0)", label: $0, detail: count > 0 ? "\(count) secciones" : nil)
            })

        case "!":
            let partial = String(token.dropFirst()).lowercased()
            let types = store.types.filter { partial.isEmpty || $0.lowercased().hasPrefix(partial) }
            return Result(replacing: token, items: types.map { Suggestion(insert: "!\($0)", label: $0, detail: "tipo") })

        case "@":
            let partial = String(token.dropFirst()).lowercased()
            guard !partial.isEmpty else { return nil }
            let apps = self.installedApps().filter { $0.lowercased().hasPrefix(partial) }.prefix(5)
            return Result(replacing: token, items: apps.map { Suggestion(insert: "@\($0)", label: $0, detail: "app") })

        default:
            return nil
        }
    }

    static let appDirectories = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    private static var appCache: [String]?

    static func installedApps() -> [String] {
        if let appCache { return appCache }
        var names: Set<String> = []
        for directory in Self.appDirectories {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for entry in contents where entry.hasSuffix(".app") {
                names.insert(String(entry.dropLast(4)))
            }
        }
        let sorted = names.sorted()
        self.appCache = sorted
        return sorted
    }
}
