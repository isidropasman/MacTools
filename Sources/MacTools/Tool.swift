import Carbon.HIToolbox
import Foundation

/// Every hotkey in one list, so adding a tool means adding a case here instead of another
/// hardcoded RegisterEventHotKey call scattered through the app delegate.
enum Tool: String, CaseIterable, Identifiable {
    case history
    case quickAdd
    case projects
    case sessions
    case notch

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .history: String(localized: "Historial del portapapeles")
        case .quickAdd: String(localized: "Nueva tarea")
        case .projects: String(localized: "Proyectos y secciones")
        case .sessions: String(localized: "Sesiones de agentes")
        case .notch: String(localized: "Abrir la notch")
        }
    }

    var detail: String {
        switch self {
        case .history: String(localized: "Todo lo que copiaste, con búsqueda, fijados y favoritos.")
        case .quickAdd: String(localized: "Capturar una tarea con proyecto, prioridad y recordatorio.")
        case .projects: String(localized: "La tabla para crear, renombrar y ordenar proyectos.")
        case .sessions: String(localized: "Qué está corriendo en Claude, Codex y Conductor.")
        case .notch: String(localized: "Desplegar el panel sin llevar el mouse hasta arriba.")
        }
    }

    var symbol: String {
        switch self {
        case .history: "doc.on.clipboard"
        case .quickAdd: "checklist"
        case .projects: "square.stack.3d.up"
        case .sessions: "cpu"
        case .notch: "macbook"
        }
    }

    /// nil means the tool ships without a shortcut; you can still assign one.
    var defaultShortcut: (key: UInt32, modifiers: UInt32)? {
        switch self {
        case .history: (UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey))
        case .quickAdd: (UInt32(kVK_ANSI_T), UInt32(optionKey | shiftKey))
        case .projects, .sessions, .notch: nil
        }
    }
}
