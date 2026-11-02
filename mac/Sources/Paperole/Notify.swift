import AppKit
import UserNotifications

/// A notification of the system's, when Paperole is not the front app (the look-ups' end, P1.3): asked for once, the
/// first time; never in a test run.
@MainActor
enum Notify {
    static func post(_ title: String, body: String) {
        guard !LaunchOptions.isTestRun else { return }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let n = UNMutableNotificationContent()
            n.title = title
            n.body = body
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
        }
    }
}
