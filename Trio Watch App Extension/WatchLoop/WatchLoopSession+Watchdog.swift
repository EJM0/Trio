import Foundation
import UserNotifications

/// The dead man's switches (as LoopKit/Loop#2545's LoopStallWatchdog): each warning is scheduled ahead and pushed
/// out by every sign of life, so it fires even when watchOS has ended the app.
extension WatchLoopSession {
    private enum Watchdog: Hashable {
        /// One per rung of the ladder, in minutes.
        case notLooping(Int)
        case handBackUnconfirmed
        case notHearingFromPhone

        var identifier: String {
            let name: String
            switch self {
            case let .notLooping(minutes): name = "notLooping.\(minutes)"
            case .handBackUnconfirmed: name = "handBackUnconfirmed"
            case .notHearingFromPhone: name = "notHearingFromPhone"
            }
            return WatchAlarms.notificationPrefix + "watchLoop." + name
        }
    }

    /// The phone's Loop-Failure ladder on the wrist (as LoopKit/Loop#2545's LoopStallWatchdog): the first rung is
    /// twice the cycle backstop, as one missed cycle is the backstop's to catch.
    static let notLoopingRungs: [TimeInterval] = [20 * 60, 40 * 60, 60 * 60, 120 * 60]
    static let handBackWarning: TimeInterval = 2 * 60

    /// After each cycle, and when a session starts or ends: every rung is pushed out again.
    func armNotLoopingWatchdog() {
        for rung in Self.notLoopingRungs {
            let watchdog = Watchdog.notLooping(Int(rung / 60))
            guard state.phase == .active else {
                disarm(watchdog)
                continue
            }
            let elapsed = Duration.seconds(rung).formatted(.units(allowed: [.hours, .minutes], width: .wide))
            arm(
                watchdog,
                after: rung,
                title: String(localized: "Watch Loop Not Looping"),
                body: String(
                    localized: "The watch hasn't looped for \(elapsed). Open Trio on the watch, or take the pod back on your iPhone."
                )
            )
        }
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
