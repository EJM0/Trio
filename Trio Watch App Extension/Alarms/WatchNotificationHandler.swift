import Foundation
import UserNotifications
import WatchConnectivity

final class WatchNotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WatchNotificationHandler()

    override private init() {
        super.init()
    }

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories(on: center)
    }

    private func registerCategories(on center: UNUserNotificationCenter) {
        center.getNotificationCategories { existingCategories in
            let glucoseCategory = NotificationCategoryFactory.createGlucoseCategory()
            let podAlertCategory = UNNotificationCategory(
                identifier: WatchLoanAlerts.podAlertCategory,
                actions: [UNNotificationAction(
                    identifier: WatchLoanAlerts.acknowledgeAction,
                    title: String(localized: "Acknowledge", comment: "Watch notification action: acknowledge a pod alert"),
                    options: []
                )],
                intentIdentifiers: [],
                options: []
            )

            var categories = existingCategories
            categories.update(with: glucoseCategory)
            categories.update(with: podAlertCategory)
            // UNUserNotificationCenter methods should be called on main thread
            Task { @MainActor in
                center.setNotificationCategories(categories)
            }
        }
    }

    /// Shows the watch's own alarms even when Trio is open on the wrist: the phone can't show them for readings it
    /// doesn't have. Everything else keeps the system's default handling (kristinkand/Trio e5f1b34).
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.identifier.hasPrefix(WatchAlarms.notificationPrefix) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([])
        }
    }

    /// UNUserNotificationCenterDelegate method called when user interacts with a notification on watch.
    /// This can be called off the main thread. WCSession.transferUserInfo is thread-safe.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // a pod alert: the watch holding the pod tells the pod, which stops beeping; done once the pod answered
        if response.actionIdentifier == WatchLoanAlerts.acknowledgeAction {
            let id = response.notification.request.identifier
            Task { @MainActor in
                await WatchLoanRuntime.host?.acknowledgePodAlert(notificationID: id)
                completionHandler()
            }
            return
        }
        defer { completionHandler() }

        guard let action = NotificationResponseAction(rawValue: response.actionIdentifier) else { return }
        sendSnoozeRequest(minutes: action.minutes)
    }

    /// Sends snooze request to iPhone via WatchConnectivity.
    /// WCSession.transferUserInfo is thread-safe and can be called from any thread.
    /// Relies on the watch app's WCSession owner (e.g., WatchState) to handle
    /// session activation and delegate management.
    /// A duration of 0 ends the active snooze.
    func sendSnoozeRequest(minutes: Int) {
        guard WCSession.isSupported() else { return }
        // at once on the watch too: its own alarms snooze while the phone is away
        DispatchQueue.main.async {
            WatchState.shared.snoozeUntilDate = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes) * 60) : .distantPast
        }

        let payload: [String: Any] = [WatchMessageKeys.snoozeDuration: minutes]
        let session = WCSession.default

        // Try sendMessage first if session is reachable and activated (faster, immediate delivery)
        // Fall back to transferUserInfo if not reachable or if sendMessage fails
        if session.isReachable, session.activationState == .activated {
            session.sendMessage(payload, replyHandler: nil) { _ in
                // Fallback to transferUserInfo if sendMessage fails
                session.transferUserInfo(payload)
            }
        } else {
            // Session not reachable or not activated - use transferUserInfo (queued delivery)
            session.transferUserInfo(payload)
        }
    }
}
