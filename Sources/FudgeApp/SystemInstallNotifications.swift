import Foundation
import FudgeCore
@preconcurrency import UserNotifications

/// Fudge's notifications through `UNUserNotificationCenter` (SPEC-156 C.6): the only code in Fudge that touches it. It
/// posts, asks, reads macOS's answer and is the center's delegate. The app makes it once, in
/// `applicationWillFinishLaunching`, so a click that launches Fudge is delivered, and never in a snapshot run, which
/// gets `FixedInstallNotifications`: an ad hoc copy keeps Fudge's bundle id, so it would act as the user's Fudge.
final class SystemInstallNotifications: NSObject, InstallNotifications, UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    private let center = UNUserNotificationCenter.current()
    private let lock = NSLock()
    private var clickHandler: (@MainActor (NoticeTarget) -> Void)?
    /// A click that came before anything could take it (one that launched Fudge), until `onClick` is set.
    private var pendingClick: NoticeTarget?

    override init() {
        super.init()
        center.delegate = self
    }

    /// Where clicks go, on the main actor; a click that came before this is handed over at once.
    @MainActor func onClick(_ handler: @escaping @MainActor (NoticeTarget) -> Void) {
        let pending = lock.withLock {
            clickHandler = handler
            defer { pendingClick = nil }
            return pendingClick
        }
        if let pending { handler(pending) }
    }

    func permission() async -> NotificationPermission {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notAsked
        case .denied: return .off
        case .authorized, .provisional, .ephemeral: return settings.alertStyle == .none ? .quiet : .allowed
        @unknown default: return .unknown
        }
    }

    func requestPermission() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert])
        } catch {
            FudgeLog.error("couldn't ask macOS about notifications: \(error.localizedDescription)")
        }
    }

    func post(_ notice: InstallNotice) async throws {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        if let body = notice.body { content.body = body }
        content.userInfo = notice.target.userInfo
        content.sound = nil
        try await center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
    }

    /// Shown even while Fudge is the active app (its Settings window in front).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// A click: its `userInfo` is checked before anything (`NoticeTarget(userInfo:)`), and anything else is ignored.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let target = NoticeTarget(userInfo: response.notification.request.content.userInfo)
        else { return }
        let handler = lock.withLock {
            if clickHandler == nil { pendingClick = target }
            return clickHandler
        }
        guard let handler else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(target) } }
    }
}
