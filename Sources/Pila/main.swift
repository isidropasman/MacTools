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
    private var hotKey: GlobalHotKey?
    private var panel: PanelController?
    private var model: HistoryModel?
    private var settingsWindow: NSWindow?
    private var media: MediaController?
    private var notch: NotchController?
    private var shelf: ShelfStore?
    private var battery: BatteryMonitor?
    private var calendar: CalendarManager?
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

        self.registerHotKey()
        Settings.shared.hotKeyChanged
            .sink { [weak self] in self?.registerHotKey() }
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

        let notch = NotchController(media: media, shelf: shelf, battery: battery, calendar: calendar)
        notch.install()
        self.notch = notch

        self.buildStatusItem()
        store.enforceRetention(maxImages: Settings.shared.maxImages, maxBytes: Settings.shared.maxImageBytes)
    }

    private func registerHotKey() {
        let settings = Settings.shared
        // Released before re-registering: Carbon refuses a duplicate combo.
        self.hotKey = nil
        self.hotKey = GlobalHotKey(keyCode: settings.keyCode, modifiers: settings.modifiers) { [weak self] in
            self?.panel?.toggle()
        }
        if self.hotKey == nil {
            NSLog("Pila: no se pudo registrar \(settings.shortcutDisplay), probablemente ya lo tomó otra app")
        }
        self.statusItem?.menu?.items.first?.title = "Abrir historial  \(settings.shortcutDisplay)"
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
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pila"
        // Without this the window stays on whatever Space it was first opened in.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: SettingsView(settings: Settings.shared, calendar: self.calendar ?? CalendarManager()))
        window.contentView = hosting
        // Apple settings windows size to their content instead of guessing a height.
        window.setContentSize(hosting.fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.make()

        let menu = NSMenu()
        menu.addItem(withTitle: "Abrir historial  \(Settings.shared.shortcutDisplay)", action: #selector(self.openPanel), keyEquivalent: "")
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
            NSLog("Pila: no se pudo cambiar el login item: \(error)")
        }
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Pila"
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
    objc_setAssociatedObject(app, "PilaDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
