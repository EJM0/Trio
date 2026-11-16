import CoreData
import Foundation
import Swinject
import Testing
@testable import Trio

/// Characterization goldens for the production path: `OpenAPS.createProfiles`, `autosense` and
/// `determineBasal`, run against in-memory Core Data and settings files, in the order `APSManager` uses.
/// Dates are written relative to the scenario clock; values `OpenAPS` takes from `Date()` become `<now>`.
@Suite("OpenAPS characterization goldens", .serialized) struct OrefCharacterizationTests {
    let resolver: Resolver

    init() {
        resolver = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly()
        ]).resolver
    }

    @Test(
        "production path matches golden",
        arguments: OrefCharacterizationScenarios.allNames
    ) func productionPathMatchesGolden(scenarioName: String) async throws {
        let clock = scenarioName == "simulation" ? Date() : OrefCharacterizationScenarios.makeClock()
        let scenario = OrefCharacterizationScenarios.build(scenarioName, clock: clock)
        let stages = try await runProductionPath(scenario)

        for (stage, json) in stages {
            try OrefGoldens.check(json, clock: clock, scenario: scenarioName, stage: stage)
        }
        if OrefGoldens.isRecording {
            Issue.record("goldens recorded for \(scenarioName); re-run without TRIO_RECORD_CHARACTERIZATION to compare")
        }
    }

    private func runProductionPath(_ scenario: OrefCharacterizationScenario) async throws -> [(String, String)] {
        let stack = try await CoreDataStack.createForTests()
        var contextProvider = { stack.newTaskContext() }
        if scenario.onDiskStore {
            let container = try Self.onDiskContainer()
            contextProvider = {
                let context = container.newBackgroundContext()
                context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
                return context
            }
        }
        try await scenario.seed(into: contextProvider())
        let storage = InMemoryFileStorage()
        scenario.seed(into: storage)

        let openAPS = OpenAPS(
            storage: storage,
            tddStorage: BaseTDDStorage(resolver: resolver, contextProvider: contextProvider),
            glucoseStorage: BaseGlucoseStorage(resolver: resolver, contextProvider: contextProvider),
            carbsStorage: BaseCarbsStorage(resolver: resolver, contextProvider: contextProvider),
            contextProvider: contextProvider
        )

        if let simulation = scenario.simulation {
            try await openAPS.createProfiles(for: scenario.dosingMode)
            _ = try await openAPS.autosense(shouldSmoothGlucose: scenario.smoothGlucose)
            let determination = try await openAPS.determineBasal(
                for: scenario.dosingMode,
                currentTemp: scenario.currentTemp,
                supportedBasalRates: scenario.supportedBasalRates,
                shouldSmoothGlucose: scenario.smoothGlucose,
                clock: scenario.clock,
                simulatedCarbsAmount: simulation.carbs,
                simulatedBolusAmount: simulation.bolus,
                simulatedCarbsDate: simulation.carbsDate,
                simulation: true
            )
            #expect(storage.retrieveRaw(OpenAPS.Monitor.iob) == nil, "a simulation must not write iob.json")
            #expect(try await storedDeterminationCount(contextProvider()) == 0, "a simulation must not store a determination")
            return [("determination", try OrefGoldens.canonical(determination))]
        }

        try await openAPS.createProfiles(for: scenario.dosingMode)
        _ = try await openAPS.autosense(shouldSmoothGlucose: scenario.smoothGlucose)
        let determination = try await openAPS.determineBasal(
            for: scenario.dosingMode,
            currentTemp: scenario.currentTemp,
            supportedBasalRates: scenario.supportedBasalRates,
            shouldSmoothGlucose: scenario.smoothGlucose,
            clock: scenario.clock
        )

        return [
            ("pumpprofile", try OrefGoldens.canonical(file: OpenAPS.Settings.pumpProfile, as: Profile.self, in: storage)),
            ("profile", try OrefGoldens.canonical(file: OpenAPS.Settings.profile, as: Profile.self, in: storage)),
            ("autosens", try OrefGoldens.canonical(file: OpenAPS.Settings.autosense, as: Autosens.self, in: storage)),
            (
                "trio_custom_oref_variables",
                try OrefGoldens.canonical(
                    file: OpenAPS.Monitor.trio_custom_oref_variables,
                    as: TrioCustomOrefVariables.self,
                    in: storage
                )
            ),
            ("iob", try OrefGoldens.canonical(file: OpenAPS.Monitor.iob, as: [IobResult].self, in: storage)),
            (
                "cob",
                try OrefGoldens.canonical(cobRelativeToDelivery(storage, determination: determination, clock: scenario.clock))
            ),
            ("determination", try OrefGoldens.canonical(determination)),
            ("stored_determination", try await storedDetermination(contextProvider()))
        ]
    }

    /// cob.json is spaced from `deliverAt`, which is `Date()`; rebase it onto the clock in whole seconds.
    private func cobRelativeToDelivery(_ storage: FileStorage, determination: Determination?, clock: Date) throws -> [CobEntry] {
        guard let entries = storage.retrieve(OpenAPS.Monitor.cob, as: [CobEntry].self),
              let deliverAt = determination?.deliverAt
        else { throw OrefGoldens.Failure("cob.json or deliverAt missing") }
        return entries.map { entry in
            CobEntry(cob: entry.cob, time: entry.time.map { clock.addingTimeInterval($0.timeIntervalSince(deliverAt).rounded()) })
        }
    }

    /// A SQLite store in a temporary file, for fetch order as on a device.
    static func onDiskContainer() throws -> NSPersistentContainer {
        let container = NSPersistentContainer(
            name: "TrioCoreDataPersistentContainer",
            managedObjectModel: CoreDataStack.managedObjectModel
        )
        container.persistentStoreDescriptions.first?.url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oref-characterization-\(UUID().uuidString).sqlite")
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        return container
    }

    private func storedDeterminationCount(_ context: NSManagedObjectContext) async throws -> Int {
        try await context.perform {
            try context.count(for: OrefDetermination.fetchRequest())
        }
    }

    /// The Core Data row `processDetermination` writes, reduced to its algorithm fields.
    private func storedDetermination(_ context: NSManagedObjectContext) async throws -> String {
        let summary: [String: String] = try await context.perform {
            let rows = try context.fetch(OrefDetermination.fetchRequest())
            guard rows.count == 1, let row = rows.first else {
                throw OrefGoldens.Failure("expected one stored determination, found \(rows.count)")
            }
            var summary: [String: String] = [
                "reason": row.reason ?? "nil",
                "temp": row.temp ?? "nil",
                "cob": "\(row.cob)",
                "carbsRequired": "\(row.carbsRequired)"
            ]
            let decimals: [String: NSDecimalNumber?] = [
                "insulinSensitivity": row.insulinSensitivity,
                "currentTarget": row.currentTarget,
                "eventualBG": row.eventualBG,
                "carbRatio": row.carbRatio,
                "glucose": row.glucose,
                "insulinReq": row.insulinReq,
                "rate": row.rate,
                "duration": row.duration,
                "iob": row.iob,
                "threshold": row.threshold,
                "minDelta": row.minDelta,
                "sensitivityRatio": row.sensitivityRatio,
                "expectedDelta": row.expectedDelta,
                "smbToDeliver": row.smbToDeliver
            ]
            for (key, value) in decimals {
                summary[key] = value.map(\.stringValue) ?? "nil"
            }
            let forecasts = (row.forecasts as? Set<Forecast>) ?? []
            for forecast in forecasts {
                let values = ((forecast.forecastValues as? Set<ForecastValue>) ?? [])
                    .sorted { $0.index < $1.index }
                    .map { String($0.value) }
                summary["forecast_\(forecast.type ?? "nil")"] = values.joined(separator: ",")
            }
            return summary
        }
        return try OrefGoldens.canonical(summary)
    }
}

/// Golden files for the characterization suite, compared byte for byte after date normalization.
enum OrefGoldens {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Keys whose value `OpenAPS` takes from `Date()`, not from the scenario clock.
    static let wallClockKeys: Set<String> = ["deliverAt", "timestamp", "date"]

    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["TRIO_RECORD_CHARACTERIZATION"] == "1"
    }

    static var goldensDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("goldens")
    }

    static func canonical(_ value: some Encodable) throws -> String {
        ParityHarness.normalizeDeterminationId(try ParityHarness.canonicalJSON(value))
    }

    static func canonical<T: JSON>(file: String, as type: T.Type, in storage: FileStorage) throws -> String {
        guard let value = storage.retrieve(file, as: type) else {
            throw Failure("\(file) missing or undecodable")
        }
        return try canonical(value)
    }

    /// Rewrites ISO8601 dates and epoch-millisecond numbers relative to `clock`.
    static func normalize(_ json: String, clock: Date) throws -> String {
        var output = json
        let isoPattern = #""([A-Za-z_]+)" : "(\d{4}-\d{2}-\d{2}T[0-9:.]+Z)""#
        let msPattern = #""([A-Za-z_]+)" : (1\d{12}(?:\.\d+)?)"#
        output = try replace(isoPattern, in: output) { key, raw in
            guard let date = Formatter.iso8601withFractionalSeconds.date(from: raw) ?? Formatter.iso8601.date(from: raw)
            else { throw Failure("unparsable date \(raw)") }
            return "\"\(key)\" : \"\(try relative(date, key: key, clock: clock))\""
        }
        output = try replace(msPattern, in: output) { key, raw in
            guard let milliseconds = Double(raw) else { throw Failure("unparsable number \(raw)") }
            let date = Date(timeIntervalSince1970: milliseconds / 1000)
            return "\"\(key)\" : \"\(try relative(date, key: key, clock: clock))\""
        }
        return output
    }

    private static func relative(_ date: Date, key: String, clock: Date) throws -> String {
        let offset = date.timeIntervalSince(clock)
        if wallClockKeys.contains(key), offset > -1, offset < 120 {
            return "<now>"
        }
        let milliseconds = Int((offset * 1000).rounded())
        return "clock\(milliseconds >= 0 ? "+" : "")\(milliseconds)ms"
    }

    private static func replace(
        _ pattern: String,
        in string: String,
        with transform: (String, String) throws -> String
    ) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        var result = string
        let matches = regex.matches(in: string, range: NSRange(string.startIndex..., in: string))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: string),
                  let key = Range(match.range(at: 1), in: string),
                  let value = Range(match.range(at: 2), in: string)
            else { continue }
            result.replaceSubrange(whole, with: try transform(String(string[key]), String(string[value])))
        }
        return result
    }

    static func check(
        _ json: String,
        clock: Date,
        scenario: String,
        stage: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let actual = try normalize(json, clock: clock)
        let url = goldensDirectory.appendingPathComponent(scenario).appendingPathComponent("\(stage).json")
        if isRecording {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let golden = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("missing golden \(scenario)/\(stage).json", sourceLocation: sourceLocation)
            return
        }
        if actual != golden {
            let actualURL = url.deletingLastPathComponent().appendingPathComponent("actual-\(stage).json")
            try? actual.write(to: actualURL, atomically: true, encoding: .utf8)
            Issue.record(
                "\(scenario)/\(stage) differs from golden; actual written to \(actualURL.path)",
                sourceLocation: sourceLocation
            )
        }
    }
}
