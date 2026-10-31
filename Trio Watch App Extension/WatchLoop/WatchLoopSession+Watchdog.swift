import Foundation
import UserNotifications

/// The dead man's switches (as LoopKit/Loop#2545's LoopStallWatchdog): each warning is scheduled ahead and pushed
/// out by every sign of life, so it fires even when watchOS has ended the app.
extension WatchLoopSession {
    private enum Watchdog: String {
        case notLooping
        case handBackUnconfirmed
        case notHearingFromPhone

        var identifier: String { WatchAlarms.notificationPrefix + "watchLoop." + rawValue }
    }

    /// Twice the cycle backstop: one missed cycle is the backstop's to catch.
    static let notLoopingWarning: TimeInterval = 20 * 60
    static let handBackWarning: TimeInterval = 2 * 60

    /// After each cycle, and when a session starts or ends.
    func armNotLoopingWatchdog() {
        guard state.phase == .active else { return disarm(.notLooping) }
        arm(
            .notLooping,
            after: Self.notLoopingWarning,
            title: String(localized: "Watch Loop Not Looping"),
            body: String(
                localized: "The watch hasn't looped for 20 minutes. Open Trio on the watch, or take the pod back on your iPhone."
            )
        )
    }

    func armHandBackWatchdog() {
        arm(
            .handBackUnconfirmed,
            after: Self.handBackWarning,
            title: String(localized: "Hand-Back Not Confirmed"),
            body: String(localized: "Your iPhone hasn't confirmed it has the pod. Open Trio on the iPhone and check the pod.")
        )
    }

    func disarmHandBackWatchdog() { disarm(.handBackUnconfirmed) }

    /// Control row 3: with no session, a phone silent for 25 min is told, once; each word from it pushes this out.
    nonisolated static func phoneHeard() {
        Task { @MainActor in shared.armNotHearingFromPhone() }
    }

    func armNotHearingFromPhone() {
        lastHeardFromPhoneAt = Date()
        guard state.phase == .idle, WatchState.shared.watchLoopEnabled,
              case let .tellIfSilent(_, after) = WatchLoopControl.decide(.init(device: .watch, trigger: .phoneHeardWithNoSession))
        else { return disarm(.notHearingFromPhone) }
        arm(
            .notHearingFromPhone,
            after: after,
            title: String(localized: "Not Hearing From Your iPhone"),
            body: String(
                localized: "Trio on the watch hasn't heard from your iPhone for 25 minutes. Check that the iPhone is looping."
            )
        )
    }

    private func arm(_ watchdog: Watchdog, after delay: TimeInterval, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: watchdog.identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        ))
    }

    private func disarm(_ watchdog: Watchdog) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [watchdog.identifier])
    }
}
