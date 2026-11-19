import Foundation
import LoopKit
import Testing
@testable import Trio

/// The watch's input builder against the phone's production goldens: a snapshot that crossed the wire, plus what
/// the watch recorded, must give the phone's determination byte for byte.
@Suite(
    "Watch loop input parity",
    .serialized,
    .enabled(if: !OrefGoldens.isRecording, "goldens are recorded from the production path only")
) struct WatchLoopInputsParityTests {
    static func snapshot(
        _ oref: OrefInputs,
        override: WatchLoanSnapshot.Adjustment? = nil,
        tempTarget: WatchLoanSnapshot.Adjustment? = nil
    ) -> WatchLoanSnapshot
    {
        WatchLoanSnapshot(
            versions: .init(schema: 1, protocolVersion: 1, appBuild: "1", pumpManager: "Omni", cgmManager: "G7"),
            requestID: UUID(),
            epoch: 1,
            expiresAt: oref.clock.addingTimeInterval(30),
            phoneTime: oref.clock,
            timeZoneIdentifier: oref.timeZone.identifier,
            oref: oref,
            overrideAtGrant: override,
            tempTargetAtGrant: tempTarget,
            bolusCalculator: .init(
                units: .mgdL,
                fraction: 0.7,
                fattyMealFactor: 0.7,
                sweetMealFactor: 1,
                maxCarbs: 250,
                supportedBolusVolumes: [0.05, 0.1]
            ),
            glucoseAlarms: [],
            glucoseAlarmConfiguration: GlucoseAlertConfiguration(),
            pumpExport: Data(),
            cgmExport: Data(),
            deliveryPulseUnits: 0.05,
            releaseReading: .init(units: 10, at: oref.clock)
        )
    }

    /// Through the grant's own wire format.
    static func overTheWire(_ snapshot: WatchLoanSnapshot) throws -> WatchLoanSnapshot {
        try WatchLoanSnapshot.decode(snapshot.encoded())
    }

    static func checkGoldens(_ inputs: OrefInputs, clock: Date, scenario: String) throws {
        let outputs = try OrefRun.run(inputs)
        for (stage, json) in try OrefRunCharacterizationTests.stages(outputs, clock: clock) {
            try OrefGoldens.check(json, clock: clock, scenario: scenario, stage: stage)
        }
    }

    @Test(
        "The snapshot alone gives the phone's goldens",
        arguments: OrefRunCharacterizationTests.scenarioNames
    ) func snapshotOnly(scenarioName: String) throws {
        let clock = OrefCharacterizationScenarios.makeClock()
        let scenario = OrefCharacterizationScenarios.build(scenarioName, clock: clock)
        let phone = try OrefRunCharacterizationTests.inputs(for: scenario)

        var snapshot = Self.snapshot(phone)
        snapshot.smoothGlucose = scenario.smoothGlucose
        snapshot.smoothingWindow = scenario.smoothGlucose ? Self.rawWindow(scenario) : []
        let inputs = WatchLoopInputs.orefInputs(
            snapshot: try Self.overTheWire(snapshot),
            records: WatchLoopRecords(),
            now: clock,
            currentTemp: scenario.currentTemp,
            autosens: nil,
            microBolusAllowed: true
        )

        try Self.checkGoldens(inputs, clock: clock, scenario: scenarioName)
    }

    static func rawWindow(_ scenario: OrefCharacterizationScenario) -> [WatchLoanSnapshot.RawReading] {
        scenario.glucose.map { WatchLoanSnapshot.RawReading(id: $0.id, date: $0.date, glucose: $0.glucose) }
    }

    static let rounding = NSDecimalNumberHandler(
        roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false,
        raiseOnUnderflow: false, raiseOnDivideByZero: false
    )

    @Test(
        "With smoothing on, a watch reading is smoothed with the phone's raw history, as the phone stores it"
    ) func smoothedWatchReading() throws {
        let clock = OrefCharacterizationScenarios.makeClock()
        let scenario = OrefCharacterizationScenarios.build("override-smb-off-smoothed", clock: clock)
        try #require(scenario.smoothGlucose)
        let phone = try OrefRunCharacterizationTests.inputs(for: scenario)
        var snapshot = Self.snapshot(phone)
        snapshot.smoothGlucose = true
        snapshot.smoothingWindow = Self.rawWindow(scenario)

        let later = clock.addingTimeInterval(300)
        let id = UUID()
        let reading = OrefInputs.bloodGlucose(
            id: id, date: later.addingTimeInterval(-10), glucose: 190, smoothedGlucose: nil, isManual: false,
            direction: "Flat", shouldSmoothGlucose: false, roundingBehavior: Self.rounding
        )
        var records = WatchLoopRecords()
        records.glucose = [reading]
        let watch = WatchLoopInputs.orefInputs(
            snapshot: try Self.overTheWire(snapshot),
            records: records,
            now: later,
            currentTemp: scenario.currentTemp,
            autosens: nil,
            microBolusAllowed: true
        )

        // the phone's steps: store the reading, smooth the last 24 h of CGM rows (newest 350, oldest first),
        // keep each new non-nil smoothed value, then map the rows for oref
        typealias Row = (id: UUID, date: Date, glucose: Int16, smoothed: Decimal?)
        var rows: [Row] = scenario.glucose.map { ($0.id, $0.date, $0.glucose, $0.smoothed) }
            + [(id, later.addingTimeInterval(-10), 190, nil)]
        let window = rows.enumerated().filter { $0.element.date >= later.addingTimeInterval(-86400) }
            .sorted { $0.element.date > $1.element.date }.prefix(350).reversed()
        let values = OrefInputs
            .exponentiallySmoothedGlucose(window.map { (date: Optional($0.element.date), glucose: $0.element.glucose) })
        for (entry, value) in zip(window, values) where value != nil {
            rows[entry.offset].smoothed = value
        }
        let expected = OrefInputs.glucose(
            rows.map {
                OrefInputs.bloodGlucose(
                    id: $0.id, date: $0.date, glucose: $0.glucose, smoothedGlucose: $0.smoothed, isManual: false,
                    direction: "Flat", shouldSmoothGlucose: true, roundingBehavior: Self.rounding
                )
            },
            since: OrefInputs.glucoseStart(hours: OrefInputs.autosensGlucoseHours, now: later)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(watch.glucose.count == expected.count)
        #expect(try encoder.encode(watch.glucose) == encoder.encode(expected))
        #expect(watch.glucose.first?.sgv != 190, "the watch's reading reaches oref smoothed")
    }

    @Test("Dynamic ISF's TDD sufficiency is recounted from the history each cycle, as the phone does") func sufficientTDD() throws {
        let clock = OrefCharacterizationScenarios.makeClock()
        var phone = try OrefRunCharacterizationTests.inputs(
            for: OrefCharacterizationScenarios.build("dynisf-insufficient-tdd", clock: clock)
        )
        phone.hasSufficientTDD = false
        let rows = (0 ..< OrefInputs.sufficientTDDRowCount).map {
            OrefInputs.TDDRow(date: clock.addingTimeInterval(-Double($0 * 300) - 60), total: 30)
        }
        var records = WatchLoopRecords()
        records.tddHistory = rows
        let inputs = WatchLoopInputs.orefInputs(
            snapshot: Self.snapshot(phone), records: records, now: clock,
            currentTemp: phone.currentTemp, autosens: nil, microBolusAllowed: true
        )
        #expect(inputs.hasSufficientTDD)
        let without = WatchLoopInputs.orefInputs(
            snapshot: Self.snapshot(phone), records: WatchLoopRecords(), now: clock,
            currentTemp: phone.currentTemp, autosens: nil, microBolusAllowed: true
        )
        #expect(without.hasSufficientTDD == OrefInputs.hasSufficientTDD(phone.tddHistory, now: clock))
    }

    @Test("Doses, readings and carbs the watch recorded count as if the phone had stored them") func watchRecords() throws {
        let clock = OrefCharacterizationScenarios.makeClock()
        let scenario = OrefCharacterizationScenarios.build("closed-loop-baseline", clock: clock)
        let phone = try OrefRunCharacterizationTests.inputs(for: scenario)

        // after the grant, 50 minutes ago, the watch recorded a bolus, a temp basal, ten readings and the meal
        let split = clock.addingTimeInterval(-50 * 60)
        var granted = phone
        granted.pumpHistory = phone.pumpHistory.filter { !["bolus-2", "temp-3", "_temp-3"].contains($0.id) }
        granted.glucose = phone.glucose.filter { $0.dateString < split }
        granted.carbs = phone.carbs.filter { $0.createdAt < split }

        let bolusDate = scenario.date(minutesAgo: 45 + 10.0 / 60)
        let tempDate = scenario.date(minutesAgo: 40)
        let kitEvents = [
            NewPumpEvent(
                date: bolusDate,
                dose: DoseEntry(
                    type: .bolus,
                    startDate: bolusDate,
                    endDate: bolusDate.addingTimeInterval(80),
                    value: 2.0,
                    unit: .units,
                    decisionId: nil,
                    deliveredUnits: 2.0,
                    automatic: false,
                    isMutable: false
                ),
                raw: Data("bolus-2".utf8),
                title: "Bolus"
            ),
            NewPumpEvent(
                date: tempDate,
                dose: DoseEntry(
                    type: .tempBasal,
                    startDate: tempDate,
                    endDate: tempDate.addingTimeInterval(30 * 60),
                    value: 1.25,
                    unit: .unitsPerHour,
                    decisionId: nil,
                    automatic: true,
                    isMutable: true
                ),
                raw: Data("temp-3".utf8),
                title: "Temp Basal"
            )
        ]
        var records = WatchLoopRecords()
        records.pumpHistory = kitEvents.reversed().flatMap {
            WatchLoopInputs.pumpHistoryEvents($0, storedAt: clock, bolusIncrement: Preferences().bolusIncrement)
        }
        records.glucose = phone.glucose.filter { $0.dateString >= split }
        records.carbs = phone.carbs.filter { $0.createdAt >= split }
        try #require(records.pumpHistory.count == 3 && records.glucose.count == 10 && records.carbs.count == 1)

        let inputs = WatchLoopInputs.orefInputs(
            snapshot: try Self.overTheWire(Self.snapshot(granted)),
            records: records,
            now: clock,
            currentTemp: scenario.currentTemp,
            autosens: nil,
            microBolusAllowed: true
        )

        try Self.checkGoldens(inputs, clock: clock, scenario: "closed-loop-baseline")
    }

    @Test("A kit event maps the way the phone stores it") func kitEventMapping() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ dose: DoseEntry) -> NewPumpEvent {
            NewPumpEvent(date: date, dose: dose, raw: Data("e".utf8), title: "")
        }
        let smb = WatchLoopInputs.pumpHistoryEvents(
            event(DoseEntry(
                type: .bolus,
                startDate: date,
                endDate: date,
                value: 0.33,
                unit: .units,
                decisionId: nil,
                deliveredUnits: 0.33
            )),
            storedAt: date,
            bolusIncrement: 0.05
        )
        #expect(smb.map(\.type) == [.bolus])
        #expect(smb.first?.isSMB == true)
        #expect(abs(Double(truncating: (smb.first?.amount ?? 0) as NSNumber) - 0.35) < 1E-9)

        let scheduled = WatchLoopInputs.pumpHistoryEvents(
            event(DoseEntry(type: .basal, startDate: date, endDate: date, value: 1, unit: .unitsPerHour, decisionId: nil)),
            storedAt: date,
            bolusIncrement: 0.05
        )
        #expect(scheduled.isEmpty)

        let late = WatchLoopInputs.pumpHistoryEvents(
            event(DoseEntry(suspendDate: date)),
            storedAt: date.addingTimeInterval(-60),
            bolusIncrement: 0.05
        )
        #expect(late.map(\.type) == [.pumpSuspend])
        #expect(late.first?.timestamp == date.addingTimeInterval(-60))
    }

    @Test("An override or temp target ends at its end or when cancelled on the watch") func adjustments() throws {
        let clock = OrefCharacterizationScenarios.makeClock()
        var phone = try OrefRunCharacterizationTests.inputs(
            for: OrefCharacterizationScenarios.build("override-smb-off-smoothed", clock: clock)
        )
        phone.activeTempTarget = OrefInputs.TempTargetState(target: 140, halfBasalTarget: 160)
        let snapshot = Self.snapshot(
            phone,
            override: .init(name: "Gym", startedAt: clock, endsAt: clock.addingTimeInterval(3600)),
            tempTarget: .init(name: "High", startedAt: clock, endsAt: clock.addingTimeInterval(1800))
        )
        func inputs(at now: Date, _ records: WatchLoopRecords = WatchLoopRecords()) -> OrefInputs {
            WatchLoopInputs.orefInputs(
                snapshot: snapshot,
                records: records,
                now: now,
                currentTemp: TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now),
                autosens: nil,
                microBolusAllowed: false
            )
        }

        let during = inputs(at: clock.addingTimeInterval(600))
        #expect(during.activeOverride != nil && during.activeTempTarget != nil)
        #expect(!during.microBolusAllowed)

        let afterTarget = inputs(at: clock.addingTimeInterval(1800))
        #expect(afterTarget.activeOverride != nil && afterTarget.activeTempTarget == nil)
        #expect(inputs(at: clock.addingTimeInterval(3600)).activeOverride == nil)

        var cancelled = WatchLoopRecords()
        cancelled.overrideCancelledAt = clock.addingTimeInterval(300)
        cancelled.tempTargetCancelledAt = clock.addingTimeInterval(300)
        let afterCancel = inputs(at: clock.addingTimeInterval(600), cancelled)
        #expect(afterCancel.activeOverride == nil && afterCancel.activeTempTarget == nil)
        #expect(afterCancel.tempTargets.last?.duration == 0)
    }

    @Test("Schedules are looked up in the grant's time zone") func grantTimeZone() throws {
        let clock = OrefCharacterizationScenarios.makeClock()
        var phone = try OrefRunCharacterizationTests.inputs(
            for: OrefCharacterizationScenarios.build("closed-loop-baseline", clock: clock)
        )
        phone.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var snapshot = Self.snapshot(phone)
        snapshot.timeZoneIdentifier = "America/New_York"
        let inputs = WatchLoopInputs.orefInputs(
            snapshot: snapshot,
            records: WatchLoopRecords(),
            now: clock,
            currentTemp: phone.currentTemp,
            autosens: nil,
            microBolusAllowed: true
        )
        #expect(inputs.timeZone.identifier == "America/New_York")
    }
}

@Suite("Loop glucose guard") struct LoopGlucoseGuardTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Three readings in the last hour, the newest at most 12 minutes old") func rule() {
        let dates = [now - 60, now - 360, now - 660]
        #expect(LoopGlucoseGuard.check(lastHour: dates, now: now) == nil)
        #expect(LoopGlucoseGuard.check(lastHour: Array(dates.prefix(2)), now: now) == .notEnoughReadings(count: 2))
        #expect(LoopGlucoseGuard.check(lastHour: [now - 720, now - 1000, now - 1300], now: now) == nil)
        #expect(LoopGlucoseGuard.check(lastHour: [now - 721, now - 1000, now - 1300], now: now) == .stale)
        #expect(LoopGlucoseGuard.check(lastHour: [nil, now - 1000, now - 1300], now: now) == nil)
    }

    @Test("The watch selects the last hour the way the phone's fetch does") func selection() {
        let dates = [now - 3600, now - 3601, now - 60, now - 1800]
        #expect(LoopGlucoseGuard.lastHour(dates, now: now) == [now - 60, now - 1800, now - 3600])
    }
}

@Suite("Watch loop rules") struct WatchLoopRulesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func smb(_ name: String, at date: Date, mutable: Bool) -> NewPumpEvent {
        NewPumpEvent(
            date: date,
            dose: DoseEntry(
                type: .bolus,
                startDate: date,
                endDate: date.addingTimeInterval(12),
                value: 0.3,
                unit: .units,
                decisionId: nil,
                deliveredUnits: mutable ? nil : 0.3,
                automatic: true,
                isMutable: mutable
            ),
            raw: Data(name.utf8),
            title: name
        )
    }

    private func booking(_ name: String, at date: Date) -> (String, WatchLoanStoredPumpEvent) {
        let event = smb(name, at: date, mutable: false)
        return (event.dose!.syncIdentifier!, WatchLoanStoredPumpEvent(
            record: .init(date: date, raw: event.raw, title: name, dose: event.dose!),
            storedAt: date,
            bookedIntent: true,
            acknowledged: true
        ))
    }

    @Test(
        "A late finalization of an earlier SMB never replaces a later SMB's booking; a new kit record replaces the closest"
    )  func bookingReplacement() {
        var stored: [String: WatchLoanStoredPumpEvent] = [:]
        WatchLoopInputs.store(
            [smb("earlier", at: now, mutable: true)],
            into: &stored,
            replacePendingEvents: false,
            at: now,
            pulseUnits: 0.05
        )
        let (laterKey, later) = booking("intent-later", at: now.addingTimeInterval(300))
        let (closeKey, close) = booking("intent-close", at: now.addingTimeInterval(480))
        stored[laterKey] = later
        stored[closeKey] = close

        // the earlier SMB's finalization arrives late: an update, and it started before both bookings' windows
        WatchLoopInputs.store(
            [smb("earlier", at: now, mutable: false)],
            into: &stored,
            replacePendingEvents: false,
            at: now.addingTimeInterval(600),
            pulseUnits: 0.05
        )
        #expect(stored[laterKey] != nil && stored[closeKey] != nil)

        // the kit's own record of the second booked SMB: replaces that booking and names it for the phone
        WatchLoopInputs.store(
            [smb("kit-close", at: now.addingTimeInterval(482), mutable: false)],
            into: &stored,
            replacePendingEvents: false,
            at: now.addingTimeInterval(700),
            pulseUnits: 0.05
        )
        #expect(stored[closeKey] == nil && stored[laterKey] != nil)
        let replacing = stored.values.first { $0.record.title == "kit-close" }
        #expect(replacing?.record.replacesSyncIdentifier == closeKey)
    }

    @Test("Between pump states the current temp is the newest temp of the last 20 minutes, as on the phone") func fallbackTemp() {
        func temp(_ minutesAgo: Double, rate: Decimal, duration: Int) -> [PumpHistoryEvent] {
            OrefInputs.pumpHistoryEvents(
                id: UUID().uuidString,
                timestamp: now.addingTimeInterval(-minutesAgo * 60),
                type: EventType.tempBasal.rawValue,
                bolus: nil,
                tempBasal: (duration: duration, rate: rate.nearestDouble, tempType: TempType.absolute.rawValue)
            )
        }
        let history = temp(5, rate: 2, duration: 30) + temp(15, rate: 1, duration: 30)
        let current = WatchLoopInputs.fallbackTemp(history, now: now)
        #expect(current.rate == 2 && current.duration == 25)
        let stale = WatchLoopInputs.fallbackTemp(temp(25, rate: 2, duration: 30), now: now)
        #expect(stale.rate == 0 && stale.duration == 0)
    }

    @Test("Start needs a Series 6, SE (2nd generation) or later") func supportedModels() {
        for model in ["Watch6,1", "Watch6,10", "Watch6,18", "Watch7,1", "Watch7,12"] {
            #expect(WatchLoopPolicy.isSupportedWatch(modelIdentifier: model), "\(model)")
        }
        for model in ["Watch5,4", "Watch5,9", "Watch4,1", "arm64", "Watch", ""] {
            #expect(!WatchLoopPolicy.isSupportedWatch(modelIdentifier: model), "\(model)")
        }
    }

    @Test("Micro boluses only in the foreground, as a constant") func microBolus() {
        #expect(!WatchLoopPolicy.allowsMicroBolusInBackground)
        #expect(!WatchLoopPolicy.microBolusAllowed(inForeground: false))
        #expect(WatchLoopPolicy.microBolusAllowed(inForeground: true))
    }

    @Test("Not-looping series at 20 to 120 minutes after the last confirmed cycle") func notLooping() {
        #expect(
            WatchLoopPolicy.notLoopingDates(after: now).map { $0.timeIntervalSince(now) / 60 }
                == [20, 40, 60, 80, 100, 120, 180, 240, 300, 360]
        )
    }

    @Test("The gate holds back insulin while delivery is uncertain, never reductions, and everything in Open Loop") func gate() {
        let certain = WatchDosingGate.plan(
            automation: .full,
            rate: 2,
            durationMinutes: 30,
            units: 0.3,
            scheduledBasal: 1,
            suspended: false,
            deliveryUncertain: false
        )
        #expect(certain == .init(tempBasal: .init(unitsPerHour: 2, minutes: 30), bolus: 0.3))

        let uncertainHigh = WatchDosingGate.plan(
            automation: .full,
            rate: 2,
            durationMinutes: 30,
            units: 0.3,
            scheduledBasal: 1,
            suspended: false,
            deliveryUncertain: true
        )
        #expect(uncertainHigh == .init(tempBasal: nil, bolus: nil, heldBack: [.tempAddsInsulin, .bolus]))

        let uncertainLow = WatchDosingGate.plan(
            automation: .full,
            rate: 0,
            durationMinutes: 120,
            units: nil,
            scheduledBasal: 1,
            suspended: false,
            deliveryUncertain: true
        )
        #expect(uncertainLow == .init(tempBasal: .init(unitsPerHour: 0, minutes: 120)))

        let suspended = WatchDosingGate.plan(
            automation: .full,
            rate: 0,
            durationMinutes: 30,
            units: nil,
            scheduledBasal: 1,
            suspended: true,
            deliveryUncertain: false
        )
        #expect(suspended == .init(heldBack: [.pumpSuspended]))

        let openLoop = WatchDosingGate.plan(
            automation: .off,
            rate: 0,
            durationMinutes: 30,
            units: 0.3,
            scheduledBasal: 1,
            suspended: false,
            deliveryUncertain: false
        )
        #expect(openLoop == .init(heldBack: [.automationOff]))
    }

    func intent(_ kind: WatchDoseIntent.Kind, addsInsulin: Bool = true, before: Double? = 10) -> WatchDoseIntent {
        WatchDoseIntent(id: UUID(), kind: kind, createdAt: now, epoch: 1, addsInsulin: addsInsulin, deliveredBefore: before)
    }

    @Test("An intent the kit can't settle is booked as delivered unless the odometer shows nothing moved") func resolution() {
        let bolus = intent(.bolus(units: 1, automatic: false))
        #expect(bolus.resolve(kitUncertain: true, kitBookedIt: false, deliveredNow: 11, pulseUnits: 0.05) == nil)
        #expect(bolus.resolve(kitUncertain: false, kitBookedIt: true, deliveredNow: 11, pulseUnits: 0.05) == .settledByKit)
        #expect(bolus.resolve(kitUncertain: false, kitBookedIt: false, deliveredNow: 10.04, pulseUnits: 0.05) == .notDelivered)
        #expect(bolus.resolve(kitUncertain: false, kitBookedIt: false, deliveredNow: 10.05, pulseUnits: 0.05) == .bookAsDelivered)
        #expect(bolus.resolve(kitUncertain: false, kitBookedIt: false, deliveredNow: nil, pulseUnits: 0.05) == .bookAsDelivered)

        let high = intent(.tempBasal(unitsPerHour: 3, minutes: 30))
        let low = intent(.tempBasal(unitsPerHour: 0, minutes: 30), addsInsulin: false)
        #expect(high.resolve(kitUncertain: false, kitBookedIt: false, deliveredNow: nil, pulseUnits: 0.05) == .bookAsDelivered)
        #expect(low.resolve(kitUncertain: false, kitBookedIt: false, deliveredNow: nil, pulseUnits: 0.05) == .notDelivered)
        #expect(
            intent(.suspend)
                .resolve(kitUncertain: false, kitBookedIt: false, deliveredNow: nil, pulseUnits: 0.05) == .settledByKit
        )
    }
}
