import AppKit
import ApplicationServices
import Combine
import Foundation

private struct AccessibilityNotification: Sendable {
    let id: String
    let applicationName: String
    let title: String
    let message: String
}

private enum NotificationCenterAccessibility {
    private static let bundleIdentifier = "com.apple.notificationcenterui"

    static func notifications() -> [AccessibilityNotification] {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleIdentifier)
        var result: [AccessibilityNotification] = []
        var remaining = 250

        for application in applications {
            let root = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.2)
            let windows = self.elements(root, attribute: kAXWindowsAttribute as CFString)
            for window in windows {
                self.collect(from: window, depth: 0, remaining: &remaining, into: &result)
            }
        }

        return result
    }

    static func pressNotification(id: String) -> Bool {
        guard UUID(uuidString: id) != nil else { return false }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleIdentifier)
        var remaining = 250

        for application in applications {
            let root = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.2)
            for window in self.elements(root, attribute: kAXWindowsAttribute as CFString) {
                if let notification = self.find(id: id, in: window, depth: 0, remaining: &remaining) {
                    return AXUIElementPerformAction(notification, kAXPressAction as CFString) == .success
                }
            }
        }

        return false
    }

    private static func collect(
        from element: AXUIElement,
        depth: Int,
        remaining: inout Int,
        into result: inout [AccessibilityNotification]
    ) {
        guard remaining > 0, depth <= 9 else { return }
        remaining -= 1
        AXUIElementSetMessagingTimeout(element, 0.2)

        let identifier = self.string(element, attribute: kAXIdentifierAttribute as CFString)
        let children = self.elements(element, attribute: kAXChildrenAttribute as CFString)
        if let identifier, UUID(uuidString: identifier) != nil {
            let title = children.first { self.string($0, attribute: kAXIdentifierAttribute as CFString) == "title" }
                .flatMap { self.string($0, attribute: kAXValueAttribute as CFString) }
            let message = children.first { self.string($0, attribute: kAXIdentifierAttribute as CFString) == "body" }
                .flatMap { self.string($0, attribute: kAXValueAttribute as CFString) }
            let description = self.string(element, attribute: kAXDescriptionAttribute as CFString) ?? ""
            if title != nil || message != nil {
                result.append(AccessibilityNotification(
                    id: identifier,
                    applicationName: description.components(separatedBy: ",").first?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .nonEmpty ?? "Notificación",
                    title: title?.nonEmpty ?? "Notificación",
                    message: message?.nonEmpty ?? ""
                ))
            }
        }

        for child in children {
            self.collect(from: child, depth: depth + 1, remaining: &remaining, into: &result)
        }
    }

    private static func find(
        id: String,
        in element: AXUIElement,
        depth: Int,
        remaining: inout Int
    ) -> AXUIElement? {
        guard remaining > 0, depth <= 9 else { return nil }
        remaining -= 1
        AXUIElementSetMessagingTimeout(element, 0.2)

        if self.string(element, attribute: kAXIdentifierAttribute as CFString) == id {
            return element
        }

        for child in self.elements(element, attribute: kAXChildrenAttribute as CFString) {
            if let match = self.find(id: id, in: child, depth: depth + 1, remaining: &remaining) {
                return match
            }
        }
        return nil
    }

    private static func elements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let string = value as? String
        else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class NotificationMonitor: ObservableObject {
    struct AppNotification {
        let id: String
        let applicationName: String
        let title: String
        let message: String
        let bundleIdentifier: String?
        let icon: NSImage?
    }

    @Published private(set) var current: AppNotification?
    private var pollTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    func start() {
        guard self.pollTask == nil else { return }
        self.pollTask = Task { [weak self] in
            var seenIDs = Set<String>()
            var isPrimed = false

            while !Task.isCancelled {
                guard let self else { return }
                if Settings.showAppNotificationsNow, Paster.isTrusted {
                    let notifications = await Task.detached(priority: .utility) {
                        NotificationCenterAccessibility.notifications()
                    }.value
                    guard !Task.isCancelled else { return }

                    if isPrimed {
                        if let newNotification = notifications.first(where: { !seenIDs.contains($0.id) }) {
                            self.dismissTask?.cancel()
                            self.current = self.makeNotification(newNotification)
                            self.dismissTask = Task { [weak self] in
                                try? await Task.sleep(for: .seconds(5))
                                guard !Task.isCancelled else { return }
                                self?.current = nil
                            }
                        }
                    } else {
                        isPrimed = true
                    }

                    for notification in notifications {
                        seenIDs.insert(notification.id)
                    }
                    if seenIDs.count > 100 {
                        seenIDs = Set(notifications.map(\.id))
                    }
                } else {
                    isPrimed = false
                    seenIDs.removeAll()
                    self.dismissTask?.cancel()
                    self.current = nil
                }

                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }

    func activate(_ notification: AppNotification) {
        Task {
            let activated = await Task.detached(priority: .userInitiated) {
                NotificationCenterAccessibility.pressNotification(id: notification.id)
            }.value
            guard !activated else { return }
            self.openApplication(for: notification)
        }
    }

    private func makeNotification(_ notification: AccessibilityNotification) -> AppNotification {
        let runningApplication = NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.localizedCaseInsensitiveCompare(notification.applicationName) == .orderedSame
        }
        let bundleIdentifier = runningApplication?.bundleIdentifier
        let applicationURL = bundleIdentifier.flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:))
            ?? NSWorkspace.shared.fullPath(forApplication: notification.applicationName).map(URL.init(fileURLWithPath:))

        return AppNotification(
            id: notification.id,
            applicationName: notification.applicationName,
            title: notification.title,
            message: notification.message,
            bundleIdentifier: bundleIdentifier,
            icon: runningApplication?.icon ?? applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        )
    }

    private func openApplication(for notification: AppNotification) {
        let applicationURL = notification.bundleIdentifier.flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:))
            ?? NSWorkspace.shared.fullPath(forApplication: notification.applicationName).map(URL.init(fileURLWithPath:))
        guard let applicationURL else { return }
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}

private extension String {
    var nonEmpty: String? { self.isEmpty ? nil : self }
}
