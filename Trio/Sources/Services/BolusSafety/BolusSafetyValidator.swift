import CoreData
import Foundation
import Swinject

/// Shared safety checks applied to any bolus command originating outside the main bolus UI
/// (remote notifications, Shortcuts, Apple Watch, etc.). Keeps validation logic consistent across call sites.
protocol BolusSafetyValidator {
    /// - Parameter lookbackStart: start of the window used for the recent-bolus 20% check.
    ///   Defaults to `now - BolusSafetyEvaluator.recentBolusWindowMinutes`. Callers that know when the
    ///   command was originally issued (e.g. APNS payload timestamp) should pass that instead so the
    ///   check covers any bolus since the command was sent.
    /// - Parameter overriding: checks the user has seen fail and chosen to bolus through. Only checks whose
    ///   `canBeOverridden` is true are skipped.
    func validate(
        bolusAmount: Decimal,
        lookbackStart: Date?,
        overriding: Set<BolusSafetyCheck>
    ) async throws -> BolusSafetyResult
    func fetchTotalRecentBolusAmount(since date: Date) async throws -> Decimal
}

extension BolusSafetyValidator {
    func validate(bolusAmount: Decimal) async throws -> BolusSafetyResult {
        try await validate(bolusAmount: bolusAmount, lookbackStart: nil, overriding: [])
    }

    func validate(bolusAmount: Decimal, lookbackStart: Date?) async throws -> BolusSafetyResult {
        try await validate(bolusAmount: bolusAmount, lookbackStart: lookbackStart, overriding: [])
    }
}

final class BaseBolusSafetyValidator: BolusSafetyValidator, Injectable {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var iobService: IOBService!

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    func validate(
        bolusAmount: Decimal,
        lookbackStart: Date?,
        overriding: Set<BolusSafetyCheck>
    ) async throws -> BolusSafetyResult {
        let windowStart = lookbackStart
            ?? Date().addingTimeInterval(-Double(BolusSafetyEvaluator.recentBolusWindowMinutes * 60))
        let inputs = BolusSafetyInputs(
            maxBolus: settingsManager.pumpSettings.maxBolus,
            maxIOB: settingsManager.preferences.maxIOB,
            currentIOB: iobService.currentIOB,
            totalRecentBolus: try await fetchTotalRecentBolusAmount(since: windowStart)
        )
        return BolusSafetyEvaluator.evaluate(bolusAmount: bolusAmount, inputs: inputs, overriding: overriding)
    }

    func fetchTotalRecentBolusAmount(since date: Date) async throws -> Decimal {
        let fetchContext = CoreDataStack.shared.newTaskContext()
        fetchContext.name = "fetchTotalRecentBolusAmount"
        let predicate = NSPredicate(
            format: "type == %@ AND timestamp > %@",
            PumpEventStored.EventType.bolus.rawValue,
            date as NSDate
        )
        let results: Any = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: fetchContext,
            predicate: predicate,
            key: "timestamp",
            ascending: true,
            fetchLimit: nil,
            propertiesToFetch: ["bolus.amount"]
        )
        guard let bolusDictionaries = results as? [[String: Any]] else {
            throw CoreDataError.fetchError(function: #function, file: #file)
        }
        return bolusDictionaries.compactMap { ($0["bolus.amount"] as? NSNumber)?.decimalValue }.reduce(0, +)
    }
}
