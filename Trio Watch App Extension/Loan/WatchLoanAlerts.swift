import CoreBluetooth
import Foundation
import LoopKit

/// The watch's own notifications while it holds the pump. All at the time-sensitive level: a watch has no critical
/// alerts, so Silent or a Focus can reduce them to a tap on the wrist.
final class WatchLoanAlerts {
    static let notLoopingPrefix = "trio.loan.notLooping."
    static let glucosePrefix = "trio.loan.glucose."
    static let glucoseCategory = "trio.loan.glucose"

    private let notifier: WatchLoanNotifier

    init(notifier: WatchLoanNotifier) {
        self.notifier = notifier
    }

    /// An insulin amount with its localized unit, as LoopKit formats it.
    static func insulin(_ units: Decimal) -> String {
        let quantity = LoopQuantity(unit: .internationalUnit, doubleValue: units.nearestDouble)
        return QuantityFormatter(for: .internationalUnit).string(from: quantity) ?? units.description
    }

    // MARK: - Not looping

    static var notLoopingIDs: [String] { WatchLoopPolicy.notLoopingMinutes.map { notLoopingPrefix + String($0) } }

    /// Replaces the series: 20 to 120 minutes after `anchor`. Steps already due collapse into one at once.
    func armNotLooping(after anchor: Date, now: Date) {
        notifier.cancel(ids: Self.notLoopingIDs)
        let steps = Array(zip(WatchLoopPolicy.notLoopingMinutes, WatchLoopPolicy.notLoopingDates(after: anchor)))
        if let overdue = steps.last(where: { $0.1 <= now }) {
            post(notLooping: overdue.0, at: nil)
        }
        for (minutes, date) in steps where date > now {
            post(notLooping: minutes, at: date)
        }
        WatchLogger.shared.info(.loop, "Not-looping alerts set from \(anchor.formatted(date: .omitted, time: .shortened))")
    }

    func disarmNotLooping() {
        notifier.cancel(ids: Self.notLoopingIDs)
        WatchLogger.shared.info(.loop, "Not-looping alerts removed")
    }

    private func post(notLooping minutes: Int, at date: Date?) {
        notifier.post(
            id: Self.notLoopingPrefix + String(minutes),
            title: String(localized: "Trio on Watch isn't looping", comment: "Watch alert title when no loop ran for a while"),
            body: String(
                localized: "No loop for \(minutes) minutes. Open Trio on your watch. The pump finishes any running temp basal, then follows its basal schedule.",
                comment: "Watch alert body; the number is minutes since the last loop"
            ),
            at: date,
            timeSensitive: true,
            category: nil
        )
    }

    // MARK: - Loan

    func post(_ alert: LoanAlert) {
        let title: String
        var body = ""
        switch alert {
        case .phoneDidNotAnswer:
            title = String(localized: "iPhone didn't answer", comment: "Watch alert when the phone didn't answer a start request")
            body = String(
                localized: "Trio on Watch didn't start. Your iPhone still controls your pump.",
                comment: "Watch alert body"
            )
        case let .startRefused(reason):
            title = String(localized: "Trio on Watch didn't start", comment: "Watch alert title when a start was refused")
            body = Self.text(for: reason)
        case let .endRefused(reason):
            title = String(localized: "Can't hand back yet", comment: "Watch alert title when End was refused")
            body = Self.text(for: reason)
        case let .stopped(reason):
            title = String(
                localized: "Trio on Watch stopped",
                comment: "Watch alert title when the watch stopped controlling the pump"
            )
            body = Self.text(for: reason)
        case .podUnreachable:
            title = String(localized: "Pod not found", comment: "Watch alert title when the watch can't reach the pod")
            body = String(
                localized: "Keep your watch close to the pod. Trio keeps trying.",
                comment: "Watch alert body when the pod can't be reached"
            )
        case .loanStateUnreadable,
             .podTakenOnThisPhone,
             .podTotalUnreliable,
             .startDidNotFinish,
             .takeBackPodUnreachable,
             .takeBackUseEnd,
             .unexpectedPodSession,
             .watchContactedPodAfterTakeBack,
             .watchDidNotConfirm,
             .watchStopped:
            return
        }
        notifier.post(
            id: "trio.loan.alert." + UUID().uuidString,
            title: title,
            body: body,
            at: nil,
            timeSensitive: true,
            category: nil
        )
    }

    static func text(for reason: WatchStopReason) -> String {
        switch reason {
        case .superseded:
            return String(
                localized: "Your iPhone took the pump back. It controls your pump again.",
                comment: "Watch stop reason: the phone took the pump back"
            )
        case .foreignSession:
            return String(
                localized: "Another device used your pod. This watch sends no more pump commands. Check Trio on your iPhone.",
                comment: "Watch stop reason: another device used the pod"
            )
        case .resumeWindowPassed:
            return String(
                localized: "Trio on Watch was off for too long. Take the pump back on your iPhone.",
                comment: "Watch stop reason: too long since the last loop"
            )
        case .unconfirmed:
            return String(
                localized: "Your iPhone didn't confirm the hand-over. Take the pump back on your iPhone.",
                comment: "Watch stop reason: the phone didn't confirm after a relaunch"
            )
        }
    }

    static func text(for refusal: LoanRefusal) -> String {
        switch refusal {
        case .phoneUnreachable:
            return String(localized: "Your iPhone isn't reachable. Keep it close and try again.", comment: "Watch refusal reason")
        case .watchBatteryLow:
            return String(localized: "Charge your watch to at least 30 % first.", comment: "Watch refusal reason")
        case .notificationsOff:
            return String(
                localized: "Allow notifications and time-sensitive notifications for Trio on your watch first.",
                comment: "Watch refusal reason"
            )
        case .unsupportedWatch:
            return String(
                localized: "Trio on Watch needs Apple Watch Series 6 or later, or SE (2nd generation) or later.",
                comment: "Watch refusal reason"
            )
        case .bolusRunning:
            return String(localized: "Wait until the bolus is finished.", comment: "Watch refusal reason")
        case .deliveryUncertain,
             .unconfirmedCommand:
            return String(
                localized: "The pump hasn't confirmed the last command. Wait for it, then try again.",
                comment: "Watch refusal reason"
            )
        case .releaseRefused:
            return String(
                localized: "The pump hasn't confirmed the last command, so this watch keeps it for now.",
                comment: "Watch refusal reason"
            )
        default:
            return String(
                localized: "Check Trio on your iPhone (\(refusal.rawValue)).",
                comment: "Watch refusal reason; the value is a technical reason code"
            )
        }
    }

    // MARK: - Glucose

    func apply(_ actions: [GlucoseAlarmEvaluation.Action], units: GlucoseUnits) {
        for action in actions {
            switch action {
            case let .fire(alarm, value):
                let shown = units == .mmolL ? value.asMmolL.description : value.description
                notifier.post(
                    id: Self.glucosePrefix + alarm.id.uuidString,
                    title: alarm.name,
                    body: alarm.type == .carbsRequired
                        ? String(localized: "\(value.description) g of carbs needed", comment: "Watch carbs required alarm body")
                        : String(localized: "Glucose \(shown) \(units.rawValue)", comment: "Watch glucose alarm body"),
                    at: nil,
                    timeSensitive: true,
                    category: Self.glucoseCategory
                )
                WatchLogger.shared.info(.loop, "Glucose alarm fired: \(alarm.type.rawValue)")
            case let .retract(alarm):
                notifier.cancel(ids: [Self.glucosePrefix + alarm.id.uuidString])
                WatchLogger.shared.info(.loop, "Glucose alarm retracted: \(alarm.type.rawValue)")
            }
        }
    }

    // MARK: - Notices

    func postBluetoothBudget() {
        notifier.post(
            id: "trio.loan.bluetoothBudget",
            title: String(
                localized: "Open Trio on your watch to keep it looping",
                comment: "Watch alert title near the Bluetooth limit"
            ),
            body: String(
                localized: "watchOS is limiting background Bluetooth for Trio. Until you open it, loops may be missed.",
                comment: "Watch alert body near the Bluetooth limit"
            ),
            at: nil,
            timeSensitive: true,
            category: nil
        )
        WatchLogger.shared.warning(.loop, "Bluetooth background limit near or reached")
    }

    static func isBluetoothBudgetError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == CBErrorDomain,
               error.code == CBError.leGattNearBackgroundNotificationLimit.rawValue
               || error.code == CBError.leGattExceededBackgroundNotificationLimit.rawValue
            {
                return true
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// 1 below 20 %, 2 below 10 %. Returns the level now in effect.
    func postBattery(level: Float, previousNotice: Int) -> Int {
        let notice = level < WatchLoopPolicy.batteryCriticalLevel ? 2 : level < WatchLoopPolicy.batteryWarningLevel ? 1 : 0
        guard notice > previousNotice else { return notice }
        let critical = notice == 2
        notifier.post(
            id: "trio.loan.battery",
            title: critical
                ? String(localized: "Trio on Watch will stop soon", comment: "Watch alert title at critical battery")
                : String(localized: "Watch battery low", comment: "Watch alert title at low battery"),
            body: String(
                localized: "End Trio on Watch, or take the pump back on your iPhone, before the watch runs out of charge.",
                comment: "Watch alert body at low battery"
            ),
            at: nil,
            timeSensitive: critical,
            category: nil
        )
        WatchLogger.shared.warning(.lifecycle, "Battery below \(critical ? 10 : 20) %")
        return notice
    }

    func postPodUnreachable(phoneReachable: Bool) {
        notifier.post(
            id: "trio.loan.podLink",
            title: String(localized: "Can't reach your pod", comment: "Watch alert title when the pod didn't answer for a while"),
            body: phoneReachable
                ? String(
                    localized: "Open Trio on your watch, or End to let your iPhone loop.",
                    comment: "Watch alert body when the pod didn't answer and the phone is near"
                )
                : String(localized: "Open Trio on your watch.", comment: "Watch alert body when the pod didn't answer"),
            at: nil,
            timeSensitive: true,
            category: nil
        )
        WatchLogger.shared.warning(.loop, "No pod contact for two cycles; user told")
    }

    func postNotSaved() {
        notifier.post(
            id: "trio.loan.notSaved",
            title: String(localized: "Trio on Watch can't save", comment: "Watch alert title when a file can't be written"),
            body: String(
                localized: "No pump commands are sent until it can. Check your watch's storage, or take the pump back on your iPhone.",
                comment: "Watch alert body when a file can't be written"
            ),
            at: nil,
            timeSensitive: true,
            category: nil
        )
    }

    func postBookedIntent() {
        notifier.post(
            id: "trio.loan.bookedIntent",
            title: String(
                localized: "Pump command unconfirmed",
                comment: "Watch alert title when a dose was booked as delivered"
            ),
            body: String(
                localized: "The pump never confirmed the last dose, so Trio counts it as given. Insulin on board may be shown too high.",
                comment: "Watch alert body when a dose was booked as delivered"
            ),
            at: nil,
            timeSensitive: true,
            category: nil
        )
    }

    func postKitAlert(_ alert: Alert) {
        notifier.post(
            id: "trio.loan.kit." + alert.identifier.value,
            title: alert.backgroundContent.title,
            body: alert.backgroundContent.body,
            at: nil,
            timeSensitive: true,
            category: nil
        )
        WatchLogger.shared.info(.loop, "Device alert shown: \(alert.identifier.alertIdentifier)")
    }

    func retractKitAlert(_ identifier: Alert.Identifier) {
        notifier.cancel(ids: ["trio.loan.kit." + identifier.value])
    }
}
