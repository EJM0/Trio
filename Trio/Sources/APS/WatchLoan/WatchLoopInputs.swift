import Foundation
import LoopKit

/// What the watch recorded during a loan, in the forms oref reads. Pump history and glucose newest first.
struct WatchLoopRecords: Codable {
    var pumpHistory: [PumpHistoryEvent] = []
    var glucose: [BloodGlucose] = []
    var carbs: [CarbsEntry] = []
    var tddHistory: [OrefInputs.TDDRow] = []
    var overrideCancelledAt: Date?
    var tempTargetCancelledAt: Date?
    /// An override and temp target started on the watch during the loan, with their start times.
    var startedOverride: Override?
    var startedOverrideAt: Date?
    var startedTempTarget: TempTarget?
    var startedTempTargetAt: Date?
}

/// The watch's oref inputs: the grant's snapshot plus what the watch recorded since, selected with the phone's windows,
/// in the grant's time zone.
enum WatchLoopInputs {
    static func orefInputs(
        snapshot: WatchLoanSnapshot,
        records: WatchLoopRecords,
        now: Date,
        currentTemp: TempBasal,
        autosens: Autosens?,
        microBolusAllowed: Bool
    ) -> OrefInputs {
        let timeZone = snapshot.timeZone ?? snapshot.oref.timeZone
        var inputs = snapshot.oref
        inputs.clock = now
        inputs.timeZone = timeZone
        inputs.currentTemp = currentTemp
        inputs.autosens = autosens
        inputs.microBolusAllowed = microBolusAllowed

        inputs.glucose = OrefInputs.glucose(
            smoothed(snapshot.oref.glucose + records.glucose, snapshot: snapshot, ownReadings: records.glucose, now: now),
            since: OrefInputs.glucoseStart(hours: OrefInputs.autosensGlucoseHours, now: now)
        )
        // the snapshot's events come in the phone's order; the selection keeps it for equal timestamps
        inputs.pumpHistory = OrefInputs.algorithmPumpEvents(
            snapshot.oref.pumpHistory + records.pumpHistory,
            type: { $0.type.rawValue },
            timestamp: { $0.timestamp },
            isScheduledBasal: { _ in false },
            now: now
        )
        inputs.carbs = OrefInputs.carbs(snapshot.oref.carbs + records.carbs, now: now, timeZone: timeZone)
        inputs.tddHistory = OrefInputs.tddHistory(snapshot.oref.tddHistory + records.tddHistory, now: now)
        // the phone counts its stored rows each cycle; the 10-day history holds every row the 7-day rule counts
        inputs.hasSufficientTDD = OrefInputs.hasSufficientTDD(inputs.tddHistory, now: now)

        // Adjustments: a value started on the watch during the loan takes precedence over the grant's. The grant's
        // override/temp target stays active unless cancelled or expired; a watch-started one replaces it until it is
        // in turn cancelled. All dosing-relevant fields are carried from the full preset model into the oref state.
        // A watch-started override replaces the grant's for the rest of the loan (the phone ends the grant override
        // when it activates a preset), so once one has been started the grant override no longer applies.
        if let started = records.startedOverride {
            inputs.activeOverride = isActive(
                startedAt: records.startedOverrideAt,
                duration: started.indefinite ? nil : started.duration,
                cancelledAt: records.overrideCancelledAt,
                now: now
            ) ? OrefInputs.OverrideState(started) : nil
        } else if !isActive(snapshot.overrideAtGrant, cancelledAt: records.overrideCancelledAt, now: now) {
            inputs.activeOverride = nil
        }

        if let started = records.startedTempTarget, let startedAt = records.startedTempTargetAt {
            if isActive(startedAt: startedAt, duration: started.duration, cancelledAt: records.tempTargetCancelledAt, now: now) {
                inputs.activeTempTarget = OrefInputs.TempTargetState(started, preferences: snapshot.oref.preferences)
                // oref reads the newest temp target entry; add the started entry so file order follows the loan's order,
                // matching the phone's `AdjustmentManager`, which writes the started entry to the temp targets file.
                inputs.tempTargets.append(started)
            } else {
                inputs.activeTempTarget = nil
            }
        } else if !isActive(snapshot.tempTargetAtGrant, cancelledAt: records.tempTargetCancelledAt, now: now) {
            inputs.activeTempTarget = nil
        }

        if let cancelledAt = records.tempTargetCancelledAt {
            inputs.tempTargets.append(.cancel(at: cancelledAt))
        }
        return inputs
    }

    /// The phone smooths after storing each CGM reading (`FetchGlucoseManager`): its last 24 h of CGM readings, at
    /// most 350, raw, oldest first. The watch does the same once it has readings of its own; until then the
    /// snapshot's values are the phone's.
    static func smoothed(
        _ glucose: [BloodGlucose],
        snapshot: WatchLoanSnapshot,
        ownReadings: [BloodGlucose],
        now: Date
    ) -> [BloodGlucose] {
        guard snapshot.smoothGlucose, !ownReadings.isEmpty else { return glucose }
        var raw = Dictionary(
            snapshot.smoothingWindow.map { ($0.id.uuidString, $0.glucose) },
            uniquingKeysWith: { first, _ in first }
        )
        for reading in ownReadings {
            raw[reading.id] = Int16(reading.sgv ?? reading.glucose ?? 0)
        }
        let window = glucose
            .filter { raw[$0.id] != nil && $0.dateString >= now.addingTimeInterval(-24 * 60 * 60) }
            .sorted { $0.dateString > $1.dateString }
            .prefix(smoothingWindowLimit)
            .reversed()
        let values = OrefInputs.exponentiallySmoothedGlucose(window.map { (date: Optional($0.dateString), glucose: raw[$0.id]!) })
        let smoothedByID = Dictionary(
            zip(window, values).compactMap { reading, value in value.map { (reading.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let rounding = NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        return glucose.map { reading in
            guard let smoothedValue = smoothedByID[reading.id], let rawValue = raw[reading.id] else { return reading }
            return OrefInputs.bloodGlucose(
                id: UUID(uuidString: reading.id),
                date: reading.dateString,
                glucose: rawValue,
                smoothedGlucose: smoothedValue,
                isManual: false,
                direction: reading.direction?.rawValue,
                shouldSmoothGlucose: true,
                roundingBehavior: rounding
            )
        }
    }

    /// The phone's smoothing fetch limit.
    static let smoothingWindowLimit = 350

    static func isActive(_ adjustment: WatchLoanSnapshot.Adjustment?, cancelledAt: Date?, now: Date) -> Bool {
        if cancelledAt != nil { return false }
        guard let endsAt = adjustment?.endsAt else { return true }
        return now < endsAt
    }

    /// Whether an adjustment started on the watch at `startedAt` for `duration` minutes (nil = indefinite) is still
    /// active: not cancelled after it started, and not past its duration. Used for watch-started overrides and TTs.
    static func isActive(startedAt: Date?, duration: Decimal?, cancelledAt: Date?, now: Date) -> Bool {
        guard let startedAt else { return false }
        // A cancel at or after the start cancels this one; an older cancel belonged to the grant's value.
        if let cancelledAt, cancelledAt >= startedAt { return false }
        guard let duration, duration > 0 else { return true } // indefinite or no duration: runs until cancelled
        let endsAt = startedAt.addingTimeInterval(Double(truncating: duration as NSNumber) * 60)
        return now < endsAt
    }

    /// A kit's pump event as the phone stores it and then hands it to oref (`PumpHistoryStorage.storePumpEvents`,
    /// then `PumpEventStored.toPumpHistoryEvents`). Scheduled basal and events oref doesn't read give nothing.
    static func pumpHistoryEvents(_ event: NewPumpEvent, storedAt: Date, bolusIncrement: Decimal) -> [PumpHistoryEvent] {
        guard let type = event.type else { return [] }
        let id = event.dose?.syncIdentifier ?? event.raw.map { String(format: "%02hhx", $0) }.joined()
        let timestamp = min(event.date, storedAt)
        func events(_ type: EventType, bolus: (Double?, Bool, Bool)? = nil, tempBasal: (Int, Double?, String?)? = nil)
            -> [PumpHistoryEvent]
        {
            OrefInputs.pumpHistoryEvents(
                id: id,
                timestamp: timestamp,
                type: type.rawValue,
                bolus: bolus.map { (amount: $0.0, isSMB: $0.1, isExternal: $0.2) },
                tempBasal: tempBasal.map { (duration: $0.0, rate: $0.1, tempType: $0.2) }
            )
        }

        switch type {
        case .bolus:
            guard let dose = event.dose else { return [] }
            let increment = Double(truncating: bolusIncrement as NSNumber)
            // the phone stores the rounded dose as a Decimal and reads it back as a Double
            let amount = NSDecimalNumber(decimal: Decimal((dose.unitsInDeliverableIncrements / increment).rounded() * increment))
            return events(.bolus, bolus: (amount.doubleValue, dose.automatic ?? true, dose.manuallyEntered))
        case .tempBasal:
            guard let dose = event.dose else { return [] }
            let duration = Int((dose.endDate.timeIntervalSince(dose.startDate) / 60).rounded())
            return events(.tempBasal, tempBasal: (duration, dose.unitsPerHour, TempType.absolute.rawValue))
        case .suspend:
            return events(.pumpSuspend)
        case .resume:
            return events(.pumpResume)
        case .rewind:
            return events(.rewind)
        case .prime:
            return events(.prime)
        default:
            return []
        }
    }

    /// Today's insulin as the phone books it before each determination, from the run's pump history.
    static func tddRow(
        _ inputs: OrefInputs,
        roundToSupportedBasalRate: @escaping (Double) -> Double
    ) -> OrefInputs.TDDRow {
        let insulin = OrefInputs.tddInsulin(
            pumpHistory: inputs.pumpHistory,
            basalProfile: inputs.basalProfile,
            now: inputs.clock,
            timeZone: inputs.timeZone,
            roundToSupportedBasalRate: roundToSupportedBasalRate
        )
        return OrefInputs.TDDRow(date: inputs.clock, total: insulin.bolus + insulin.tempBasal + insulin.scheduledBasal)
    }
}

/// A pump event the watch keeps: the kit's record, when it was stored, and whether the watch booked it for a
/// command whose outcome stayed unknown.
struct WatchLoanStoredPumpEvent: Codable {
    var record: WatchLoanRecordBatch.PumpEventRecord
    var storedAt: Date
    var bookedIntent: Bool
    var acknowledged: Bool
}

extension WatchLoopInputs {
    /// A kit dose recorded within this window around a booked or pending command is that command's.
    static let doseMatchWindow: TimeInterval = 10 * 60

    /// Mirrors the phone's pump history rules (`PumpHistoryStorage.storePumpEvents`): one event per sync identifier, a
    /// finalized one never changes, and a complete pending report drops the pending events it no longer has. Events
    /// without a sync identifier are dropped (OmnipodKit always sets one). A new kit record of a dose the watch booked
    /// replaces the closest booking and names it, so the phone deletes its copy.
    static func store(
        _ events: [NewPumpEvent],
        into stored: inout [String: WatchLoanStoredPumpEvent],
        replacePendingEvents: Bool,
        at now: Date,
        pulseUnits: Double
    ) {
        var asserted = Set<String>()
        for event in events {
            guard let dose = event.dose, !event.raw.isEmpty, let key = dose.syncIdentifier else { continue }
            asserted.insert(key)
            if let existing = stored[key], !existing.record.dose.isMutable { continue }
            var replaces = stored[key]?.record.replacesSyncIdentifier
            if stored[key] == nil, let booked = closestBooking(for: dose, in: stored, pulseUnits: pulseUnits) {
                stored[booked] = nil
                replaces = booked
            }
            stored[key] = WatchLoanStoredPumpEvent(
                record: .init(date: event.date, raw: event.raw, title: event.title, dose: dose, replacesSyncIdentifier: replaces),
                storedAt: stored[key]?.storedAt ?? now,
                bookedIntent: false,
                acknowledged: false
            )
        }
        if replacePendingEvents {
            for (key, event) in stored where event.record.dose.isMutable && !event.bookedIntent && !asserted.contains(key) {
                stored[key] = nil
            }
        }
    }

    /// The booking a kit dose stands for, by the intent's own rule: same type and amount to the pulse, starting from
    /// 60 s before the booked command to 10 min after it; the closest if several.
    static func closestBooking(
        for dose: DoseEntry,
        in stored: [String: WatchLoanStoredPumpEvent],
        pulseUnits: Double
    ) -> String? {
        stored
            .filter { $0.value.bookedIntent && sameDose($0.value.record.dose, dose, pulseUnits: pulseUnits) }
            .min {
                abs($0.value.record.dose.startDate.timeIntervalSince(dose.startDate)) <
                    abs($1.value.record.dose.startDate.timeIntervalSince(dose.startDate)) }?
            .key
    }

    /// `kit` is the kit's dose of the command `booked` stands for: same type, the same amount to the pulse, starting from
    /// 60 s before the booked command to 10 min after it.
    static func sameDose(_ booked: DoseEntry, _ kit: DoseEntry, pulseUnits: Double) -> Bool {
        let offset = kit.startDate.timeIntervalSince(booked.startDate)
        guard booked.type == kit.type, offset >= -60, offset <= doseMatchWindow else { return false }
        let (a, b) = (booked, kit)
        switch a.type {
        case .bolus: return abs(a.programmedUnits - b.programmedUnits) < pulseUnits
        case .tempBasal: return abs(a.unitsPerHour - b.unitsPerHour) < pulseUnits
        default: return true
        }
    }

    /// The phone's current temp when the pump is between states (`APSManager.fetchCurrentTempBasal`): the newest temp
    /// basal of the last 20 minutes with what is left of it, otherwise none.
    static func fallbackTemp(_ history: [PumpHistoryEvent], now: Date) -> TempBasal {
        let since = now.addingTimeInterval(-20 * 60)
        guard let rate = history.filter({ $0.type == .tempBasal && $0.timestamp >= since })
            .max(by: { $0.timestamp < $1.timestamp }),
            let duration = history.first(where: { $0.type == .tempBasalDuration && $0.timestamp == rate.timestamp })?
            .durationMin
        else { return TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now) }
        let elapsed = Int((now.timeIntervalSince1970 - rate.timestamp.timeIntervalSince1970) / 60)
        return TempBasal(duration: max(0, duration - elapsed), rate: rate.rate ?? 0, temp: .absolute, timestamp: now)
    }
}

extension WatchDoseIntent {
    /// The kit recorded this command: a dose of its kind and amount near the time it was sent.
    func matches(_ dose: DoseEntry, pulseUnits: Double) -> Bool {
        guard dose.startDate >= createdAt.addingTimeInterval(-60),
              dose.startDate <= createdAt.addingTimeInterval(WatchLoopInputs.doseMatchWindow)
        else { return false }
        switch kind {
        case let .bolus(units, _):
            return dose.type == .bolus && abs(dose.programmedUnits - units.nearestDouble) < pulseUnits
        case let .tempBasal(rate, _):
            return dose.type == .tempBasal && abs(dose.unitsPerHour - rate.nearestDouble) < pulseUnits
        case .suspend:
            return dose.type == .suspend
        case .resume:
            return dose.type == .resume
        }
    }
}

// MARK: - Preset to oref state (dosing-relevant conversions)

extension Override {
    /// The preset as started now: a live, non-preset override with a start time, mirroring the phone's
    /// `AdjustmentManager.commitOverride` (enabled, dated now, fresh id).
    func started(at date: Date) -> Override {
        Override(
            name: name,
            enabled: true,
            date: date,
            duration: duration,
            indefinite: indefinite,
            percentage: percentage,
            smbIsOff: smbIsOff,
            isPreset: false,
            id: UUID().uuidString,
            overrideTarget: overrideTarget,
            target: target,
            advancedSettings: advancedSettings,
            isfAndCr: isfAndCr,
            isf: isf,
            cr: cr,
            smbIsScheduledOff: smbIsScheduledOff,
            start: start,
            end: end,
            smbMinutes: smbMinutes,
            uamMinutes: uamMinutes
        )
    }
}

extension TempTarget {
    /// The preset as started at `date`: a live, enabled temp target with that timestamp and a fresh id, the entry
    /// oref reads from the temp targets file. Mirrors the phone's `AdjustmentManager.orefTempTarget`.
    func started(at date: Date) -> TempTarget {
        TempTarget(
            id: UUID().uuidString,
            name: name,
            createdAt: date,
            targetTop: targetTop ?? targetBottom,
            targetBottom: targetBottom ?? targetTop,
            duration: duration,
            enteredBy: TempTarget.local,
            reason: reason ?? TempTarget.custom,
            isPreset: isPreset,
            enabled: true,
            halfBasalTarget: halfBasalTarget
        )
    }
}

extension OrefInputs.OverrideState {
    /// The active-override state oref reads, with every dosing-relevant field carried from the full preset. `target`
    /// is 0 when the preset does not override the target, matching the phone's `OverrideStored.target` semantics
    /// (`OverrideStorage`), which `OrefRun.trioCustomOrefVariables` reads as `activeOverride?.target ?? 0`.
    init(_ override: Override) {
        self.init(
            enabled: override.enabled,
            percentage: override.percentage,
            indefinite: override.indefinite,
            smbIsOff: override.smbIsOff,
            target: override.overrideTarget ? override.target : 0,
            duration: override.duration,
            advancedSettings: override.advancedSettings,
            isfAndCr: override.isfAndCr,
            isf: override.isf,
            cr: override.cr,
            smbIsScheduledOff: override.smbIsScheduledOff,
            start: override.start,
            end: override.end,
            smbMinutes: override.smbMinutes,
            uamMinutes: override.uamMinutes
        )
    }
}

extension OrefInputs.TempTargetState {
    /// The active-temp-target state oref reads: the target and the half basal target. `halfBasalTarget` falls back to
    /// the preference, as the phone's `AdjustmentManager.orefTempTarget` does when a preset carries none.
    init?(_ tempTarget: TempTarget, preferences: Preferences?) {
        guard let target = tempTarget.targetBottom ?? tempTarget.targetTop else { return nil }
        self.init(
            target: target,
            halfBasalTarget: tempTarget.halfBasalTarget ?? preferences?.halfBasalExerciseTarget
        )
    }
}
