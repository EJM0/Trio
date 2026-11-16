import Combine
import CoreData
import Foundation
import LoopKitUI
import Swinject
import Testing
@testable import Trio

/// Goldens for the bolus calculator math, recorded through `BaseBolusCalculationManager` with a pump
/// that rounds down to 0.05 U. Dates are relative to the time of the run; edges are at least 10 s away.
@Suite("Bolus calculator characterization goldens", .serialized) struct BolusCalculatorCharacterizationTests {
    struct Case {
        var carbs: Decimal = 0
        var currentBG: Decimal = 180
        var deltaBG: Decimal = 5
        var target: Decimal = 100
        var isf: Decimal = 40
        var carbRatio: Decimal = 10
        var iob: Decimal = 1
        var cob: Int16 = 20
        var useFattyMealCorrectionFactor = false
        var fattyMealFactor: Decimal = 0.7
        var useSuperBolus = false
        var sweetMealFactor: Decimal = 2
        var basal: Decimal = 1.5
        var fraction: Decimal = 0.8
        var maxBolus: Decimal = 10
        var maxIOB: Decimal = 15
        var maxCOB: Decimal = 120
        var minPredBG: Decimal = 80
        var lastLoopMinutesAgo: Double = 3

        func input(now: Date) -> CalculationInput {
            CalculationInput(
                carbs: carbs,
                currentBG: currentBG,
                deltaBG: deltaBG,
                target: target,
                isf: isf,
                carbRatio: carbRatio,
                iob: iob,
                cob: cob,
                useFattyMealCorrectionFactor: useFattyMealCorrectionFactor,
                fattyMealFactor: fattyMealFactor,
                useSuperBolus: useSuperBolus,
                sweetMealFactor: sweetMealFactor,
                basal: basal,
                fraction: fraction,
                maxBolus: maxBolus,
                maxIOB: maxIOB,
                maxCOB: maxCOB,
                minPredBG: minPredBG,
                lastLoopDate: now.addingTimeInterval(-lastLoopMinutesAgo * 60)
            )
        }
    }

    static let cases: [String: Case] = [
        "standard-meal": Case(carbs: 80),
        "fatty-meal": Case(carbs: 80, useFattyMealCorrectionFactor: true),
        "super-bolus": Case(carbs: 80, useSuperBolus: true),
        "fatty-meal-and-super-bolus": Case(carbs: 80, useFattyMealCorrectionFactor: true, useSuperBolus: true),
        // ISF, CR and target as an active override (125 %) leaves them in the determination
        "override-adjusted": Case(carbs: 45, currentBG: 160, target: 90, isf: 32, carbRatio: 8, fraction: 1),
        "glucose-below-54": Case(carbs: 40, currentBG: 53, deltaBG: -3),
        "glucose-at-54": Case(carbs: 40, currentBG: 54, deltaBG: -3),
        "min-predicted-below-54": Case(carbs: 40, minPredBG: 53),
        "min-predicted-at-54": Case(carbs: 40, minPredBG: 54),
        "loop-stale": Case(carbs: 40, lastLoopMinutesAgo: 15 + 10.0 / 60),
        "loop-just-fresh": Case(carbs: 40, lastLoopMinutesAgo: 15 - 10.0 / 60),
        "cob-capped-at-max-cob": Case(carbs: 50, cob: 100),
        "iob-above-max-iob": Case(carbs: 40, iob: 16),
        "negative-correction": Case(currentBG: 90, deltaBG: -5, iob: 3, cob: 0),
        "negative-correction-with-super-bolus": Case(currentBG: 90, deltaBG: -5, iob: 3, cob: 0, useSuperBolus: true),
        "negative-correction-fatty-meal": Case(currentBG: 90, deltaBG: -5, iob: 3, cob: 0, useFattyMealCorrectionFactor: true),
        "no-glucose": Case(carbs: 30, currentBG: 0, deltaBG: 0),
        "flat-delta": Case(carbs: 30, deltaBG: 0),
        "falling-delta": Case(carbs: 30, deltaBG: -15),
        "max-bolus-cap": Case(carbs: 200, iob: 0, maxCOB: 250),
        "max-iob-cap": Case(carbs: 60, maxIOB: 4),
        "rounding-down-to-increment": Case(
            carbs: Decimal(string: "23.7")!,
            currentBG: 100,
            deltaBG: 0,
            iob: 0,
            cob: 0,
            fraction: 1
        ),
        "repeating-decimals": Case(
            carbs: 31,
            currentBG: 167,
            deltaBG: 7,
            isf: 37,
            carbRatio: 7,
            iob: Decimal(string: "0.35")!,
            cob: 11
        )
    ]

    static var goldenURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("goldens/bolus-calculator.json")
    }

    /// Stands in for a pump's `roundToSupportedBolusVolume`: down to 0.05 U.
    static func roundDownToPodIncrement(_ amount: Decimal) -> Decimal {
        var scaled = amount * 20
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .down)
        return rounded / 20
    }

    static func summary(_ result: CalculationResult) -> [String: String] {
        [
            "insulinCalculated": "\(result.insulinCalculated)",
            "factoredInsulin": "\(result.factoredInsulin)",
            "wholeCalc": "\(result.wholeCalc)",
            "iobInsulinReduction": "\(result.iobInsulinReduction)",
            "superBolusInsulin": "\(result.superBolusInsulin)",
            "targetDifference": "\(result.targetDifference)",
            "targetDifferenceInsulin": "\(result.targetDifferenceInsulin)",
            "fifteenMinutesInsulin": "\(result.fifteenMinutesInsulin)",
            "wholeCob": "\(result.wholeCob)",
            "wholeCobInsulin": "\(result.wholeCobInsulin)"
        ]
    }

    static func manager() -> BaseBolusCalculationManager {
        let resolver = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly()
        ]).resolver
        (resolver as! Container).register(APSManager.self) { _ in RoundingAPSManagerStub() }
        return BaseBolusCalculationManager(resolver: resolver)
    }

    @Test("manager matches the golden") func managerMatchesGolden() async throws {
        let manager = Self.manager()
        var actual: [String: [String: String]] = [:]
        for (name, testCase) in Self.cases {
            actual[name] = Self.summary(await manager.calculateInsulin(input: testCase.input(now: Date())))
        }
        try GoldenFile.check(actual, at: Self.goldenURL)
    }

    @Test("glucose variables match the golden") func glucoseVariablesMatchGolden() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        let manager = Self.manager()
        let now = Date()
        // newest first, as fetched; minutes ago, nil for a reading without a date
        let cases: [String: [(minutesAgo: Double?, glucose: Int16)]] = [
            "none": [],
            "one-fresh": [(2, 120)],
            "window-of-four": [(0.5, 140), (5.5, 132), (10.5, 125), (15.5, 118)],
            "edge-inside": [(1, 150), (20 - 10.0 / 60, 130)],
            "edge-outside": [(1, 150), (20 + 10.0 / 60, 130)],
            "latest-stale": [(25, 99), (30, 101), (35, 104)],
            "latest-without-date": [(nil, 77), (3, 90), (8, 95)],
            "falling": [(1, 80), (6, 95), (11, 110)]
        ]
        var actual: [String: [String: String]] = [:]
        for (name, readings) in cases {
            actual[name] = await context.perform {
                let objects = readings.map { reading -> GlucoseStored in
                    let object = GlucoseStored(context: context)
                    object.date = reading.minutesAgo.map { now.addingTimeInterval(-$0 * 60) }
                    object.glucose = reading.glucose
                    return object
                }
                let variables = manager.updateGlucoseVariables(with: objects)
                return ["currentBG": "\(variables.currentBG)", "deltaBG": "\(variables.deltaBG)"]
            }
        }
        try GoldenFile.check(
            actual,
            at: Self.goldenURL.deletingLastPathComponent().appendingPathComponent("bolus-calculator-glucose.json")
        )
    }
}

/// A golden JSON file compared byte for byte; `TRIO_RECORD_CHARACTERIZATION=1` records it.
enum GoldenFile {
    static func check(_ value: some Encodable, at url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let actual = String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
        if OrefGoldens.isRecording {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
            Issue.record("golden recorded at \(url.lastPathComponent); re-run without TRIO_RECORD_CHARACTERIZATION to compare")
            return
        }
        let golden = try String(contentsOf: url, encoding: .utf8)
        #expect(actual == golden, "differs from \(url.lastPathComponent):\n\(actual)", sourceLocation: sourceLocation)
    }
}

/// Only `roundBolus` is used by the calculator.
final class RoundingAPSManagerStub: APSManager {
    func heartbeat(date _: Date) {}
    func markNextLoopUserInitiated() {}
    func enactBolus(amount _: Double, isSMB _: Bool, callback _: ((Bool, String) -> Void)?) async {}
    var pumpManager: PumpManagerUI?
    var bluetoothManager: BluetoothStateManager? { nil }
    let pumpDisplayState = CurrentValueSubject<PumpDisplayState?, Never>(nil)
    let pumpName = CurrentValueSubject<String, Never>("")
    let isLooping = CurrentValueSubject<Bool, Never>(false)
    var lastLoopDate: Date { .distantPast }
    let lastLoopDateSubject = PassthroughSubject<Date, Never>()
    let bolusProgress = CurrentValueSubject<Decimal?, Never>(nil)
    let pumpExpiresAtDate = CurrentValueSubject<Date?, Never>(nil)
    let pumpActivatedAtDate = CurrentValueSubject<Date?, Never>(nil)
    var isManualTempBasal: Bool { false }
    var isScheduledBasal: Bool? { nil }
    var isSuspended: Bool { false }
    func determineBasal() async throws {}
    func determineBasalSync() async throws {}
    func simulateDetermineBasal(
        simulatedCarbsAmount _: Decimal,
        simulatedBolusAmount _: Decimal,
        simulatedCarbsDate _: Date?
    ) async -> Determination? { nil }
    func roundBolus(amount: Decimal) -> Decimal { BolusCalculatorCharacterizationTests.roundDownToPodIncrement(amount) }
    let lastError = CurrentValueSubject<Error?, Never>(nil)
    func cancelBolus(_: ((Bool, String) -> Void)?) async {}
    let iobFileDidUpdate = PassthroughSubject<Void, Never>()
}
