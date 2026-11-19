import Foundation

/// Insulin totals behind a TDD row, from pump history alone.
extension OrefInputs {
    /// Bolus, temp basal and inferred scheduled basal insulin in `pumpHistory`.
    static func tddInsulin(
        pumpHistory: [PumpHistoryEvent],
        basalProfile: [BasalProfileEntry],
        now: Date,
        timeZone: TimeZone,
        roundToSupportedBasalRate: @escaping (_ unitsPerHour: Double) -> Double
    ) -> (bolus: Decimal, tempBasal: Decimal, scheduledBasal: Decimal) {
        // Group events by type once to avoid multiple filters
        let groupedEvents = Dictionary(grouping: pumpHistory, by: { $0.type })
        let bolusEvents = groupedEvents[.bolus] ?? []
        let allBasalEvents = groupedEvents[.tempBasal] ?? []
        let tempBasalEvents = allBasalEvents.filter { $0.isScheduledBasal != true }
        let pumpSuspendEvents = groupedEvents[.pumpSuspend] ?? []
        let pumpResumeEvents = groupedEvents[.pumpResume] ?? []

        // Spans nothing else covers ran the pump's schedule, at the profile rate. The sweep owns
        // *when*, so a span can never overlap a temp basal or a suspension; the profile owns the
        // rate, because it is what Trio programmed into the pump.
        let scheduledBasalSegments = ScheduledBasalInference.segments(
            events: timelineEvents(from: pumpHistory),
            profile: basalProfile,
            now: now,
            timeZone: timeZone
        )

        let suspensions = suspensionSpans(
            suspends: pumpSuspendEvents,
            resumes: pumpResumeEvents,
            now: now
        )

        let bolus = bolusEvents.reduce(Decimal(0)) { total, event in total + (event.amount as Decimal? ?? 0) }
        let scheduledBasal = calculateScheduledBasalInsulin(
            scheduledBasalSegments,
            roundToSupportedBasalRate: roundToSupportedBasalRate
        )
        let tempBasal = calculateTempBasalInsulin(
            tempBasalEvents,
            suspensions: suspensions,
            now: now,
            roundToSupportedBasalRate: roundToSupportedBasalRate
        )

        return (bolus, tempBasal, scheduledBasal)
    }

    /// Pairs each suspend with the resume that ends it, chronologically. Counts are
    /// routinely unbalanced — the pump may still be suspended, or the window may open
    /// mid-suspension — so positional pairing silently drops real spans.
    /// - Returns: suspension spans, an open suspension ending at `now`
    static func suspensionSpans(
        suspends: [PumpHistoryEvent],
        resumes: [PumpHistoryEvent],
        now: Date
    ) -> [(start: Date, end: Date)] {
        let suspendTimes = suspends.map(\.timestamp).sorted()
        let resumeTimes = resumes.map(\.timestamp).sorted()

        var spans: [(start: Date, end: Date)] = []
        var nextResume = resumeTimes.startIndex

        for suspend in suspendTimes {
            // spans never nest: skip resumes that belong to an earlier suspension
            while nextResume < resumeTimes.endIndex, resumeTimes[nextResume] <= suspend {
                nextResume += 1
            }
            guard nextResume < resumeTimes.endIndex else {
                // no resume follows: the pump is still suspended
                if suspend < now { spans.append((start: suspend, end: now)) }
                break
            }
            spans.append((start: suspend, end: resumeTimes[nextResume]))
            nextResume += 1
        }
        return spans
    }

    /// Calculates temporary basal insulin delivery for a given time period, accounting for interruptions and suspensions
    /// - Parameters:
    ///   - tempBasalEvents: Array of temporary basal events
    ///   - suspensions: Suspension spans from `suspensionSpans(suspends:resumes:now:)`
    ///   - roundToSupportedBasalRate: Closure to round rates to pump-supported values
    /// - Returns: Total insulin delivered via temporary basal rates in units
    static func calculateTempBasalInsulin(
        _ tempBasalEvents: [PumpHistoryEvent],
        suspensions: [(start: Date, end: Date)],
        now: Date,
        roundToSupportedBasalRate: @escaping (_ unitsPerHour: Double) -> Double
    ) -> Decimal {
        guard !tempBasalEvents.isEmpty else { return 0 }

        // Finalized rows carry the pump-reported total (suspends and pulse
        // quantization included); timeline math covers only the rest.
        let reportedInsulin = tempBasalEvents.compactMap(\.deliveredUnits).reduce(0, +)
        let inferredEvents = tempBasalEvents.filter { $0.deliveredUnits == nil }
        guard !inferredEvents.isEmpty else { return reportedInsulin }

        var timeline = [(start: Date, end: Date, rate: Decimal)]()
        for event in inferredEvents {
            guard let duration = event.duration, let rate = event.amount else { continue }
            let end = event.timestamp.addingTimeInterval(TimeInterval(duration * 60))
            timeline.append((start: event.timestamp, end: end, rate: rate))
        }
        timeline.sort { $0.start < $1.start }

        var totalInsulin: Decimal = 0

        for (index, event) in timeline.enumerated() {
            let start = event.start
            // clamp to now for running temps, and to the temp that superseded this one
            var end = min(event.end, now)
            if index < timeline.count - 1 {
                end = min(end, timeline[index + 1].start)
            }
            guard end > start else { continue }

            // a suspension anywhere inside the window delivers nothing
            let suspendedSeconds = suspensions.reduce(0.0) { total, suspension in
                let overlapStart = max(start, suspension.start)
                let overlapEnd = min(end, suspension.end)
                return total + max(0, overlapEnd.timeIntervalSince(overlapStart))
            }

            let deliveredMinutes = max(0, (end.timeIntervalSince(start) - suspendedSeconds) / 60)
            guard deliveredMinutes > 0 else { continue }

            let durationHours = (Decimal(deliveredMinutes) / 60).truncated(toPlaces: 5)
            let insulin = Decimal(roundToSupportedBasalRate(Double(event.rate * durationHours)))
            if insulin > 0 { totalInsulin += insulin }
        }

        return reportedInsulin + totalInsulin
    }

    /// Sums the scheduled-basal segments the sweep resolved.
    static func calculateScheduledBasalInsulin(
        _ segments: [ScheduledBasalInference.Segment],
        roundToSupportedBasalRate: @escaping (_ unitsPerHour: Double) -> Double
    ) -> Decimal {
        segments.reduce(into: Decimal(0)) { totalInsulin, segment in
            let durationHours = Decimal(segment.end.timeIntervalSince(segment.start) / 3600)
            let insulin = Decimal(roundToSupportedBasalRate(Double(truncating: (segment.rate * durationHours) as NSNumber)))
            if insulin > 0 { totalInsulin += insulin }
        }
    }

    /// Maps pump history onto the inference timeline (temp basal intervals, suspend/resume points).
    static func timelineEvents(from pumpHistory: [PumpHistoryEvent]) -> [ScheduledBasalInference.TimelineEvent] {
        pumpHistory.compactMap { event in
            switch event.type {
            case .tempBasal:
                // A scheduled-basal row asserts a rate, not a span: it covers nothing, so the
                // sweep still sizes the gap. Its placeholder duration would otherwise mark up to
                // 24 h covered and mute the very sweep that accounts for it. It stays in the
                // timeline as a zero-width point so it can still anchor the window's start.
                let minutes = event.isScheduledBasal == true ? 0 : (event.duration ?? 0)
                let end = event.timestamp.addingTimeInterval(TimeInterval(minutes) * 60)
                return ScheduledBasalInference.TimelineEvent(start: event.timestamp, end: end, kind: .tempBasal)
            case .pumpSuspend:
                return ScheduledBasalInference.TimelineEvent(start: event.timestamp, kind: .suspend)
            case .pumpResume:
                return ScheduledBasalInference.TimelineEvent(start: event.timestamp, kind: .resume)
            default:
                return nil
            }
        }
    }
}

/// Finds the basal rate at the specified minute offset using binary search
/// - Parameters:
///   - totalMinutes: minute offset into a 24 hour day
///   - profile: Array of basal profile entries sorted by time
/// - Returns: Basal rate in units per hour, or nil if not found
func findBasalRateForOffset(for totalMinutes: Int, in profile: [BasalProfileEntry]) -> Decimal? {
    if profile.isEmpty {
        return nil // not yet initalized
    }

    // Special case: If profile has only one entry, it applies for full 24 hours
    // Return its rate immediately without searching
    if profile.count == 1 {
        return profile[0].rate
    }

    // Use binary search to efficiently find the applicable basal rate
    // Profile entries are sorted by minutes, so we can divide and conquer
    var left = 0
    var right = profile.count - 1

    while left <= right {
        let mid = (left + right) / 2
        let entry = profile[mid]
        // Get end time for current entry - either next entry's start time or end of day (24 * 60 mins)
        let nextMinutes = mid + 1 < profile.count ? profile[mid + 1].minutes : 24 * 60

        // Check if target time falls within current entry's time range
        if totalMinutes >= entry.minutes, totalMinutes < nextMinutes {
            return entry.rate
        }

        // Adjust search range based on comparison
        if totalMinutes < entry.minutes {
            right = mid - 1 // Search in left half if target time is earlier
        } else {
            left = mid + 1 // Search in right half if target time is later
        }
    }

    // No applicable rate found for the given time
    return nil
}
