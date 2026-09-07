import ServiceManagement

/// SMAppService replaces the old LaunchAgent plist dance: one call, and macOS
/// shows the app under Login Items where the user can revoke it themselves.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("llmpet: no pude cambiar el arranque automático: \(error)")
        }
    }
}
