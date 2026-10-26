import AppKit
import EbbAppKit
import Foundation
import UserNotifications

/// The process starts here. launchd runs this same executable with
/// `--agent` for the daily scan: no window, no menu bar item, one scan at
/// most, then exit. Otherwise it's the app.
@main
enum Launcher {
    static func main() {
        let arguments = CommandLine.arguments
        // Used by the uninstaller, so no login item is left behind.
        if arguments.contains("--remove-login-item") {
            LoginItem.set(false)
            exit(0)
        }
        guard arguments.contains("--agent") else {
            MenuBarPlacement.prepare()
            EbbApp.main()
            return
        }
        let runner = AgentRunner(
            home: NSHomeDirectory(),
            temporaryDirectory: NSTemporaryDirectory(),
            conditions: MacConditions(),
            notifier: SystemNotifier()
        )
        Task {
            let line = await runner.run(force: arguments.contains("--now"))
            let stamp = Date().formatted(.iso8601)
            print("\(stamp) \(line)")
            exit(0)
        }
        dispatchMain()
    }
}

/// Posts through Notification Center, if the user allowed notifications
/// (asked when the daily agent is turned on).
struct SystemNotifier: Notifier {
    static let reviewCategory = "review"

    func post(_ notice: AgentPolicy.Notice) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.categoryIdentifier = Self.reviewCategory
        // One notification at a time: a new day's replaces the last.
        let request = UNNotificationRequest(identifier: "daily", content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}

/// Handles clicks on the daily notification: open the review screen.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var navigation: Navigation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Opening Ebb again (from Applications, Spotlight or the Dock) shows
    /// the window. On a crowded menu bar the item can end up behind the
    /// notch, and this keeps Ebb reachable anyway.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { navigation?.openRequested = true }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            navigation?.pane = .recommendations
            navigation?.openRequested = true
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
