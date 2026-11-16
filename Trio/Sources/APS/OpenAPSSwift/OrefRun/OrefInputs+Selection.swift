import Foundation

/// Which stored rows feed one oref run. The phone's fetches, `OrefRun.run` and any other store
/// use these windows and filters.
extension OrefInputs {
    // MARK: - Glucose

    /// Autosens reads the last 24 h of glucose.
    static let autosensGlucoseHours: Decimal = 24

    /// The determination reads the longest tracked meal absorption plus a half-hour lead-in.
    static func determinationGlucoseHours(_ preferences: Preferences) -> Decimal {
        preferences.maxMealAbsorptionTime + 0.5
    }

    static func glucoseStart(hours: Decimal, now: Date) -> Date {
        now.addingTimeInterval(-(Double(truncating: hours as NSNumber) * 3600))
    }

    /// Readings at or after `start`, newest first.
    static func glucose(_ glucose: [BloodGlucose], since start: Date) -> [BloodGlucose] {
        glucose.filter { $0.dateString >= start }.sorted { $0.dateString > $1.dateString }
    }

    // MARK: - Carbs

    static func carbsStart(now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -1, to: now)!
    }

    /// Entries of the last day, newest first.
    static func carbs(_ carbs: [CarbsEntry], now: Date) -> [CarbsEntry] {
        let start = carbsStart(now: now)
        return carbs.filter { $0.createdAt >= start }.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Pump history

    static func pumpHistoryStart(now: Date) -> Date {
        Calendar.current.date(byAdding: .minute, value: -1440, to: now)!
    }

    /// Orphaned resumes are looked for in 48 h: the 24 h history plus 24 h for the suspend before it.
    static func orphanedResumeWindowStart(now: Date) -> Date {
        now - TimeInterval(hours: 48)
    }

    /// The stored pump events oref reads: no scheduled-basal rows, no orphaned resumes, the last 24 h, newest first.
    static func algorithmPumpEvents<Event>(
        _ events: [Event],
        type: (Event) -> String?,
        timestamp: (Event) -> Date?,
        isScheduledBasal: (Event) -> Bool,
        now: Date
    ) -> [Event] {
        let windowStart = orphanedResumeWindowStart(now: now)
        let candidates = events.enumerated()
            .compactMap { offset, event -> (offset: Int, event: Event, timestamp: Date)? in
                guard let date = timestamp(event), date >= windowStart, !isScheduledBasal(event) else { return nil }
                return (offset, event, date)
            }
            .sorted { $0.timestamp < $1.timestamp }

        let orphaned = Set(
            orphanedResumes(in: candidates, type: { type($0.event) }, timestamp: { $0.timestamp }).map(\.offset)
        )
        let historyStart = pumpHistoryStart(now: now)
        return candidates
            .filter { $0.timestamp >= historyStart && !orphaned.contains($0.offset) }
            .sorted { $0.timestamp > $1.timestamp }
            .map(\.event)
    }

    // MARK: - TDD

    static func tddHistoryStart(now: Date) -> Date {
        now.addingTimeInterval(-TimeInterval(hours: 10 * 24))
    }

    /// Rows of the last 10 days with a total above 0, oldest first.
    static func tddHistory(_ rows: [TDDRow], now: Date) -> [TDDRow] {
        let start = tddHistoryStart(now: now)
        return rows
            .filter { row in row.date.map { $0 > start } ?? false && (row.total ?? 0) > 0 }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    static func sufficientTDDStart(now: Date) -> Date {
        now.addingTimeInterval(-86400 * 7)
    }

    /// 75 % of 7 days of 5-minute rows.
    static let sufficientTDDRowCount = Int(Double(7 * 288) * 0.75)

    /// Dynamic ISF needs enough TDD rows from the last 7 days.
    static func hasSufficientTDD(_ rows: [TDDRow], now: Date) -> Bool {
        let start = sufficientTDDStart(now: now)
        return rows.filter { row in row.date.map { $0 > start } ?? false && (row.total ?? 0) > 0 }.count
            >= sufficientTDDRowCount
    }
}
