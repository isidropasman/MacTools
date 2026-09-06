import AppKit
import Foundation

/// What the Conexiones tab shows. Every row is checked live against the machine
/// rather than described from memory — a settings screen that claims a source is
/// connected when it is not is worse than no screen at all.
enum Diagnostics {
    struct Source {
        let name: String
        let connected: Bool
        let status: String
        let detail: String
    }

    static func sources(store: SessionStore) -> [Source] {
        [conductor(store), chrome(store), terminal(store), claudeDesktop(store), web()]
    }

    private static func count(_ store: SessionStore, source: String) -> Int {
        store.sessions.filter { $0.source == source }.count
    }

    private static func conductor(_ store: SessionStore) -> Source {
        let path = NSHomeDirectory()
            + "/Library/Application Support/com.conductor.app/conductor.db"
        let installed = FileManager.default.fileExists(atPath: path)
        let n = count(store, source: "conductor")
        return Source(
            name: "Conductor",
            connected: installed,
            status: installed ? "\(n) sesiones" : "no instalado",
            detail: "Lee su base SQLite local en modo solo lectura. Distingue "
                  + "workspaces locales de los cloud, y qué agente corre en cada "
                  + "uno (Claude o Codex). Al clickear una fila abre esa sesión."
        )
    }

    private static func chrome(_ store: SessionStore) -> Source {
        let n = count(store, source: "chrome")
        return Source(
            name: "Navegador — ChatGPT, Claude, Gemini, AI Studio",
            connected: n > 0,
            status: n > 0 ? "\(n) pestañas" : "sin pestañas",
            detail: "Necesita la extensión cargada en Chrome. Detecta que el "
                  + "modelo está escribiendo mirando cuánto cambia la página, no "
                  + "el botón de detener — así no se rompe si cambia el idioma o "
                  + "el diseño. Al clickear trae esa pestaña al frente."
        )
    }

    private static func terminal(_ store: SessionStore) -> Source {
        let hooks = NSHomeDirectory() + "/.claude/settings.json"
        let registered = (try? String(contentsOfFile: hooks, encoding: .utf8))?
            .contains("llmpet") ?? false
        let n = count(store, source: "claude") + count(store, source: "codex")
        return Source(
            name: "Terminal — Claude Code y Codex",
            connected: registered,
            status: registered ? "\(n) sesiones" : "hooks sin registrar",
            detail: "Los hooks avisan cuando una sesión arranca y cuando termina, "
                  + "e informan el PID. Si cerrás la terminal, la fila desaparece "
                  + "sola porque el proceso ya no existe."
        )
    }

    private static func claudeDesktop(_ store: SessionStore) -> Source {
        let path = NSHomeDirectory()
            + "/Library/Application Support/Claude/claude-code-sessions"
        let installed = FileManager.default.fileExists(atPath: path)
        let n = count(store, source: "claude-desktop")
        return Source(
            name: "Claude Desktop",
            connected: installed && n > 0,
            status: n > 0 ? "\(n) sesiones" : "solo Claude Code",
            detail: "Solo se ven las sesiones de Claude Code que corras dentro de "
                  + "la app. Los chats normales no dejan rastro en el disco — son "
                  + "del servidor — así que para esos conviene usar la web en una "
                  + "pestaña, donde sí los detecta."
        )
    }

    private static func web() -> Source {
        Source(
            name: "Internet",
            connected: false,
            status: "sin conexión saliente",
            detail: "LLMPet no manda datos a ningún lado. Lo único que escucha es "
                  + "127.0.0.1:7717, y solo para que la extensión de Chrome le "
                  + "pase el estado de tus pestañas. Ese puerto no es accesible "
                  + "desde fuera de tu Mac."
        )
    }
}
