import Foundation
import Testing
@testable import Trio

/// The production-path goldens, reproduced by `OrefRun.run` from the same scenario values. Inputs are
/// built with the shared `OrefInputs` mappers, as another store would, and cross a JSON round trip first.
@Suite(
    "OrefRun characterization goldens",
    .serialized,
    .enabled(if: !OrefGoldens.isRecording, "goldens are recorded from the production path only")
) struct OrefRunCharacterizationTests {
    static let scenarioNames = OrefCharacterizationScenarios.allNames.filter { $0 != "simulation" }

    @Test(
        "OrefRun matches the production golden",
        arguments: scenarioNames
    )  func orefRunMatchesGolden(scenarioName: String) throws {
        let clock = OrefCharacterizationScenarios.makeClock()
        let scenario = OrefCharacterizationScenarios.build(scenarioName, clock: clock)
        let inputs: OrefInputs = try roundTrip(try Self.inputs(for: scenario))

        let outputs = try OrefRun.run(inputs)

        let determination = try #require(outputs.determination)
        // cob.json as OpenAPS writes it, rebased from deliverAt onto the clock like the production golden
        let cob = (determination.cobProjection ?? []).enumerated().map { index, cob in
            CobEntry(cob: cob, time: clock.addingTimeInterval(Double(index) * 300))
        }

        // the profile, autosens and iob goldens were read back from their files
        let stages: [(String, String)] = [
            ("pumpprofile", try OrefGoldens.canonical(roundTrip(outputs.pumpProfile))),
            ("profile", try OrefGoldens.canonical(roundTrip(outputs.profile))),
            ("autosens", try OrefGoldens.canonical(roundTrip(outputs.autosens))),
            ("trio_custom_oref_variables", try OrefGoldens.canonical(roundTrip(outputs.trioCustomOrefVariables))),
            ("iob", try OrefGoldens.canonical(roundTrip(outputs.iob))),
            ("cob", try OrefGoldens.canonical(roundTrip(cob))),
            ("determination", try OrefGoldens.canonical(determination))
        ]
        for (stage, json) in stages {
            try OrefGoldens.check(json, clock: clock, scenario: scenarioName, stage: stage)
        }
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: JSONCoding.encoder.encode(value))
    }

    /// What the phone gathers from Core Data and the settings files, built from the scenario values.
    static func inputs(for scenario: OrefCharacterizationScenario) throws -> OrefInputs {
        func settings<T: Decodable>(_ name: String) throws -> T {
            try JSONBridge.from(string: scenario.settingsFiles[name] ?? OpenAPS.defaults(for: name))
        }
        let clock = scenario.clock
        let rounding = NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )

        let glucose = scenario.glucose
            .sorted { $0.date > $1.date }
            .map {
                OrefInputs.bloodGlucose(
                    id: $0.id,
                    date: $0.date,
                    glucose: $0.glucose,
                    smoothedGlucose: $0.smoothed,
                    isManual: false,
                    direction: "Flat",
                    shouldSmoothGlucose: scenario.smoothGlucose,
                    roundingBehavior: rounding
                )
            }

        typealias StoredEvent = (
            id: String,
            date: Date,
            type: String,
            bolus: (amount: Double?, isSMB: Bool, isExternal: Bool)?,
            tempBasal: (duration: Int, rate: Double?, tempType: String?)?
        )
        let stored: [StoredEvent] = scenario.pumpEvents.map { event in
            switch event {
            case let .bolus(id, minutesAgo, amount, isSMB):
                return (id, scenario.date(minutesAgo: minutesAgo), EventType.bolus.rawValue, (amount, isSMB, false), nil)
            case let .tempBasal(id, minutesAgo, rate, duration):
                return (
                    id,
                    scenario.date(minutesAgo: minutesAgo),
                    EventType.tempBasal.rawValue,
                    nil,
                    (duration, rate, TempType.absolute.rawValue)
                )
            case let .suspend(id, minutesAgo):
                return (id, scenario.date(minutesAgo: minutesAgo), EventType.pumpSuspend.rawValue, nil, nil)
            case let .resume(id, minutesAgo):
                return (id, scenario.date(minutesAgo: minutesAgo), EventType.pumpResume.rawValue, nil, nil)
            }
        }
        let orphanedIDs = Set(
            OrefInputs.orphanedResumes(
                in: stored.filter { $0.date >= clock.addingTimeInterval(-TimeInterval(hours: 48)) }.sorted { $0.date < $1.date },
                type: { $0.type },
                timestamp: { $0.date }
            ).map(\.id)
        )
        let pumpHistory = stored
            .filter { $0.date >= clock.addingTimeInterval(-TimeInterval(hours: 24)) && !orphanedIDs.contains($0.id) }
            .sorted { $0.date > $1.date }
            .flatMap {
                OrefInputs.pumpHistoryEvents(
                    id: $0.id,
                    timestamp: $0.date,
                    type: $0.type,
                    bolus: $0.bolus,
                    tempBasal: $0.tempBasal
                )
            }

        let carbs = scenario.carbs
            .sorted { $0.date > $1.date }
            .map { OrefInputs.carbsEntry(id: $0.id, date: $0.date, carbs: $0.carbs, fat: 0, protein: 0, isFPU: false) }

        let tddHistory = scenario.tdd
            .filter { $0.date > clock.addingTimeInterval(-10 * 86400) && $0.total > 0 }
            .sorted { $0.date < $1.date }
            .map { OrefInputs.TDDRow(date: $0.date, total: $0.total) }
        let recentTDDCount = scenario.tdd.filter { $0.date > clock.addingTimeInterval(-7 * 86400) && $0.total > 0 }.count

        return try OrefInputs(
            pumpSettings: settings(OpenAPS.Settings.settings),
            bgTargets: settings(OpenAPS.Settings.bgTargets),
            basalProfile: settings(OpenAPS.Settings.basalProfile),
            insulinSensitivities: settings(OpenAPS.Settings.insulinSensitivities),
            carbRatios: settings(OpenAPS.Settings.carbRatios),
            tempTargets: settings(OpenAPS.Settings.tempTargets),
            preferences: scenario.preferences.map { try JSONBridge.from(string: $0.rawJSON) },
            dosingMode: scenario.dosingMode,
            activeTempTarget: scenario.tempTarget.map {
                OrefInputs.TempTargetState(target: $0.target, halfBasalTarget: $0.halfBasalTarget)
            },
            activeOverride: scenario.override.map {
                OrefInputs.OverrideState(
                    enabled: true,
                    percentage: $0.percentage,
                    indefinite: $0.indefinite,
                    smbIsOff: $0.smbIsOff,
                    target: $0.target,
                    duration: $0.duration,
                    advancedSettings: false,
                    isfAndCr: $0.isfAndCr,
                    isf: $0.isf,
                    cr: $0.cr,
                    smbIsScheduledOff: false,
                    start: nil,
                    end: nil,
                    smbMinutes: nil,
                    uamMinutes: nil
                )
            },
            tddHistory: tddHistory,
            hasSufficientTDD: recentTDDCount >= Int(Double(7 * 288) * 0.75),
            glucose: glucose,
            pumpHistory: pumpHistory,
            carbs: carbs,
            currentTemp: scenario.currentTemp,
            supportedBasalRates: scenario.supportedBasalRates,
            autosens: nil,
            clock: clock
        )
    }
}
