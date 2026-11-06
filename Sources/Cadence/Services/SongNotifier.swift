import AppKit
import UserNotifications

/// Posts a banner when the song changes.
@MainActor
final class SongNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes when the process is not inside an app bundle (e.g. `swift run`).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        center?.delegate = self
        if AppSettings.shared.notificationsEnabled { requestAuthorization() }
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// Called on track change; waits briefly so artwork has a chance to load.
    func trackChanged(_ snap: PlayerSnapshot) {
        let settings = AppSettings.shared
        guard settings.notificationsEnabled, snap.state == .playing else { return }
        if settings.notifyOnlyInBackground,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == snap.kind.bundleID { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard PlayerManager.shared.snapshot?.trackKey == snap.trackKey else { return }
            self.post(snap)
        }
    }

    func post(_ snap: PlayerSnapshot) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = snap.track.title
        content.subtitle = snap.track.artist
        content.body = snap.track.album
        content.threadIdentifier = "now-playing"
        if let png = PlayerManager.shared.artwork?.pngData() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-art-\(UUID().uuidString).png")
            if (try? png.write(to: url)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "art", url: url) {
                content.attachments = [attachment]
            }
        }
        center.removeAllDeliveredNotifications()
        center.add(UNNotificationRequest(identifier: "now-playing", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in PlayerManager.shared.activatePlayer() }
        completionHandler()
    }
}
