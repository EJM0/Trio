import Foundation

/// Checks the pump's delivered total against the doses Trio has booked, so insulin nobody recorded still counts.
enum WatchLoanAudit {
    struct Input {
        /// Start of the window and the delivered total then (0 at pod activation).
        var start: Date
        var startUnits: Double
        /// The latest reading of the delivered total.
        var end: Date
        var endUnits: Double
        /// What a bolus under way at `end` has still to deliver. It will be delivered, so it counts as delivered.
        var bolusRemainder: Double
        var basalProfile: [BasalProfileEntry]
        /// The pump's schedule zone.
        var timeZone: TimeZone
        var pulse: Double
        /// Booked events from before `start` (to see a running temp or suspend) through `end`, any order.
        /// Scheduled-basal rows are ignored: scheduled basal comes from the profile. External insulin (pen, syringe)
        /// never came from the pump; other audits' tagged boluses did.
        var events: [PumpHistoryEvent]
        /// The tagged bolus this audit replaces, so it doesn't explain itself.
        var ownBolusID: String
    }

    struct Result: Equatable {
        var expected: Double
        var actual: Double
        /// What to book as the tagged audit bolus: the whole excess in whole pulses once past the tolerance, else 0.
        var unexplained: Double
        /// More booked than delivered, beyond tolerance.
        var isShortfall: Bool
    }

    static let auditBolusIDPrefix = "trio-watch-loan-audit-"

    static func tolerance(pulse: Double) -> Double { pulse + 0.15 }

    static func evaluate(_ input: Input) -> Result {
        let actual = input.endUnits + input.bolusRemainder - input.startUnits
        let expected = expectedDelivery(input)
        let excess = actual - expected
        let band = tolerance(pulse: input.pulse)
        let unexplained = excess > band ? floorToPulse(excess, pulse: input.pulse) : 0
        return Result(expected: expected, actual: actual, unexplained: unexplained, isShortfall: excess < -band)
    }

    /// Boluses at their booked amount, temps in whole pulses (replacing the schedule during their span),
    /// scheduled basal from the profile elsewhere, nothing while suspended.
    static func expectedDelivery(_ input: Input) -> Double {
        let window = DateInterval(start: input.start, end: max(input.start, input.end))
        let events = input.events
            .filter { $0.id != input.ownBolusID && !($0.isScheduledBasal ?? false) }
            .sorted { $0.timestamp < $1.timestamp }

        let boluses = events
            .filter { $0.type == .bolus && window.contains($0.timestamp) && $0.timestamp < window.end }
            .filter { $0.isExternal != true || $0.id.hasPrefix(auditBolusIDPrefix) }
            .reduce(0.0) { $0 + ($1.amount.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0) }

        let suspensions = suspendedSpans(events, window: window)
        let temps = tempSpans(events, window: window)

        var tempUnits = 0.0
        for temp in temps {
            let delivering = subtract(suspensions, from: temp.span)
            let hours = delivering.reduce(0) { $0 + $1.duration } / 3600
            tempUnits += floorToPulse(temp.rate * hours, pulse: input.pulse)
        }

        let uncovered = subtract(suspensions + temps.map(\.span), from: window)
        let scheduled = uncovered.reduce(0.0) {
            $0 + scheduledUnits($1, profile: input.basalProfile, timeZone: input.timeZone)
        }
        return boluses + tempUnits + scheduled
    }

    // MARK: - Spans

    private static func suspendedSpans(_ events: [PumpHistoryEvent], window: DateInterval) -> [DateInterval] {
        var spans: [DateInterval] = []
        var suspendedSince: Date?
        for event in events {
            switch event.type {
            case .pumpSuspend:
                if suspendedSince == nil { suspendedSince = event.timestamp }
            case .pumpResume:
                if let since = suspendedSince, event.timestamp > since {
                    spans.append(DateInterval(start: since, end: event.timestamp))
                }
                suspendedSince = nil
            default:
                break
            }
        }
        if let since = suspendedSince, since < window.end { spans.append(DateInterval(start: since, end: window.end)) }
        return spans.compactMap { $0.intersection(with: window) }.filter { $0.duration > 0 }
    }

    /// A temp runs for its duration, or until the next temp starts.
    private static func tempSpans(
        _ events: [PumpHistoryEvent],
        window: DateInterval
    ) -> [(span: DateInterval, rate: Double)] {
        let temps = events.filter { $0.type == .tempBasal }
        return temps.enumerated().compactMap { index, temp in
            let programmedEnd = temp.timestamp.addingTimeInterval(TimeInterval((temp.duration ?? 0) * 60))
            let nextStart = temps.dropFirst(index + 1).first?.timestamp ?? .distantFuture
            let end = min(programmedEnd, nextStart)
            guard end > temp.timestamp,
                  let span = DateInterval(start: temp.timestamp, end: end).intersection(with: window),
                  span.duration > 0
            else { return nil }
            return (span, temp.amount.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0)
        }
    }

    /// The parts of `interval` that no span in `spans` covers.
    private static func subtract(_ spans: [DateInterval], from interval: DateInterval) -> [DateInterval] {
        var remaining = [interval]
        for span in spans {
            remaining = remaining.flatMap { piece -> [DateInterval] in
                guard let overlap = piece.intersection(with: span), overlap.duration > 0 else { return [piece] }
                var parts: [DateInterval] = []
                if overlap.start > piece.start { parts.append(DateInterval(start: piece.start, end: overlap.start)) }
                if overlap.end < piece.end { parts.append(DateInterval(start: overlap.end, end: piece.end)) }
                return parts
            }
        }
        return remaining
    }

    // MARK: - Scheduled basal

    /// The profile's rate over `interval`, split at every schedule change and midnight in `timeZone`.
    static func scheduledUnits(_ interval: DateInterval, profile: [BasalProfileEntry], timeZone: TimeZone) -> Double {
        guard !profile.isEmpty else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let entries = profile.sorted { $0.minutes < $1.minutes }

        var units = 0.0
        var cursor = interval.start
        while cursor < interval.end {
            let midnight = calendar.startOfDay(for: cursor)
            let minutes = cursor.timeIntervalSince(midnight) / 60
            let current = entries.last { Double($0.minutes) <= minutes } ?? entries[0]
            let nextChange = entries.first { Double($0.minutes) > minutes }
                .map { midnight.addingTimeInterval(TimeInterval($0.minutes * 60)) }
                ?? calendar.date(byAdding: .day, value: 1, to: midnight)!
            let segmentEnd = min(nextChange, interval.end)
            units += NSDecimalNumber(decimal: current.rate).doubleValue * segmentEnd.timeIntervalSince(cursor) / 3600
            cursor = segmentEnd
        }
        return units
    }

    private static func floorToPulse(_ units: Double, pulse: Double) -> Double {
        guard pulse > 0 else { return units }
        // a hair of slack so 0.15000000001 / 0.05 doesn't floor a whole pulse away
        return (units / pulse + 1E-9).rounded(.down) * pulse
    }
}
