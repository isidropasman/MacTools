import AppKit
import ServiceManagement
import UserNotifications
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var calendar: CalendarManager
    @ObservedObject var sessions: SessionStore

    @State private var section: Section? = .tools
    @State private var recordingTool: Tool?
    @State private var notificationsAllowed: Bool?
    @State private var trusted = Paster.isTrusted
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    enum Section: String, CaseIterable, Identifiable {
        case tools = "Atajos"
        case general = "General"
        case history = "Historial"
        case privacy = "Privacidad"
        case notch = "Notch"
        case agents = "Agentes"
        case connections = "Conexiones"
        case system = "Sistema"

        var id: String { self.rawValue }

        var symbol: String {
            switch self {
            case .tools: "square.grid.2x2"
            case .general: "gearshape"
            case .history: "clock.arrow.circlepath"
            case .privacy: "hand.raised"
            case .notch: "macbook"
            case .agents: "cpu"
            case .connections: "point.3.connected.trianglepath.dotted"
            case .system: "desktopcomputer"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: self.$section) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 186, ideal: 186, max: 220)
            // Ajustes del sistema has no collapse control at all: the sidebar is the navigation, so
            // hiding it leaves the window with nowhere to go.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form {
                switch self.section ?? .tools {
                case .tools: self.tools
                case .general: self.general
                case .history: self.history
                case .privacy: self.privacy
                case .notch: self.notch
                case .agents: self.agents
                case .connections: self.connections
                case .system: self.system
                }
            }
            .formStyle(.grouped)
            .navigationTitle(self.section?.rawValue ?? "Atajos")
        }
        .frame(width: 720, height: 480)
        .onAppear(perform: self.refreshPermissions)
        // Permissions are granted in another app, so nothing tells this window they changed. Without
        // the poll it kept insisting on a permission you had already given.
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            self.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.refreshPermissions()
        }
    }

    @ViewBuilder
    private var tools: some View {
        SwiftUI.Section {
            ForEach(Tool.allCases) { tool in
                HStack(spacing: 12) {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(.tint)
                        .frame(width: 26)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.title).font(.system(size: 13, weight: .medium))
                        Text(tool.detail).font(.caption).foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Button(self.label(for: tool)) {
                        self.recordingTool = self.recordingTool == tool ? nil : tool
                    }
                    .frame(minWidth: 120)

                    Button {
                        self.settings.setShortcut(nil, for: tool)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(self.settings.shortcut(for: tool) == nil || tool == .history ? 0 : 1)
                    .help("Quitar el atajo")
                }
                .padding(.vertical, 4)
                // Reading the revision here is what redraws the label after a capture.
                .id("\(tool.rawValue)-\(self.settings.shortcutRevision)")
            }
        } footer: {
            Text("⌘⇧V choca con «pegar sin formato» en Chrome, Slack y Notion. ⌘⇧B está libre.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .background(ShortcutRecorder(tool: self.$recordingTool, settings: self.settings))
    }

    private func label(for tool: Tool) -> String {
        if self.recordingTool == tool { return "Apretá las teclas…" }
        guard let shortcut = settings.shortcut(for: tool) else { return "Sin atajo" }
        return self.settings.display(shortcut)
    }

    @ViewBuilder
    private var general: some View {
        SwiftUI.Section("Al elegir un item") {
            Toggle("Pegar automáticamente", isOn: self.$settings.pasteOnPick)
            if self.settings.pasteOnPick, !self.trusted {
                HStack(spacing: 8) {
                    Label("Necesita permiso de Accesibilidad", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Button("Dar permiso") { Paster.requestPermission() }
                        .controlSize(.small)
                }
            }
            Text(self.settings.pasteOnPick
                ? "Enter copia y pega en la app donde estabas."
                : "Enter solo copia; pegás vos con ⌘V.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var history: some View {
        SwiftUI.Section {
            Toggle("Guardar dictados de FluidVoice", isOn: self.$settings.ingestDictations)
            LabeledContent("Máximo de imágenes") {
                TextField("", value: self.$settings.maxImages, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Tope de imágenes (GB)") {
                TextField("", value: self.$settings.maxImageGB, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
            Text("El texto no se borra nunca. Los fijados tampoco.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var privacy: some View {
        SwiftUI.Section {
            Toggle("Ocultar de capturas y pantalla compartida", isOn: self.$settings.hideFromCapture)
            Text("La notch y el historial dejan de aparecer en grabaciones, capturas y Zoom o Meet. Vos los seguís viendo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var notch: some View {
        SwiftUI.Section {
            Toggle("Recordar la última pestaña", isOn: self.$settings.rememberLastTab)
            Toggle("Asomarse al cambiar de canción", isOn: self.$settings.peekOnTrackChange)
            LabeledContent("Espera para abrir") {
                HStack {
                    Slider(value: self.$settings.hoverDelay, in: 0.05 ... 0.6)
                        .frame(width: 160)
                    Text(String(format: "%.2fs", self.settings.hoverDelay))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Text("La notch siempre avisa cuando enchufás o desenchufás el cargador.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Everything the app needs from the system, with its real state and the one button that fixes
    /// it. Sending someone to hunt through System Settings is not a connection flow.
    /// Everything llmpet used to configure in its own window.
    @ViewBuilder
    private var agents: some View {
        SwiftUI.Section("Qué se monitorea") {
            LabeledContent("Conductor") {
                Text(FileManager.default.fileExists(
                    atPath: NSHomeDirectory() + "/Library/Application Support/com.conductor.app/conductor.db")
                    ? "Detectado" : "No encontrado")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Claude Desktop") {
                Text(FileManager.default.fileExists(atPath: "/Applications/Claude.app") ? "Detectado" : "No encontrado")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Sesiones de terminal") {
                Text("\(self.llmSessionCount) activas")
                    .foregroundStyle(.secondary)
            }
        }

        SwiftUI.Section("Extensión de Chrome") {
            Text("Escuchando en localhost:\(String(LocalListener.port)). La extensión reporta las pestañas de ChatGPT y Claude; sin ella igual ves Conductor, Claude Desktop y las sesiones de terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Abrir la carpeta de la extensión") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Self.extensionPath)
                }
                .disabled(!FileManager.default.fileExists(atPath: Self.extensionPath))
                Spacer()
            }
        }

        SwiftUI.Section("Hooks") {
            Text("Los scripts de ~/.llmpet reportan lo que corre en la terminal. Se instalan una vez y siguen andando.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Abrir ~/.llmpet") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.llmpet"))
                }
                .disabled(!FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.llmpet"))
                Spacer()
            }
        }
    }

    private var llmSessionCount: Int { self.sessions.visible.count }

    private static let extensionPath = NSHomeDirectory() + "/Desktop/Isidro/MacTools/llmpet/extension"

    @ViewBuilder
    private var connections: some View {
        SwiftUI.Section("Permisos") {
            self.permissionRow(
                "Calendario",
                detail: "Ver tus eventos en la notch.",
                symbol: "calendar",
                state: self.calendarState
            ) {
                if self.calendar.access == .unknown {
                    self.calendar.requestAccess()
                } else {
                    Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                }
            }

            self.permissionRow(
                "Accesibilidad",
                detail: "Pegar automáticamente al elegir un item del historial.",
                symbol: "hand.raised",
                state: self.trusted ? .ok("Concedido") : .missing("Sin permiso")
            ) {
                Paster.requestPermission()
            }

            self.permissionRow(
                "Notificaciones",
                detail: "Avisarte cuando vence una tarea.",
                symbol: "bell",
                state: self.notificationsState
            ) {
                Self.open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            }

            self.permissionRow(
                "Automatización",
                detail: "Leer y controlar Spotify o Música.",
                symbol: "music.note",
                state: .unknown("Se pide al primer uso")
            ) {
                Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            }
        }

        SwiftUI.Section("Cuentas de calendario") {
            if self.calendar.accounts.isEmpty {
                Text("Todavía no hay ninguna.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.calendar.accounts) { account in
                    LabeledContent(account.calendarTitles.first ?? account.sourceTitle) {
                        TextField(account.label, text: Binding(
                            get: { AccountLabels.custom()[account.id] ?? "" },
                            set: { AccountLabels.setCustom($0, for: account.id) }
                        ))
                        .frame(width: 110)
                    }
                }
            }

            HStack {
                Button("Agregar cuenta…") {
                    Self.open("x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")
                }
                Button("Recargar") { self.calendar.reloadNow() }
                Spacer()
            }

            Text("Google, iCloud y Exchange se agregan en el panel de cuentas del sistema; MacTools lee de ahí. Todas las de Google se llaman «Google», poné arriba cómo querés verlas.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        SwiftUI.Section("Dictados") {
            Toggle("Guardar lo que dictás con FluidVoice", isOn: self.$settings.ingestDictations)
            LabeledContent("FluidVoice") {
                Text(FileManager.default.fileExists(atPath: "/Applications/FluidVoice.app") ? "Instalado" : "No encontrado")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private enum PermissionState {
        case ok(String)
        case missing(String)
        case unknown(String)

        var label: String {
            switch self {
            case let .ok(text), let .missing(text), let .unknown(text): text
            }
        }

        var color: Color {
            switch self {
            case .ok: .green
            case .missing: .orange
            case .unknown: .secondary
            }
        }
    }

    private var calendarState: PermissionState {
        switch self.calendar.access {
        case .granted: .ok("Conectado")
        case .denied: .missing("Denegado")
        case .writeOnly: .missing("Solo escritura")
        case .unknown: .unknown("Sin pedir")
        }
    }

    private var notificationsState: PermissionState {
        switch self.notificationsAllowed {
        case true?: .ok("Concedido")
        case false?: .missing("Sin permiso")
        case nil: .unknown("Comprobando…")
        }
    }

    private func permissionRow(
        _ title: String,
        detail: String,
        symbol: String,
        state: PermissionState,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 5) {
                Circle().fill(state.color).frame(width: 7, height: 7)
                Text(state.label).font(.caption).foregroundStyle(.secondary)
            }

            Button("Abrir") { action() }
        }
        .padding(.vertical, 3)
    }

    private static func open(_ url: String) {
        guard let url = URL(string: url) else { return }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private var system: some View {
        SwiftUI.Section {
            Toggle("Abrir al iniciar sesión", isOn: self.$launchAtLogin)
                .onChange(of: self.launchAtLogin) { _, enabled in
                    try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
        }
    }
}

extension SettingsView {
    private func refreshPermissions() {
        let trusted = Paster.isTrusted
        if self.trusted != trusted { self.trusted = trusted }
        self.refreshNotificationState()
    }

    private func refreshNotificationState() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                if self.notificationsAllowed != allowed { self.notificationsAllowed = allowed }
            }
        }
    }
}

/// Captures the next key press while armed. A plain NSView monitor beats a custom control here.
private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var tool: Tool?
    let settings: Settings

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.arm(for: self.tool, settings: self.settings) { self.tool = nil }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?

        func arm(for tool: Tool?, settings: Settings, done: @escaping () -> Void) {
            self.remove()
            guard let tool else { return }
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    done()
                    return nil
                }
                let modifiers = Settings.carbonModifiers(from: event.modifierFlags)
                // A bare letter would fire while you type anywhere in the system.
                guard modifiers != 0 else { return nil }
                settings.setShortcut(
                    Settings.Shortcut(key: UInt32(event.keyCode), modifiers: modifiers),
                    for: tool
                )
                done()
                return nil
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            self.monitor = nil
        }
    }
}
