import Combine
import Foundation
import LoopKit
import LoopKitUI
import Swinject
import Testing

@testable import Trio

/// Every phone pump-command path (V2-27, C-05) refuses while the phone isn't owner, and does what it did
/// before when there is no loan state file.
@Suite("Watch loan: phone gate on every pump path", .serialized) struct WatchLoanGateTests {
    private final class CountingTDDStorage: TDDStorage {
        private(set) var calculations = 0

        func calculateTDD(
            pumpManager _: any PumpManagerUI,
            pumpHistory _: [PumpHistoryEvent],
            basalProfile _: [BasalProfileEntry]
        ) async throws -> TDDResult {
            calculations += 1
            return TDDResult(total: 0, bolus: 0, tempBasal: 0, scheduledBasal: 0, weightedAverage: 0, hoursOfData: 0)
        }

        func storeTDD(_: TDDResult) async {}
        func hasSufficientTDD() async throws -> Bool { true }
    }

    private final class GateAssembly: Assembly {
        let gate: WatchLoanGate
        let tdd: CountingTDDStorage

        init(gate: WatchLoanGate, tdd: CountingTDDStorage) {
            self.gate = gate
            self.tdd = tdd
        }

        func assemble(container: Container) {
            container.register(WatchLoanGate.self) { _ in self.gate }
            container.register(TDDStorage.self) { _ in self.tdd }
            // One device manager for the APS manager and the test
            container.register(DeviceDataManager.self) { r in BaseDeviceDataManager(resolver: r) }.inObjectScope(.container)
        }
    }

    private struct Rig {
        let resolver: Resolver
        let tdd: CountingTDDStorage
        let spy = SpyPumpManager()
        var deviceDataManager: BaseDeviceDataManager { resolver.resolve(DeviceDataManager.self) as! BaseDeviceDataManager }
        var apsManager: BaseAPSManager { resolver.resolve(APSManager.self) as! BaseAPSManager }
    }

    /// `owner == false` persists `lent`; `owner == true` leaves no file, which is today's state.
    private static func makeRig(owner: Bool) async throws -> Rig {
        let store = WatchLoanStoreTests.temporaryStore()
        if !owner { try store.save(.lent(epoch: 1)) }
        let tdd = CountingTDDStorage()
        let coreDataStack = try await CoreDataStack.createForTests()
        let resolver = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: coreDataStack.newTaskContext()),
            GateAssembly(gate: WatchLoanGate(store: store), tdd: tdd)
        ]).resolver
        return Rig(resolver: resolver, tdd: tdd)
    }

    /// Setting a pump persists its raw state; clear it so later suites start without one.
    private static func clearStoredPump(_ rig: Rig) async {
        try? await Task.sleep(nanoseconds: 700_000_000)
        rig.deviceDataManager.rawPumpManager = nil
    }

    private static func eventually(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private static func settleBriefly() async {
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: Gate

    @Test("Gate: no file means owner; every hand-off state and an unreadable file mean not owner") func gateStates() throws {
        let store = WatchLoanStoreTests.temporaryStore()
        let gate = WatchLoanGate(store: store)
        #expect(gate.permits("Test"))
        for state in [
            PhoneLoanState.lending(epoch: 1, requestID: LoanFixture.requestA),
            .lent(epoch: 1),
            .takingBack(epoch: 2, loan: LoanRecord(epoch: 1))
        ] {
            try store.save(state)
            #expect(!gate.permits("Test"), "\(state)")
        }
        let handedOver = gate.refusal("Test")
        try store.save(.home(epoch: 2, lastLoan: LoanRecord(epoch: 1)))
        #expect(gate.permits("Test"))
        #expect(gate.refusal("Test") == nil)
        try Data("{".utf8).write(to: store.url)
        #expect(!gate.permits("Test"))
        let unreadable = gate.refusal("Test")
        #expect(handedOver != nil && unreadable != nil && handedOver != unreadable)
    }

    // MARK: APSManager

    @Test(
        "Loop (incl. re-entry after a manual temp ends): skipped when not owner, starts when owner",
        arguments: [false, true]
    ) func loop(owner: Bool) async throws {
        let rig = try await Self.makeRig(owner: owner)
        let aps = rig.apsManager
        aps.pumpManager = rig.spy
        aps.lastLoopDate = .distantPast
        aps.isManualTempBasal = false
        var started = false
        let cancellable = aps.isLooping.sink { if $0 { started = true } }
        rig.deviceDataManager.manualTempBasal.send(true)
        rig.deviceDataManager.manualTempBasal.send(false)
        if owner {
            #expect(await Self.eventually(5) { started })
        } else {
            await Self.settleBriefly()
            #expect(!started)
        }
        cancellable.cancel()
        await Self.clearStoredPump(rig)
    }

    @Test("Bolus: refused with an answer when not owner, enacted when owner", arguments: [
        false,
        true
    ]) func bolus(owner: Bool) async throws {
        let rig = try await Self.makeRig(owner: owner)
        let aps = rig.apsManager
        aps.pumpManager = rig.spy
        var answer: Bool?
        await aps.enactBolus(amount: 1, isSMB: true) { success, _ in answer = success }
        #expect(answer == owner)
        #expect(rig.spy.commands.contains("enactBolus") == owner)
        await Self.clearStoredPump(rig)
    }

    @Test("Cancel bolus: refused with an answer when not owner, sent when owner", arguments: [
        false,
        true
    ]) func cancelBolus(owner: Bool) async throws {
        let rig = try await Self.makeRig(owner: owner)
        let aps = rig.apsManager
        rig.spy.status.bolusState = .inProgress(DoseEntry(
            type: .bolus, startDate: Date(), endDate: Date().addingTimeInterval(60), value: 1, unit: .units, decisionId: nil
        ))
        aps.pumpManager = rig.spy
        var answer: (Bool, String)?
        await aps.cancelBolus { answer = ($0, $1) }
        #expect(answer?.0 == owner)
        #expect(rig.spy.commands.contains("cancelBolus") == owner)
        if !owner { #expect(answer?.1.contains("Apple Watch") == true) }
        await Self.clearStoredPump(rig)
    }

    @Test(
        "Loop enactment: throws before touching anything when not owner, runs as before when owner",
        arguments: [false, true]
    ) func enactDetermination(owner: Bool) async throws {
        let rig = try await Self.makeRig(owner: owner)
        let aps = rig.apsManager
        aps.pumpManager = rig.spy
        do {
            _ = try await aps.enactDetermination()
            Issue.record("Expected a throw: no determination is stored")
        } catch let APSError.invalidPumpState(message) {
            #expect(!owner, "owner was gated: \(message)")
        } catch let APSError.apsError(message) {
            #expect(owner, "not owner reached the determination lookup: \(message)")
        }
        #expect(!rig.spy.commands.contains("enactTempBasal"))
        await Self.clearStoredPump(rig)
    }

    @Test(
        "Temp cancel for basal testing: not sent when not owner, sent when owner",
        arguments: [false, true]
    ) func cancelAutomaticTempBasal(owner: Bool) async throws {
        let rig = try await Self.makeRig(owner: owner)
        let aps = rig.apsManager
        rig.spy.status.basalDeliveryState = .tempBasal(DoseEntry(
            type: .tempBasal, startDate: Date(), endDate: Date().addingTimeInterval(1800), value: 1,
            unit: .unitsPerHour, decisionId: nil, automatic: true
        ))
        aps.pumpManager = rig.spy
        aps.isManualTempBasal = false
        await aps.cancelAutomaticTempBasal()
        #expect(rig.spy.commands.contains("enactTempBasal") == owner)
        await Self.clearStoredPump(rig)
    }

    @Test(
        "TDD: skipped for a released pump, calculated when owner",
        arguments: [false, true]
    ) func tdd(owner: Bool) async throws {
        let rig = try await Self.makeRig(owner: owner)
        let aps = rig.apsManager
        aps.pumpManager = rig.spy
        _ = try? await aps.determineBasal()
        #expect(rig.tdd.calculations == (owner ? 1 : 0))
        await Self.clearStoredPump(rig)
    }

    // MARK: DeviceDataManager

    @Test(
        "Pump set (launch restore): delivery limits and heartbeat request not sent when not owner",
        arguments: [false, true]
    ) func pumpSet(owner: Bool) async throws {
        let rig = try await Self.makeRig(owner: owner)
        let ddm = rig.deviceDataManager
        ddm.updatePumpBLEHeartbeat(lastCGMReadingDate: Date(), expectedCGMReadingInterval: 300)
        ddm.pumpManager = rig.spy
        if owner {
            #expect(await Self.eventually { rig.spy.commands.contains("syncDeliveryLimits") })
            #expect(rig.spy.commands.contains("setBLEHeartbeatRequest"))
        } else {
            await Self.settleBriefly()
            #expect(rig.spy.commands.isEmpty)
        }
        await Self.clearStoredPump(rig)
    }

    @Test(
        "BLE heartbeat requests: not sent when not owner",
        arguments: [false, true]
    ) func bleHeartbeat(owner: Bool) async throws {
        let rig = try await Self.makeRig(owner: owner)
        let ddm = rig.deviceDataManager
        ddm.pumpManager = rig.spy
        await Self.settleBriefly()
        let before = rig.spy.commands.filter { $0 == "setBLEHeartbeatRequest" }.count
        ddm.updatePumpBLEHeartbeat(lastCGMReadingDate: Date(), expectedCGMReadingInterval: 300)
        ddm.updateCGMHeartbeatCapability(providesBLEHeartbeat: true)
        ddm.updatePumpBLEHeartbeat(lastCGMReadingDate: Date(), expectedCGMReadingInterval: 300)
        let after = rig.spy.commands.filter { $0 == "setBLEHeartbeatRequest" }.count
        #expect(after - before == (owner ? 3 : 0))
        await Self.clearStoredPump(rig)
    }

    @Test("Heartbeat: no pump refresh and no loop request when not owner", arguments: [
        false,
        true
    ]) func heartbeat(owner: Bool) async throws {
        let rig = try await Self.makeRig(owner: owner)
        let ddm = rig.deviceDataManager
        ddm.pumpManager = rig.spy
        var loopRequested = false
        let cancellable = ddm.recommendsLoop.sink { loopRequested = true }
        ddm.heartbeat(date: Date())
        #expect(rig.spy.commands.contains("ensureCurrentPumpData") == owner)
        #expect(loopRequested == owner)
        cancellable.cancel()
        await Self.clearStoredPump(rig)
    }

    @Test("Pump alert acknowledgement: not sent to the pump when not owner", arguments: [
        false,
        true
    ]) func alertAcknowledgement(owner: Bool) async throws {
        let rig = try await Self.makeRig(owner: owner)
        let alertManager = try #require(rig.resolver.resolve(TrioAlertManager.self) as? BaseTrioAlertManager)
        alertManager.register(responder: rig.spy, for: rig.spy.pluginIdentifier)
        alertManager.handleAcknowledgement(
            identifier: Alert.Identifier(managerIdentifier: rig.spy.pluginIdentifier, alertIdentifier: "test")
        )
        if owner {
            #expect(await Self.eventually { rig.spy.commands.contains("acknowledgeAlert") })
        } else {
            await Self.settleBriefly()
            #expect(!rig.spy.commands.contains("acknowledgeAlert"))
        }
    }

    // MARK: Settings sync

    private static func complete(_ publisher: AnyPublisher<Void, Error>) async -> Bool {
        await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = publisher.sink { completion in
                if case .finished = completion { continuation.resume(returning: true) }
                else { continuation.resume(returning: false) }
                _ = cancellable
            } receiveValue: {}
        }
    }

    @Test(
        "Delivery limits from settings (three screens): refused when not owner",
        arguments: [false, true]
    ) func deliveryLimitsFromSettings(owner: Bool) async throws {
        let rig = try await Self.makeRig(owner: owner)
        rig.deviceDataManager.pumpManager = rig.spy
        await Self.settleBriefly()
        let before = rig.spy.commands.filter { $0 == "syncDeliveryLimits" }.count

        let units = UnitsLimitsSettings.Provider(resolver: rig.resolver)
        let algorithm = AlgorithmAdvancedSettings.Provider(resolver: rig.resolver)
        let nightscout = NightscoutConfig.Provider(resolver: rig.resolver)
        let settings = units.settings()

        #expect(await Self.complete(units.save(settings: settings)) == owner)
        #expect(await Self.complete(algorithm.save(settings: settings)) == owner)
        #expect(await Self.complete(nightscout.savePumpSettings(settings: settings)) == owner)
        let after = rig.spy.commands.filter { $0 == "syncDeliveryLimits" }.count
        #expect(after - before == (owner ? 3 : 0))
        await Self.clearStoredPump(rig)
    }

    @Test("Basal schedule sync: refused when not owner", arguments: [false, true]) func basalSchedule(owner: Bool) async throws {
        let rig = try await Self.makeRig(owner: owner)
        rig.deviceDataManager.pumpManager = rig.spy
        let provider = BasalProfileEditor.Provider(resolver: rig.resolver)
        #expect(await Self.complete(provider.saveProfile(provider.profile)) == owner)
        #expect(rig.spy.commands.contains("syncBasalRateSchedule") == owner)
        await Self.clearStoredPump(rig)
    }

    // MARK: UI

    @Test("Pump settings and setup screens: replaced by the reason when not owner") @MainActor func pumpScreens() throws {
        let store = WatchLoanStoreTests.temporaryStore()
        #expect(PumpConfig.handedOverViewController(gate: WatchLoanGate(store: store)) == nil)
        try store.save(.lent(epoch: 1))
        #expect(PumpConfig.handedOverViewController(gate: WatchLoanGate(store: store)) != nil)
    }

    @Test("Dosing Mode: locked while the phone doesn't hold the pump") func dosingModeLock() throws {
        let store = WatchLoanStoreTests.temporaryStore()
        func reason(devices: Bool = true) -> String? {
            Settings.StateModel.dosingModeLockReason(
                hasCgmAndPump: devices,
                phoneMayCommandPump: WatchLoanGate(store: store).phoneMayCommandPump
            )
        }
        #expect(reason() == nil)
        let noDevices = try #require(reason(devices: false))
        try store.save(.lent(epoch: 1))
        let lent = try #require(reason())
        #expect(lent != noDevices)
        try store.save(.home(epoch: 1, lastLoan: nil))
        #expect(reason() == nil)
    }
}
