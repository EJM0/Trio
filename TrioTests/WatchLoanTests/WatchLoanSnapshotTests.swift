import CoreData
import Foundation
import LoopKit
import Swinject
import Testing

@testable import Trio

@Suite("Watch loan: grant snapshot", .serialized) struct WatchLoanSnapshotTests {
    static let appBuild = "1.0.2 (1)"
    static let requestID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    static func plist(_ configuration: SharedDeviceConfiguration) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: configuration.rawValue, format: .binary, options: 0)
    }

    /// A complete snapshot around `oref`, as the phone would send it.
    static func snapshot(
        oref: OrefInputs? = nil,
        epoch: Int64 = 3,
        now: Date = LoanFixture.now,
        glucoseAlarms: [GlucoseAlert] = []
    ) throws -> WatchLoanSnapshot {
        let clock = OrefCharacterizationScenarios.makeClock()
        let inputs = try oref ?? OrefRunCharacterizationTests.inputs(
            for: OrefCharacterizationScenarios.build("closed-loop-baseline", clock: clock)
        )
        return WatchLoanSnapshot(
            versions: WatchLoanSnapshot.Versions(
                schema: WatchLoanSnapshot.currentSchemaVersion,
                protocolVersion: WatchLoanEnvelope.currentProtocolVersion,
                appBuild: appBuild,
                pumpManager: "Omnipod-Dash",
                pumpStateVersion: 1,
                cgmManager: "G7CGMManager",
                cgmStateVersion: 1
            ),
            requestID: requestID,
            epoch: epoch,
            expiresAt: now.addingTimeInterval(WatchLoan.grantLifetime),
            phoneTime: now,
            timeZoneIdentifier: "Europe/Berlin",
            oref: inputs,
            overrideAtGrant: WatchLoanSnapshot.Adjustment(name: "Exercise", startedAt: now, endsAt: now.addingTimeInterval(3600)),
            tempTargetAtGrant: nil,
            bolusCalculator: WatchLoanSnapshot.BolusCalculatorSettings(
                units: .mgdL,
                fraction: 0.8,
                fattyMealFactor: 0.7,
                sweetMealFactor: 1,
                maxCarbs: 250,
                supportedBolusVolumes: LoanPumpDouble.onboardingSupportedBolusVolumes
            ),
            glucoseAlarms: glucoseAlarms,
            glucoseAlarmConfiguration: GlucoseAlertConfiguration(),
            pumpExport: try plist(LoanPumpDouble().exportConfiguration()),
            cgmExport: try plist(SharedDeviceConfiguration(
                managerIdentifier: "G7CGMManager",
                asOf: now,
                state: ["sensorID": "AB1234", "version": 1]
            )),
            deliveryPulseUnits: 0.05,
            releaseReading: WatchLoanSnapshot.OdometerReading(units: 10, at: now),
            podEndsAt: now.addingTimeInterval(5 * 3600),
            sensorEndsAt: now.addingTimeInterval(9 * 3600)
        )
    }

    static func expectation(now: Date = LoanFixture.now, epoch: Int64 = 3) -> WatchLoanSnapshot.Expectation {
        WatchLoanSnapshot.Expectation(
            requestID: requestID,
            epoch: epoch,
            appBuild: appBuild,
            now: now,
            timeZone: TimeZone(identifier: "Europe/Berlin")!
        )
    }

    @Test("A complete snapshot survives the wire and passes the shared validator") func roundTrip() throws {
        let sent = try Self.snapshot()
        let received = try WatchLoanSnapshot.decode(sent.encoded())
        #expect(received.missingParts.isEmpty)
        #expect(received.refusal(for: Self.expectation()) == nil)
        #expect(received.versions == sent.versions)
        #expect(received.releaseReading == sent.releaseReading)
        #expect(received.overrideAtGrant == sent.overrideAtGrant)
        #expect(received.bolusCalculator == sent.bolusCalculator)
        #expect(received.pumpExport == sent.pumpExport)
        #expect(received.oref.glucose.count == sent.oref.glucose.count)
        #expect(received.oref.pumpHistory == sent.oref.pumpHistory)
        #expect(received.podEndsSoon(now: LoanFixture.now))
        #expect(!received.sensorEndsSoon(now: LoanFixture.now))
    }

    @Test("Every missing part makes the snapshot incomplete") func completeness() throws {
        let complete = try Self.snapshot()
        let mutations: [(String, (inout WatchLoanSnapshot) -> Void)] = [
            ("basal profile", { $0.oref.basalProfile = [] }),
            ("insulin sensitivities", { $0.oref.insulinSensitivities.sensitivities = [] }),
            ("carb ratios", {
                $0.oref.carbRatios = CarbRatios(units: $0.oref.carbRatios.units, schedule: [])
            }),
            ("glucose targets", { $0.oref.bgTargets.targets = [] }),
            ("glucose", { $0.oref.glucose = [] }),
            ("supported basal rates", { $0.oref.supportedBasalRates = [] }),
            ("supported bolus volumes", { $0.bolusCalculator.supportedBolusVolumes = [] }),
            ("pump export", { $0.pumpExport = Data() }),
            ("CGM export", { $0.cgmExport = Data("not a plist".utf8) }),
            ("delivery pulse", { $0.deliveryPulseUnits = 0 }),
            ("time zone", { $0.timeZoneIdentifier = "Not/AZone" }),
            ("versions", { $0.versions.cgmManager = "" })
        ]
        for (part, mutate) in mutations {
            var snapshot = complete
            mutate(&snapshot)
            #expect(snapshot.missingParts == [part], "\(part)")
            let received = try WatchLoanSnapshot.decode(snapshot.encoded())
            #expect(received.refusal(for: Self.expectation()) == .snapshotIncomplete, "\(part)")
        }
    }

    @Test("Versions, request, epoch, clock and time zone are checked") func validator() throws {
        let snapshot = try Self.snapshot()
        var other = snapshot
        other.versions.appBuild = "1.0.3 (1)"
        #expect(other.refusal(for: Self.expectation()) == .versionMismatch)
        other = snapshot
        other.versions.protocolVersion += 1
        #expect(other.refusal(for: Self.expectation()) == .versionMismatch)
        other = snapshot
        other.versions.schema += 1
        #expect(other.refusal(for: Self.expectation()) == .versionMismatch)
        #expect(snapshot.refusal(for: Self.expectation(epoch: 4)) == .snapshotIncomplete)
        var otherRequest = Self.expectation()
        otherRequest.requestID = UUID()
        #expect(snapshot.refusal(for: otherRequest) == .snapshotIncomplete)
        #expect(snapshot.refusal(for: Self.expectation(now: LoanFixture.now.addingTimeInterval(60))) == nil)
        #expect(snapshot.refusal(for: Self.expectation(now: LoanFixture.now.addingTimeInterval(61))) == .clockOffset)
        #expect(snapshot.refusal(for: Self.expectation(now: LoanFixture.now.addingTimeInterval(-61))) == .clockOffset)
        var otherZone = Self.expectation()
        otherZone.timeZone = TimeZone(identifier: "America/New_York")!
        #expect(snapshot.refusal(for: otherZone) == .timeZoneMismatch)
    }

    /// A worst-case day: a reading every 5 min, an SMB and a new temp every cycle, 10 days of TDD rows.
    @Test("A full day fits one live message") func size() throws {
        let clock = OrefCharacterizationScenarios.makeClock()
        var inputs = try OrefRunCharacterizationTests.inputs(
            for: OrefCharacterizationScenarios.build("dynisf-sufficient-tdd", clock: clock)
        )
        let rounding = NSDecimalNumberHandler(
            roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        inputs.glucose = (0 ..< 288).map { (index: Int) -> BloodGlucose in
            let value = 100 + index % 80
            let smoothed = Decimal(value) + Decimal(string: "0.4")!
            return OrefInputs.bloodGlucose(
                id: UUID(),
                date: clock.addingTimeInterval(-Double(index) * 300),
                glucose: Int16(value),
                smoothedGlucose: smoothed,
                isManual: false,
                direction: "Flat",
                shouldSmoothGlucose: true,
                roundingBehavior: rounding
            )
        }
        inputs.pumpHistory = (0 ..< 288).flatMap { index -> [PumpHistoryEvent] in
            let date = clock.addingTimeInterval(-Double(index) * 300)
            return OrefInputs.pumpHistoryEvents(
                id: UUID().uuidString, timestamp: date, type: PumpEventStored.EventType.bolus.rawValue,
                bolus: (0.35, true, false), tempBasal: nil
            ) + OrefInputs.pumpHistoryEvents(
                id: UUID().uuidString, timestamp: date.addingTimeInterval(-1),
                type: PumpEventStored.EventType.tempBasal.rawValue,
                bolus: nil, tempBasal: (30, 1.35, PumpEventStored.TempType.absolute.rawValue)
            )
        }
        inputs.carbs = (0 ..< 8).map { index in
            OrefInputs.carbsEntry(
                id: UUID(), date: clock.addingTimeInterval(-Double(index) * 3 * 3600), carbs: 45, fat: 10, protein: 20,
                isFPU: false
            )
        }
        inputs.tddHistory = (0 ..< 2880).map { index in
            OrefInputs.TDDRow(date: clock.addingTimeInterval(-Double(index) * 300), total: Decimal(42) + Decimal(index % 97) / 10)
        }
        let alarms = GlucoseAlertType.allCases.map { GlucoseAlert(type: $0) }
        let snapshot = try Self.snapshot(oref: inputs, glucoseAlarms: alarms)

        let json = try JSONCoding.encoder.encode(snapshot)
        let wire = try snapshot.encoded()
        let envelope = try WatchLoanWire.encode(WatchLoanEnvelope(
            protocolVersion: WatchLoanEnvelope.currentProtocolVersion,
            messageID: UUID(),
            sentAt: LoanFixture.now,
            message: WatchLoanMessage(epoch: 3, kind: .grant(requestID: Self.requestID, expiresAt: LoanFixture.now))
        ))
        print("Watch loan grant size: snapshot JSON \(json.count) B, compressed \(wire.count) B, envelope \(envelope.count) B")
        #expect(wire.count + envelope.count <= WatchLoanSnapshot.grantBudgetBytes)
        #expect(try WatchLoanSnapshot.decode(wire).oref.tddHistory.count == 2880)
    }

    // MARK: The phone's gathered inputs

    static let parityScenarios = OrefCharacterizationScenarios.allNames.filter { $0 != "simulation" }

    /// The snapshot's oref inputs are what the phone's own pipeline reads: gathered from the stores, sent over the
    /// wire and run through `OrefRun`, they reproduce the production goldens.
    @Test(
        "Gathered inputs reproduce the phone's determination after the wire",
        .enabled(if: !OrefGoldens.isRecording),
        arguments: parityScenarios
    ) func gatheredInputsMatchProduction(scenarioName: String) async throws {
        let clock = OrefCharacterizationScenarios.makeClock()
        try await Self.checkEquivalence(
            OrefCharacterizationScenarios.build(scenarioName, clock: clock),
            name: scenarioName,
            goldens: true
        )
    }

    /// Non-flat schedules a few hours after each Europe/Berlin DST change (the pod's zone in the tests),
    /// compared with the phone's own pipeline on the same store and clock.
    @Test(
        "Gathered inputs match the phone's pipeline across a DST change",
        arguments: ["time-of-day-dst-spring-forward", "time-of-day-dst-fall-back"]
    ) func gatheredInputsAcrossDST(scenarioName: String) async throws {
        let scenario = OrefTimeOfDayCharacterizationTests.scenario(scenarioName)
        #expect(TimeZone.current.identifier == "Europe/Berlin")
        let window = DateInterval(start: scenario.clock.addingTimeInterval(-24 * 3600), end: scenario.clock)
        #expect(
            TimeZone.current.isDaylightSavingTime(for: window.start) != TimeZone.current
                .isDaylightSavingTime(for: window.end)
        )
        try await Self.checkEquivalence(scenario, name: scenarioName, goldens: false)
    }

    static func checkEquivalence(
        _ scenario: OrefCharacterizationScenario,
        name scenarioName: String,
        goldens: Bool
    ) async throws {
        let clock = scenario.clock
        let resolver = Assembler([
            StorageAssembly(), ServiceAssembly(), APSAssembly(), NetworkAssembly(), UIAssembly(), SecurityAssembly()
        ]).resolver
        let stack = try await CoreDataStack.createForTests()
        var contextProvider = { stack.newTaskContext() }
        if scenario.onDiskStore {
            let container = try OrefCharacterizationTests.onDiskContainer()
            contextProvider = {
                let context = container.newBackgroundContext()
                context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
                return context
            }
        }
        try await scenario.seed(into: contextProvider())
        let storage = InMemoryFileStorage()
        scenario.seed(into: storage)
        let now = { scenario.clock }
        let openAPS = OpenAPS(
            storage: storage,
            tddStorage: BaseTDDStorage(resolver: resolver, contextProvider: contextProvider, now: now),
            glucoseStorage: BaseGlucoseStorage(resolver: resolver, contextProvider: contextProvider, now: now),
            carbsStorage: BaseCarbsStorage(resolver: resolver, contextProvider: contextProvider, now: now),
            contextProvider: contextProvider,
            now: now
        )

        let gathered = try await openAPS.orefInputs(
            for: scenario.dosingMode,
            currentTemp: scenario.currentTemp,
            supportedBasalRates: scenario.supportedBasalRates,
            shouldSmoothGlucose: scenario.smoothGlucose
        )
        #expect(!gathered.glucose.isEmpty && !gathered.pumpHistory.isEmpty)
        let received = try WatchLoanSnapshot.decode(Self.snapshot(oref: gathered).encoded())
        #expect(received.missingParts.isEmpty)
        #expect(received.oref.timeZone.identifier == TimeZone.current.identifier)

        let outputs = try OrefRun.run(received.oref)
        let stages = try OrefRunCharacterizationTests.stages(outputs, clock: clock)
        if goldens {
            for (stage, json) in stages {
                try OrefGoldens.check(json, clock: clock, scenario: scenarioName, stage: stage)
            }
        }

        // and directly against the phone's own pipeline, on the same store and clock
        try await openAPS.createProfiles(for: scenario.dosingMode)
        _ = try await openAPS.autosense(shouldSmoothGlucose: scenario.smoothGlucose)
        let determination = try await openAPS.determineBasal(
            for: scenario.dosingMode,
            currentTemp: scenario.currentTemp,
            supportedBasalRates: scenario.supportedBasalRates,
            shouldSmoothGlucose: scenario.smoothGlucose,
            clock: scenario.clock
        )
        let phone: [String: String] = try [
            "pumpprofile": OrefGoldens.canonical(file: OpenAPS.Settings.pumpProfile, as: Profile.self, in: storage),
            "profile": OrefGoldens.canonical(file: OpenAPS.Settings.profile, as: Profile.self, in: storage),
            "autosens": OrefGoldens.canonical(file: OpenAPS.Settings.autosense, as: Autosens.self, in: storage),
            "trio_custom_oref_variables": OrefGoldens.canonical(
                file: OpenAPS.Monitor.trio_custom_oref_variables,
                as: TrioCustomOrefVariables.self,
                in: storage
            ),
            "iob": OrefGoldens.canonical(file: OpenAPS.Monitor.iob, as: [IobResult].self, in: storage),
            "determination": OrefGoldens.canonical(determination)
        ]
        for (stage, json) in stages {
            guard let phoneJSON = phone[stage] else { continue }
            #expect(
                try OrefGoldens.normalize(json, clock: clock) == OrefGoldens.normalize(phoneJSON, clock: clock),
                "\(scenarioName): \(stage) differs from the phone's own pipeline"
            )
        }
        #expect(phone.count == 6)
    }
}
