import Foundation
import LoopKit
import Testing

@testable import Trio

final class Flag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock()
        defer { lock.unlock() }
        return value }

    func set() { lock.lock()
        value = true
        lock.unlock() }
}

final class TestClock {
    var now = LoanFixture.now
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

final class FakeLoanTransport: WatchLoanTransport {
    var isReachable = true
    private(set) var live: [[String: Any]] = []
    private(set) var queued: [[String: Any]] = []
    private(set) var cancelled = 0

    /// Live sends that go out but don't arrive, as when the watch drops away right after.
    var undeliveredLiveSends = 0
    var unreachableAfterFailure = false

    func sendLive(_ payload: [String: Any], failed: ((Error) -> Void)?) -> Bool {
        guard isReachable else { return false }
        live.append(payload)
        if undeliveredLiveSends > 0 {
            undeliveredLiveSends -= 1
            if unreachableAfterFailure { isReachable = false }
            failed?(NSError(domain: "WCErrorDomain", code: 7007))
        }
        return true
    }

    func send(_ payload: [String: Any]) {
        if isReachable { live.append(payload) } else { queued.append(payload) }
    }

    func cancelOutstandingLoanTransfers() {
        cancelled += 1
        queued.removeAll()
    }

    private var all: [[String: Any]] { live + queued }

    var messages: [WatchLoanMessage] {
        all.compactMap { payload in
            guard let data = payload[WatchLoanWireKey.message] as? Data,
                  case let .message(envelope) = WatchLoanWire.decode(data) else { return nil }
            return envelope.message
        }
    }

    var stops: [WatchLoanStop] {
        all.compactMap { payload in
            guard let data = payload[WatchLoanWireKey.message] as? Data,
                  case let .stop(stop) = WatchLoanWire.decode(data) else { return nil }
            return stop
        }
    }

    var recordAcks: [WatchLoanRecordAck] {
        all
            .compactMap {
                ($0[WatchLoanWireKey.recordsAck] as? Data)
                    .flatMap { try? JSONDecoder().decode(WatchLoanRecordAck.self, from: $0) } }
    }
}

/// The app side, in memory: booked pump history, alarms, alerts.
final class FakeLoanHost: WatchLoanPhoneHost {
    let double: LoanPumpDouble
    let fakeTransport = FakeLoanTransport()
    let clock: TestClock
    var refusal: LoanRefusal?
    var idle: () async -> Void = {}
    var snapshotFails = false
    var snapshotPadding = 0
    var phoneGlucose: [BloodGlucose] = []
    /// Scheduled basal 0, so the audit numbers are only boluses and temps.
    var profile = [BasalProfileEntry(start: "00:00", minutes: 0, rate: 0)]

    private(set) var booked: [PumpHistoryEvent] = []
    private(set) var auditBookings: [(id: String, units: Double)] = []
    private(set) var alarms: [(alarm: LoanAlarm, armed: Bool, anchor: Date)] = []
    private(set) var alerts: [LoanAlert] = []
    private(set) var notices: [(units: Double, isShortfall: Bool)] = []
    private(set) var returnedHome = 0
    private(set) var snapshots: [WatchLoanSnapshot] = []

    init(clock: TestClock) {
        self.clock = clock
        double = LoanPumpDouble()
        double.clock = { clock.now }
    }

    var pump: WatchLoanPumpAdapter? { WatchLoanPumpAdapter(double) }
    var transport: WatchLoanTransport? { fakeTransport }

    func recentGlucose() async -> [BloodGlucose] { phoneGlucose }

    func startRefusal() async -> LoanRefusal? { refusal }
    func awaitPumpIdle() async { await idle() }

    func snapshot(
        requestID: UUID,
        epoch: Int64,
        expiresAt: Date,
        release: WatchLoanSnapshot.OdometerReading,
        pump: WatchLoanPumpAdapter
    ) async throws -> WatchLoanSnapshot {
        if snapshotFails { throw WatchLoanHostError.noSharedCGM }
        var snapshot = try WatchLoanSnapshotTests.snapshot(epoch: epoch, now: clock.now)
        snapshot.requestID = requestID
        snapshot.expiresAt = expiresAt
        snapshot.releaseReading = release
        snapshot.pumpExport = try pump.exportedConfiguration()
        if snapshotPadding > 0 {
            let now = clock.now
            snapshot.smoothingWindow = (0 ..< snapshotPadding).map { index in
                WatchLoanSnapshot.RawReading(id: UUID(), date: now.addingTimeInterval(-Double(index) * 17), glucose: 100)
            }
        }
        snapshots.append(snapshot)
        return snapshot
    }

    func merge(_ batch: WatchLoanRecordBatch) async throws {
        for event in batch.storablePumpEvents {
            guard let dose = event.dose, let id = dose.syncIdentifier, !booked.contains(where: { $0.id == id }) else { continue }
            switch dose.type {
            case .bolus:
                booked.append(PumpHistoryEvent(
                    id: id, type: .bolus, timestamp: event.date, amount: Decimal(dose.deliveredUnits ?? dose.programmedUnits)
                ))
            case .tempBasal:
                booked.append(PumpHistoryEvent(
                    id: id, type: .tempBasal, timestamp: event.date, amount: Decimal(dose.unitsPerHour),
                    duration: Int(dose.endDate.timeIntervalSince(dose.startDate) / 60)
                ))
            default:
                break
            }
        }
    }

    func bookedEvents(since date: Date) async throws -> [PumpHistoryEvent] { booked.filter { $0.timestamp >= date } }

    func replaceAuditBolus(id: String, units: Double, at date: Date) async throws {
        auditBookings.append((id, units))
        booked.removeAll { $0.id == id }
        if units > 0 { booked.append(PumpHistoryEvent(id: id, type: .bolus, timestamp: date, amount: Decimal(units))) }
    }

    func basalProfile() async -> [BasalProfileEntry] { profile }
    func setAlarm(_ alarm: LoanAlarm, armed: Bool, anchor: Date) { alarms.append((alarm, armed, anchor)) }
    func alert(_ alert: LoanAlert) { alerts.append(alert) }
    func auditNotice(units: Double, isShortfall: Bool) { notices.append((units, isShortfall)) }
    func didReturnHome() { returnedHome += 1 }
    func onForeignPodSession(_: @escaping () -> Void) {}

    var auditRows: [PumpHistoryEvent] { booked.filter { $0.id.hasPrefix(WatchLoanAudit.auditBolusIDPrefix) } }

    /// Audit bolus amounts to the hundredth, as booked.
    var auditAmounts: [Double] {
        auditRows.map { (NSDecimalNumber(decimal: $0.amount ?? 0).doubleValue * 100).rounded() / 100 }
    }

    var bookedAuditUnits: [Double] { auditBookings.map { ($0.units * 100).rounded() / 100 } }
}

@Suite("Watch loan: phone coordinator", .serialized) struct WatchLoanCoordinatorTests {
    typealias F = LoanFixture

    struct Rig {
        let clock = TestClock()
        let host: FakeLoanHost
        let store: WatchLoanStore<PhoneLoanState>
        let ledgerStore: WatchLoanStore<WatchLoanLedger>
        let coordinator: WatchLoanCoordinator

        init(
            state: PhoneLoanState? = nil,
            ledger: WatchLoanLedger? = nil,
            pumpIdleTimeout: TimeInterval = WatchLoanCoordinator.defaultPumpIdleTimeout
        ) throws {
            host = FakeLoanHost(clock: clock)
            store = WatchLoanStoreTests.temporaryStore()
            ledgerStore = WatchLoanStoreTests.temporaryStore(WatchLoanLedger.self)
            if let state { try store.save(state) }
            if let ledger { try ledgerStore.save(ledger) }
            let clock = clock
            coordinator = WatchLoanCoordinator(
                host: host,
                store: store,
                ledgerStore: ledgerStore,
                now: { clock.now },
                pumpIdleTimeout: pumpIdleTimeout
            )
        }

        /// A coordinator after a relaunch: same files, same pump.
        func relaunched() -> WatchLoanCoordinator {
            let clock = clock
            return WatchLoanCoordinator(host: host, store: store, ledgerStore: ledgerStore, now: { clock.now })
        }

        var double: LoanPumpDouble { host.double }
        var transport: FakeLoanTransport { host.fakeTransport }

        static func message(_ message: WatchLoanMessage, id: UUID = UUID(), sentAt: Date = LoanFixture.now) throws
            -> [String: Any]
        {
            [WatchLoanWireKey.message: try WatchLoanWire.encode(WatchLoanEnvelope(
                protocolVersion: WatchLoanEnvelope.currentProtocolVersion,
                messageID: id,
                sentAt: sentAt,
                message: message
            ))]
        }

        func envelope(_ message: WatchLoanMessage, id: UUID = UUID()) throws -> [String: Any] {
            try Self.message(message, id: id, sentAt: clock.now)
        }

        func receive(_ message: WatchLoanMessage, id: UUID = UUID()) async throws {
            await coordinator.receive(try envelope(message, id: id))
        }

        /// Start, answered by the watch: the phone ends `lent(1)` with a release reading of `double.odometer`.
        func lend() async throws {
            try await receive(F.message(0, .request(requestID: F.requestA)))
            try await receive(F.message(1, .holding))
        }

        func batch(epoch: Int64, id: UUID = UUID(), doses: [(minutesFromNow: Double, units: Double)]) throws -> [String: Any] {
            let batch = WatchLoanRecordBatch(
                version: WatchLoanRecordBatch.currentVersion,
                batchID: id,
                epoch: epoch,
                sentAt: clock.now,
                pumpEvents: doses.map { dose in
                    let date = clock.now.addingTimeInterval(dose.minutesFromNow * 60)
                    return WatchLoanRecordBatch.PumpEventRecord(
                        date: date,
                        raw: Data(UUID().uuidString.utf8),
                        title: "Bolus",
                        dose: DoseEntry(
                            type: .bolus, startDate: date, endDate: date.addingTimeInterval(dose.units * 40),
                            value: dose.units, unit: .units, decisionId: nil, deliveredUnits: dose.units
                        )
                    )
                },
                runningTemp: nil,
                carbs: [],
                deletedCarbIDs: [],
                glucose: []
            )
            return [WatchLoanWireKey.records: try batch.encoded()]
        }
    }

    // MARK: Start

    @Test("Start: persist, cancel the temp, read the total, release, then a live grant the watch's validator accepts") func lend(
    ) async throws {
        let rig = try Rig()
        try await rig.receive(F.message(0, .request(requestID: F.requestA)))

        #expect(await rig.coordinator.state == .lending(epoch: 1, requestID: F.requestA))
        #expect(try rig.store.load().get() == .lending(epoch: 1, requestID: F.requestA))
        #expect(rig.double.commands == ["tempBasal(0.0)", "refreshDeliveredUnits", "releaseControl", "export"])
        let grant = try #require(rig.transport.live.last)
        let grantMessage = try #require(rig.transport.messages.last)
        #expect(grantMessage == F.message(1, .grant(requestID: F.requestA, expiresAt: rig.clock.now.addingTimeInterval(30))))
        let snapshot = try WatchLoanSnapshot.decode(try #require(grant[WatchLoanWireKey.snapshot] as? Data))
        let expectation = WatchLoanSnapshot.Expectation(
            requestID: F.requestA, epoch: 1, appBuild: WatchLoanSnapshotTests.appBuild, now: rig.clock.now,
            timeZone: TimeZone(identifier: "Europe/Berlin")!
        )
        #expect(snapshot.refusal(for: expectation) == nil)
        #expect(snapshot.releaseReading == WatchLoanSnapshot.OdometerReading(units: 10, at: rig.clock.now))
        #expect(rig.transport.queued.isEmpty)

        try await rig.receive(F.message(1, .holding))
        #expect(await rig.coordinator.state == .lent(epoch: 1))
    }

    @Test("Live Activity: watch mode from the start until the phone has the pump back") func liveActivityWatchMode() async throws {
        let rig = try Rig()
        #expect(await rig.coordinator.watchMode == nil)
        try await rig.lend()
        let mode = try #require(await rig.coordinator.watchMode)
        #expect(mode.since == rig.clock.now && mode.lastLoop == nil)
        #expect(!PhoneLoanState.home(epoch: 1, lastLoan: nil).isLent && !PhoneLoanState.unreadable.isLent)
        #expect(PhoneLoanState.takingBack(epoch: 1, loan: LoanRecord(epoch: 1)).isLent)
    }

    @Test("Phone readings go to the watch only while it holds the pump, each once") func forwardReadings() async throws {
        let rig = try Rig()
        let reading = WatchLoanPhoneIntegrationTests.reading(rig.clock.now, 120)
        rig.host.phoneGlucose = [reading]
        await rig.coordinator.forwardReadings()
        #expect(rig.transport.live.allSatisfy { $0[WatchLoanWireKey.phoneReadings] == nil })

        try await rig.lend()
        await rig.coordinator.forwardReadings()
        await rig.coordinator.forwardReadings()
        let sent = rig.transport.live.compactMap { $0[WatchLoanWireKey.phoneReadings] as? Data }
        #expect(sent.count == 1)
        let decoded = try WatchLoanPhoneReadings.decode(try #require(sent.first))
        #expect(decoded.epoch == 1 && decoded.readings.map(\.dateString) == [reading.dateString])
    }

    @Test("Status query: the phone answers the watch with its epoch") func statusAnswer() async throws {
        let rig = try Rig()
        #expect(WatchLoanWireKey.isStatusQuery(try Rig.message(F.message(0, .statusQuery))))
        #expect(!WatchLoanWireKey.isStatusQuery(try Rig.message(F.message(0, .holding))))
        #expect((await rig.coordinator.statusAnswer()[WatchLoanWireKey.phoneEpoch] as? NSNumber)?.int64Value == 0)
        try await rig.lend()
        #expect((await rig.coordinator.statusAnswer()[WatchLoanWireKey.phoneEpoch] as? NSNumber)?.int64Value == 1)
    }

    @Test("Start: a pod that doesn't answer keeps the pump on the phone, nothing is released") func lendPodUnreachable() async throws {
        let rig = try Rig()
        rig.double.failTempBasal = true
        try await rig.receive(F.message(0, .request(requestID: F.requestA)))
        #expect(await rig.coordinator.state == .home(epoch: 1, lastLoan: nil))
        #expect(rig.double.commands == ["tempBasal(0.0)"])
        #expect(rig.transport.messages == [F.message(1, .refused(requestID: F.requestA, reason: .releaseRefused))])
    }

    @Test("Start: refused preconditions answer the watch and touch nothing") func lendRefused() async throws {
        let rig = try Rig()
        rig.host.refusal = .pumpScreenOpen
        try await rig.receive(F.message(0, .request(requestID: F.requestA)))
        #expect(await rig.coordinator.state == .initial)
        #expect(rig.double.commands.isEmpty)
        #expect(rig.transport.messages == [F.message(0, .refused(requestID: F.requestA, reason: .pumpScreenOpen))])
    }

    private static func eventually(_ timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }

    private static func grants(_ transport: FakeLoanTransport) -> Int {
        transport.messages.filter { if case .grant = $0.kind { return true } else { return false } }.count
    }

    @Test("Start: a grant that went out but didn't arrive goes again once the watch is reachable") func grantResent() async throws {
        let rig = try Rig()
        rig.transport.undeliveredLiveSends = 1
        try await rig.receive(F.message(0, .request(requestID: F.requestA)))
        #expect(await Self.eventually { Self.grants(rig.transport) == 2 })
        #expect(await rig.coordinator.state == .lending(epoch: 1, requestID: F.requestA))
    }

    @Test("Start: a grant still not delivered when it expires: the phone takes the pump back by itself") func grantLostExpired(
    ) async throws {
        let rig = try Rig()
        rig.transport.undeliveredLiveSends = 1
        rig.transport.unreachableAfterFailure = true
        try await rig.receive(F.message(0, .request(requestID: F.requestA)))
        #expect(await rig.coordinator.state == .lending(epoch: 1, requestID: F.requestA))
        rig.clock.advance(WatchLoan.grantLifetime + 1)
        #expect(await Self.eventually { await rig.coordinator.state == .home(epoch: 2, lastLoan: LoanRecord(epoch: 1)) })
        #expect(Self.grants(rig.transport) == 1)
        #expect(rig.transport.messages.contains(F.message(1, .refused(requestID: F.requestA, reason: .grantExpired))))
    }

    @Test("Start: a watch that gave up on its request takes the pump back on the phone, from its older epoch") func watchGaveUp(
    ) async throws {
        let rig = try Rig()
        try await rig.receive(F.message(0, .request(requestID: F.requestA)))
        try await rig.receive(F.message(0, .grantRejected(requestID: F.requestA, reason: .grantExpired)))
        #expect(await rig.coordinator.state == .home(epoch: 2, lastLoan: LoanRecord(epoch: 1)))
    }

    @Test("Start: a watch not reachable for the grant gets it once it is") func grantWaitsForWatch() async throws {
        let rig = try Rig()
        rig.transport.isReachable = false
        try await rig.receive(F.message(0, .request(requestID: F.requestA)))
        #expect(await rig.coordinator.state == .lending(epoch: 1, requestID: F.requestA))
        #expect(rig.transport.live.isEmpty)
        rig.transport.isReachable = true
        #expect(await Self.eventually { Self.grants(rig.transport) == 1 })
        #expect(await rig.coordinator.state == .lending(epoch: 1, requestID: F.requestA))
    }

    // 2026-11-23 10:11: the revoke cancelled the queued refusal, and the watch kept asking
    @Test(
        "Start: a grant never live before it expires is never queued; the phone takes the pump back and the watch hears"
    ) func grantNotLive() async throws {
        let rig = try Rig()
        rig.transport.isReachable = false
        try await rig.receive(F.message(0, .request(requestID: F.requestA)))
        rig.clock.advance(WatchLoan.grantLifetime + 1)
        #expect(await Self.eventually { await rig.coordinator.state == .home(epoch: 2, lastLoan: LoanRecord(epoch: 1)) })
        #expect(rig.transport.live.isEmpty)
        #expect(Self.grants(rig.transport) == 0)
        #expect(rig.transport.stops == [WatchLoanStop(kind: .revoke, epoch: 2)])
        #expect(rig.double.commands.suffix(3) == ["takeControl", "tempBasal(0.0)", "refreshDeliveredUnits"])
        #expect(!rig.double.isControlReleased)
        #expect(rig.transport.cancelled > 0)
        #expect(rig.transport.messages.contains(F.message(1, .refused(requestID: F.requestA, reason: .grantExpired))))
    }

    @Test(
        "Start: a grant over one message goes in pieces, the last with the grant, and the pieces make the snapshot"
    ) func grantInParts() async throws {
        let rig = try Rig()
        rig.host.snapshotPadding = 4000
        try await rig.receive(F.message(0, .request(requestID: F.requestA)))
        #expect(await rig.coordinator.state == .lending(epoch: 1, requestID: F.requestA))
        let live = rig.transport.live
        #expect(live.count >= 2)
        var assembler = WatchLoanSnapshotAssembler()
        for (offset, payload) in live.enumerated() {
            let header = try JSONDecoder().decode(
                WatchLoanSnapshotPart.self,
                from: try #require(payload[WatchLoanWireKey.snapshotPartHeader] as? Data)
            )
            #expect(header.index == offset && header.count == live.count)
            #expect(header.requestID == F.requestA && header.epoch == 1)
            #expect((payload[WatchLoanWireKey.message] != nil) == (offset == live.count - 1))
            #expect(payload[WatchLoanWireKey.snapshot] == nil)
            let bytes = try #require(payload[WatchLoanWireKey.snapshotPart] as? Data)
            #expect(bytes.count <= WatchLoanSnapshot.partBytes)
            assembler.add(header, bytes)
        }
        let data = try #require(assembler.assembled(requestID: F.requestA, epoch: 1))
        #expect(try WatchLoanSnapshot.decode(data).smoothingWindow.count == 4000)
        #expect(rig.transport.queued.isEmpty)
        try await rig.receive(F.message(1, .holding))
        #expect(await rig.coordinator.state == .lent(epoch: 1))
    }

    @Test("Start: a snapshot that can't be built retakes the same way") func snapshotFails() async throws {
        let rig = try Rig()
        rig.host.snapshotFails = true
        try await rig.receive(F.message(0, .request(requestID: F.requestA)))
        #expect(await rig.coordinator.state == .home(epoch: 2, lastLoan: LoanRecord(epoch: 1)))
        #expect(rig.transport.live.allSatisfy { $0[WatchLoanWireKey.snapshot] == nil })
        #expect(rig.transport.messages.contains(F.message(1, .refused(requestID: F.requestA, reason: .snapshotIncomplete))))
    }

    // MARK: Take Back (R-1, R-2, M3C-10)

    @Test("Take Back: take with the window, cancel the watch's temp, read, audit, then home and re-sync the pump") func takeBack(
    ) async throws {
        let rig = try Rig()
        try await rig.lend()
        let afterLend = rig.double.commands.count
        rig.double.odometer = 11
        rig.clock.advance(3600)
        let window = rig.clock.now.addingTimeInterval(WatchLoan.resumeWindow)

        await rig.coordinator.takeBack()

        #expect(await rig.coordinator.state == .home(epoch: 2, lastLoan: .superseding(epoch: 1, at: rig.clock.now)))
        #expect(Array(rig.double.commands.dropFirst(afterLend)) == [
            "takeControlSuperseding(\(Int(window.timeIntervalSince1970)))",
            "tempBasal(0.0)",
            "refreshDeliveredUnits"
        ])
        #expect(rig.transport.cancelled == 1)
        #expect(rig.transport.stops == [WatchLoanStop(kind: .revoke, epoch: 2)])
        #expect(rig.host.returnedHome == 1)
        // 1.0 U the watch didn't record
        #expect(rig.host.auditAmounts == [1.0])
        #expect(rig.host.auditRows.first?.id == WatchLoanAudit.auditBolusIDPrefix + "1")
        #expect(rig.host.notices.count == 1)
    }

    @Test("Take Back: a pod that doesn't answer the temp cancel keeps the pump closed until it does") func takeBackCancelFails(
    ) async throws {
        let rig = try Rig()
        try await rig.lend()
        rig.double.failTempBasal = true
        await rig.coordinator.takeBack()
        #expect(await rig.coordinator.state == .takingBack(epoch: 2, loan: .superseding(epoch: 1, at: rig.clock.now)))
        #expect(rig.host.alerts.contains(.takeBackPodUnreachable))
        #expect(rig.host.returnedHome == 0)

        rig.double.failTempBasal = false
        await rig.coordinator.takeBack()
        #expect(await rig.coordinator.state == .home(epoch: 2, lastLoan: .superseding(epoch: 1, at: rig.clock.now)))
    }

    @Test("Take Back: the undelivered rest of a bolus under way is counted") func takeBackDuringBolus() async throws {
        let rig = try Rig()
        try await rig.lend()
        rig.clock.advance(600)
        // 0.5 U delivered so far of a 1 U bolus the watch started; 20 s left at 40 s/U
        rig.double.odometer = 10.5
        rig.double.bolusUnderWayEndsAt = rig.clock.now.addingTimeInterval(20)
        await rig.coordinator.takeBack()
        #expect(rig.host.auditAmounts == [1.0])
        let ledger = try #require(try rig.ledgerStore.load().get())
        #expect(ledger.audits.last?.bolusRemainder == 0.5)
    }

    // MARK: Late records (R-3) and booked intents (C-4)

    @Test("Late records recompute and replace the audit bolus; a repeated batch changes nothing") func lateRecords() async throws {
        let rig = try Rig()
        try await rig.lend()
        rig.clock.advance(1800)
        rig.double.odometer = 11
        await rig.coordinator.takeBack()
        #expect(rig.host.auditAmounts == [1.0])

        let lateID = UUID()
        let late = try rig.batch(epoch: 1, id: lateID, doses: [(-20, 0.6)])
        await rig.coordinator.receive(late)
        #expect(rig.host.auditAmounts == [0.4])
        #expect(rig.host.bookedAuditUnits == [1.0, 0.4])

        await rig.coordinator.receive(late)
        #expect(rig.host.auditBookings.count == 2)
        #expect(rig.transport.recordAcks.filter { $0.batchID == lateID }.count == 2)

        await rig.coordinator.receive(try rig.batch(epoch: 1, doses: [(-10, 0.4)]))
        #expect(rig.host.auditRows.isEmpty)
        #expect(rig.host.bookedAuditUnits == [1.0, 0.4, 0])
        #expect(await rig.coordinator.state == .home(epoch: 2, lastLoan: .superseding(epoch: 1, at: rig.clock.now)))
    }

    @Test("A dose the watch booked as delivered counts; the audit doesn't book it again") func bookedIntent() async throws {
        let rig = try Rig()
        try await rig.lend()
        rig.clock.advance(1800)
        await rig.coordinator.receive(try rig.batch(epoch: 1, doses: [(-5, 1.0)]))
        rig.double.odometer = 11
        await rig.coordinator.takeBack()
        #expect(rig.host.auditRows.isEmpty)
        #expect(rig.host.auditBookings.isEmpty)
    }

    // MARK: Foreign sessions (C-1)

    @Test(
        "Inside the window the phone keeps commanding, audits again and alerts on every foreign session"
    ) func foreignSessionInWindow() async throws {
        let rig = try Rig()
        try await rig.lend()
        rig.double.odometer = 11
        await rig.coordinator.takeBack()
        #expect(rig.host.auditAmounts == [1.0])

        rig.clock.advance(600)
        rig.double.odometer = 11.5
        await rig.coordinator.handle(.foreignPodSession)
        #expect(!rig.double.commands.contains("stopSuperseding"))
        #expect(rig.host.alerts.filter { $0 == .watchContactedPodAfterTakeBack }.count == 1)
        #expect(rig.host.auditAmounts == [1.5])

        await rig.coordinator.handle(.foreignPodSession)
        #expect(rig.host.alerts.filter { $0 == .watchContactedPodAfterTakeBack }.count == 2)

        // the kit lost its scope: restore it with the window's end, never a plain take
        rig.double.simulateForeignSessionRefusal()
        await rig.coordinator.handle(.foreignPodSession)
        #expect(rig.double.commands.filter { $0.hasPrefix("takeControlSuperseding") }.count == 2)
        #expect(!rig.double.refusesSessions)
    }

    @Test(
        "Outside the window a foreign session ends the kit's scope, releases the pod and alerts"
    ) func foreignSessionAfterWindow() async throws {
        let rig = try Rig()
        try await rig.lend()
        await rig.coordinator.takeBack()
        rig.clock.advance(WatchLoan.resumeWindow + 1)
        let before = rig.double.commands.count
        await rig.coordinator.handle(.foreignPodSession)
        #expect(Array(rig.double.commands.dropFirst(before)) == ["stopSuperseding", "releaseControl"])
        #expect(rig.double.isControlReleased)
        #expect(rig.host.alerts.last == .unexpectedPodSession)

        // Use the pod on this iPhone lifts it again
        await rig.coordinator.usePodOnThisPhone()
        #expect(!rig.double.isControlReleased)
    }

    @Test(
        "A foreign session the phone never handled (lost report, crash) is handled at the next start, once"
    ) func foreignSessionDurable() async throws {
        let rig = try Rig()
        try await rig.lend()
        rig.double.odometer = 11
        await rig.coordinator.takeBack()
        // the kit saw the stale watch; the report never reached the coordinator
        rig.clock.advance(300)
        rig.double.foreignSessionDetectedAt = rig.clock.now
        rig.double.odometer = 11.5

        let relaunched = rig.relaunched()
        await relaunched.start()
        #expect(rig.host.alerts.filter { $0 == .watchContactedPodAfterTakeBack }.count == 1)
        #expect(rig.host.auditAmounts == [1.5])
        #expect(try rig.ledgerStore.load().get()?.lastForeignSessionHandled == rig.clock.now)

        await rig.relaunched().start()
        #expect(rig.host.alerts.filter { $0 == .watchContactedPodAfterTakeBack }.count == 1)
    }

    @Test("A delivered total that went down books nothing and alerts") func decreasingTotal() async throws {
        let rig = try Rig()
        try await rig.lend()
        rig.double.odometer = 9
        await rig.coordinator.takeBack()
        #expect(rig.host.auditBookings.isEmpty)
        #expect(rig.host.alerts.contains(.podTotalUnreliable))
        #expect(await rig.coordinator.state == .home(epoch: 2, lastLoan: .superseding(epoch: 1, at: rig.clock.now)))
    }

    @Test("A faulted pod is audited with its final total and no bolus remainder") func faultedPod() async throws {
        let rig = try Rig()
        try await rig.lend()
        rig.double.deliveredUnitsAreFinal = true
        rig.double.odometer = 11
        rig.double.bolusUnderWayEndsAt = rig.clock.now.addingTimeInterval(60)
        await rig.coordinator.takeBack()
        #expect(rig.host.auditAmounts == [1.0])
        #expect(!rig.host.alerts.contains(.podTotalUnreliable))
        #expect(try rig.ledgerStore.load().get()?.audits.last?.bolusRemainder == 0)
    }

    @Test("Records from an older loan are still merged and acknowledged") func olderEpochRecords() async throws {
        let rig = try Rig(state: .home(epoch: 4, lastLoan: LoanRecord(epoch: 3)))
        let id = UUID()
        await rig.coordinator.receive(try rig.batch(epoch: 1, id: id, doses: [(-30, 0.5)]))
        #expect(rig.host.booked.count == 1)
        #expect(rig.transport.recordAcks == [WatchLoanRecordAck(epoch: 1, batchID: id)])
        #expect(await rig.coordinator.state == .home(epoch: 4, lastLoan: LoanRecord(epoch: 3)))
    }

    @Test("A pump that never goes idle: the wait is cancelled, nothing is released, the watch is refused") func pumpIdleTimeout(
    ) async throws {
        let rig = try Rig(pumpIdleTimeout: 0.3)
        let stopped = Flag()
        rig.host.idle = {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
            stopped.set()
        }
        try await rig.receive(F.message(0, .request(requestID: F.requestA)))
        #expect(await rig.coordinator.state == .home(epoch: 1, lastLoan: nil))
        #expect(rig.double.commands.isEmpty)
        #expect(rig.transport.messages == [F.message(1, .refused(requestID: F.requestA, reason: .releaseRefused))])
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(stopped.isSet)
    }

    @Test("The watch's released stop ends the window and the kit's scope") func releasedStopClearsWindow() async throws {
        let rig = try Rig()
        try await rig.lend()
        await rig.coordinator.takeBack()
        await rig.coordinator.receive([WatchLoanWireKey.message: try WatchLoanWire.encode(
            WatchLoanStop(kind: .stop, epoch: 1, released: true)
        )])
        #expect(await rig.coordinator.state == .home(epoch: 2, lastLoan: LoanRecord(epoch: 1)))
        #expect(rig.double.commands.last == "stopSuperseding")
    }

    @Test("Use the pod on this iPhone after an unknown session lifts the kit's refusal without a window") func usePodOnThisPhone(
    ) async throws {
        let rig = try Rig(state: .home(epoch: 4, lastLoan: nil))
        rig.double.simulateForeignSessionRefusal()
        await rig.coordinator.usePodOnThisPhone()
        #expect(await rig.coordinator.state == .home(epoch: 5, lastLoan: LoanRecord(epoch: nil)))
        #expect(rig.double.commands.prefix(3) == ["takeControlLiftingRefusal", "tempBasal(0.0)", "refreshDeliveredUnits"])
        #expect(rig.host.alerts.contains(.podTakenOnThisPhone))
    }

    // MARK: Relaunch (C-3)

    @Test("Relaunch in takingBack redoes take (same window), cancel, read and the same audit, once") func relaunchRedo() async throws {
        let rig = try Rig()
        try await rig.lend()
        rig.double.odometer = 11
        rig.clock.advance(900)
        await rig.coordinator.takeBack()
        let loan = LoanRecord.superseding(epoch: 1, at: rig.clock.now)
        let until = Int(try #require(loan.supersededUntil).timeIntervalSince1970)
        #expect(rig.host.auditAmounts == [1.0])

        // crash after the audit, before `home` was persisted
        try rig.store.save(.takingBack(epoch: 2, loan: loan))
        rig.clock.advance(60)
        let relaunched = rig.relaunched()
        await relaunched.start()

        #expect(await relaunched.state == .home(epoch: 2, lastLoan: loan))
        #expect(rig.double.commands.suffix(3) == ["takeControlSuperseding(\(until))", "tempBasal(0.0)", "refreshDeliveredUnits"])
        #expect(rig.host.auditAmounts == [1.0])
        #expect(rig.host.auditBookings.count == 1)
        #expect(rig.host.alarms.last { $0.alarm == .phoneNotLooping }?.armed == true)
    }

    // MARK: Alarms (V2-12, V2-14)

    @Test("Queued batches that arrive together arm the watch-silence alarm once") func silenceAlarmBurst() async throws {
        let rig = try Rig()
        try await rig.lend()
        rig.clock.advance(1800)
        func silenceArms() -> Int { rig.host.alarms.filter { $0.alarm == .phoneNoWatchUpdates && $0.armed }.count }
        let before = silenceArms()
        for _ in 0 ..< 5 {
            await rig.coordinator.receive(try rig.batch(epoch: 1, doses: []))
            rig.clock.advance(1)
        }
        #expect(silenceArms() == before + 1)
        #expect(rig.host.alarms.last { $0.alarm == .phoneNoWatchUpdates }?.anchor == rig.clock.now.addingTimeInterval(-5))

        rig.clock.advance(WatchLoanCoordinator.silenceRearmInterval)
        await rig.coordinator.receive(try rig.batch(epoch: 1, doses: []))
        #expect(silenceArms() == before + 2)
    }

    @Test("Live Activity: one chart reading per interval, whole seconds, and an update that fits in 4 KB") func liveActivitySize(
    ) {
        let now = Date()
        // a sensor read by the phone and the watch: a reading every 2.5 min for 6 hours
        let doubled = (0 ..< 144).map {
            GlucoseData(glucose: 100 + $0 % 40, date: now.addingTimeInterval(-Double($0) * 150 - 0.37), direction: .flat)
        }
        let thinned = LiveActivityAttributes.ContentState.thinned(doubled, spacing: 240)
        #expect(thinned.count == 72)
        #expect(thinned.first?.date == doubled.first?.date)

        func state(_ chart: [GlucoseData]) -> LiveActivityAttributes.ContentState {
            .fitting { spacing in
                LiveActivityAttributes.ContentState(
                    new: chart[0], prev: chart[1], units: .mgdL, chart: chart, settings: TrioSettings(), determination: nil,
                    iob: 1, override: nil, tempTarget: nil, widgetItems: LiveActivityAttributes.LiveActivityItem.defaultItems,
                    chartSpacing: spacing
                )
            }
        }
        let fromDoubled = state(doubled)
        #expect(fromDoubled.fitsUpdateLimit)
        #expect(fromDoubled.detailedViewState.chart.count == 72)
        #expect(fromDoubled.detailedViewState.chart.allSatisfy {
            $0.date.timeIntervalSinceReferenceDate == $0.date.timeIntervalSinceReferenceDate.rounded()
        })

        // a reading a minute: thinner still until it fits
        let everyMinute = (0 ..< 360).map {
            GlucoseData(glucose: 100 + $0 % 40, date: now.addingTimeInterval(-Double($0) * 60), direction: .flat)
        }
        let fromEveryMinute = state(everyMinute)
        #expect(fromEveryMinute.fitsUpdateLimit)
        // the delta still comes from the two newest readings
        #expect(fromEveryMinute.change == LiveActivityAttributes.ContentState.calculateChange(chart: everyMinute, units: .mgdL))
    }

    @Test("Lent: not-looping off, watch silence armed from the last batch, kept across a relaunch") func silenceAlarm() async throws {
        let rig = try Rig()
        try await rig.receive(F.message(0, .request(requestID: F.requestA)))
        try await rig.receive(F.message(1, .holding))
        let lentAt = rig.clock.now
        #expect(rig.host.alarms.last { $0.alarm == .phoneNoWatchUpdates }?.armed == true)
        #expect(rig.host.alarms.last { $0.alarm == .phoneNoWatchUpdates }?.anchor == lentAt)
        #expect(rig.host.alarms.last { $0.alarm == .phoneNotLooping }?.armed == false)

        rig.clock.advance(900)
        await rig.coordinator.receive(try rig.batch(epoch: 1, doses: []))
        let batchAt = rig.clock.now
        #expect(rig.host.alarms.last?.alarm == .phoneNoWatchUpdates)
        #expect(rig.host.alarms.last?.anchor == batchAt)

        rig.clock.advance(600)
        let relaunched = rig.relaunched()
        await relaunched.start()
        #expect(rig.host.alarms.last { $0.alarm == .phoneNoWatchUpdates }?.anchor == batchAt)
        #expect(rig.host.alarms.last { $0.alarm == .phoneNotLooping }?.armed == false)

        await relaunched.takeBack()
        #expect(rig.host.alarms.last { $0.alarm == .phoneNotLooping }?.armed == true)
        #expect(rig.host.alarms.last { $0.alarm == .phoneNoWatchUpdates }?.armed == false)
    }

    // MARK: Transport

    @Test("A message id is passed on once") func dedupe() async throws {
        let rig = try Rig(state: .home(epoch: 2, lastLoan: LoanRecord(epoch: 1)))
        let id = UUID()
        try await rig.receive(F.message(1, .handBack), id: id)
        try await rig.receive(F.message(1, .handBack), id: id)
        #expect(rig.transport.messages == [F.message(1, .handBackAck)])
        try await rig.receive(F.message(1, .handBack))
        #expect(rig.transport.messages.count == 2)
        // a relaunch keeps the ids it saw
        await rig.relaunched().receive(try rig.envelope(F.message(1, .handBack), id: id))
        #expect(rig.transport.messages.count == 2)
    }

    @Test("Below the phone's epoch only request, grant rejected, hand-back and records pass") func epochFilter() {
        // a watch that never got the grant rejects it from its older epoch
        let passing: [WatchLoanMessage.Kind] = [
            .request(requestID: F.requestA), .grantRejected(requestID: F.requestA, reason: .grantExpired), .handBack, .records
        ]
        let dropped: [WatchLoanMessage.Kind] = [
            .holding, .status(.idle(epoch: 1)),
            .handBackAck, .statusQuery, .refused(requestID: F.requestA, reason: .busy),
            .grant(requestID: F.requestA, expiresAt: F.now)
        ]
        for kind in passing {
            #expect(WatchLoanInbox.passes(WatchLoanMessage(epoch: 1, kind: kind), phoneEpoch: 2))
        }
        for kind in dropped {
            #expect(!WatchLoanInbox.passes(WatchLoanMessage(epoch: 1, kind: kind), phoneEpoch: 2))
            #expect(WatchLoanInbox.passes(WatchLoanMessage(epoch: 2, kind: kind), phoneEpoch: 2))
        }
        #expect(WatchLoanInbox.passes(WatchLoanMessage(epoch: 0, kind: .holding), phoneEpoch: nil))
    }

    @Test("The inbox forgets the oldest ids beyond its capacity") func inboxCapacity() {
        var inbox = WatchLoanInbox()
        let first = UUID()
        let accepted = inbox.accept(first)
        let repeated = inbox.accept(first)
        #expect(accepted && !repeated)
        for _ in 0 ..< WatchLoanInbox.capacity { _ = inbox.accept(UUID()) }
        #expect(inbox.seen.count == WatchLoanInbox.capacity)
        let forgotten = inbox.accept(first)
        #expect(forgotten)
    }

    @Test("Records from a newer protocol aren't merged or acknowledged") func recordsOtherVersion() async throws {
        let rig = try Rig(state: .lent(epoch: 1))
        var batch = WatchLoanRecordBatch(
            version: WatchLoanRecordBatch.currentVersion + 1, batchID: UUID(), epoch: 1, sentAt: F.now, pumpEvents: [],
            runningTemp: nil, carbs: [], deletedCarbIDs: [], glucose: []
        )
        await rig.coordinator.receive([WatchLoanWireKey.records: try batch.encoded()])
        #expect(rig.transport.recordAcks.isEmpty)
        batch.version = WatchLoanRecordBatch.currentVersion
        await rig.coordinator.receive([WatchLoanWireKey.records: try batch.encoded()])
        #expect(rig.transport.recordAcks == [WatchLoanRecordAck(epoch: 1, batchID: batch.batchID)])
    }

    @Test("A batch carries the watch's last loop for the pill; one without it still decodes (G-2)") func watchLoop() async throws {
        let rig = try Rig(state: .lent(epoch: 2))
        var batch = WatchLoanRecordBatch(
            version: WatchLoanRecordBatch.currentVersion, batchID: UUID(), epoch: 2, sentAt: F.now, pumpEvents: [],
            runningTemp: nil, carbs: [], deletedCarbIDs: [], glucose: []
        )
        let older = try JSONSerialization.jsonObject(with: try batch.encoded()) as? [String: Any]
        #expect(older?["lastLoopAt"] == nil)
        await rig.coordinator.receive([WatchLoanWireKey.records: try batch.encoded()])
        #expect(await rig.coordinator.watchLoopAt == nil)
        #expect(await rig.coordinator.lastBatchAt != nil)

        batch.batchID = UUID()
        batch.lastLoopAt = F.now.addingTimeInterval(-240)
        await rig.coordinator.receive([WatchLoanWireKey.records: try batch.encoded()])
        #expect(await rig.coordinator.watchLoopAt == F.now.addingTimeInterval(-240))

        // a late batch from an earlier loan never shows as this loan's loop
        batch.batchID = UUID()
        batch.epoch = 1
        batch.lastLoopAt = F.now
        await rig.coordinator.receive([WatchLoanWireKey.records: try batch.encoded()])
        #expect(await rig.coordinator.watchLoopAt == F.now.addingTimeInterval(-240))
    }

    // MARK: The pump double

    @Test("A whole loan never commands the pump while the phone doesn't hold it") func noCommandWhileReleased() async throws {
        let rig = try Rig()
        try await rig.lend()
        try await rig.receive(F.message(1, .handBack))
        #expect(await rig.coordinator.state == .home(epoch: 2, lastLoan: LoanRecord(epoch: 1)))
        try await rig.receive(F.message(2, .request(requestID: F.requestB)))
        try await rig.receive(F.message(3, .holding))
        await rig.coordinator.takeBack()
        await rig.coordinator.handle(.foreignPodSession)
        #expect(await rig.coordinator.state == .home(epoch: 4, lastLoan: .superseding(epoch: 3, at: rig.clock.now)))
        #expect(rig.double.commands.filter { $0 == "releaseControl" }.count == 2)
    }

    @Test("The double fails a test that commands a released pump") func doubleCatchesCommand() async {
        let double = LoanPumpDouble()
        double.releaseControl()
        await withKnownIssue {
            _ = await double.refreshDeliveredUnits()
        } matching: { issue in
            String(describing: issue).contains("doesn't hold the pod")
        }
    }

    // MARK: Start preconditions (V2-2, V2-26, M3C-01)

    @Test("Start preconditions, in order") func preconditions() {
        let double = LoanPumpDouble()
        let now = F.now
        func refusal(
            mode: DosingMode = .closed,
            cgm: Bool = true,
            screen: Bool = false,
            override: Bool = false
        ) -> LoanRefusal? {
            BaseWatchLoanPhoneHost.preconditionRefusal(
                dosingMode: mode,
                pump: WatchLoanPumpAdapter(double),
                cgmShared: cgm,
                kitScreenOpen: screen,
                indefiniteOverride: override,
                now: now
            )
        }
        #expect(BaseWatchLoanPhoneHost.preconditionRefusal(
            dosingMode: .closed, pump: nil, cgmShared: true, kitScreenOpen: false, indefiniteOverride: false, now: now
        ) == .unsupportedDevice)
        for mode in [DosingMode.open, .lowGlucoseSuspend, .basalTesting] {
            #expect(refusal(mode: mode, cgm: false, screen: true) == .notClosedLoop, "\(mode)")
        }
        #expect(refusal(cgm: false) == .unsupportedDevice)
        #expect(refusal(screen: true) == .pumpScreenOpen)
        double.deliveredUnits = (10, now.addingTimeInterval(-60))
        #expect(refusal() == nil)
        #expect(refusal(override: true) == .indefiniteOverride)
        double.deliveredUnits = (10, now.addingTimeInterval(-BaseWatchLoanPhoneHost.pumpStatusMaxAge))
        #expect(refusal() == .pumpStatusStale)
        double.deliveredUnits = (10, now)
        double.status.deliveryIsUncertain = true
        #expect(refusal() == .deliveryUncertain)
        double.status.bolusState = .inProgress(DoseEntry(
            type: .bolus, startDate: now, endDate: now.addingTimeInterval(60), value: 1, unit: .units, decisionId: nil
        ))
        #expect(refusal() == .bolusRunning)
    }

    @Test("An open kit screen counts until it's dismantled") func kitScreens() {
        #expect(!PumpConfig.isKitScreenOpen)
        let settings = PumpConfig.KitScreenToken()
        let setup = PumpConfig.KitScreenToken()
        settings.open()
        settings.open()
        setup.open()
        #expect(PumpConfig.isKitScreenOpen)
        settings.close()
        #expect(PumpConfig.isKitScreenOpen)
        setup.close()
        setup.close()
        #expect(!PumpConfig.isKitScreenOpen)
    }
}
