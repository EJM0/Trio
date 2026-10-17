import Foundation

/// Checks the pump's own delivered total against the history after it comes back from the watch.
/// The pump knows how much it delivered, not when, so the difference can only be booked as "now".
enum UntetheredAudit {
    /// Below this the records explain the pump: pulse rounding and per-minute basal steps.
    static let tolerance: Decimal = 0.2

    enum Verdict: Equatable {
        case explained
        /// The pump delivered this much that no record explains.
        case unrecorded(Decimal)
        /// The records claim this much more than the pump delivered.
        case overstated(Decimal)
    }

    static func verdict(delivered: Decimal, expected: Decimal) -> Verdict {
        let unexplained = delivered - expected
        if unexplained > tolerance { return .unrecorded(unexplained) }
        if unexplained < -tolerance { return .overstated(-unexplained) }
        return .explained
    }

    /// What `history` says the pump delivered between `start` and `end`: boluses, plus basal minute by
    /// minute from temp basals, suspensions and otherwise the scheduled profile.
    static func expectedDelivery(
        from start: Date,
        to end: Date,
        history: [PumpHistoryEvent],
        basalProfile: [BasalProfileEntry],
        calendar: Calendar = .current
    ) -> Decimal {
        let events = history.sorted { $0.timestamp < $1.timestamp }

        let boluses = events
            .filter { [.bolus, .smb].contains($0.type) && $0.timestamp >= start && $0.timestamp < end }
            .reduce(Decimal(0)) { $0 + ($1.deliveredUnits ?? $1.amount ?? 0) }

        let durations = Dictionary(
            events.filter { $0.type == .tempBasalDuration }.map { ($0.timestamp, $0.durationMin ?? 0) },
            uniquingKeysWith: { $1 }
        )
        let temps = events.filter { $0.type == .tempBasal }.map { event in
            (
                start: event.timestamp,
                end: event.timestamp.addingTimeInterval(Double(durations[event.timestamp] ?? 0) * 60),
                rate: event.rate ?? 0
            )
        }
        let suspensions = events.filter { $0.type == .pumpSuspend || $0.type == .pumpResume }
        let profile = basalProfile.sorted { $0.minutes < $1.minutes }

        var basal: Decimal = 0
        var time = start
        while time < end {
            let step = min(60, end.timeIntervalSince(time))
            let rate: Decimal
            if suspensions.last(where: { $0.timestamp <= time })?.type == .pumpSuspend {
                rate = 0
            } else if let temp = temps.last(where: { $0.start <= time }), time < temp.end {
                rate = temp.rate
            } else {
                let minute = calendar.component(.hour, from: time) * 60 + calendar.component(.minute, from: time)
                rate = profile.last(where: { $0.minutes <= minute })?.rate ?? profile.first?.rate ?? 0
            }
            basal += rate * Decimal(step) / 3600
            time = time.addingTimeInterval(step)
        }
        return boluses + basal
    }
}

/// The pump's delivered total at a session's start and at its return. Kept until the watch's last records are in,
/// so the complete history judges the same span again.
struct UntetheredAuditPoint: Codable, Equatable {
    let epoch: Int
    let start: Date
    let startUnits: Double
    let end: Date
    let endUnits: Double
    /// The banner this audit raised, replaced only while it is still the one showing.
    var message: String?

    var delivered: Decimal { Decimal(endUnits - startUnits) }
}
