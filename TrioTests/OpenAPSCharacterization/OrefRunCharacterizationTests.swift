import Foundation
import Testing
@testable import Trio

/// The production-path goldens, reproduced by `OrefRun.run` from the same scenario values. Inputs are
/// selected and mapped with the shared `OrefInputs` rules, as another store would, and cross a JSON round trip first.
@Suite(
    "OrefRun characterization goldens",
    .serialized,
    .enabled(if: !OrefGoldens.isRecording, "goldens are recorded from the production path only")
) struct OrefRunCharacterizationTests {
    static let scenarioNames = OrefCharacterizationScenarios.allNames.filter { $0 != "simulation" }

    @Test(
        "OrefRun matches the production golden",
        arguments: scenarioNames
    ) func orefRunMatchesGolden(scenarioName: String) throws {
        let clock = OrefCharacterizationScenarios.makeClock()
        let scenario = OrefCharacterizationScenarios.build(scenarioName, clock: clock)
        let inputs: OrefInputs = try Self.roundTrip(try Self.inputs(for: scenario))

        let outputs = try OrefRun.run(inputs)

        for (stage, json) in try Self.stages(outputs, clock: clock) {
            try OrefGoldens.check(json, clock: clock, scenario: scenarioName, stage: stage)
        }
    }

    /// The outputs as the production goldens hold them.
    static func stages(_ outputs: OrefRun.Outputs, clock: Date) throws -> [(String, String)] {
        let determination = try #require(outputs.determination)
        // cob.json as OpenAPS writes it, rebased from deliverAt onto the clock like the production golden
        let cob = (determination.cobProjection ?? []).enumerated().map { index, cob in
            CobEntry(cob: cob, time: clock.addingTimeInterval(Double(index) * 300))
        }

        // the profile, autosens and iob goldens were read back from their files
        return [
            ("pumpprofile", try OrefGoldens.canonical(roundTrip(outputs.pumpProfile))),
            ("profile", try OrefGoldens.canonical(roundTrip(outputs.profile))),
            ("autosens", try OrefGoldens.canonical(roundTrip(outputs.autosens))),
            ("trio_custom_oref_variables", try OrefGoldens.canonical(roundTrip(outputs.trioCustomOrefVariables))),
            ("iob", try OrefGoldens.canonical(roundTrip(outputs.iob))),
            ("cob", try OrefGoldens.canonical(roundTrip(cob))),
            ("determination", try OrefGoldens.canonical(determination))
        ]
    }

    static func roundTrip<T: Codable>(_ value: T) throws -> T {
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

        let glucose = OrefInputs.glucose(
            scenario.glucose.map {
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
            },
            since: OrefInputs.glucoseStart(hours: OrefInputs.autosensGlucoseHours, now: clock)
        )

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
        let pumpHistory = OrefInputs.algorithmPumpEvents(
            stored,
            type: { $0.type },
            timestamp: { $0.date },
            isScheduledBasal: { _ in false },
            now: clock
        ).flatMap {
            OrefInputs.pumpHistoryEvents(id: $0.id, timestamp: $0.date, type: $0.type, bolus: $0.bolus, tempBasal: $0.tempBasal)
        }

        let carbs = OrefInputs.carbs(
            scenario.carbs
                .map { OrefInputs.carbsEntry(id: $0.id, date: $0.date, carbs: $0.carbs, fat: 0, protein: 0, isFPU: false) },
            now: clock,
            timeZone: TimeZone.current
        )

        let tddRows = scenario.tdd.map { OrefInputs.TDDRow(date: $0.date, total: $0.total) }

        return try OrefInputs(
            pumpSettings: settings(OpenAPS.Settings.settings),
            bgTargets: settings(OpenAPS.Settings.bgTargets),
            basalProfile: settings(OpenAPS.Settings.basalProfile),
            insulinSensitivities: settings(OpenAPS.Settings.insulinSensitivities),
            carbRatios: settings(OpenAPS.Settings.carbRatios),
            tempTargets: settings(OpenAPS.Settings.tempTargets),
            preferences: scenario.preferences.map { try JSONBridge.from(string: $0.rawJSON) },
            dosingMode: scenario.dosingMode,
            microBolusAllowed: true,
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
                    advancedSettings: $0.advancedSettings,
                    isfAndCr: $0.isfAndCr,
                    isf: $0.isf,
                    cr: $0.cr,
                    smbIsScheduledOff: $0.smbIsScheduledOff,
                    start: $0.start,
                    end: $0.end,
                    smbMinutes: $0.smbMinutes,
                    uamMinutes: $0.uamMinutes
                )
            },
            tddHistory: OrefInputs.tddHistory(tddRows, now: clock),
            hasSufficientTDD: OrefInputs.hasSufficientTDD(tddRows, now: clock),
            glucose: glucose,
            pumpHistory: pumpHistory,
            carbs: carbs,
            currentTemp: scenario.currentTemp,
            supportedBasalRates: scenario.supportedBasalRates,
            autosens: nil,
            clock: clock,
            timeZone: TimeZone.current
        )
    }
}

@Suite("OrefRun without micro boluses") struct OrefRunMicroBolusTests {
    @Test(
        "no SMB and no SMB-paired low temp; oref's normal temp instead",
        arguments: ["closed-loop-baseline", "dynisf-sufficient-tdd"]
    ) func temporaryBasalOnly(scenarioName: String) throws {
        let scenario = OrefCharacterizationScenarios.build(scenarioName, clock: OrefCharacterizationScenarios.makeClock())
        var inputs = try OrefRunCharacterizationTests.inputs(for: scenario)
        let allowed = try #require(try OrefRun.run(inputs).determination)
        // the premise: with SMBs this scenario microboluses and pairs it with a low temp
        #expect((allowed.units ?? 0) > 0)
        #expect(allowed.reason.contains("low temp"))

        inputs.microBolusAllowed = false
        let outputs = try OrefRun.run(inputs)
        let notAllowed = try #require(outputs.determination)

        #expect(notAllowed.units == nil)
        #expect(!notAllowed.reason.contains("Microbolusing"))
        #expect(!notAllowed.reason.contains("low temp"))
        #expect(notAllowed.insulinReq == allowed.insulinReq)
        #expect(notAllowed.predictions == allowed.predictions)
        // insulin required with glucose above target: a high temp, as with SMBs off
        #expect(notAllowed.duration == 30)
        #expect((notAllowed.rate ?? 0) > (outputs.profile.currentBasal ?? .greatestFiniteMagnitude))
    }
}

/// `microBolusAllowed` against trio-oref's determine-basal.js, run by `js/determine-basal-jsc.js` under
/// JavaScriptCore's `jsc` from the inputs this suite records. Each scenario runs with SMBs allowed and not.
/// JS gets `outputs.profile`, without the injected `supportedBasalRates` and `suspendOnly`; neither matters at these rates.
@Suite(
    "OrefRun micro bolus flag: oref JS parity",
    .serialized,
    .enabled(if: TimeZone.current.identifier == "Europe/Berlin", "recorded in Europe/Berlin")
) struct OrefRunMicroBolusJSParityTests {
    struct JSInputs: Encodable {
        let glucose: [BloodGlucose]
        let currenttemp: TempBasal
        let iob_data: [IobResult]
        let profile: Profile
        let autosens_data: Autosens
        let meal_data: ComputedCarbs?
        let microBolusAllowed: Bool
        let currentTime: Date
        let pumphistory: [PumpHistoryEvent]
        let preferences: Preferences
        let basalprofile: [BasalProfileEntry]
        let trio_custom_variables: TrioCustomOrefVariables
    }

    struct JSDetermination: Codable, Equatable {
        var rate: Decimal?
        var duration: Decimal?
        var units: Decimal?
        var reason: String
    }

    static let scenarioNames = [
        "smb-and-low-temp",
        "delta-below-expected-zero-temp",
        "in-range-zero-temp",
        "top-of-hour",
        "temp-mismatch"
    ]

    static func inputs(_ name: String) throws -> OrefInputs {
        let iso = ISO8601DateFormatter()
        // 12:20:10 CEST; the top-of-hour scenario runs at 12:56:10
        let clock = iso.date(from: name == "top-of-hour" ? "2026-06-15T10:56:10Z" : "2026-06-15T10:20:10Z")!
        var scenario = OrefCharacterizationScenarios.build("closed-loop-baseline", clock: clock)
        switch name {
        case "smb-and-low-temp":
            break
        case "delta-below-expected-zero-temp":
            // falling faster than expected while eventual BG stays above target, a zero temp running
            scenario.glucose = OrefCharacterizationScenarios.glucose(
                clock: clock,
                base: 195,
                tail: [205, 201, 196, 190, 183, 176]
            )
            scenario.pumpEvents.append(.tempBasal(id: "temp-zero", minutesAgo: 5 + 10.0 / 60, rate: 0, duration: 30))
            scenario.currentTemp = TempBasal(duration: 25, rate: 0, temp: .absolute, timestamp: clock)
        case "in-range-zero-temp":
            scenario.settingsFiles[OpenAPS.Settings.bgTargets] =
                #"{"units": "mg/dL", "user_preferred_units": "mg/dL", "targets": [{"low": 100, "high": 160, "start": "00:00:00", "offset": 0}]}"#
            scenario.glucose = OrefCharacterizationScenarios.glucose(
                clock: clock,
                base: 135,
                tail: [136, 136, 135, 135, 134, 134]
            )
            scenario.pumpEvents.append(.tempBasal(id: "temp-zero", minutesAgo: 5 + 10.0 / 60, rate: 0, duration: 30))
            scenario.currentTemp = TempBasal(duration: 25, rate: 0, temp: .absolute, timestamp: clock)
        case "top-of-hour":
            var preferences = try #require(scenario.preferences)
            preferences.skipNeutralTemps = true
            scenario.preferences = preferences
        case "temp-mismatch":
            // the pump runs 0.5 U/h while the history says 1.25 U/h, started 15 min ago
            scenario.pumpEvents.append(.tempBasal(id: "temp-history", minutesAgo: 15 + 10.0 / 60, rate: 1.25, duration: 30))
            scenario.currentTemp = TempBasal(duration: 15, rate: 0.5, temp: .absolute, timestamp: clock)
        default:
            preconditionFailure("unknown scenario \(name)")
        }
        return try OrefRunCharacterizationTests.inputs(for: scenario)
    }

    static func directory(_ name: String) -> URL {
        OrefGoldens.goldensDirectory.appendingPathComponent("micro-bolus-js/\(name)")
    }

    @Test("matches oref JS", arguments: scenarioNames, [true, false]) func matchesJS(
        name: String,
        microBolusAllowed: Bool
    ) throws {
        var inputs = try Self.inputs(name)
        inputs.microBolusAllowed = microBolusAllowed
        let outputs = try OrefRun.run(inputs)
        let determination = try #require(outputs.determination)
        let suffix = microBolusAllowed ? "smb-allowed" : "smb-not-allowed"

        if OrefGoldens.isRecording {
            let preferences = (inputs.preferences ?? Preferences()).clamped(for: inputs.dosingMode)
            let glucose = OrefInputs.glucose(
                inputs.glucose,
                since: OrefInputs.glucoseStart(hours: OrefInputs.determinationGlucoseHours(preferences), now: inputs.clock)
            )
            let jsInputs = JSInputs(
                glucose: glucose,
                currenttemp: inputs.currentTemp,
                iob_data: outputs.iob,
                profile: outputs.profile,
                autosens_data: outputs.autosens,
                meal_data: outputs.meal,
                microBolusAllowed: microBolusAllowed,
                currentTime: inputs.clock,
                pumphistory: inputs.pumpHistory,
                preferences: preferences,
                basalprofile: inputs.basalProfile,
                trio_custom_variables: outputs.trioCustomOrefVariables
            )
            try FileManager.default.createDirectory(at: Self.directory(name), withIntermediateDirectories: true)
            try JSONCoding.encoder.encode(jsInputs)
                .write(to: Self.directory(name).appendingPathComponent("js-inputs-\(suffix).json"))
            Issue
                .record(
                    "JS inputs recorded for \(name); run js/determine-basal-jsc.js, then re-run without TRIO_RECORD_CHARACTERIZATION"
                )
            return
        }

        let data = try Data(contentsOf: Self.directory(name).appendingPathComponent("js-determination-\(suffix).json"))
        var js = try JSONDecoder().decode(JSDetermination.self, from: data)
        var swift = JSDetermination(
            rate: determination.rate,
            duration: determination.duration,
            units: determination.units,
            reason: determination.reason
        )
        // JS gets the port's unrounded meal COB and prints it raw; the port prints it rounded.
        // Whether the port should round meal COB like meal/total.js is open (M1b re-review R2-02)
        js.reason = js.reason.replacingOccurrences(of: #"COB: [0-9.]+,"#, with: "COB: _,", options: .regularExpression)
        swift.reason = swift.reason.replacingOccurrences(of: #"COB: [0-9.]+,"#, with: "COB: _,", options: .regularExpression)
        #expect(swift == js)
    }
}
