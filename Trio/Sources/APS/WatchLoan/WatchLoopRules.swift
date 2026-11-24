import Foundation

/// Fixed rules of the watch loop. Constants, never settings.
enum WatchLoopPolicy {
    /// Background wakes may give SMBs too: pump commands fit well inside the wake's time window.
    static let allowsMicroBolusInBackground = true

    static func microBolusAllowed(inForeground: Bool) -> Bool {
        inForeground || allowsMicroBolusInBackground
    }

    /// Minutes after the last cycle that confirmed the pump's state: the phone's 20 to 120, then hourly to the 6-hour
    /// resume horizon, since the watch has no critical alert to end on.
    static let notLoopingMinutes = [20, 40, 60, 80, 100, 120, 180, 240, 300, 360]
    /// A cycle confirms the pump's state only with a status at most this old; the kit refreshes older ones.
    static let pumpStatusMaxAge: TimeInterval = 6 * 60
    static let quietWakeStatusAge: TimeInterval = 2 * 60
    static let batteryWarningLevel: Float = 0.2
    static let batteryCriticalLevel: Float = 0.1
    /// Readings closer than this to the previous one are dropped, as the phone's glucose store does.
    static let glucoseFilterTime: TimeInterval = 3.5 * 60
    static let recordsRetention: TimeInterval = 48 * 60 * 60
    /// Without a confirmed cycle this long, and two cycles in a row without the pod, the user is told.
    static let podLinkNoticeDelay: TimeInterval = 5 * 60

    /// Background Bluetooth alerts need a Series 6 or later or an SE (2nd generation): `Watch6,x` and up.
    /// Older models (Series 4/5, SE 1st generation: `Watch5,x`) would accept a loan and never wake.
    static func isSupportedWatch(modelIdentifier: String) -> Bool {
        guard modelIdentifier.hasPrefix("Watch"),
              let major = Int(modelIdentifier.dropFirst(5).prefix { $0 != "," })
        else { return false }
        return major >= 6
    }

    static func notLoopingDates(after lastConfirmedCycle: Date) -> [Date] {
        notLoopingMinutes.map { lastConfirmedCycle.addingTimeInterval(TimeInterval($0 * 60)) }
    }
}

/// A pump command the watch wrote down before sending it. One at a time; cleared when its outcome is known.
struct WatchDoseIntent: Codable, Equatable {
    enum Kind: Codable, Equatable {
        case tempBasal(unitsPerHour: Decimal, minutes: Int)
        case bolus(units: Decimal, automatic: Bool)
        case suspend
        case resume
    }

    var id: UUID
    var kind: Kind
    var createdAt: Date
    var epoch: Int64
    /// More insulin than the scheduled basal would give: a bolus, or a temp above the scheduled rate.
    var addsInsulin: Bool
    /// The pump's delivered total before the command, when known.
    var deliveredBefore: Double?

    enum Resolution: Equatable {
        /// The kit settled it: its own events or status carry what happened.
        case settledByKit
        /// The odometer shows nothing was delivered at all since the command.
        case notDelivered
        /// Unknown: book it as delivered, so insulin on board errs high, and tell the user.
        case bookAsDelivered
    }

    /// Nil while the kit still reports delivery as uncertain: the command may yet be confirmed.
    func resolve(
        kitUncertain: Bool,
        kitBookedIt: Bool,
        deliveredNow: Double?,
        pulseUnits: Double
    ) -> Resolution? {
        guard !kitUncertain else { return nil }
        if kitBookedIt { return .settledByKit }
        switch kind {
        case .bolus:
            if let deliveredBefore, let deliveredNow, deliveredNow - deliveredBefore < pulseUnits {
                return .notDelivered
            }
            return .bookAsDelivered
        case .tempBasal:
            // a lost reduction counted as not given leaves the scheduled basal booked, which errs high too
            return addsInsulin ? .bookAsDelivered : .notDelivered
        case .resume,
             .suspend:
            // the pump's status says whether it is suspended
            return .settledByKit
        }
    }
}

/// What one cycle may enact from oref's determination. While delivery is uncertain or an intent is unresolved,
/// commands that add insulin wait; reductions don't. Nothing while the pump is suspended. A command is sent as
/// oref made it or not at all. Oref runs without micro boluses then, so no low temp paired with an SMB is left alone.
enum WatchDosingGate {
    struct TempCommand: Equatable {
        var unitsPerHour: Decimal
        var minutes: Int
    }

    struct Plan: Equatable {
        var tempBasal: TempCommand?
        var bolus: Decimal?
        var heldBack: [HeldBack] = []
    }

    enum HeldBack: Equatable {
        case automationOff
        case pumpSuspended
        case tempAddsInsulin
        case bolus
    }

    static func plan(
        automation: AutomationLevel,
        rate: Decimal?,
        durationMinutes: Decimal?,
        units: Decimal?,
        scheduledBasal: Decimal,
        suspended: Bool,
        deliveryUncertain: Bool
    ) -> Plan {
        var plan = Plan()
        guard automation != .off else {
            plan.heldBack = [.automationOff]
            return plan
        }
        guard !suspended else {
            plan.heldBack = [.pumpSuspended]
            return plan
        }
        if let rate, let durationMinutes {
            let minutes = Int(truncating: durationMinutes as NSNumber)
            if deliveryUncertain, rate > scheduledBasal {
                plan.heldBack.append(.tempAddsInsulin)
            } else {
                plan.tempBasal = TempCommand(unitsPerHour: rate, minutes: minutes)
            }
        }
        if let units, units > 0 {
            if deliveryUncertain {
                plan.heldBack.append(.bolus)
            } else {
                plan.bolus = units
            }
        }
        return plan
    }
}
