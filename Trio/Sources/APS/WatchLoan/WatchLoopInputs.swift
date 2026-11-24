import Foundation
import LoopKit

/// What the watch recorded during a loan, in the forms oref reads. Pump history and glucose newest first.
struct WatchLoopRecords: Codable {
    var pumpHistory: [PumpHistoryEvent] = []
    var glucose: [BloodGlucose] = []
    var carbs: [CarbsEntry] = []
    var tddHistory: [OrefInputs.TDDRow] = []
    /// The watch's latest override and temp target change; each ends the adjustment the loan started with.
    var overrideChange: WatchLoanAdjustmentChange?
    var tempTargetChange: WatchLoanAdjustmentChange?
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

        if !isActive(snapshot.overrideAtGrant, cancelledAt: records.overrideChange?.at, now: now) {
            inputs.activeOverride = nil
        }
        if let change = records.overrideChange, let preset = startedOverride(snapshot: snapshot, change: change),
           endDate(of: preset, startedAt: change.at).map({ now < $0 }) ?? true
        {
            // the phone starts a preset by enabling its row
            var state = preset.state
            state.enabled = true
            inputs.activeOverride = state
        }
        if !isActive(snapshot.tempTargetAtGrant, cancelledAt: records.tempTargetChange?.at, now: now) {
            inputs.activeTempTarget = nil
        }
        if let change = records.tempTargetChange {
            if change.presetID == nil {
                inputs.tempTargets.append(.cancel(at: change.at))
            } else if let preset = startedTempTarget(snapshot: snapshot, change: change) {
                // as the phone's adjustment manager starts a preset: the file entry and the active row
                let halfBasalFallback = snapshot.oref.preferences?.halfBasalExerciseTarget ?? Preferences()
                    .halfBasalExerciseTarget
                inputs.tempTargets.append(TempTarget(
                    name: preset.name,
                    createdAt: change.at,
                    targetTop: preset.target,
                    targetBottom: preset.target,
                    duration: preset.duration,
                    enteredBy: TempTarget.local,
                    reason: TempTarget.custom,
                    isPreset: true,
                    enabled: true,
                    halfBasalTarget: preset.halfBasalTarget ?? halfBasalFallback
                ))
                if now < endDate(of: preset, startedAt: change.at) {
                    inputs.activeTempTarget = OrefInputs.TempTargetState(
                        target: preset.target,
                        halfBasalTarget: preset.halfBasalTarget
                    )
                }
            }
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

    /// The temp target preset a watch change started.
    static func startedTempTarget(snapshot: WatchLoanSnapshot, change: WatchLoanAdjustmentChange?) -> WatchLoanSnapshot
        .TempTargetPreset?
    {
        guard let change, change.kind == .tempTarget, let id = change.presetID else { return nil }
        return snapshot.tempTargetPresets.first { $0.id == id }
    }

    /// The override preset a watch change started.
    static func startedOverride(snapshot: WatchLoanSnapshot, change: WatchLoanAdjustmentChange?) -> WatchLoanSnapshot
        .OverridePreset?
    {
        guard let change, change.kind == .override, let id = change.presetID else { return nil }
        return snapshot.overridePresets.first { $0.id == id }
    }

    /// Nil: runs until stopped.
    static func endDate(of preset: WatchLoanSnapshot.OverridePreset, startedAt: Date) -> Date? {
        guard !preset.indefinite, let duration = preset.duration else { return nil }
        return startedAt.addingTimeInterval(Double(truncating: duration as NSNumber) * 60)
    }

    static func endDate(of preset: WatchLoanSnapshot.TempTargetPreset, startedAt: Date) -> Date {
        startedAt.addingTimeInterval(Double(truncating: preset.duration as NSNumber) * 60)
    }

    static func isActive(_ adjustment: WatchLoanSnapshot.Adjustment?, cancelledAt: Date?, now: Date) -> Bool {
        if cancelledAt != nil { return false }
        guard let endsAt = adjustment?.endsAt else { return true }
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
    /// without a sync identifier are dropped (the kits set one from the raw data). A new kit record of a dose the watch booked
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
