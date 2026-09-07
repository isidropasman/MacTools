import AppKit
import ServiceManagement
import UserNotifications
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var calendar: CalendarManager
    @ObservedObject var sessions: SessionStore
    @ObservedObject var tasks: TaskStore
    @ObservedObject var setup: Setup
    @ObservedObject var connectors: Connectors
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var fluid: FluidVoiceControl

    @State private var section: Section? = .overview
    @State private var recordingTool: Tool?
    @State private var notificationsAllowed: Bool?
    @State private var trusted = Paster.isTrusted
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Resumen"
        case tools = "Atajos"
        case clipboard = "Portapapeles"
        case dictation = "Dictado"
        case tasks = "Tareas"
        case agents = "Agentes"
        case shelf = "Estante"
        case notch = "Notch"
        case privacy = "Privacidad"
        case connections = "Conexiones"
        case system = "Sistema"

        var id: String { self.rawValue }

        var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .tools: "command"
            case .clipboard: "doc.on.clipboard"
            case .dictation: "mic"
            case .tasks: "checklist"
            case .agents: "cpu"
            case .shelf: "tray.full"
            case .notch: "macbook"
            case .privacy: "hand.raised"
            case .connections: "point.3.connected.trianglepath.dotted"
            case .system: "desktopcomputer"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: self.$section) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 210, max: 240)
            // Ajustes del sistema has no collapse control at all: the sidebar is the navigation, so
            // hiding it leaves the window with nowhere to go.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form {
                switch self.section ?? .overview {
                case .overview: self.overview
                case .tools: self.tools
                case .clipboard: self.clipboard
                case .dictation: self.dictation
                case .tasks: self.tasksSection
                case .agents: self.agents
                case .shelf: self.shelfSection
                case .notch: self.notch
                case .privacy: self.privacy
                case .connections: self.connections
                case .system: self.system
                }
            }
            .formStyle(.grouped)
            .navigationTitle(self.section?.rawValue ?? "Resumen")
        }
        .frame(width: 780, height: 520)
        .onAppear(perform: self.refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: .mactoolsShowAgents)) { _ in
            self.section = .agents
        }
        // Permissions are granted in another app, so nothing tells this window they changed. Without
        // the poll it kept insisting on a permission you had already given.
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            self.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.refreshPermissions()
        }
    }

    /// One row per mini app. The point of merging everything was being able to see, in one glance,
    /// what is on and what is not.
    @ViewBuilder
    private var overview: some View {
        if !self.setup.isReady {
            SwiftUI.Section {
                ForEach(self.setup.pending) { step in
                    HStack(spacing: 12) {
                        Image(systemName: step.symbol)
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title).font(.system(size: 13, weight: .medium))
                            Text(step.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button(step.actionTitle, action: step.action)
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("Falta configurar")
            }
        }

        SwiftUI.Section("Herramientas") {
            self.overviewRow(
                "Portapapeles", "doc.on.clipboard",
                detail: "Historial de todo lo que copiás",
                state: .ok(Settings.shared.shortcut(for: .history).map(Settings.shared.display) ?? String(localized: "sin atajo")),
                go: .clipboard
            )
            self.overviewRow(
                "Dictado", "mic",
                detail: LocalizedStringKey(self.fluid.isInstalled
                    ? "FluidVoice \(self.fluid.installedVersion ?? "")"
                        + (self.fluid.isRunning ? " · \(String(localized: "corriendo"))" : " · \(String(localized: "cerrado"))")
                    : String(localized: "FluidVoice no está instalado")),
                state: self.fluid.isInstalled
                    ? (self.fluid.isRunning ? .ok(String(localized: "Activo")) : .warn(String(localized: "Cerrado")))
                    : .warn(String(localized: "Falta")),
                go: .dictation
            )
            self.overviewRow(
                "Tareas", "checklist",
                detail: LocalizedStringKey("\(self.tasks.pending.count) \(String(localized: "pendientes")) · \(self.tasks.projects.count) \(String(localized: "proyectos"))"),
                state: .ok(Settings.shared.shortcut(for: .quickAdd).map(Settings.shared.display) ?? String(localized: "sin atajo")),
                go: .tasks
            )
            self.overviewRow(
                "Agentes", "cpu",
                detail: LocalizedStringKey("\(self.connectors.list.filter(\.installed).count) / \(self.connectors.list.count) \(String(localized: "conectores"))"),
                state: self.sessions.visible.isEmpty ? .idle(String(localized: "Nada corriendo")) : .ok("\(self.sessions.visible.count) \(String(localized: "sesiones"))"),
                go: .agents
            )
            self.overviewRow(
                "Estante", "tray.full",
                detail: "Archivos parkeados en la notch",
                state: self.shelf.items.isEmpty ? .idle(String(localized: "Vacío")) : .ok("\(self.shelf.items.count) \(String(localized: "archivos"))"),
                go: .shelf
            )
            self.overviewRow(
                "Notch", "macbook",
                detail: "Música, agenda y batería",
                state: .ok(String(localized: "Al pasar el mouse")),
                go: .notch
            )
        }
    }

    private enum RowState {
        case ok(String), warn(String), idle(String)

        var text: String {
            switch self { case let .ok(t), let .warn(t), let .idle(t): t }
        }

        var color: Color {
            switch self { case .ok: .green; case .warn: .orange; case .idle: .secondary }
        }
    }

    private func overviewRow(
        _ title: LocalizedStringKey,
        _ symbol: String,
        detail: LocalizedStringKey,
        state: RowState,
        go: Section
    ) -> some View {
        Button { self.section = go } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.tint)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 5) {
                    Circle().fill(state.color).frame(width: 7, height: 7)
                    Text(state.text).font(.caption).foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Dictado

    @ViewBuilder
    private var dictation: some View {
        SwiftUI.Section {
            if self.fluid.isInstalled {
                LabeledContent("FluidVoice") {
                    HStack(spacing: 8) {
                        Text(self.fluid.installedVersion ?? "—").foregroundStyle(.secondary)
                        Circle()
                            .fill(self.fluid.isRunning ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Button(self.fluid.isRunning ? "Cerrar" : "Abrir") {
                            self.fluid.isRunning ? self.fluid.quit() : self.fluid.launch()
                        }
                        .controlSize(.small)
                    }
                }
            } else {
                HStack {
                    Label("FluidVoice no está instalado", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Spacer()
                    Button("Descargar") { self.fluid.openReleases() }
                        .controlSize(.small)
                }
            }
        } header: {
            Text("Motor")
        } footer: {
            Text("El dictado corre en FluidVoice: ahí viven los modelos de voz y la captura de audio. MacTools lo controla desde acá en vez de duplicarlo, así sigue recibiendo las actualizaciones de ellos.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if self.fluid.isInstalled {
            SwiftUI.Section("Cómo dicta") {
                Picker("Modo del atajo", selection: Binding(
                    get: { self.fluid.string("HotkeyMode") ?? "toggle" },
                    set: { self.fluid.set($0, for: "HotkeyMode") }
                )) {
                    Text("Tocar para arrancar y parar").tag("toggle")
                    Text("Mantener apretado").tag("pressAndHold")
                }
                Picker("Cómo inserta el texto", selection: Binding(
                    get: { self.fluid.string("TextInsertionMode") ?? "reliablePaste" },
                    set: { self.fluid.set($0, for: "TextInsertionMode") }
                )) {
                    Text("Pegar (confiable)").tag("reliablePaste")
                    Text("Tipear caracter por caracter").tag("typing")
                }
                LabeledContent("Modelo", value: self.fluid.string("SelectedSpeechModel") ?? "—")
                LabeledContent("Idioma", value: self.fluid.string("OnboardingSelectedLanguageID") ?? "—")
                Text("Tipear no avisa si el texto llegó, y en apps Electron se pierde en silencio. Los cambios se aplican cuando FluidVoice arranca de nuevo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section("En MacTools") {
                Toggle("Guardar los dictados en el portapapeles", isOn: self.$settings.ingestDictations)
            }

            SwiftUI.Section("Actualizaciones") {
                HStack {
                    if self.fluid.checking {
                        Text("Buscando…").foregroundStyle(.secondary)
                    } else if let error = self.fluid.checkError {
                        Text(error).foregroundStyle(.orange).font(.caption)
                    } else if self.fluid.hasUpdate {
                        Label("Hay una \(self.fluid.latestVersion ?? "") disponible", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else if self.fluid.latestVersion != nil {
                        Text("Estás al día").foregroundStyle(.secondary).font(.caption)
                    } else {
                        Text("Sin chequear").foregroundStyle(.secondary).font(.caption)
                    }
                    Spacer()
                    Button("Buscar") { self.fluid.checkForUpdate() }
                    Button("Descargar") { self.fluid.openReleases() }
                        .disabled(!self.fluid.hasUpdate)
                }
            }
        }
    }

    // MARK: - Tareas

    @ViewBuilder
    private var tasksSection: some View {
        SwiftUI.Section {
            LabeledContent("Pendientes", value: "\(self.tasks.pending.count)")
            LabeledContent("Proyectos", value: "\(self.tasks.projects.count)")
            Text("Escribí #proyecto/sección, @app, !tipo, p1 a p4 y «en 25m» en la misma línea; los tokens saltan a los chips solos.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Estante

    @ViewBuilder
    private var shelfSection: some View {
        SwiftUI.Section {
            LabeledContent("Archivos guardados", value: "\(self.shelf.items.count)")
            LabeledContent("Ocupan", value: Self.sizeLabel(self.shelf.totalBytes))
            HStack {
                Button("Abrir la carpeta") { NSWorkspace.shared.open(ShelfStore.directory) }
                Button("Vaciar", role: .destructive) { self.shelf.clear() }
                    .disabled(self.shelf.items.isEmpty)
                Spacer()
            }
        } footer: {
            Text("Los archivos se copian al estante, así que mover o borrar el original no lo vacía. Doble clic abre, arrastralos afuera para copiarlos donde quieras.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func sizeLabel(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
    private var clipboard: some View {
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

        self.history
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
            LabeledContent("Máximo de textos") {
                TextField("", value: self.$settings.maxTexts, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Tope de imágenes (GB)") {
                TextField("", value: self.$settings.maxImageGB, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
            Text("Al pasarse del tope se borran los más viejos. Los fijados nunca.")
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
    /// Everything llmpet used to configure in its own window, plus what it never had: a way to
    /// install the pieces instead of a README telling you to copy files.
    @ViewBuilder
    private var agents: some View {
        SwiftUI.Section {
            ForEach(self.connectors.list) { connector in
                HStack(spacing: 12) {
                    Image(systemName: connector.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(connector.installed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(connector.name).font(.system(size: 13, weight: .medium))
                        Text(connector.note ?? connector.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    if connector.installed {
                        HStack(spacing: 5) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text("Conectado").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let install = connector.install {
                        Button("Instalar", action: install)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 3)
            }
        } header: {
            Text("Conectores")
        } footer: {
            Text("Instalar el hook de la terminal escribe en ~/.claude/settings.json y deja una copia del archivo anterior al lado.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        SwiftUI.Section("Ahora mismo") {
            LabeledContent("Sesiones visibles", value: "\(self.sessions.visible.count)")
            LabeledContent("Esperando respuesta", value: "\(self.sessions.readyCount)")
            HStack {
                Button("Abrir ~/.llmpet") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Connectors.home))
                }
                .disabled(!FileManager.default.fileExists(atPath: Connectors.home))
                Spacer()
            }
        }
    }

    /// Everything the app needs from the system, with its real state and the one button that fixes
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
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
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
        SwiftUI.Section("Idioma") {
            LabeledContent("Idioma") { LanguagePicker() }
            Text("La app está escrita en español; el resto de los idiomas se traducen. Cambiarlo pide reiniciarla.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

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
