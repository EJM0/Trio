import Combine
import CoreData
import Foundation
import LoopKit
import Swinject
import Testing

@testable import Trio

/// The coordinator's host against the real stores, APS manager and device data manager.
@Suite("Watch loan: phone stores and pump idle", .serialized) struct WatchLoanPhoneIntegrationTests {
    typealias F = LoanFixture

    private final class LoanTestAssembly: Assembly {
        let context: NSManagedObjectContext
        let gate: WatchLoanGate
        let alertManager: TrioAlertManager?
        let notLoopingMonitor: NotLoopingMonitor?

        init(
            context: NSManagedObjectContext,
            gate: WatchLoanGate,
            alertManager: TrioAlertManager?,
            notLoopingMonitor: NotLoopingMonitor?
        ) {
            self.context = context
            self.gate = gate
            self.alertManager = alertManager
            self.notLoopingMonitor = notLoopingMonitor
        }

        func assemble(container: Container) {
            container.register(WatchLoanGate.self) { _ in self.gate }
            if let alertManager {
                container.register(TrioAlertManager.self) { _ in alertManager }
            }
            if let notLoopingMonitor {
                container.register(NotLoopingMonitor.self) { _ in notLoopingMonitor }
            }
            container.register(DeviceDataManager.self) { r in BaseDeviceDataManager(resolver: r) }.inObjectScope(.container)
            container.register(CarbEntryMutationService.self) { r in
                BaseCarbEntryMutationService(resolver: r, contextProvider: { self.context })
            }.inObjectScope(.container)
        }
    }

    private struct Rig {
        let resolver: Resolver
        let context: NSManagedObjectContext
        let gateStore: WatchLoanStore<PhoneLoanState>
        let host: BaseWatchLoanPhoneHost
        var pumpHistory: PumpHistoryStorage { resolver.resolve(PumpHistoryStorage.self)! }
        var glucoseStorage: GlucoseStorage { resolver.resolve(GlucoseStorage.self)! }
        var deviceDataManager: BaseDeviceDataManager { resolver.resolve(DeviceDataManager.self) as! BaseDeviceDataManager }
        var apsManager: BaseAPSManager { resolver.resolve(APSManager.self) as! BaseAPSManager }

        func count<T: NSManagedObject>(_: T.Type, _ predicate: NSPredicate? = nil) async throws -> Int {
            try await context.perform {
                let request = NSFetchRequest<T>(entityName: String(describing: T.self))
                request.predicate = predicate
                return try context.count(for: request)
            }
        }

        func clearStoredPump() async {
            try? await Task.sleep(nanoseconds: 700_000_000)
            deviceDataManager.rawPumpManager = nil
        }
    }

    private static func makeRig(
        alertManager: TrioAlertManager? = nil,
        notLoopingMonitor: NotLoopingMonitor? = nil
    ) async throws -> Rig {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        let gateStore: WatchLoanStore<PhoneLoanState> = WatchLoanStoreTests.temporaryStore()
        let gate = WatchLoanGate(store: gateStore)
        let resolver = Assembler([
            StorageAssembly(), ServiceAssembly(), APSAssembly(), NetworkAssembly(), UIAssembly(), SecurityAssembly(),
            TestAssembly(testContext: context),
            LoanTestAssembly(context: context, gate: gate, alertManager: alertManager, notLoopingMonitor: notLoopingMonitor)
        ]).resolver
        return Rig(
            resolver: resolver,
            context: context,
            gateStore: gateStore,
            host: BaseWatchLoanPhoneHost(resolver: resolver, contextProvider: {
                context
            })
        )
    }

    static func record(_ date: Date, _ dose: DoseEntry, raw: String = UUID().uuidString) -> WatchLoanRecordBatch.PumpEventRecord {
        WatchLoanRecordBatch.PumpEventRecord(date: date, raw: Data(raw.utf8), title: "dose", dose: dose)
    }

    static func reading(_ date: Date, _ value: Int) -> BloodGlucose {
        BloodGlucose(
            sgv: value,
            direction: .flat,
            date: Decimal(date.timeIntervalSince1970 * 1000),
            dateString: date,
            glucose: value,
            type: "sgv"
        )
    }

    // MARK: Merge

    @Test("Merging a batch twice stores each dose, carb and reading once; running doses are never stored") func mergeIdempotent(
    ) async throws {
        let rig = try await Self.makeRig()
        let now = Date().addingTimeInterval(-600)
        try await rig.glucoseStorage.storeGlucose([Self.reading(now.addingTimeInterval(-300), 110)])
        let carbID = UUID().uuidString
        let batch = WatchLoanRecordBatch(
            version: WatchLoanRecordBatch.currentVersion,
            batchID: UUID(),
            epoch: 1,
            sentAt: now,
            pumpEvents: [
                Self.record(now.addingTimeInterval(-240), DoseEntry(
                    type: .bolus, startDate: now.addingTimeInterval(-240), endDate: now.addingTimeInterval(-200),
                    value: 1, unit: .units, decisionId: nil, deliveredUnits: 1
                )),
                Self.record(now.addingTimeInterval(-1800), DoseEntry(
                    type: .tempBasal, startDate: now.addingTimeInterval(-1800), endDate: now.addingTimeInterval(-600),
                    value: 1.5, unit: .unitsPerHour, decisionId: nil, deliveredUnits: 0.5
                )),
                Self.record(now.addingTimeInterval(-600), DoseEntry(
                    type: .tempBasal, startDate: now.addingTimeInterval(-600), endDate: now.addingTimeInterval(1200),
                    value: 2, unit: .unitsPerHour, decisionId: nil, isMutable: true
                ))
            ],
            runningTemp: nil,
            carbs: [CarbsEntry(
                id: carbID, createdAt: now, actualDate: now, carbs: 30, fat: 0, protein: 0, note: nil, enteredBy: "Trio",
                isFPU: false, fpuID: nil
            )],
            deletedCarbIDs: [],
            // the first is the phone's own reading, seen by the watch 40 s later
            glucose: [Self.reading(now.addingTimeInterval(-260), 111), Self.reading(now, 120)]
        )

        try await rig.host.merge(batch)
        try await rig.host.merge(batch)

        #expect(try await rig.count(PumpEventStored.self) == 2)
        #expect(try await rig.count(PumpEventStored.self, NSPredicate(format: "isMutable == YES")) == 0)
        #expect(try await rig.count(CarbEntryStored.self, NSPredicate(format: "isFPU == NO")) == 1)
        #expect(try await rig.count(GlucoseStored.self) == 2)
    }

    @Test("A kit record that replaces a watch booking deletes the phone's copy of the booking") func replacedBooking(
    ) async throws {
        let rig = try await Self.makeRig()
        let start = Date().addingTimeInterval(-900)
        func batch(_ records: [WatchLoanRecordBatch.PumpEventRecord]) -> WatchLoanRecordBatch {
            WatchLoanRecordBatch(
                version: WatchLoanRecordBatch.currentVersion, batchID: UUID(), epoch: 1, sentAt: Date(), pumpEvents: records,
                runningTemp: nil, carbs: [], deletedCarbIDs: [], glucose: []
            )
        }
        let dose = DoseEntry(
            type: .bolus,
            startDate: start,
            endDate: start,
            value: 1,
            unit: .units,
            decisionId: nil,
            deliveredUnits: 1,
            automatic: false
        )
        let booked = Self.record(start, dose, raw: "trio-watch-intent-\(UUID().uuidString)")
        try await rig.host.merge(batch([booked]))
        #expect(try await rig.count(PumpEventStored.self) == 1)

        var kit = Self.record(start.addingTimeInterval(2), dose)
        kit.replacesSyncIdentifier = booked.newPumpEvent.dose?.syncIdentifier
        try await rig.host.merge(batch([kit]))
        #expect(try await rig.count(PumpEventStored.self) == 1)
        #expect(try await rig.count(
            PumpEventStored.self,
            NSPredicate(format: "syncIdentifier == %@", kit.newPumpEvent.dose!.syncIdentifier!)
        ) == 1)
    }

    @Test(
        "A booking a kit record replaced stays deleted whichever batch arrives first",
        arguments: [true, false]
    ) func replacedBookingEitherOrder(bookingFirst: Bool) async throws {
        let rig = try await Self.makeRig()
        let store: WatchLoanStore<PhoneLoanState> = WatchLoanStoreTests.temporaryStore()
        try store.save(.lent(epoch: 1))
        let coordinator = WatchLoanCoordinator(
            host: rig.host,
            store: store,
            ledgerStore: WatchLoanStoreTests.temporaryStore(WatchLoanLedger.self)
        )
        let start = Date().addingTimeInterval(-900)
        let dose = DoseEntry(
            type: .bolus, startDate: start, endDate: start, value: 1, unit: .units, decisionId: nil, deliveredUnits: 1,
            automatic: false
        )
        let booked = Self.record(start, dose, raw: "trio-watch-intent-\(UUID().uuidString)")
        var kit = Self.record(start.addingTimeInterval(2), dose)
        kit.replacesSyncIdentifier = booked.newPumpEvent.dose?.syncIdentifier
        func payload(_ record: WatchLoanRecordBatch.PumpEventRecord) throws -> [String: Any] {
            let batch = WatchLoanRecordBatch(
                version: WatchLoanRecordBatch.currentVersion, batchID: UUID(), epoch: 1, sentAt: Date(), pumpEvents: [record],
                runningTemp: nil, carbs: [], deletedCarbIDs: [], glucose: []
            )
            return [WatchLoanWireKey.records: try batch.encoded()]
        }
        for record in bookingFirst ? [booked, kit] : [kit, booked] {
            await coordinator.receive(try payload(record))
        }
        // a late re-delivery of the booking is dropped too
        await coordinator.receive(try payload(booked))
        #expect(try await rig.count(PumpEventStored.self) == 1)
        #expect(try await rig.count(
            PumpEventStored.self,
            NSPredicate(format: "syncIdentifier == %@", kit.newPumpEvent.dose!.syncIdentifier!)
        ) == 1)
    }

    @Test("The status query's reply-handler delegate method is visible to WatchConnectivity") func replyHandlerSelector() {
        #expect(BaseWatchManager.instancesRespond(to: NSSelectorFromString("session:didReceiveMessage:replyHandler:")))
    }

    @Test("The phone driver's pending report doesn't purge merged watch doses") func purgeProtection() async throws {
        let rig = try await Self.makeRig()
        let now = Date().addingTimeInterval(-600)
        let watchRaw = "watch-temp"
        try await rig.host.merge(WatchLoanRecordBatch(
            version: WatchLoanRecordBatch.currentVersion, batchID: UUID(), epoch: 1, sentAt: now,
            pumpEvents: [Self.record(now.addingTimeInterval(-1800), DoseEntry(
                type: .tempBasal, startDate: now.addingTimeInterval(-1800), endDate: now.addingTimeInterval(-900),
                value: 0.5, unit: .unitsPerHour, decisionId: nil, deliveredUnits: 0.1
            ), raw: watchRaw)],
            runningTemp: nil, carbs: [], deletedCarbIDs: [], glucose: []
        ))
        // the phone's own pending temp from before the loan, then a complete pending report without it
        let phoneTemp = NewPumpEvent(
            date: now.addingTimeInterval(-3600),
            dose: DoseEntry(
                type: .tempBasal, startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(-1800),
                value: 1, unit: .unitsPerHour, decisionId: nil, isMutable: true
            ),
            raw: Data("phone-temp".utf8),
            title: "temp"
        )
        try await rig.pumpHistory.storePumpEvents([phoneTemp], replacePendingEvents: false)
        try await rig.pumpHistory.storePumpEvents([], replacePendingEvents: true)

        let watchID = watchRaw.utf8.map { String(format: "%02x", $0) }.joined()
        #expect(try await rig.count(PumpEventStored.self, NSPredicate(format: "syncIdentifier == %@", watchID)) == 1)
        // the purge itself works: the phone's withdrawn pending temp is gone
        #expect(try await rig.count(PumpEventStored.self) == 1)
    }

    @Test("A carb entry deleted on the watch is deleted on the phone") func carbDeletion() async throws {
        let rig = try await Self.makeRig()
        let now = Date().addingTimeInterval(-600)
        let carbID = UUID().uuidString
        func batch(carbs: [CarbsEntry], deleted: [String]) -> WatchLoanRecordBatch {
            WatchLoanRecordBatch(
                version: WatchLoanRecordBatch.currentVersion, batchID: UUID(), epoch: 1, sentAt: now, pumpEvents: [],
                runningTemp: nil, carbs: carbs, deletedCarbIDs: deleted, glucose: []
            )
        }
        try await rig.host.merge(batch(carbs: [CarbsEntry(
            id: carbID, createdAt: now, actualDate: now, carbs: 20, fat: 0, protein: 0, note: nil, enteredBy: "Trio",
            isFPU: false, fpuID: nil
        )], deleted: []))
        #expect(try await rig.count(CarbEntryStored.self) == 1)
        try await rig.host.merge(batch(carbs: [], deleted: [carbID]))
        #expect(try await rig.count(CarbEntryStored.self) == 0)
    }

    @Test("The audit bolus is replaced in place and removed at 0") func taggedBolus() async throws {
        let rig = try await Self.makeRig()
        let id = WatchLoanAudit.auditBolusIDPrefix + "1"
        try await rig.host.replaceAuditBolus(id: id, units: 0.8, at: Date())
        try await rig.host.replaceAuditBolus(id: id, units: 0.2, at: Date())
        let events = try await rig.host.bookedEvents(since: Date().addingTimeInterval(-60))
        #expect(events.filter { $0.id == id }.map(\.amount) == [0.2])
        try await rig.host.replaceAuditBolus(id: id, units: 0, at: Date())
        #expect(try await rig.host.bookedEvents(since: Date().addingTimeInterval(-60)).isEmpty)
    }

    // MARK: Pump idle (M3C-02) and the return home (M3C-10)

    @Test(
        "A lend issued while a loop is between its gate and its temp cancels after that temp, not before"
    ) func lendWaitsForLoop() async throws {
        let rig = try await Self.makeRig()
        let aps = rig.apsManager
        let clock = TestClock()
        let host = FakeLoanHost(clock: clock)
        aps.pumpManager = host.double
        try? await Task.sleep(nanoseconds: 500_000_000)
        host.idle = { await aps.awaitPumpIdle() }
        let coordinator = WatchLoanCoordinator(
            host: host,
            store: WatchLoanStoreTests.temporaryStore(),
            ledgerStore: WatchLoanStoreTests.temporaryStore(WatchLoanLedger.self),
            now: { clock.now }
        )
        // the loop passed the gate and holds the loop guard
        #expect(await aps.loopGuard.tryStart(minInterval: 0, lastLoopDate: .distantPast, lastLoopStartDate: .distantPast))
        let before = host.double.commands.count

        let request = try WatchLoanCoordinatorTests.Rig.message(F.message(0, .request(requestID: F.requestA)))
        let lend = Task { await coordinator.receive(request) }
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(host.double.commands.count == before, "nothing may reach the pump while the loop runs")
        #expect(await coordinator.state == .lending(epoch: 1, requestID: F.requestA))

        host.double.enactTempBasal(decisionId: nil, unitsPerHour: 2.5, for: 1800) { _ in }
        await aps.loopGuard.finish()
        await lend.value

        #expect(Array(host.double.commands.dropFirst(before)) == [
            "tempBasal(2.5)", "tempBasal(0.0)", "refreshDeliveredUnits", "releaseControl", "export"
        ])
        await rig.clearStoredPump()
    }

    @Test("A lend waits for a bolus under way to finish") func lendWaitsForBolus() async throws {
        let rig = try await Self.makeRig()
        let aps = rig.apsManager
        let clock = TestClock()
        let host = FakeLoanHost(clock: clock)
        host.double.status.bolusState = .inProgress(DoseEntry(
            type: .bolus, startDate: Date(), endDate: Date().addingTimeInterval(30), value: 1, unit: .units, decisionId: nil
        ))
        aps.pumpManager = host.double
        try? await Task.sleep(nanoseconds: 500_000_000)
        host.idle = { await aps.awaitPumpIdle() }
        let coordinator = WatchLoanCoordinator(
            host: host,
            store: WatchLoanStoreTests.temporaryStore(),
            ledgerStore: WatchLoanStoreTests.temporaryStore(WatchLoanLedger.self),
            now: { clock.now }
        )
        let before = host.double.commands.count
        let request = try WatchLoanCoordinatorTests.Rig.message(F.message(0, .request(requestID: F.requestA)))
        let lend = Task { await coordinator.receive(request) }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(host.double.commands.count == before)

        host.double.status.bolusState = .noBolus
        await lend.value
        #expect(host.double.commands.dropFirst(before).first == "tempBasal(0.0)")
        await rig.clearStoredPump()
    }

    @Test("Back home, the delivery limits and heartbeat request held back during the loan are sent") func resyncAfterTakeBack(
    ) async throws {
        let rig = try await Self.makeRig()
        let ddm = rig.deviceDataManager
        let double = LoanPumpDouble()
        ddm.updatePumpBLEHeartbeat(lastCGMReadingDate: Date(), expectedCGMReadingInterval: 300)
        ddm.pumpManager = double
        try? await Task.sleep(nanoseconds: 500_000_000)
        let limits = double.commands.filter { $0 == "syncDeliveryLimits" }.count
        let heartbeats = double.commands.filter { $0 == "setBLEHeartbeatRequest" }.count

        ddm.resyncPumpAfterTakeBack()
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(double.commands.filter { $0 == "syncDeliveryLimits" }.count == limits + 1)
        #expect(double.commands.filter { $0 == "setBLEHeartbeatRequest" }.count == heartbeats + 1)
        await rig.clearStoredPump()
    }

    // MARK: Small checks

    @Test("Pump history carries external insulin, so the audit can leave it out") func externalInsulinMapped() async throws {
        let rig = try await Self.makeRig()
        await rig.pumpHistory.storeExternalInsulinEvent(amount: 2, timestamp: Date().addingTimeInterval(-60))
        let events = try await rig.host.bookedEvents(since: Date().addingTimeInterval(-600))
        #expect(events.map(\.isExternal) == [true])
    }

    @Test("No Nightscout device status while Apple Watch holds the pump") func nightscoutStatus() async throws {
        let rig = try await Self.makeRig()
        let nightscout = try #require(rig.resolver.resolve(NightscoutManager.self) as? BaseNightscoutManager)
        #expect(nightscout.isDeviceStatusUploadAllowed)
        try rig.gateStore.save(.lent(epoch: 1))
        #expect(!nightscout.isDeviceStatusUploadAllowed)
        try rig.gateStore.save(.home(epoch: 2, lastLoan: LoanRecord(epoch: 1)))
        #expect(nightscout.isDeviceStatusUploadAllowed)
    }

    #if !TRIO_ON_WATCH
        @Test("With the build flag off, Start is refused before anything else") func featureOff() async throws {
            let rig = try await Self.makeRig()
            #expect(await rig.host.startRefusal() == .featureOff)
        }
    #endif

    @Test("Only loan payloads are routed to the coordinator") func routing() {
        #expect(WatchLoanWireKey.isLoanPayload([WatchLoanWireKey.records: Data()]))
        #expect(WatchLoanWireKey.isLoanPayload([WatchLoanWireKey.message: Data(), "watchLogs": "x"]))
        #expect(!WatchLoanWireKey.isLoanPayload([WatchMessageKeys.snoozeDuration: 5]))
        #expect(!WatchLoanWireKey.isLoanPayload([WatchMessageKeys.bolus: 1.0, WatchMessageKeys.carbs: 10]))
        #expect(!WatchLoanWireKey.isLoanPayload(["watchLogs": "x"]))
    }

    @Test(
        "Not-looping alarm: loop dates schedule as before; disarmed nothing is pending; re-armed it counts from then"
    ) func notLoopingArming() {
        let subject = PassthroughSubject<Date, Never>()
        let spy = SpyAlertManager()
        let monitor = NotLoopingMonitor(loopDates: subject.eraseToAnyPublisher(), trioAlertManager: spy)
        subject.send(Date().addingTimeInterval(-600))
        func firstDelay() -> TimeInterval? {
            spy.issuedAlerts.last { $0.identifier.alertIdentifier == "loop.notActive.w1" }.flatMap {
                if case let .delayed(interval) = $0.trigger { return interval } else { return nil }
            }
        }
        // anchored on the loop 10 min ago, as before
        #expect(abs((firstDelay() ?? 0) - 600) < 5)

        let issued = spy.issuedAlerts.count
        monitor.setArmed(false)
        subject.send(Date())
        #expect(spy.issuedAlerts.count == issued)

        monitor.setArmed(true)
        #expect(abs((firstDelay() ?? 0) - 1200) < 5)
    }

    @Test(
        "G-1: relaunched where no device may dose, the phone's series is pending again; in lent the silence steps are",
        arguments: ["lending", "takingBack", "unreadable", "lent"]
    ) func alarmsAfterRelaunch(_ name: String) async throws {
        let spy = SpyAlertManager()
        let loopDates = PassthroughSubject<Date, Never>()
        let monitor = NotLoopingMonitor(loopDates: loopDates.eraseToAnyPublisher(), trioAlertManager: spy)
        let rig = try await Self.makeRig(alertManager: spy, notLoopingMonitor: monitor)
        // the last loop was long ago: the series from it is over, nothing is pending
        loopDates.send(Date().addingTimeInterval(-3 * 3600))
        let store: WatchLoanStore<PhoneLoanState> = WatchLoanStoreTests.temporaryStore()
        switch name {
        case "lending": try store.save(.lending(epoch: 1, requestID: UUID()))
        case "takingBack": try store.save(.takingBack(epoch: 2, loan: .superseding(epoch: 1, at: Date())))
        case "lent": try store.save(.lent(epoch: 1))
        default: try Data("not json".utf8).write(to: store.url)
        }
        let before = spy.issuedAlerts.count
        let coordinator = WatchLoanCoordinator(
            host: rig.host,
            store: store,
            ledgerStore: WatchLoanStoreTests.temporaryStore(WatchLoanLedger.self)
        )
        await coordinator.start()

        let issued = spy.issuedAlerts.dropFirst(before)
        func delay(_ alert: Alert) -> TimeInterval? {
            if case let .delayed(interval) = alert.trigger { return interval }
            return nil
        }
        let notLooping = issued.filter { $0.identifier.managerIdentifier == "trio.aps" }.compactMap(delay)
        let silence = issued.filter { $0.identifier.managerIdentifier == "trio.watchloan" }.compactMap(delay)
        if name == "lent" {
            #expect(notLooping.isEmpty)
            #expect(silence.count == 4)
        } else {
            #expect(notLooping.count == 6, "20 to 120 min, from the relaunch")
            #expect(abs((notLooping.min() ?? 0) - 1200) < 5)
            #expect(silence.isEmpty)
        }
    }

    @Test(
        "A snooze change re-issues the pending \"No updates from Apple Watch\" steps from the same anchor"
    ) func silenceStepsAfterSnooze() async throws {
        let spy = SpyAlertManager()
        let rig = try await Self.makeRig(alertManager: spy)
        let anchor = Date().addingTimeInterval(-40 * 60)
        func pending() -> [Int] {
            spy.issuedAlerts.compactMap { alert -> Int? in
                guard alert.identifier.managerIdentifier == "trio.watchloan",
                      case let .delayed(interval) = alert.trigger else { return nil }
                return Int((interval / 60).rounded())
            }
        }
        rig.host.setAlarm(.phoneNoWatchUpdates, armed: true, anchor: anchor)
        #expect(pending() == [20, 50, 80])
        #expect(spy.issuedAlerts.last?.interruptionLevel == .critical)

        let before = spy.issuedAlerts.count
        await MainActor.run { rig.host.snoozeDidChange(Date().addingTimeInterval(1800)) }
        #expect(spy.issuedAlerts.count == before + 3)
        #expect(Array(pending().suffix(3)) == [20, 50, 80])
        #expect(spy.retractedIdentifiers.filter { $0.managerIdentifier == "trio.watchloan" }.count == 8)

        rig.host.setAlarm(.phoneNoWatchUpdates, armed: false, anchor: Date())
        let disarmed = spy.issuedAlerts.count
        await MainActor.run { rig.host.snoozeDidChange(Date().addingTimeInterval(1800)) }
        #expect(spy.issuedAlerts.count == disarmed)
    }
}

@Suite("Watch loan: glucose from the watch") struct WatchLoanWatchGlucoseTests {
    static func reading(_ value: Int16) -> BloodGlucose {
        OrefInputs.bloodGlucose(
            id: nil, date: Date(), glucose: value, smoothedGlucose: nil, isManual: false, direction: "Flat",
            shouldSmoothGlucose: false, roundingBehavior: NSDecimalNumberHandler(
                roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false,
                raiseOnUnderflow: false, raiseOnDivideByZero: false
            )
        )
    }

    @Test("A watch reading is stored with its value, not as 0") func storedWithValue() {
        let reading = Self.reading(169)
        #expect(reading.glucose == nil && reading.sgv == 169)
        #expect(BaseWatchLoanPhoneHost.storable([reading]).map(\.glucose) == [169])
    }

    @Test("A reading without a value is dropped") func withoutValue() {
        var reading = Self.reading(169)
        reading.sgv = nil
        #expect(BaseWatchLoanPhoneHost.storable([reading]).isEmpty)
    }
}
