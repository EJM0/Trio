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

        if !isActive(snapshot.overrideAtGrant, cancelledAt: records.overrideCancelledAt, now: now) {
            inputs.activeOverride = nil
        }
        if !isActive(snapshot.tempTargetAtGrant, cancelledAt: records.tempTargetCancelledAt, now: now) {
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
