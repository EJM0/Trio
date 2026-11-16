import Foundation

/// Value-level mapping from stored device data to oref inputs. Core Data adapters call these,
/// so any other store produces identical inputs.
extension OrefInputs {
    // MARK: - Pump history

    /// The pump history events one stored pump event yields. A temp basal yields a duration entry
    /// followed by a rate entry.
    static func pumpHistoryEvents(
        id: String?,
        timestamp: Date?,
        type: String?,
        bolus: (amount: Double?, isSMB: Bool, isExternal: Bool)?,
        tempBasal: (duration: Int, rate: Double?, tempType: String?)?
    ) -> [PumpHistoryEvent] {
        guard let timestamp else { return [] }
        var events: [PumpHistoryEvent] = []

        if let bolus, let amount = bolus.amount {
            events.append(PumpHistoryEvent(
                id: id ?? UUID().uuidString,
                type: .bolus,
                timestamp: timestamp,
                amount: Decimal(algorithmValue: amount),
                duration: 0,
                isSMB: bolus.isSMB,
                isExternal: bolus.isExternal
            ))
        }

        guard let id else { return events }

        if let tempBasal {
            // The temp basal duration populates `durationMin`, not `duration`.
            events
                .append(PumpHistoryEvent(id: id, type: .tempBasalDuration, timestamp: timestamp, durationMin: tempBasal.duration))
            // The rate entry id is prefixed with "_". An unrecognized `tempType` maps to nil.
            if let rate = tempBasal.rate {
                events.append(PumpHistoryEvent(
                    id: "_\(id)",
                    type: .tempBasal,
                    timestamp: timestamp,
                    rate: Decimal(algorithmValue: rate),
                    temp: tempBasal.tempType.flatMap { TempType(rawValue: $0) }
                ))
            }
        }

        switch type {
        case EventType.pumpSuspend.rawValue:
            events.append(PumpHistoryEvent(id: id, type: .pumpSuspend, timestamp: timestamp))
        case EventType.pumpResume.rawValue:
            events.append(PumpHistoryEvent(id: id, type: .pumpResume, timestamp: timestamp))
        case EventType.rewind.rawValue:
            events.append(PumpHistoryEvent(id: id, type: .rewind, timestamp: timestamp))
        case EventType.prime.rawValue:
            events.append(PumpHistoryEvent(id: id, type: .prime, timestamp: timestamp))
        default:
            break
        }

        return events
    }

    /// Resumes without a paired suspend in the 24 h before them, from 48 h of pump events, oldest first.
    ///
    /// Addresses https://github.com/nightscout/Trio/issues/898: on a cold start the oldest event can be
    /// a resume with no preceding pump activity. oref reads it as the end of a suspend that never started,
    /// which drives negative IOB and can cause excessive insulin delivery.
    static func orphanedResumes<Event>(
        in events: [Event],
        type: (Event) -> String?,
        timestamp: (Event) -> Date?
    ) -> [Event] {
        let suspendsAndResumes = events
            .filter { type($0) == EventType.pumpSuspend.rawValue || type($0) == EventType.pumpResume.rawValue }

        // 48 hours because the standard pump history is 24 hours, plus 24 hours of inspection for resumes
        let orphanedResumes = zip(suspendsAndResumes, suspendsAndResumes.dropFirst())
            .compactMap { prev, curr -> Event? in
                guard let prevTimestamp = timestamp(prev), let currTimestamp = timestamp(curr) else {
                    return nil
                }
                let interval = currTimestamp.timeIntervalSince(prevTimestamp)

                // previous event not a suspend, or a suspend more than 24 hours ago
                if type(curr) == EventType.pumpResume.rawValue,
                   type(prev) != EventType.pumpSuspend.rawValue || interval > TimeInterval(hours: 24)
                {
                    return curr
                }
                return nil
            }
        // check the first event to see if it's an orphaned resume
        let firstResumeOrphaned = suspendsAndResumes.first.flatMap { event -> [Event]? in
            guard type(event) == EventType.pumpResume.rawValue else { return nil }
            return [event]
        } ?? []

        return firstResumeOrphaned + orphanedResumes
    }

    // MARK: - Glucose

    /// Drops readings less than `filterTime` after the previous kept one, starting from `date`.
    static func filterTooFrequentGlucose(_ glucose: [BloodGlucose], at date: Date, filterTime: TimeInterval) -> [BloodGlucose] {
        var lastDate = date
        var filtered: [BloodGlucose] = []
        let sorted = glucose.sorted { $0.date < $1.date }

        for entry in sorted {
            guard entry.dateString.addingTimeInterval(-filterTime) > lastDate else {
                continue
            }
            filtered.append(entry)
            lastDate = entry.dateString
        }

        return filtered
    }

    /// The glucose value the algorithm consumes for a stored reading: the smoothed value when
    /// smoothing is on and a valid non-zero smoothed CGM value exists, otherwise the raw value
    /// (finger pricks/manual entries always use the raw value — cf.
    /// https://github.com/nightscout/Trio/issues/1054).
    static func algorithmGlucoseValue(
        glucose: Int16,
        smoothedGlucose: Decimal?,
        isManual: Bool,
        shouldSmoothGlucose: Bool,
        roundingBehavior: NSDecimalNumberHandler
    ) -> Int16 {
        if shouldSmoothGlucose {
            if !isManual, let smoothedGlucose, smoothedGlucose != 0 {
                return NSDecimalNumber(decimal: smoothedGlucose).rounding(accordingToBehavior: roundingBehavior).int16Value
            } else {
                return glucose
            }
        } else {
            return glucose
        }
    }

    /// The `BloodGlucose` the algorithm consumes for a stored reading:
    /// - CGM readings populate `sgv`, manual readings populate `glucose`.
    /// - `date` is the unix-millisecond timestamp as a `Decimal`.
    /// - `type` is always "sgv".
    static func bloodGlucose(
        id: UUID?,
        date: Date?,
        glucose: Int16,
        smoothedGlucose: Decimal?,
        isManual: Bool,
        direction: String?,
        shouldSmoothGlucose: Bool,
        roundingBehavior: NSDecimalNumberHandler
    ) -> BloodGlucose {
        let glucoseValue = algorithmGlucoseValue(
            glucose: glucose,
            smoothedGlucose: smoothedGlucose,
            isManual: isManual,
            shouldSmoothGlucose: shouldSmoothGlucose,
            roundingBehavior: roundingBehavior
        )
        // The ?? Date() is problematic, but this is how it worked previously
        // so we'll retain it
        let dateString = date ?? Date()
        let dateMilliseconds = Decimal(Int64(dateString.timeIntervalSince1970 * 1000))

        return BloodGlucose(
            id: id?.uuidString ?? UUID().uuidString,
            sgv: isManual ? nil : Int(glucoseValue),
            direction: direction.flatMap { BloodGlucose.Direction(rawValue: $0) },
            date: dateMilliseconds,
            dateString: dateString,
            glucose: isManual ? Int(glucoseValue) : nil,
            type: "sgv"
        )
    }

    /// AAPS exponential smoothing over CGM readings, oldest first. Returns the smoothed value per
    /// reading; nil leaves that reading's stored smoothed value unchanged.
    static func exponentiallySmoothedGlucose(
        _ data: [(date: Date?, glucose: Int16)],
        minimumWindowSize: Int = 4,
        maximumAllowedGapMinutes: Int = 12,
        xDripErrorGlucose: Int = 38,
        minimumSmoothedGlucose: Decimal = 39,
        firstOrderWeight: Decimal = 0.4,
        firstOrderAlpha: Decimal = 0.5,
        secondOrderAlpha: Decimal = 0.4,
        secondOrderBeta: Decimal = 1.0
    ) -> [Decimal?] {
        var smoothed = [Decimal?](repeating: nil, count: data.count)
        guard !data.isEmpty else { return smoothed }

        // Determine the size of the valid most-recent smoothing window.
        // We walk adjacent pairs from newest -> oldest to preserve the same window semantics
        // as the original implementation, but avoid manual reverse indexing.
        var validWindowCount = max(data.count - 1, 0)

        for (recentOffset, pair) in zip(data.dropFirst().reversed(), data.dropLast().reversed()).enumerated() {
            let (newer, older) = pair

            guard let newerDate = newer.date, let olderDate = older.date else { continue }

            let gapSeconds = newerDate.timeIntervalSince(olderDate)
            let gapMinutesRounded = Int((gapSeconds / 60.0).rounded())

            if gapMinutesRounded >= maximumAllowedGapMinutes {
                validWindowCount = recentOffset + 1 // include the more recent reading
                break
            }

            // Ported from AAPS: 38 mg/dL may represent an xDrip error state.
            if Int(newer.glucose) == xDripErrorGlucose {
                validWindowCount = recentOffset // exclude this 38 value
                break
            }
        }

        let windowStart = data.count - validWindowCount

        // Not enough recent contiguous readings to smooth (e.g. after CGM gap).
        // IMPORTANT: Only apply fallback to the recent window, not all data.
        // Otherwise a recent gap would overwrite historical smoothed values.
        guard validWindowCount >= minimumWindowSize else {
            for index in windowStart ..< data.count {
                let raw = Decimal(Int(data[index].glucose))
                smoothed[index] = max(raw, minimumSmoothedGlucose)
            }
            return smoothed
        }

        // Restrict smoothing to the valid most-recent window, still in chronological order.
        let validWindow = data.suffix(validWindowCount)

        guard let oldest = validWindow.first else { return smoothed }

        // ---- 1st order smoothing ----
        var firstOrderSmoothed: [Decimal] = []
        firstOrderSmoothed.reserveCapacity(validWindow.count)

        var firstOrderCurrent = Decimal(Int(oldest.glucose))
        firstOrderSmoothed.append(firstOrderCurrent)

        for sample in validWindow.dropFirst() {
            let raw = Decimal(Int(sample.glucose))
            firstOrderCurrent = firstOrderCurrent + firstOrderAlpha * (raw - firstOrderCurrent)
            firstOrderSmoothed.append(firstOrderCurrent)
        }

        // ---- 2nd order smoothing ----
        let secondOrderInput = Array(validWindow)
        guard secondOrderInput.count >= 2 else { return smoothed }

        var secondOrderSmoothed: [Decimal] = []
        secondOrderSmoothed.reserveCapacity(secondOrderInput.count)

        var secondOrderDeltas: [Decimal] = []
        secondOrderDeltas.reserveCapacity(secondOrderInput.count)

        var previousSecondOrderSmoothed = Decimal(Int(secondOrderInput[0].glucose))
        var previousSecondOrderDelta =
            Decimal(Int(secondOrderInput[1].glucose) - Int(secondOrderInput[0].glucose))

        secondOrderSmoothed.append(previousSecondOrderSmoothed)
        secondOrderDeltas.append(previousSecondOrderDelta)

        for sample in secondOrderInput.dropFirst() {
            let raw = Decimal(Int(sample.glucose))

            let nextSmoothed =
                secondOrderAlpha * raw
                    + (1 - secondOrderAlpha) * (previousSecondOrderSmoothed + previousSecondOrderDelta)

            let nextDelta =
                secondOrderBeta * (nextSmoothed - previousSecondOrderSmoothed)
                    + (1 - secondOrderBeta) * previousSecondOrderDelta

            previousSecondOrderSmoothed = nextSmoothed
            previousSecondOrderDelta = nextDelta

            secondOrderSmoothed.append(nextSmoothed)
            secondOrderDeltas.append(nextDelta)
        }

        // ---- Weighted blend ----
        let blended = zip(firstOrderSmoothed, secondOrderSmoothed).map { firstOrder, secondOrder in
            firstOrderWeight * firstOrder + (1 - firstOrderWeight) * secondOrder
        }

        // Apply to the most recent valid-window readings.
        for (index, blendedValue) in zip(windowStart ..< data.count, blended) {
            let rounded = blendedValue.rounded(toPlaces: 0) // nearest integer, ties away from zero
            smoothed[index] = max(rounded, minimumSmoothedGlucose)
        }
        return smoothed
    }

    // MARK: - Carbs

    /// The `CarbsEntry` the algorithm consumes for a stored carb entry.
    static func carbsEntry(id: UUID?, date: Date?, carbs: Double, fat: Double, protein: Double, isFPU: Bool) -> CarbsEntry {
        // The old encode used `date ?? Date()` for both created_at and actualDate.
        let date = date ?? Date()
        return CarbsEntry(
            id: id?.uuidString,
            createdAt: date,
            actualDate: date,
            carbs: Decimal(algorithmValue: carbs),
            fat: Decimal(algorithmValue: fat),
            protein: Decimal(algorithmValue: protein),
            note: nil,
            enteredBy: CarbsEntry.local,
            isFPU: isFPU,
            fpuID: nil
        )
    }
}
