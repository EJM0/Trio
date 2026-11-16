import CoreData
import Foundation
import LoopKit
import Swinject
import Testing

@testable import Trio

/// The watch's reimplementations against the phone's real code on an in-memory store: pump events, glucose
/// smoothing and the TDD sufficiency count.
@Suite("Watch loop equivalence with the phone's stores", .serialized) struct WatchLoopPhoneEquivalenceTests: Injectable {
    @Injected() var storage: PumpHistoryStorage!
    @Injected() var settingsManager: SettingsManager!
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!

    init() async throws {
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()
        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext)
        ])
        resolver = assembler.resolver
        injectServices(resolver)
    }

    // MARK: - Pump events

    private static func event(_ name: String, _ dose: DoseEntry) -> NewPumpEvent {
        NewPumpEvent(date: dose.startDate, dose: dose, raw: Data(name.utf8), title: name)
    }

    /// Everything but the row id, which each side assigns its own way.
    private static func normalized(_ events: [PumpHistoryEvent]) throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try events.map { event in
            var object = try JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any] ?? [:]
            object["id"] = nil
            object["_id"] = nil
            return String(data: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), encoding: .utf8)!
        }
    }

    @Test("Kit pump events reach oref the same way through the watch's records as through the phone's store")  func pumpEvents(
    ) async throws {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        let shortenedTempStart = ago(200)
        let cutBolusStart = ago(100)
        let first: [NewPumpEvent] = [
            Self.event("suspend", DoseEntry(suspendDate: ago(300))),
            Self.event("resume", DoseEntry(resumeDate: ago(290))),
            Self.event("external", DoseEntry(
                type: .bolus, startDate: ago(250), endDate: ago(250), value: 2, unit: .units, decisionId: nil,
                deliveredUnits: 2, manuallyEntered: true
            )),
            Self.event("temp-shortened", DoseEntry(
                type: .tempBasal, startDate: shortenedTempStart, endDate: shortenedTempStart.addingTimeInterval(30 * 60),
                value: 1.5, unit: .unitsPerHour, decisionId: nil, automatic: true, isMutable: true
            )),
            Self.event("bolus-cut", DoseEntry(
                type: .bolus, startDate: cutBolusStart, endDate: cutBolusStart.addingTimeInterval(80), value: 2,
                unit: .units, decisionId: nil, automatic: false, isMutable: true
            )),
            Self.event("temp-dropped", DoseEntry(
                type: .tempBasal, startDate: ago(40), endDate: ago(10), value: 2, unit: .unitsPerHour, decisionId: nil,
                automatic: true, isMutable: true
            ))
        ]
        let second: [NewPumpEvent] = [
            Self.event("temp-shortened", DoseEntry(
                type: .tempBasal, startDate: shortenedTempStart, endDate: shortenedTempStart.addingTimeInterval(12 * 60),
                value: 1.5, unit: .unitsPerHour, decisionId: nil, deliveredUnits: 0.3, automatic: true, isMutable: false
            )),
            Self.event("temp-zero", DoseEntry(
                type: .tempBasal, startDate: ago(150), endDate: ago(120), value: 0, unit: .unitsPerHour, decisionId: nil,
                deliveredUnits: 0, automatic: true
            )),
            Self.event("bolus-cut", DoseEntry(
                type: .bolus, startDate: cutBolusStart, endDate: cutBolusStart.addingTimeInterval(48), value: 2,
                unit: .units, decisionId: nil, deliveredUnits: 1.2, automatic: false, isMutable: false
            )),
            Self.event("smb", DoseEntry(
                type: .bolus, startDate: ago(60), endDate: ago(60), value: 0.3, unit: .units, decisionId: nil,
                deliveredUnits: 0.3, automatic: true
            )),
            Self.event("scheduled", DoseEntry(
                type: .basal, startDate: ago(30), endDate: ago(30), value: 1, unit: .unitsPerHour, decisionId: nil
            ))
        ]

        // phone
        try await storage.storePumpEvents(first, replacePendingEvents: false)
        try await storage.storePumpEvents(second, replacePendingEvents: true)
        let context = testContext!
        let phone = try await context.perform {
            let request = PumpEventStored.fetchRequest() as NSFetchRequest<PumpEventStored>
            request.predicate = NSPredicate.pumpHistoryLast1440Minutes(now: now)
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            return OpenAPS.nativePumpHistory(try context.fetch(request).map(\.objectID), orphanedResumes: [], from: context)
        }

        // watch
        let increment = settingsManager.preferences.bolusIncrement
        var stored: [String: WatchLoanStoredPumpEvent] = [:]
        WatchLoopInputs.store(first, into: &stored, replacePendingEvents: false, at: now, pulseUnits: 0.05)
        WatchLoopInputs.store(second, into: &stored, replacePendingEvents: true, at: now, pulseUnits: 0.05)
        let mapped = stored.values.sorted { $0.record.date > $1.record.date }.flatMap {
            WatchLoopInputs.pumpHistoryEvents($0.record.newPumpEvent, storedAt: $0.storedAt, bolusIncrement: increment)
        }
        let watch = OrefInputs.algorithmPumpEvents(
            mapped,
            type: { $0.type.rawValue },
            timestamp: { $0.timestamp },
            isScheduledBasal: { _ in false },
            now: now
        )

        #expect(phone.count == 9, "\(phone.map(\.type))")
        #expect(try Self.normalized(watch) == Self.normalized(phone))
    }

    // MARK: - Smoothing

    @Test("A watch reading is smoothed as the phone's smoothing pass and glucose fetch would") func smoothing() async throws {
        let clock = OrefCharacterizationScenarios.makeClock()
        let scenario = OrefCharacterizationScenarios.build("override-smb-off-smoothed", clock: clock)
        let phoneInputs = try OrefRunCharacterizationTests.inputs(for: scenario)
        let later = clock.addingTimeInterval(300)
        let newID = UUID()
        let newDate = later.addingTimeInterval(-10)

        // phone: store the readings as they were, add the new one, run the real smoothing pass and glucose mapping
        let context = testContext!
        try await context.perform {
            for reading in scenario.glucose {
                let object = GlucoseStored(context: context)
                object.id = reading.id
                object.date = reading.date
                object.glucose = reading.glucose
                object.smoothedGlucose = reading.smoothed.map { NSDecimalNumber(decimal: $0) }
                object.isManual = false
                object.direction = "Flat"
            }
            let object = GlucoseStored(context: context)
            object.id = newID
            object.date = newDate
            object.glucose = 190
            object.isManual = false
            object.direction = "Flat"
            try context.save()
        }
        try await BaseFetchGlucoseManager.smoothStoredGlucose(context: context, now: later)
        let rounding = WatchLoopInputsParityTests.rounding
        let phone = try await context.perform {
            let request = GlucoseStored.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            return try context.fetch(request).map {
                BaseGlucoseStorage.mapToBloodGlucose($0, shouldSmoothGlucose: true, roundingBehavior: rounding)
            }
        }

        // watch
        var snapshot = WatchLoopInputsParityTests.snapshot(phoneInputs)
        snapshot.smoothGlucose = true
        snapshot.smoothingWindow = WatchLoopInputsParityTests.rawWindow(scenario)
        var records = WatchLoopRecords()
        records.glucose = [OrefInputs.bloodGlucose(
            id: newID, date: newDate, glucose: 190, smoothedGlucose: nil, isManual: false, direction: "Flat",
            shouldSmoothGlucose: false, roundingBehavior: rounding
        )]
        let watch = WatchLoopInputs.orefInputs(
            snapshot: try WatchLoopInputsParityTests.overTheWire(snapshot),
            records: records,
            now: later,
            currentTemp: scenario.currentTemp,
            autosens: nil,
            microBolusAllowed: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let expected = OrefInputs.glucose(
            phone,
            since: OrefInputs.glucoseStart(hours: OrefInputs.autosensGlucoseHours, now: later)
        )
        #expect(watch.glucose.count == expected.count)
        #expect(try encoder.encode(watch.glucose) == encoder.encode(expected))
        #expect(watch.glucose.first?.sgv != 190)
    }

    // MARK: - TDD sufficiency

    @Test(
        "The watch's TDD sufficiency count matches the phone's store at the 75 % boundary",
        arguments: [-1, 0]
    )  func sufficiency(offset: Int) async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = OrefInputs.sufficientTDDRowCount + offset
        let context = testContext!
        try await context.perform {
            func insert(_ date: Date, _ total: Decimal) {
                let object = TDDStored(context: context)
                object.id = UUID()
                object.date = date
                object.total = NSDecimalNumber(decimal: total)
            }
            for index in 0 ..< rows { insert(now.addingTimeInterval(-Double(index * 300) - 30), 30) }
            // rows the 7-day rule must not count: zero totals, and older than 7 days but inside the 10-day history
            for index in 0 ..< 20 { insert(now.addingTimeInterval(-Double(index * 300) - 45), 0) }
            for index in 0 ..< 40 { insert(now.addingTimeInterval(-8 * 86400 - Double(index * 300)), 30) }
            try context.save()
        }
        let phone = try await BaseTDDStorage.hasSufficientTDD(context: context, now: now)
        let history = try await context.perform {
            try context.fetch(TDDStored.fetchRequest()).map {
                OrefInputs.TDDRow(date: $0.date, total: $0.total?.decimalValue)
            }
        }
        let watch = OrefInputs.hasSufficientTDD(OrefInputs.tddHistory(history, now: now), now: now)
        #expect(phone == (offset >= 0))
        #expect(watch == phone)
    }
}
