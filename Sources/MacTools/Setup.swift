import AppKit
import EventKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// What the app needs from the system to actually work, as data. The welcome window and the
/// settings pane render the same list, so there is one definition of "todo listo".
@MainActor
final class Setup: ObservableObject {
    struct Step: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        /// A step you can skip without breaking anything else.
        let optional: Bool
        var done: Bool
        let actionTitle: String
        let action: () -> Void
    }

    @Published private(set) var steps: [Step] = []
    private var timer: Timer?

    private let calendar: CalendarManager
    private let fluid: FluidVoiceControl
    private let connectors: Connectors
    private var notificationsAllowed = false

    init(calendar: CalendarManager, fluid: FluidVoiceControl, connectors: Connectors) {
        self.calendar = calendar
        self.fluid = fluid
        self.connectors = connectors
        self.refresh()

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var pending: [Step] { self.steps.filter { !$0.done && !$0.optional } }
    var isReady: Bool { self.pending.isEmpty }

    func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Task { @MainActor in
                self.notificationsAllowed = allowed
                self.rebuild()
            }
        }
        self.rebuild()
    }

    private func rebuild() {
        let steps: [Step] = [
            Step(
                id: "accessibility",
                title: String(localized: "Permitir Accesibilidad"),
                detail: String(localized: "Para que pegue solo lo que elegís del historial."),
                symbol: "hand.raised.fill",
                optional: false,
                done: Paster.isTrusted,
                actionTitle: String(localized: "Dar permiso"),
                action: { Paster.requestPermission() }
            ),
            Step(
                id: "notifications",
                title: String(localized: "Permitir notificaciones"),
                detail: String(localized: "Para avisarte cuando vence una tarea."),
                symbol: "bell.fill",
                optional: false,
                done: self.notificationsAllowed,
                actionTitle: String(localized: "Pedir"),
                action: {
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                }
            ),
            Step(
                id: "calendar",
                title: String(localized: "Conectar el calendario"),
                detail: String(localized: "Tus próximos eventos en la notch."),
                symbol: "calendar",
                optional: true,
                done: self.calendar.access == .granted,
                actionTitle: self.calendar.access == .unknown ? "Conectar" : "Abrir Ajustes",
                action: { [calendar] in
                    if calendar.access == .unknown {
                        calendar.requestAccess()
                    } else {
                        Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                    }
                }
            ),
            Step(
                id: "dictation",
                title: String(localized: "Instalar FluidVoice"),
                detail: String(localized: "El motor del dictado. Sin él el resto anda igual."),
                symbol: "mic.fill",
                optional: true,
                done: self.fluid.isInstalled,
                actionTitle: String(localized: "Descargar"),
                action: { [fluid] in fluid.openReleases() }
            ),
            Step(
                id: "connectors",
                title: String(localized: "Conectar tus agentes"),
                detail: self.connectorSummary,
                symbol: "cpu",
                optional: true,
                done: self.connectors.list.contains { $0.installed && $0.install != nil },
                actionTitle: String(localized: "Ver"),
                action: { NotificationCenter.default.post(name: .mactoolsShowAgents, object: nil) }
            ),
            Step(
                id: "login",
                title: String(localized: "Abrir al iniciar sesión"),
                detail: String(localized: "Para no tener que abrirla a mano cada día."),
                symbol: "power",
                optional: true,
                done: SMAppService.mainApp.status == .enabled,
                actionTitle: String(localized: "Activar"),
                action: { try? SMAppService.mainApp.register() }
            ),
        ]

        if self.steps.map(\.done) != steps.map(\.done) || self.steps.count != steps.count {
            self.steps = steps
        }
    }

    private var connectorSummary: String {
        let installable = self.connectors.list.filter { $0.install != nil }
        let done = installable.filter(\.installed).count
        return done == installable.count && !installable.isEmpty
            ? String(localized: "Terminal y navegador reportando.")
            : String(localized: "Falta el hook de la terminal o la extensión del navegador.")
    }

    static func open(_ url: String) {
        guard let url = URL(string: url) else { return }
        NSWorkspace.shared.open(url)
    }
}
