import AppKit
import Foundation

/// Where the agent sessions come from. Conductor and Claude Desktop are read straight off disk;
/// the browser and the terminal need a piece installed first, and this is what installs it.
@MainActor
final class Connectors: ObservableObject {
    struct Connector: Identifiable {
        let id: String
        let name: String
        let detail: String
        let symbol: String
        var installed: Bool
        /// nil when there is nothing to install: it either works or the app is not there.
        let install: (() -> Void)?
        var note: String?
    }

    @Published private(set) var list: [Connector] = []
    private var timer: Timer?

    static let home = NSHomeDirectory() + "/.llmpet"
    private static let conductorDB = NSHomeDirectory()
        + "/Library/Application Support/com.conductor.app/conductor.db"

    init() {
        self.refresh()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let fm = FileManager.default
        let list: [Connector] = [
            Connector(
                id: "conductor",
                name: String(localized: "Conductor"),
                detail: String(localized: "Se lee de su base local. No hay nada que instalar."),
                symbol: "square.split.2x1",
                installed: fm.fileExists(atPath: Self.conductorDB),
                install: nil,
                note: fm.fileExists(atPath: Self.conductorDB) ? nil : "Conductor no está instalado."
            ),
            Connector(
                id: "claude-desktop",
                name: String(localized: "Claude Desktop"),
                detail: String(localized: "Se leen sus conversaciones locales."),
                symbol: "bubble.left.and.bubble.right",
                installed: fm.fileExists(atPath: "/Applications/Claude.app"),
                install: nil,
                note: fm.fileExists(atPath: "/Applications/Claude.app") ? nil : "La app no está instalada."
            ),
            Connector(
                id: "terminal",
                name: String(localized: "Claude Code y Codex en la terminal"),
                detail: String(localized: "Un hook les avisa cuándo arrancan y cuándo terminan."),
                symbol: "terminal",
                installed: Self.hooksInstalled,
                install: { Self.installHooks() },
                note: Self.hooksInstalled ? nil : "Copia los scripts a ~/.llmpet y los registra en ~/.claude/settings.json."
            ),
            Connector(
                id: "chrome",
                name: String(localized: "ChatGPT y Claude en el navegador"),
                detail: String(localized: "Una extensión de Chrome reporta cada pestaña."),
                symbol: "globe",
                installed: Self.extensionReporting,
                install: { Self.revealExtension() },
                note: Self.extensionReporting
                    ? nil
                    : "Abre la carpeta: cargala en chrome://extensions con «Cargar descomprimida»."
            ),
        ]

        var full = list
        // Named on purpose: silence would read as "should work" when it simply is not supported.
        for (app, name) in [("/Applications/Cursor.app", "Cursor"), ("/Applications/Windsurf.app", "Windsurf")]
        where fm.fileExists(atPath: app) {
            full.append(Connector(
                id: name.lowercased(),
                name: name,
                detail: String(localized: "Detectada, pero todavía no se leen sus sesiones."),
                symbol: "exclamationmark.triangle",
                installed: false,
                install: nil,
                note: String(localized: "Sin soporte todavía.")
            ))
        }

        if full.map(\.installed) != self.list.map(\.installed) || full.count != self.list.count {
            self.list = full
        }
    }

    // MARK: - Terminal hooks

    private static var hooksInstalled: Bool {
        FileManager.default.fileExists(atPath: home + "/llmpet-hook.sh")
            && (try? String(contentsOfFile: NSHomeDirectory() + "/.claude/settings.json", encoding: .utf8))?
                .contains("llmpet-hook.sh") == true
    }

    /// Merges into the existing settings instead of replacing them, and keeps a copy of the file it
    /// touched: other tools register hooks in there too.
    private static func installHooks() {
        let fm = FileManager.default
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("hooks") else { return }

        try? fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: source.path)) ?? [] {
            let destination = home + "/" + name
            try? fm.removeItem(atPath: destination)
            try? fm.copyItem(atPath: source.appendingPathComponent(name).path, toPath: destination)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination)
        }

        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath) {
            try? data.write(to: URL(fileURLWithPath: settingsPath + ".mactools-backup"), options: .atomic)
            settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, argument) in [("SessionStart", "working"), ("Stop", "ready"), ("SessionEnd", "end")] {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let command = "\(home)/llmpet-hook.sh \(argument)"
            let already = entries.contains { entry in
                let inner = entry["hooks"] as? [[String: Any]] ?? []
                return inner.contains { ($0["command"] as? String)?.contains("llmpet-hook.sh") == true }
            }
            guard !already else { continue }
            entries.append(["hooks": [["type": "command", "command": command]]])
            hooks[event] = entries
        }
        settings["hooks"] = hooks

        try? fm.createDirectory(atPath: NSHomeDirectory() + "/.claude", withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    // MARK: - Chrome extension

    private static var extensionReporting: Bool {
        let sessions = home + "/sessions"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: sessions)) ?? []
        return files.contains { $0.hasPrefix("chrome-") }
    }

    private static func revealExtension() {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("chrome-extension") else { return }
        // Copied out of the bundle: Chrome refuses to load an unpacked extension from inside an app.
        let destination = URL(fileURLWithPath: home + "/chrome-extension")
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: destination.path)
        NSWorkspace.shared.open(URL(string: "chrome://extensions")!)
    }
}
