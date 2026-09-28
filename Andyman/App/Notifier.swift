import AppKit
import OSLog
import UserNotifications

/// Posts a macOS notification when long-running work finishes while the panel is closed
/// (installs, setup, an emulator booting or crashing). While the panel is open the result is
/// already on screen, so nothing is posted.
final class Notifier: NSObject {
    static let shared = Notifier()

    /// Where a click on a notification takes you.
    enum Destination: String {
        case emulators, sdk, tools, setup
    }

    private static let enabledKey = "notificationsEnabled"

    /// Set by the panel controller.
    var isPanelVisible: () -> Bool = { false }
    /// Opens the panel on a tab; set by the app delegate.
    var open: (Destination) -> Void = { _ in }

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue { requestAuthorization() }
        }
    }

    private var center: UNUserNotificationCenter { .current() }
    private let log = Logger(subsystem: "dev.dhruvbhavsar.Andyman", category: "notifications")

    func start() {
        center.delegate = self
    }

    /// Asks for permission the first time the user starts something that may notify, so the
    /// system prompt appears in context rather than out of nowhere later.
    func requestAuthorization() {
        guard isEnabled else { return }
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                log.notice("Authorization granted: \(granted)")
            } catch {
                log.error("Authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Whether macOS blocks our notifications (the user chose Don't Allow, or turned them off
    /// in System Settings), so Settings can say so.
    func isBlockedBySystem() async -> Bool {
        await center.notificationSettings().authorizationStatus == .denied
    }

    /// Andyman's page in System Settings → Notifications.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.dhruvbhavsar.Andyman"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func post(_ title: String, _ body: String, opening destination: Destination) {
        guard isEnabled, !isPanelVisible() else {
            log.notice("Skipped \(title, privacy: .public): \(self.isEnabled ? "panel open" : "disabled", privacy: .public)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["destination": destination.rawValue]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                do {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                } catch {
                    log.error("Authorization failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            do {
                try await center.add(request)
                log.notice("Posted \(title, privacy: .public) (authorization \(settings.authorizationStatus.rawValue))")
            } catch {
                log.error("Couldn't post \(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["destination"] as? String
        await MainActor.run {
            open(raw.flatMap(Destination.init) ?? .emulators)
        }
    }

    /// A menu bar app counts as frontmost while its panel is open; show banners anyway (the
    /// panel check in `post` already filters out what's on screen).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
