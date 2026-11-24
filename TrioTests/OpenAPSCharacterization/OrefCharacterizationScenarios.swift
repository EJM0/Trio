import CoreData
import Foundation
@testable import Trio

/// One characterization scenario: everything OpenAPS reads from Core Data and the settings files,
/// as plain values relative to `clock`.
///
/// Times avoid every rounding and window edge by at least 10 s. The clock is a fixed morning instant,
/// injected into `OpenAPS` and the stores, so the IOB projection never crosses local midnight.
/// Schedules are flat.
struct OrefCharacterizationScenario {
    enum PumpEvent {
        case bolus(id: String, minutesAgo: Double, amount: Double, isSMB: Bool)
        case tempBasal(id: String, minutesAgo: Double, rate: Double, duration: Int)
        case suspend(id: String, minutesAgo: Double)
        case resume(id: String, minutesAgo: Double)
    }

    struct Glucose {
        let id: UUID
        let date: Date
        let glucose: Int16
        let smoothed: Decimal?
    }

    struct Carb {
        let id: UUID
        let date: Date
        let carbs: Double
    }

    struct TDD {
        let date: Date
        let total: Decimal
    }

    struct ActiveTempTarget {
        let date: Date
        let duration: Decimal
        let target: Decimal
        let halfBasalTarget: Decimal?
    }

    struct ActiveOverride {
        let date: Date
        let percentage: Double
        let target: Decimal?
        let duration: Decimal?
        let indefinite: Bool
        let smbIsOff: Bool
        let isfAndCr: Bool
        let isf: Bool
        let cr: Bool
        var advancedSettings = false
        var smbIsScheduledOff = false
        var start: Decimal?
        var end: Decimal?
        var smbMinutes: Decimal?
        var uamMinutes: Decimal?
    }

    struct Simulation {
        let carbs: Decimal
        let carbsDate: Date
        let bolus: Decimal
    }

    let name: String
    let clock: Date
    var dosingMode: DosingMode = .closed
    var smoothGlucose = false
    /// Raw settings files by name; a missing file falls back to the bundled default, as in production.
    var settingsFiles: [String: RawJSON]
    var preferences: Preferences?
    var glucose: [Glucose]
    var pumpEvents: [PumpEvent]
    var carbs: [Carb]
    var tdd: [TDD]
    var tempTarget: ActiveTempTarget?
    var override: ActiveOverride?
    var currentTemp: TempBasal
    var supportedBasalRates: [Decimal]
    var simulation: Simulation?
    /// Seeds an on-disk SQLite store instead of the in-memory one.
    var onDiskStore = false

    func date(minutesAgo: Double) -> Date {
        clock.addingTimeInterval(-minutesAgo * 60)
    }
}

enum OrefCharacterizationScenarios {
    static let allNames = [
        "closed-loop-baseline",
        "temp-target-custom-hbt",
        "temp-target-standard-adjusted-hbt",
        "dynisf-insufficient-tdd",
        "dynisf-sufficient-tdd",
        "override-smb-off-smoothed",
        "low-glucose-suspend",
        "low-glucose-suspend-high",
        "basal-testing-suspend-only",
        "basal-testing-dynisf-on",
        "defaults-no-settings",
        "simulation",
        "autosens-8h-24h-differ",
        "carbs-glucose-window-gap",
        "override-advanced",
        "suspend-resume-same-instant",
        "suspend-resume-same-instant-on-disk"
    ]

    /// 07:40:10 CEST, whole seconds, so every fixture date survives the millisecond ISO8601 round trip.
    static func makeClock() -> Date {
        ISO8601DateFormatter().date(from: "2026-06-15T05:40:10Z")!
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func build(_ name: String, clock: Date) -> OrefCharacterizationScenario {
        var preferences = Preferences()
        preferences.maxIOB = 6
        preferences.enableSMBAlways = true
        preferences.enableUAM = true

        let settingsFiles: [String: RawJSON] = [
            OpenAPS.Settings.settings: #"{"insulin_action_curve": 10, "maxBolus": 10, "maxBasal": 3}"#,
            OpenAPS.Settings.bgTargets:
                #"{"units": "mg/dL", "user_preferred_units": "mg/dL", "targets": [{"low": 100, "high": 100, "start": "00:00:00", "offset": 0}]}"#,
            OpenAPS.Settings.insulinSensitivities:
                #"{"units": "mg/dL", "user_preferred_units": "mg/dL", "sensitivities": [{"sensitivity": 50, "offset": 0, "start": "00:00:00"}]}"#,
            OpenAPS.Settings.carbRatios: #"{"units": "grams", "schedule": [{"start": "00:00:00", "offset": 0, "ratio": 10}]}"#,
            OpenAPS.Settings.basalProfile: #"[{"start": "00:00:00", "minutes": 0, "rate": 1.0}]"#,
            OpenAPS.Settings.tempTargets: "[]"
        ]
        let pumpEvents: [OrefCharacterizationScenario.PumpEvent] = [
            // no suspend in the 48 h before it: an orphaned resume, dropped from history
            .resume(id: "resume-orphan", minutesAgo: 1200),
            .suspend(id: "suspend-1", minutesAgo: 360),
            .resume(id: "resume-1", minutesAgo: 330),
            .bolus(id: "bolus-1", minutesAgo: 185, amount: 1.5, isSMB: false),
            .tempBasal(id: "temp-1", minutesAgo: 160, rate: 1.5, duration: 30),
            .bolus(id: "smb-1", minutesAgo: 130, amount: 0.5, isSMB: true),
            .tempBasal(id: "temp-2", minutesAgo: 100, rate: 0.5, duration: 30),
            .bolus(id: "bolus-2", minutesAgo: 45 + 10.0 / 60, amount: 2.0, isSMB: false),
            .tempBasal(id: "temp-3", minutesAgo: 40, rate: 1.25, duration: 30),
            .bolus(id: "smb-2", minutesAgo: 20 + 10.0 / 60, amount: 0.25, isSMB: true)
        ]
        let carbs = [OrefCharacterizationScenario.Carb(id: uuid(1), date: clock.addingTimeInterval(-(45 * 60 + 10)), carbs: 30)]
        // no temp running, as APSManager reports it
        let currentTemp = TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: clock)
        let supportedBasalRates: [Decimal] = (0 ... 60).map { Decimal($0) / 20 }

        var scenario = OrefCharacterizationScenario(
            name: name,
            clock: clock,
            settingsFiles: settingsFiles,
            preferences: preferences,
            glucose: glucose(clock: clock, base: 120, tail: [128, 134, 141, 147, 152, 158]),
            pumpEvents: pumpEvents,
            carbs: carbs,
            tdd: tdd(clock: clock, count: 30, base: 30),
            currentTemp: currentTemp,
            supportedBasalRates: supportedBasalRates
        )

        switch name {
        case "closed-loop-baseline":
            break
        case "temp-target-custom-hbt":
            preferences.highTemptargetRaisesSensitivity = true
            // autosensMax 1 also switches lowTemptargetLowersSensitivity off before the profile
            preferences.lowTemptargetLowersSensitivity = true
            preferences.autosensMax = 1
            scenario.preferences = preferences
            scenario.setTempTarget(minutesAgo: 20, duration: 60, target: 140, halfBasalTarget: 130)
        case "temp-target-standard-adjusted-hbt":
            preferences.highTemptargetRaisesSensitivity = true
            preferences.halfBasalExerciseTarget = 110
            scenario.preferences = preferences
            scenario.setTempTarget(minutesAgo: 25, duration: 90, target: 180, halfBasalTarget: nil)
        case "dynisf-insufficient-tdd":
            preferences.useNewFormula = true
            preferences.sigmoid = true
            preferences.adjustmentFactorSigmoid = 0.6
            scenario.preferences = preferences
        case "dynisf-sufficient-tdd":
            preferences.useNewFormula = true
            preferences.adjustmentFactor = 0.8
            preferences.weightPercentage = 0.65
            scenario.preferences = preferences
            // 7 days at 5 min, above the 75 % threshold
            scenario.tdd = tdd(clock: clock, count: 7 * 288, base: 28)
        case "override-smb-off-smoothed":
            scenario.smoothGlucose = true
            scenario.glucose = glucose(
                clock: clock,
                base: 135,
                tail: [142, 149, 155, 160, 166, 171],
                smoothedOffset: Decimal(string: "0.4")
            )
            scenario.override = OrefCharacterizationScenario.ActiveOverride(
                date: clock.addingTimeInterval(-(10 * 60 + 10)),
                percentage: 120,
                target: 95,
                duration: 60,
                indefinite: false,
                smbIsOff: true,
                isfAndCr: true,
                isf: true,
                cr: true
            )
        case "low-glucose-suspend":
            scenario.dosingMode = .lowGlucoseSuspend
            scenario.glucose = glucose(clock: clock, base: 110, tail: [104, 98, 93, 88, 84, 80])
        case "low-glucose-suspend-high":
            // Max IOB 0 from the dosing-mode clamp blocks SMBs and high temps
            scenario.dosingMode = .lowGlucoseSuspend
            scenario.glucose = glucose(clock: clock, base: 150, tail: [168, 176, 185, 193, 201, 210])
        case "basal-testing-suspend-only":
            scenario.dosingMode = .basalTesting
            scenario.glucose = glucose(clock: clock, base: 100, tail: [92, 86, 81, 77, 73, 70])
        case "basal-testing-dynisf-on":
            // Dynamic ISF on in preferences; the dosing-mode clamps keep it off
            scenario.dosingMode = .basalTesting
            preferences.useNewFormula = true
            scenario.preferences = preferences
            scenario.tdd = tdd(clock: clock, count: 7 * 288, base: 28)
            scenario.glucose = glucose(clock: clock, base: 150, tail: [168, 176, 185, 193, 201, 210])
        case "defaults-no-settings":
            scenario.settingsFiles = [:]
            scenario.preferences = nil
        case "simulation":
            scenario.simulation = OrefCharacterizationScenario.Simulation(
                carbs: 20,
                carbsDate: clock.addingTimeInterval(-70),
                bolus: 1
            )
        case "autosens-8h-24h-differ":
            // resistant over 24 h, less so over the last 8 h: the two ratios differ and neither is 1
            preferences.maxUAMSMBBasalMinutes = 90
            scenario.preferences = preferences
            scenario.carbs = []
            scenario.glucose = glucose(clock: clock) { index in
                let slope = index < 96 ? 0.5 : 3
                return 120 + Int((Double(11 - index % 12) * slope).rounded())
            }
        case "carbs-glucose-window-gap":
            // the pre-meal reading falls outside the determination's glucose window (6.5 h)
            scenario.glucose = glucose(clock: clock, base: 120, tail: [154, 158, 162, 166, 170, 174])
                .filter { $0.date >= clock.addingTimeInterval(-346 * 60) || $0.date <= clock.addingTimeInterval(-425 * 60) }
            scenario.carbs = [
                OrefCharacterizationScenario.Carb(id: uuid(1), date: clock.addingTimeInterval(-345 * 60), carbs: 200),
                // older than the window and maxMealAbsorptionTime
                OrefCharacterizationScenario.Carb(id: uuid(2), date: clock.addingTimeInterval(-420 * 60), carbs: 20)
            ]
        case "override-advanced":
            preferences.maxSMBBasalMinutes = 30
            preferences.maxUAMSMBBasalMinutes = 90
            scenario.preferences = preferences
            scenario.glucose = glucose(clock: clock, base: 150, tail: [168, 176, 185, 193, 201, 210])
            var override = OrefCharacterizationScenario.ActiveOverride(
                date: clock.addingTimeInterval(-(15 * 60 + 10)),
                percentage: 110,
                target: 105,
                duration: 120,
                indefinite: false,
                smbIsOff: false,
                isfAndCr: true,
                isf: true,
                cr: true
            )
            override.advancedSettings = true
            // SMBs off for every hour [0, 24); swapping start and end turns them back on
            override.smbIsScheduledOff = true
            override.start = 0
            override.end = 24
            override.smbMinutes = 45
            override.uamMinutes = 60
            scenario.override = override
        case "suspend-resume-same-instant",
             "suspend-resume-same-instant-on-disk":
            // ties: which of the two the fetch returns first decides orphan pairing and duplicate removal
            scenario.pumpEvents += [
                // pairs the tied resume, so both reach duplicate removal, which keeps the first
                .suspend(id: "suspend-pre", minutesAgo: 100),
                .suspend(id: "suspend-tie", minutesAgo: 90 + 10.0 / 60),
                .resume(id: "resume-tie", minutesAgo: 90 + 10.0 / 60)
            ]
            scenario.onDiskStore = name.hasSuffix("on-disk")
        default:
            preconditionFailure("unknown scenario \(name)")
        }

        return scenario
    }

    /// 288 readings at 5 min, newest 2 min 10 s ago, newest first; `tail` holds the newest values, oldest first.
    static func glucose(
        clock: Date,
        base: Int,
        tail: [Int],
        smoothedOffset: Decimal? = nil
    ) -> [OrefCharacterizationScenario.Glucose] {
        (0 ..< 288).map { index in
            let value: Int
            if index < tail.count {
                value = tail[tail.count - 1 - index]
            } else {
                value = base + Int((sin(Double(index) / 12) * 9).rounded())
            }
            return OrefCharacterizationScenario.Glucose(
                id: uuid(1000 + index),
                date: clock.addingTimeInterval(-Double(130 + index * 300)),
                glucose: Int16(value),
                smoothed: smoothedOffset.map { Decimal(value) + $0 }
            )
        }
    }

    /// 288 readings at 5 min, newest 2 min 10 s ago, newest first; `value` takes the index, 0 being newest.
    static func glucose(clock: Date, value: (Int) -> Int) -> [OrefCharacterizationScenario.Glucose] {
        (0 ..< 288).map { index in
            OrefCharacterizationScenario.Glucose(
                id: uuid(1000 + index),
                date: clock.addingTimeInterval(-Double(130 + index * 300)),
                glucose: Int16(value(index)),
                smoothed: nil
            )
        }
    }

    /// TDD rows every 5 min, newest 2 min 40 s ago, oldest first.
    static func tdd(clock: Date, count: Int, base: Decimal) -> [OrefCharacterizationScenario.TDD] {
        (0 ..< count).reversed().map { index in
            OrefCharacterizationScenario.TDD(
                date: clock.addingTimeInterval(-Double(160 + index * 300)),
                total: base + Decimal(index % 7) / 4 + Decimal(string: "0.0137")!
            )
        }
    }

    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

extension OrefCharacterizationScenario {
    mutating func setTempTarget(minutesAgo: Double, duration: Decimal, target: Decimal, halfBasalTarget: Decimal?) {
        let date = clock.addingTimeInterval(-(minutesAgo * 60 + 10))
        tempTarget = ActiveTempTarget(date: date, duration: duration, target: target, halfBasalTarget: halfBasalTarget)
        settingsFiles[OpenAPS.Settings.tempTargets] = [TempTarget(
            id: "tt-1",
            name: "Characterization",
            createdAt: date,
            targetTop: target,
            targetBottom: target,
            duration: duration,
            enteredBy: TempTarget.local,
            reason: "Characterization",
            isPreset: false,
            enabled: true,
            halfBasalTarget: halfBasalTarget
        )].rawJSON
    }

    /// Writes the Core Data side of the scenario.
    func seed(into context: NSManagedObjectContext) async throws {
        try await context.perform {
            for reading in glucose {
                let object = GlucoseStored(context: context)
                object.id = reading.id
                object.date = reading.date
                object.glucose = reading.glucose
                object.smoothedGlucose = reading.smoothed.map { NSDecimalNumber(decimal: $0) }
                object.isManual = false
                object.direction = "Flat"
            }

            for event in pumpEvents {
                let stored = PumpEventStored(context: context)
                switch event {
                case let .bolus(id, minutesAgo, amount, isSMB):
                    stored.id = id
                    stored.timestamp = date(minutesAgo: minutesAgo)
                    stored.type = PumpEventStored.EventType.bolus.rawValue
                    let bolus = BolusStored(context: context)
                    bolus.amount = NSDecimalNumber(value: amount)
                    bolus.isSMB = isSMB
                    bolus.isExternal = false
                    bolus.pumpEvent = stored
                case let .tempBasal(id, minutesAgo, rate, duration):
                    stored.id = id
                    stored.timestamp = date(minutesAgo: minutesAgo)
                    stored.type = PumpEventStored.EventType.tempBasal.rawValue
                    let tempBasal = TempBasalStored(context: context)
                    tempBasal.rate = NSDecimalNumber(value: rate)
                    tempBasal.duration = Int16(duration)
                    tempBasal.tempType = TempType.absolute.rawValue
                    tempBasal.pumpEvent = stored
                case let .suspend(id, minutesAgo):
                    stored.id = id
                    stored.timestamp = date(minutesAgo: minutesAgo)
                    stored.type = PumpEventStored.EventType.pumpSuspend.rawValue
                case let .resume(id, minutesAgo):
                    stored.id = id
                    stored.timestamp = date(minutesAgo: minutesAgo)
                    stored.type = PumpEventStored.EventType.pumpResume.rawValue
                }
                // one save per event, so the store's row order follows the list
                try context.save()
            }

            for carb in carbs {
                let object = CarbEntryStored(context: context)
                object.id = carb.id
                object.date = carb.date
                object.carbs = carb.carbs
                object.fat = 0
                object.protein = 0
                object.isFPU = false
            }

            for row in tdd {
                let object = TDDStored(context: context)
                object.id = UUID()
                object.date = row.date
                object.total = NSDecimalNumber(decimal: row.total)
                object.bolus = 0
                object.tempBasal = 0
                object.scheduledBasal = 0
            }

            if let tempTarget {
                let object = TempTargetStored(context: context)
                object.id = UUID()
                object.date = tempTarget.date
                object.duration = NSDecimalNumber(decimal: tempTarget.duration)
                object.target = NSDecimalNumber(decimal: tempTarget.target)
                object.halfBasalTarget = tempTarget.halfBasalTarget.map { NSDecimalNumber(decimal: $0) }
                object.enabled = true
                object.isPreset = false
            }

            if let override {
                let object = OverrideStored(context: context)
                object.id = UUID().uuidString
                object.date = override.date
                object.enabled = true
                object.percentage = override.percentage
                object.target = override.target.map { NSDecimalNumber(decimal: $0) }
                object.duration = override.duration.map { NSDecimalNumber(decimal: $0) }
                object.indefinite = override.indefinite
                object.smbIsOff = override.smbIsOff
                object.isfAndCr = override.isfAndCr
                object.isf = override.isf
                object.cr = override.cr
                object.advancedSettings = override.advancedSettings
                object.smbIsScheduledOff = override.smbIsScheduledOff
                object.start = override.start.map { NSDecimalNumber(decimal: $0) }
                object.end = override.end.map { NSDecimalNumber(decimal: $0) }
                object.smbMinutes = override.smbMinutes.map { NSDecimalNumber(decimal: $0) }
                object.uamMinutes = override.uamMinutes.map { NSDecimalNumber(decimal: $0) }
            }

            try context.save()
        }
    }

    /// Writes the settings-file side of the scenario.
    func seed(into storage: FileStorage) {
        for (name, raw) in settingsFiles {
            storage.save(raw, as: name)
        }
        if let preferences {
            storage.save(preferences, as: OpenAPS.Settings.preferences)
        }
    }
}
