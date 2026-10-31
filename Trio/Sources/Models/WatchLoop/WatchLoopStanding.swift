import Foundation

/// Starting on the watch without the phone, from the copy of the grant the phone leaves with it (LoopKit/Loop#2545's
/// dormant grant), and the pump-total check that keeps two controllers from dosing beside each other.
enum WatchLoopStanding {
    /// The phone sends a new copy at least this often, and after a change of insulin, carbs or settings.
    static let refreshInterval: TimeInterval = 30 * 60

    /// A copy older than the insulin's action time can't account for what the pump delivered since.
    static func isUsable(_ copy: WatchLoopGrant, now: Date) -> Bool {
        let actionTime = Double(truncating: copy.pumpSettings.insulinActionCurve as NSNumber) * 3600
        return now.timeIntervalSince(copy.issuedAt) < actionTime
    }

    /// The doses a pump history accounts for, for the audit (`WatchLoopAudit.recordedInsulin`): a bolus is delivered
    /// over `bolusDuration` (the pump's `estimatedDuration(toBolus:)`), a temp basal ends at the next temp or suspend,
    /// a suspend at the next resume.
    static func doses(
        _ history: [PumpHistoryEvent],
        now: Date,
        bolusDuration: (Double) -> TimeInterval = { _ in 0 }
    ) -> [WatchLoopDose] {
        let events = history.sorted { $0.timestamp < $1.timestamp }
        return events.enumerated().compactMap { index, event in
            let later = events[(index + 1)...]
            switch event.type {
            case .bolus,
                 .smb:
                let units = event.amount ?? 0
                let duration = bolusDuration(Double(truncating: units as NSNumber))
                return dose(event, .bolus, value: units, end: event.timestamp.addingTimeInterval(duration))
            case .tempBasal:
                let programmed = event.timestamp.addingTimeInterval(Double(event.duration ?? 0) * 60)
                let next = later.first { $0.type == .tempBasal || $0.type == .pumpSuspend }?.timestamp
                return dose(event, .tempBasal, value: event.amount ?? event.rate ?? 0, end: min(programmed, next ?? programmed))
            case .pumpSuspend:
                let resume = later.first { $0.type == .pumpResume }?.timestamp ?? now
                return dose(event, .suspend, value: 0, end: resume)
            default:
                return nil
            }
        }
    }

    private static func dose(_ event: PumpHistoryEvent, _ kind: WatchLoopDose.Kind, value: Decimal, end: Date) -> WatchLoopDose {
        WatchLoopDose(
            kind: kind,
            syncIdentifier: event.id,
            startDate: event.timestamp,
            endDate: end,
            value: Double(truncating: value as NSNumber),
            deliveredUnits: nil,
            automatic: true,
            isMutable: false
        )
    }
}

/// When the watch starts the Watch Loop by itself: the phone has stopped looping, and the watch's own sensor
/// readings show the body is with the watch. Noisy readings and a sensor with a problem never start it.
enum WatchLoopFallback {
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
}
