import CoreData
import Foundation
import LoopKitUI
import Swinject

protocol TDDStorage {
    func calculateTDD(
        pumpManager: any PumpManagerUI,
        pumpHistory: [PumpHistoryEvent],
        basalProfile: [BasalProfileEntry]
    ) async throws
        -> TDDResult
    func storeTDD(_ tddResult: TDDResult) async
    func hasSufficientTDD() async throws -> Bool
}

/// Structure containing the results of TDD calculations
struct TDDResult {
    let total: Decimal
    let bolus: Decimal
    let tempBasal: Decimal
    let scheduledBasal: Decimal
    let weightedAverage: Decimal?
    let hoursOfData: Double
}

/// Implementation of the TDD Calculator
final class BaseTDDStorage: TDDStorage, Injectable {
    @Injected() private var storage: FileStorage!

    private let makeContext: () -> NSManagedObjectContext
    private let now: () -> Date

    init(resolver: Resolver, contextProvider: (() -> NSManagedObjectContext)? = nil, now: @escaping () -> Date = Date.init) {
        makeContext = contextProvider ?? { CoreDataStack.shared.newTaskContext() }
        self.now = now
        injectServices(resolver)
    }

    /// Main function to calculate TDD from pump history
    /// - Parameters:
    ///   - pumpManager: Representation of paired pump's PumpManagerUI
    ///   - pumpHistory: Array of pump history events
    ///   - basalProfile: Schedule used to infer delivery for uncovered gaps
    /// - Returns: TDDResult containing all calculated values
    func calculateTDD(
        pumpManager: any PumpManagerUI,
        pumpHistory: [PumpHistoryEvent],
        basalProfile: [BasalProfileEntry]
    ) async throws -> TDDResult {
        debug(.algorithm, "Calculating TDD from \(pumpHistory.count) pump events")

        // Log the first and last pump history events if available
        let earliestEvent: String
        let latestEvent: String

        // We fetch descending, so invert logic
        if let firstEvent = pumpHistory.last, let lastEvent = pumpHistory.first {
            earliestEvent = "Type: \(firstEvent.type), Timestamp: \(firstEvent.timestamp.ISO8601Format())"
            latestEvent = "Type: \(lastEvent.type), Timestamp: \(lastEvent.timestamp.ISO8601Format())"
        } else {
            earliestEvent = "No events available"
            latestEvent = "No events available"
        }

        // Calculate all components concurrently
        async let pumpDataHours = calculatePumpDataHours(pumpHistory)
        async let weightedAverage = calculateWeightedAverage()
        let insulin = OrefInputs.tddInsulin(
            pumpHistory: pumpHistory,
            basalProfile: basalProfile,
            now: Date(),
            timeZone: TimeZone.current,
            roundToSupportedBasalRate: pumpManager.roundToSupportedBasalRate
        )
        let (bolus, temp, scheduled) = (insulin.bolus, insulin.tempBasal, insulin.scheduledBasal)

        // Await all concurrent calculations
        let (hours, weighted) = try await (pumpDataHours, weightedAverage)

        // Total insulin calculation
        let total = bolus + temp + scheduled

        // Safeguard against division by zero
        let percentage: (Decimal, Decimal) -> String = { part, total in
            total > 0 ? String(format: "%.2f", NSDecimalNumber(decimal: (part / total * 100).rounded(toPlaces: 2)).doubleValue) :
                "0.00"
        }

        // Store log strings in variables to avoid Xcode auto formatter from breaking up the lines in log statement
        let totalString = String(format: "%.2f", NSDecimalNumber(decimal: total.rounded(toPlaces: 2)).doubleValue)
        let bolusString = String(format: "%.2f", NSDecimalNumber(decimal: bolus.rounded(toPlaces: 2)).doubleValue)
        let tempBasalString = String(format: "%.2f", NSDecimalNumber(decimal: temp.rounded(toPlaces: 2)).doubleValue)
        let scheduledBasalString = String(format: "%.2f", NSDecimalNumber(decimal: scheduled.rounded(toPlaces: 2)).doubleValue)
        let weightedAvgString = String(format: "%.2f", NSDecimalNumber(decimal: weighted?.rounded(toPlaces: 2) ?? 0).doubleValue)
        let hoursString = String(format: "%.5f", NSDecimalNumber(decimal: Decimal(hours).truncated(toPlaces: 5)).doubleValue)

        debug(
            .algorithm,
            "TDD \(totalString) U: bolus \(bolusString) U (\(percentage(bolus, total))%), " +
                "temp basal \(tempBasalString) U (\(percentage(temp, total))%), " +
                "scheduled basal \(scheduledBasalString) U (\(percentage(scheduled, total))%), " +
                "weighted average \(weightedAvgString) U, \(hoursString) h of data, " +
                "earliest event \(earliestEvent), latest event \(latestEvent)"
        )

        // Return calculated TDDResult
        return TDDResult(
            total: total,
            bolus: bolus,
            tempBasal: temp,
            scheduledBasal: scheduled,
            weightedAverage: weighted,
            hoursOfData: hours
        )
    }

    /// Stores the Total Daily Dose (TDD) result in Core Data
    /// - Parameter tddResult: The TDD result to store, containing total insulin, bolus, temp basal, scheduled basal and weighted average
    func storeTDD(_ tddResult: TDDResult) async {
        let context = makeContext()
        context.name = "storeTDD"
        await context.perform {
            let tddStored = TDDStored(context: context)
            tddStored.id = UUID()
            tddStored.date = Date()
            tddStored.total = NSDecimalNumber(decimal: tddResult.total)
            tddStored.bolus = NSDecimalNumber(decimal: tddResult.bolus)
            tddStored.tempBasal = NSDecimalNumber(decimal: tddResult.tempBasal)
            tddStored.scheduledBasal = NSDecimalNumber(decimal: tddResult.scheduledBasal)
            tddStored.weightedAverage = tddResult.weightedAverage.map { NSDecimalNumber(decimal: $0) }

            do {
                guard context.hasChanges else { return }
                try context.save()
            } catch {
                warning(.storage, "Saving TDD failed", error: error)
            }
        }
    }

    /// Calculates the number of hours of available pump history data
    /// - Parameter pumpHistory: Array of pump history events
    /// - Returns: Number of hours of available data
    private func calculatePumpDataHours(_ pumpHistory: [PumpHistoryEvent]) -> Double {
        guard let firstEvent = pumpHistory.last, // we are fetching in a descending order
              let lastEvent = pumpHistory.first
        else {
            return 0
        }

        let startDate = firstEvent.timestamp
        var endDate = lastEvent.timestamp

        // If last event in the list is tempBasal, check if it is running longer than current time
        // If yes, set current date, else ignore
        if lastEvent.type == .tempBasal, lastEvent.timestamp > Date().addingTimeInterval(-1) {
            endDate = Date()
        }

        return Double(endDate.timeIntervalSince(startDate)) / 3600.0
    }

    /// Calculates a weighted average of Total Daily Dose (TDD) based on recent and historical data
    ///
    /// The weighted average is calculated using two time periods:
    /// - Recent: Last 2 hours of TDD data
    /// - Historical: Last 10 days of TDD data
    ///
    /// The formula used is:
    /// ```
    /// weightedTDD = (weightPercentage × recent_average) + ((1 - weightPercentage) × historical_average)
    /// ```
    /// where weightPercentage defaults to 0.65 if not set in preferences
    ///
    /// - Returns: A weighted average of TDD as Decimal, or nil if insufficient data
    /// - Note: The weight percentage can be configured in preferences. Default is 0.65 (65% recent, 35% historical)
    private func calculateWeightedAverage() async throws -> Decimal? {
        let tenDaysAgo = Date().addingTimeInterval(-10.days.timeInterval)
        let twoHoursAgo = Date().addingTimeInterval(-2.hours.timeInterval)

        let context = makeContext()
        context.name = "calculateWeightedAverage"

        return try await context.perform { () -> Decimal? in
            let recent = try Self.aggregateTDD(from: twoHoursAgo, in: context)
            let historical = try Self.aggregateTDD(from: tenDaysAgo, in: context)

            // Extract into locals so SwiftFormat's isEmpty rule doesn't
            // mis-rewrite the tuple member access into `!tuple.isEmpty`
            let historicalCount = historical.count
            let recentCount = recent.count
            guard historicalCount > 0 else { return 0 }

            let averageTDDLastTwoHours = recent.total / max(Decimal(recentCount), 1)
            let averageTDDLastTenDays = historical.total / Decimal(historicalCount)

            // Get weight percentage from preferences (default 0.65 if not set)
            let userPreferences = self.storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self)
            let weightPercentage = userPreferences?.weightPercentage ?? Decimal(0.65) // why is this 1 as default in trio-oref??

            // weightedTDD = (weightPercentage × recent_average) + ((1 - weightPercentage) × historical_average)
            let weightedTDD = weightPercentage * averageTDDLastTwoHours +
                (1 - weightPercentage) * averageTDDLastTenDays

            return weightedTDD.truncated(toPlaces: 3)
        }
    }

    /// Runs a SUM(total) + COUNT aggregate on TDDStored for records with date >= `from`,
    /// avoiding materializing hundreds of rows just to add them up.
    private static func aggregateTDD(
        from: Date,
        in context: NSManagedObjectContext
    ) throws -> (total: Decimal, count: Int) {
        let request = NSFetchRequest<NSDictionary>(entityName: "TDDStored")
        request.resultType = .dictionaryResultType
        request.predicate = NSPredicate(format: "date >= %@ AND total != nil", from as NSDate)

        let sumExp = NSExpressionDescription()
        sumExp.name = "sumTotal"
        sumExp.expression = NSExpression(forFunction: "sum:", arguments: [NSExpression(forKeyPath: "total")])
        sumExp.expressionResultType = .decimalAttributeType

        let countExp = NSExpressionDescription()
        countExp.name = "countTotal"
        countExp.expression = NSExpression(forFunction: "count:", arguments: [NSExpression(forKeyPath: "total")])
        countExp.expressionResultType = .integer64AttributeType

        request.propertiesToFetch = [sumExp, countExp]

        guard let row = try context.fetch(request).first else {
            return (0, 0)
        }
        let sum = (row["sumTotal"] as? NSDecimalNumber)?.decimalValue ?? 0
        let count = (row["countTotal"] as? NSNumber)?.intValue ?? 0
        return (sum, count)
    }

    /// Checks if there is enough Total Daily Dose (TDD) data collected over the past 7 days.
    ///
    /// This function performs a count fetch for TDDStored records in Core Data where:
    /// - The record's date is within the last 7 days.
    /// - The total value is greater than 0.
    ///
    /// It then checks if at least 75% of the expected data points are present,
    /// assuming at least 288 expected entries per day (one every 5 minutes).
    ///
    /// - Returns: `true` if sufficient TDD data is available, otherwise `false`.
    /// - Throws: An error if the Core Data count operation fails.
    func hasSufficientTDD() async throws -> Bool {
        let context = makeContext()
        context.name = "hasSufficientTDD"
        return try await BaseTDDStorage.hasSufficientTDD(context: context, now: now())
    }

    /// internal function with context exposed to enable testing
    static func hasSufficientTDD(context: NSManagedObjectContext, now: Date) async throws -> Bool {
        try await context.perform {
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "TDDStored")
            fetchRequest.predicate = NSPredicate(
                format: "date > %@ AND total > 0",
                OrefInputs.sufficientTDDStart(now: now) as NSDate
            )
            fetchRequest.resultType = .countResultType

            let count = try context.count(for: fetchRequest)
            return count >= OrefInputs.sufficientTDDRowCount
        }
    }
}
