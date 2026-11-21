import Foundation
import LoopKit

/// What the watch recorded during a loan, kept for oref and sent to the phone until it acknowledges. Pump events follow
/// the phone's pump history rules (`WatchLoopInputs.store`). Called from the kit's queue and the file queue.
final class WatchLoanRecordStore {
    struct Contents: Codable {
        var epoch: Int64 = 0
        var pulseUnits: Double = 0.05
        var pumpEvents: [String: WatchLoanStoredPumpEvent] = [:]
        var glucose: [BloodGlucose] = []
        var carbs: [CarbsEntry] = []
        var acknowledgedGlucose: Set<String> = []
        var acknowledgedCarbs: Set<String> = []
        var tddHistory: [OrefInputs.TDDRow] = []
        var overrideChange: WatchLoanAdjustmentChange?
        var tempTargetChange: WatchLoanAdjustmentChange?
        /// The batch sent last and what it carried, until the phone acknowledges it.
        var pendingBatch: UUID?
        var pendingKeys: [String] = []
    }

    private let files: WatchLoanFiles
    private let lock = NSLock()
    private var contents: Contents

    init(files: WatchLoanFiles) {
        self.files = files
        contents = Contents()
    }

    /// Reads the saved records; on the file queue.
    func load() {
        do {
            let saved = try files.load(Contents.self, from: .records) ?? Contents()
            lock.withLock { contents = saved }
        } catch {
            WatchLogger.shared.error(.loop, "Watch records can't be read; starting empty", error: error)
        }
    }

    var snapshot: Contents { lock.withLock { contents } }

    /// A new loan starts with no records.
    func reset(epoch: Int64, pulseUnits: Double) throws {
        try mutate { $0 = Contents(epoch: epoch, pulseUnits: pulseUnits) }
    }

    private func mutate<T>(_ change: (inout Contents) -> T) throws -> T {
        try lock.withLock {
            var updated = contents
            let result = change(&updated)
            try files.save(updated, to: .records)
            contents = updated
            return result
        }
    }

    // MARK: - Pump events

    func storePumpEvents(_ events: [NewPumpEvent], replacePendingEvents: Bool, at now: Date) throws {
        try mutate { contents in
            WatchLoopInputs.store(
                events,
                into: &contents.pumpEvents,
                replacePendingEvents: replacePendingEvents,
                at: now,
                pulseUnits: contents.pulseUnits
            )
        }
    }

    /// Books the dose of a command whose outcome stayed unknown, tagged so it is never mistaken for the kit's record.
    func book(_ intent: WatchDoseIntent) throws {
        let raw = Data("trio-watch-intent-\(intent.id.uuidString)".utf8)
        let dose: DoseEntry
        switch intent.kind {
        case let .bolus(units, automatic):
            let value = Double(truncating: units as NSNumber)
            dose = DoseEntry(
                type: .bolus,
                startDate: intent.createdAt,
                endDate: intent.createdAt,
                value: value,
                unit: .units,
                decisionId: nil,
                deliveredUnits: value,
                automatic: automatic
            )
        case let .tempBasal(rate, minutes):
            dose = DoseEntry(
                type: .tempBasal,
                startDate: intent.createdAt,
                endDate: intent.createdAt.addingTimeInterval(TimeInterval(minutes * 60)),
                value: Double(truncating: rate as NSNumber),
                unit: .unitsPerHour,
                decisionId: nil,
                automatic: true
            )
        case .resume,
             .suspend:
            return
        }
        let event = NewPumpEvent(date: intent.createdAt, dose: dose, raw: raw, title: "Unconfirmed command booked as delivered")
        guard let key = event.dose?.syncIdentifier, let booked = event.dose else { return }
        try mutate { contents in
            contents.pumpEvents[key] = WatchLoanStoredPumpEvent(
                record: .init(date: event.date, raw: raw, title: event.title, dose: booked),
                storedAt: intent.createdAt,
                bookedIntent: true,
                acknowledged: false
            )
        }
    }

    /// Whether the kit recorded this command's dose.
    func kitRecorded(_ intent: WatchDoseIntent) -> Bool {
        lock.withLock {
            contents.pumpEvents.values
                .contains { !$0.bookedIntent && intent.matches($0.record.dose, pulseUnits: contents.pulseUnits) }
        }
    }

    func recentBolusUnits(since date: Date) -> Decimal {
        lock.withLock {
            contents.pumpEvents.values
                .filter { $0.record.dose.type == .bolus && $0.record.date > date }
                .reduce(Decimal(0)) { $0 + Decimal($1.record.dose.unitsInDeliverableIncrements) }
        }
    }

    // MARK: - Glucose, carbs, TDD, adjustments

    /// Keeps readings at least the phone's filter time after the newest one known. Returns the ones kept.
    @discardableResult func storeGlucose(_ readings: [BloodGlucose], newestKnown: Date?) throws -> [BloodGlucose] {
        try mutate { contents in
            var last = max(newestKnown ?? .distantPast, contents.glucose.map(\.dateString).max() ?? .distantPast)
            var kept: [BloodGlucose] = []
            for reading in readings.sorted(by: { $0.dateString < $1.dateString })
                where reading.dateString.addingTimeInterval(-WatchLoopPolicy.glucoseFilterTime) > last
            {
                kept.append(reading)
                last = reading.dateString
            }
            contents.glucose.insert(contentsOf: kept.reversed(), at: 0)
            return kept
        }
    }

    func storeCarbs(_ entry: CarbsEntry) throws {
        try mutate { $0.carbs.insert(entry, at: 0) }
    }

    func storeTDD(_ row: OrefInputs.TDDRow) throws {
        try mutate { $0.tddHistory.append(row) }
    }

    func cancelOverride(at date: Date) throws {
        try mutate { $0.overrideChange = WatchLoanAdjustmentChange(id: UUID(), kind: .override, at: date) }
    }

    func startAdjustment(_ kind: WatchLoanAdjustmentChange.Kind, presetID: String, name: String, at date: Date) throws {
        let change = WatchLoanAdjustmentChange(id: UUID(), kind: kind, presetID: presetID, presetName: name, at: date)
        try mutate { contents in
            switch kind {
            case .override: contents.overrideChange = change
            case .tempTarget: contents.tempTargetChange = change
            }
        }
    }

    func cancelTempTarget(at date: Date) throws {
        try mutate { $0.tempTargetChange = WatchLoanAdjustmentChange(id: UUID(), kind: .tempTarget, at: date) }
    }

    // MARK: - For oref

    func loopRecords(bolusIncrement: Decimal) -> WatchLoopRecords {
        let contents = snapshot
        var records = WatchLoopRecords()
        records.pumpHistory = contents.pumpEvents.values
            .sorted { $0.record.date > $1.record.date }
            .flatMap {
                WatchLoopInputs.pumpHistoryEvents($0.record.newPumpEvent, storedAt: $0.storedAt, bolusIncrement: bolusIncrement)
            }
        records.glucose = contents.glucose
        records.carbs = contents.carbs
        records.tddHistory = contents.tddHistory
        records.overrideChange = contents.overrideChange
        records.tempTargetChange = contents.tempTargetChange
        return records
    }

    // MARK: - To the phone

    /// Everything not yet acknowledged: finalized doses, readings and carbs. The running temp is shown, not stored.
    func nextBatch(epoch: Int64, now: Date) throws -> WatchLoanRecordBatch {
        try mutate { contents in
            let events = contents.pumpEvents.filter { !$0.value.acknowledged && !$0.value.record.dose.isMutable }
            let batch = WatchLoanRecordBatch(
                version: WatchLoanRecordBatch.currentVersion,
                batchID: UUID(),
                epoch: epoch,
                sentAt: now,
                pumpEvents: events.values.map(\.record).sorted { $0.date < $1.date },
                runningTemp: contents.pumpEvents.values.map(\.record.dose)
                    .first { $0.isMutable && $0.type == .tempBasal && $0.endDate > now },
                carbs: contents.carbs.filter { !contents.acknowledgedCarbs.contains($0.id ?? "") },
                deletedCarbIDs: [],
                glucose: contents.glucose.filter { !contents.acknowledgedGlucose.contains($0.id) },
                adjustmentChanges: [contents.overrideChange, contents.tempTargetChange].compactMap { $0 }
            )
            contents.pendingBatch = batch.batchID
            contents.pendingKeys = Array(events.keys)
                + batch.carbs.map { "carbs:\($0.id ?? "")" }
                + batch.glucose.map { "glucose:\($0.id)" }
            return batch
        }
    }

    func acknowledge(_ ack: WatchLoanRecordAck, now: Date) throws {
        try mutate { contents in
            guard ack.batchID == contents.pendingBatch else { return }
            for key in contents.pendingKeys {
                if key.hasPrefix("carbs:") {
                    contents.acknowledgedCarbs.insert(String(key.dropFirst(6)))
                } else if key.hasPrefix("glucose:") {
                    contents.acknowledgedGlucose.insert(String(key.dropFirst(8)))
                } else {
                    contents.pumpEvents[key]?.acknowledged = true
                }
            }
            contents.pendingBatch = nil
            contents.pendingKeys = []
            // acknowledged records older than the retention window are only needed by the phone now
            let cutoff = now.addingTimeInterval(-WatchLoopPolicy.recordsRetention)
            contents.pumpEvents = contents.pumpEvents.filter { !$0.value.acknowledged || $0.value.record.date > cutoff }
            contents.glucose.removeAll { contents.acknowledgedGlucose.contains($0.id) && $0.dateString <= cutoff }
            contents.carbs.removeAll { contents.acknowledgedCarbs.contains($0.id ?? "") && $0.createdAt <= cutoff }
            contents.tddHistory.removeAll { ($0.date ?? .distantPast) <= cutoff }
        }
    }
}
