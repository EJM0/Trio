import Foundation
import Testing
@testable import Trio

/// Goldens for schedule lookups: non-flat basal, ISF, carb ratio and target schedules at a fixed clock,
/// including clocks a few hours after both Europe/Berlin DST changes. `OpenAPS` reads `Date()`, so these
/// run through `OrefRun.run`, which takes the clock from its inputs.
@Suite(
    "OrefRun time-of-day goldens",
    .serialized,
    .enabled(if: TimeZone.current.identifier == "Europe/Berlin", "recorded in Europe/Berlin")
) struct OrefTimeOfDayCharacterizationTests {
    static let clocks: [String: String] = [
        // 07:40:10 CEST
        "time-of-day-non-flat": "2026-06-15T05:40:10Z",
        // 03:20:10 CEST, 1 h 20 min after the clocks skipped 02:00-03:00
        "time-of-day-dst-spring-forward": "2026-03-29T01:20:10Z",
        // 06:40:10 CET, 3 h 40 min after 02:00-03:00 repeated
        "time-of-day-dst-fall-back": "2026-10-25T05:40:10Z"
    ]

    static let scenarioNames = clocks.keys.sorted()

    static let nonFlatSchedules: [String: RawJSON] = [
        OpenAPS.Settings.basalProfile: """
        [{"start": "00:00:00", "minutes": 0, "rate": 0.8}, {"start": "02:00:00", "minutes": 120, "rate": 0.95},
         {"start": "03:00:00", "minutes": 180, "rate": 1.1}, {"start": "06:00:00", "minutes": 360, "rate": 1.4},
         {"start": "07:30:00", "minutes": 450, "rate": 1.2}, {"start": "12:00:00", "minutes": 720, "rate": 0.9},
         {"start": "18:00:00", "minutes": 1080, "rate": 1.0}, {"start": "22:00:00", "minutes": 1320, "rate": 0.7}]
        """,
        OpenAPS.Settings.insulinSensitivities: """
        {"units": "mg/dL", "user_preferred_units": "mg/dL", "sensitivities": [
         {"sensitivity": 60, "offset": 0, "start": "00:00:00"}, {"sensitivity": 57, "offset": 120, "start": "02:00:00"},
         {"sensitivity": 52, "offset": 180, "start": "03:00:00"}, {"sensitivity": 45, "offset": 360, "start": "06:00:00"},
         {"sensitivity": 50, "offset": 450, "start": "07:30:00"}, {"sensitivity": 55, "offset": 720, "start": "12:00:00"}]}
        """,
        OpenAPS.Settings.carbRatios: """
        {"units": "grams", "schedule": [
         {"start": "00:00:00", "offset": 0, "ratio": 12}, {"start": "02:00:00", "offset": 120, "ratio": 11},
         {"start": "03:00:00", "offset": 180, "ratio": 10}, {"start": "06:00:00", "offset": 360, "ratio": 8},
         {"start": "07:30:00", "offset": 450, "ratio": 9}, {"start": "11:00:00", "offset": 660, "ratio": 10}]}
        """,
        OpenAPS.Settings.bgTargets: """
        {"units": "mg/dL", "user_preferred_units": "mg/dL", "targets": [
         {"low": 110, "high": 110, "start": "00:00:00", "offset": 0}, {"low": 105, "high": 105, "start": "03:00:00", "offset": 180},
         {"low": 100, "high": 100, "start": "06:00:00", "offset": 360}, {"low": 95, "high": 95, "start": "07:30:00", "offset": 450},
         {"low": 110, "high": 110, "start": "22:00:00", "offset": 1320}]}
        """
    ]

    /// The closed-loop baseline at a fixed clock with non-flat schedules.
    static func scenario(_ name: String, clock: Date? = nil) -> OrefCharacterizationScenario {
        let clock = clock ?? ISO8601DateFormatter().date(from: clocks[name]!)!
        var scenario = OrefCharacterizationScenarios.build("closed-loop-baseline", clock: clock)
        scenario.settingsFiles.merge(nonFlatSchedules) { $1 }
        return scenario
    }

    @Test("OrefRun matches the time-of-day golden", arguments: scenarioNames) func matchesGolden(scenarioName: String) throws {
        let scenario = Self.scenario(scenarioName)
        let inputs = try OrefRunCharacterizationTests.roundTrip(try OrefRunCharacterizationTests.inputs(for: scenario))

        let outputs = try OrefRun.run(inputs)

        for (stage, json) in try OrefRunCharacterizationTests.stages(outputs, clock: scenario.clock) {
            try OrefGoldens.check(json, clock: scenario.clock, scenario: scenarioName, stage: stage)
        }
        if OrefGoldens.isRecording {
            Issue.record("goldens recorded for \(scenarioName); re-run without TRIO_RECORD_CHARACTERIZATION to compare")
        }
    }
}
