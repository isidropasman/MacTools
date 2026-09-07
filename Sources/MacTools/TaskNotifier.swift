import Foundation
import UserNotifications

/// Local notifications for tasks that carry a deadline. Nothing is scheduled for tasks without one,
/// so the permission prompt only appears once someone actually asks to be reminded.
final class TaskNotifier {
    private var center: UNUserNotificationCenter? {
        // Only a bundled app has a notification centre; guarding keeps command-line builds alive.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        self.center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func schedule(_ task: TodoTask) {
        guard let center, let due = task.due, due > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = [task.project.map { "#\($0)" }, task.type.map { "!\($0)" }]
            .compactMap { $0 }
            .joined(separator: "  ")
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, due.timeIntervalSinceNow),
            repeats: false
        )
        center.add(UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: trigger))
    }

    func cancel(_ task: TodoTask) {
        self.center?.removePendingNotificationRequests(withIdentifiers: [task.id.uuidString])
    }
}
