import Foundation

/// Fixed rules of the watch loop. Constants, never settings.
enum WatchLoopPolicy {
    /// The phone's copy starts the watch on a tap while younger than this.
    static let copyMaxAgeForButton: TimeInterval = 15 * 60
    /// The Fallback Loop waits for 10 min of the phone's silence, so its copy may be older (5/5's limit); the pod
    /// total check books what the copy's records miss.
    static let copyMaxAgeForFallback: TimeInterval = 60 * 60
    /// SMB from a background wake too: the watch confirmed SMB commands in about 1.3 s, temps in under 11 s.
    static let allowsMicroBolusInBackground = true

    static func microBolusAllowed(inForeground: Bool) -> Bool {
        inForeground || allowsMicroBolusInBackground
    }

    /// Minutes after the last cycle that confirmed the pump's state: the phone's 20 to 120, then hourly to the 6-hour
    /// resume horizon, since the watch has no critical alert to end on.
    static let notLoopingMinutes = [20, 40, 60, 80, 100, 120, 180, 240, 300, 360]
    /// A cycle confirms the pump's state only with a status at most this old; the kit refreshes older ones.
    static let pumpStatusMaxAge: TimeInterval = 6 * 60
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

    /// What the pod delivers now, as far as the dedup needs it.
    enum RunningBasal: Equatable {
        case scheduled
        case temp(unitsPerHour: Decimal, endsAt: Date)
    }

    /// Loop's `adjustForCurrentDelivery`: a temp the pod already runs at this rate with more than this left is not
    /// sent again. oref renews a 30-minute temp after 10 minutes; each pod command counts toward watchOS's background
    /// Bluetooth limit.
    static let continuationInterval: TimeInterval = 11 * 60

    /// True when sending `temp` would change nothing: the pod runs that rate with time to spare, or the scheduled
    /// basal runs and `temp` asks for it (a neutral temp) or for a cancel. Rates are compared as the pump rounds them.
    static func isRedundant(
        _ temp: TempCommand,
        running: RunningBasal,
        scheduledBasal: Decimal,
        now: Date,
        round: (Decimal) -> Decimal
    ) -> Bool {
        switch running {
        case .scheduled:
            return temp.minutes == 0 || round(temp.unitsPerHour) == round(scheduledBasal)
        case let .temp(unitsPerHour, endsAt):
            return temp.minutes > 0 && round(temp.unitsPerHour) == round(unitsPerHour)
                && endsAt.timeIntervalSince(now) > continuationInterval
        }
    }
}

/// When the watch starts Trio on Watch by itself (Fallback Loop, from feat/watch-loop-5/5): the phone has stopped
/// looping, and the watch's own sensor readings show the body is with the watch. Noisy readings and a sensor with a
/// problem never start it.
enum WatchLoanFallback {
    struct Inputs {
        /// The watch's own readings that arrived live (not backfill) with a valid glucose, any order.
        var ownReadings: [Date]
        var phoneNewestReading: Date?
        var phoneLastLoop: Date?
        /// The phone answered the watch's last question.
        var phoneAnswered: Bool
        var sensorProblemNow: Bool
        var lastSensorProblemAt: Date?
        var copyUsable: Bool
        var now: Date
    }

    static let phoneSilence: TimeInterval = 10 * 60
    static let readingWindow: TimeInterval = 12 * 60
    static let sensorCalm: TimeInterval = 15 * 60

    static func shouldStart(_ i: Inputs) -> Bool {
        guard !i.phoneAnswered, i.copyUsable, !i.sensorProblemNow else { return false }
        if let problem = i.lastSensorProblemAt, i.now.timeIntervalSince(problem) < sensorCalm { return false }
        let phoneReading = i.phoneNewestReading ?? .distantPast
        guard i.now.timeIntervalSince(phoneReading) > phoneSilence,
              i.now.timeIntervalSince(i.phoneLastLoop ?? .distantPast) > phoneSilence
        else { return false }
        // two consecutive readings of the sensor's own 5-minute cadence, recent, and ones the phone doesn't have
        let readings = i.ownReadings
            .filter { $0 > phoneReading && i.now.timeIntervalSince($0) <= readingWindow }
            .sorted()
        return zip(readings, readings.dropFirst()).contains { earlier, later in
            (3.5 * 60 ... 6.5 * 60).contains(later.timeIntervalSince(earlier))
        }
    }

    /// A loan the fallback started goes back once the phone answers again with fresh readings of its own.
    static func shouldHandBack(phoneReachable: Bool, phoneNewestReading: Date?, now: Date) -> Bool {
        guard phoneReachable, let phoneNewestReading else { return false }
        return now.timeIntervalSince(phoneNewestReading) < phoneSilence
    }
}
