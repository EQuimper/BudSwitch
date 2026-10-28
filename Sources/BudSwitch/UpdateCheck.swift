import AppKit
import UserNotifications

/// Once a day, asks GitHub for the latest release and posts a notification the first time it sees a newer version.
/// It skips the request while BudSwitch can't send notifications, so turning them off in System Settings stops it.
final class UpdateCheck: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private static let latestRelease = URL(string: "https://api.github.com/repos/EQuimper/BudSwitch/releases/latest")!
    private static let releasePage = URL(string: "https://github.com/EQuimper/BudSwitch/releases/latest")!

    private let session: URLSession

    override init() {
        // At login the network may not be up yet: wait for it rather than fail until the next day.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: .alert) { _, _ in }
        Task {
            while true {
                await check()
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    private func check() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized,
              let (data, _) = try? await session.data(from: Self.latestRelease),
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = release["tag_name"] as? String,
              let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return }

        let version = String(tag.trimmingPrefix("v"))
        guard version.compare(current, options: .numeric) == .orderedDescending else {
            // Up to date: the notification about this version, if it's still there, is old news.
            center.removeDeliveredNotifications(withIdentifiers: ["update"])
            return
        }
        guard version != UserDefaults.standard.string(forKey: "notifiedVersion") else { return }

        let content = UNMutableNotificationContent()
        content.title = "BudSwitch \(version) is available"
        content.body = "brew upgrade equimper/tap/budswitch"
        try? await center.add(UNNotificationRequest(identifier: "update", content: content, trigger: nil))
        UserDefaults.standard.set(version, forKey: "notifiedVersion")
    }

    /// Shows the banner even while BudSwitch is the active app, which it can be right after launch.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        NSWorkspace.shared.open(Self.releasePage)
    }
}
