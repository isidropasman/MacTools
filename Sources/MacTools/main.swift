import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var store: Store?
    private var watcher: ClipboardWatcher?
    private var ingestor: FluidVoiceIngestor?
    private var hotKeys: [Tool: GlobalHotKey] = [:]
    private var panel: PanelController?
    private var model: HistoryModel?
    private var settingsWindow: NSWindow?
    private var projectsWindow: NSWindow?
    /// Closing the catalogue should put you back where you were, not just leave you with nothing.
    private var projectsCameFromQuickAdd = false
    private var media: MediaController?
    private var notch: NotchController?
    private var shelf: ShelfStore?
    private var battery: BatteryMonitor?
    private var calendar: CalendarManager?
    private var tasks: TaskStore?
    private var sessions: SessionStore?
    private var fluid: FluidVoiceControl?
    private var setup: Setup?
    private var connectors: Connectors?
    private var welcomeWindow: NSWindow?
    private var listener: LocalListener?
    private var quickAdd: QuickAddController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store: Store
        do {
            store = try Store()
        } catch {
            self.presentFatal("No se pudo abrir la base de datos: \(error)")
            return
        }
        self.store = store

        let model = HistoryModel(store: store)
        self.model = model

        let watcher = ClipboardWatcher(store: store) { [weak model] in
            model?.reload()
        }
        self.watcher = watcher
        watcher.start()

        let ingestor = FluidVoiceIngestor(store: store) { [weak model, weak self] inserted in
            if inserted { model?.reload() }
            model?.refreshDictationWarning(self?.ingestor?.isHistoryDisabled ?? false)
        }
        self.ingestor = ingestor
        ingestor.start()

        let panel = PanelController(model: model) { [weak watcher] item in
            watcher?.copyBack(item)
        }
        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        self.panel = panel

        Settings.shared.hotKeyChanged
            .sink { [weak self] in self?.registerHotKeys() }
            .store(in: &self.cancellables)

        let media = MediaController()
        media.start()
        self.media = media

        let shelf = ShelfStore()
        self.shelf = shelf

        let battery = BatteryMonitor()
        battery.start()
        self.battery = battery

        let calendar = CalendarManager()
        calendar.start()
        self.calendar = calendar

        let tasks = TaskStore()
        self.tasks = tasks

        // What llmpet used to watch from its own floating window.
        let sessions = SessionStore()
        sessions.start()
        self.sessions = sessions

        // The Chrome extension POSTs here; extensions cannot write files themselves.
        let fluid = FluidVoiceControl()
        self.fluid = fluid
        let connectors = Connectors()
        self.connectors = connectors
        self.setup = Setup(calendar: calendar, fluid: fluid, connectors: connectors)

        let listener = LocalListener()
        listener.start()
        self.listener = listener

        let quickAdd = QuickAddController(tasks: tasks)
        quickAdd.onManageProjects = { [weak self] in
            self?.projectsCameFromQuickAdd = true
            self?.openProjects()
        }
        self.quickAdd = quickAdd

        let notch = NotchController(media: media, shelf: shelf, battery: battery, calendar: calendar, tasks: tasks, sessions: sessions)
        notch.onQuickAdd = { [weak quickAdd] in quickAdd?.show() }
        notch.onEditTask = { [weak quickAdd] task in quickAdd?.show(editing: task) }
        notch.onOpenSettings = { [weak self] in self?.openSettings() }
        quickAdd.onTaskAdded = { [weak notch] task, screen in
            notch?.announce(task, on: screen)
        }
        notch.install()
        self.notch = notch

        self.buildStatusItem()
        self.registerHotKeys()

        // First run opens the guide instead of leaving a menu bar icon and no explanation.
        if !Settings.shared.welcomeShown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.openWelcome() }
        }
    }

    private func registerHotKeys() {
        // Released before re-registering: Carbon refuses a duplicate combo.
        self.hotKeys.removeAll()

        for tool in Tool.allCases {
            guard let shortcut = Settings.shared.shortcut(for: tool) else { continue }
            let hotKey = GlobalHotKey(keyCode: shortcut.key, modifiers: shortcut.modifiers) { [weak self] in
                self?.run(tool)
            }
            if let hotKey {
                self.hotKeys[tool] = hotKey
            } else {
                NSLog("MacTools: no se pudo registrar el atajo de \(tool.title), probablemente ya lo tomó otra app")
            }
        }

        self.refreshMenuTitles()
    }

    private func showNotchTab(_ tab: NotchTab) {
        self.notch?.show(tab)
    }

    private func run(_ tool: Tool) {
        switch tool {
        case .history: self.panel?.toggle()
        case .quickAdd: self.quickAdd?.toggle()
        case .projects: self.openProjects()
        case .sessions: self.showNotchTab(.sessions)
        case .notch: self.notch?.toggleUnderPointer()
        }
    }

    private func refreshMenuTitles() {
        guard let items = statusItem?.menu?.items else { return }
        for (offset, tool) in [Tool.history, .quickAdd, .projects].enumerated() {
            let index = offset + 2
            guard items.indices.contains(index) else { continue }
            let shortcut = Settings.shared.shortcut(for: tool).map { "  " + Settings.shared.display($0) } ?? ""
            items[index].title = self.menuTitle(tool) + shortcut
        }
    }

    private func menuTitle(_ tool: Tool) -> String {
        switch tool {
        case .history: "Abrir historial"
        case .quickAdd: "Nueva tarea"
        case .projects: "Proyectos y secciones…"
        case .sessions: "Sesiones de agentes"
        case .notch: "Abrir la notch"
        }
    }

    @objc private func openSettings() {
        if let settingsWindow {
            settingsWindow.center()
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacTools"
        // Without this the window stays on whatever Space it was first opened in.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: SettingsView(
            settings: Settings.shared,
            calendar: self.calendar ?? CalendarManager(),
            sessions: self.sessions ?? SessionStore(),
            tasks: self.tasks ?? TaskStore(),
            setup: self.setup ?? Setup(calendar: self.calendar ?? CalendarManager(), fluid: self.fluid ?? FluidVoiceControl(), connectors: self.connectors ?? Connectors()),
            connectors: self.connectors ?? Connectors(),
            shelf: self.shelf ?? ShelfStore(),
            fluid: self.fluid ?? FluidVoiceControl()
        ))
        window.contentView = hosting
        window.setContentSize(NSSize(width: 780, height: 520))
        window.contentMinSize = NSSize(width: 700, height: 440)
        window.center()
        window.isReleasedWhenClosed = false
        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openWelcome() {
        guard let setup else { return }
        if let welcomeWindow {
            welcomeWindow.center()
            welcomeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: WelcomeView(setup: setup) { [weak self] in
            Settings.shared.welcomeShown = true
            self?.welcomeWindow?.performClose(nil)
        })
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.title = ""
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.center()
        self.welcomeWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openProjects() {
        guard let tasks else { return }
        if let projectsWindow {
            projectsWindow.center()
            projectsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // A hosting controller resizes the window as projects come and go; a plain hosting view
        // would freeze whatever height the list happened to have when it opened.
        let controller = NSHostingController(rootView: ProjectsView(tasks: tasks) { [weak self] in
            guard let self else { return }
            self.projectsWindow?.performClose(nil)
            if self.projectsCameFromQuickAdd {
                self.projectsCameFromQuickAdd = false
                self.quickAdd?.show()
            }
        })
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.title = "Proyectos y secciones"
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        window.isReleasedWhenClosed = false
        self.projectsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.make()

        let menu = NSMenu()
        menu.addItem(withTitle: "Guía de inicio", action: #selector(self.openWelcome), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Abrir historial", action: #selector(self.openPanel), keyEquivalent: "")
        menu.addItem(withTitle: "Nueva tarea", action: #selector(self.openQuickAdd), keyEquivalent: "")
        menu.addItem(withTitle: "Proyectos y secciones…", action: #selector(self.openProjects), keyEquivalent: "")
        menu.addItem(withTitle: "Configuración…", action: #selector(self.openSettings), keyEquivalent: ",")
        menu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: "Abrir al iniciar sesión",
            action: #selector(self.toggleLoginItem),
            keyEquivalent: ""
        )
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for entry in menu.items where entry.action != nil && entry.action != #selector(NSApplication.terminate(_:)) {
            entry.target = self
        }

        item.menu = menu
        self.statusItem = item
    }

    @objc private func openQuickAdd() {
        self.quickAdd?.show()
    }

    @objc private func openPanel() {
        self.panel?.show()
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSLog("MacTools: no se pudo cambiar el login item: \(error)")
        }
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MacTools"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}

// Top-level code already runs on the main thread; the assertion just teaches the compiler that.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    objc_setAssociatedObject(app, "MacToolsDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
