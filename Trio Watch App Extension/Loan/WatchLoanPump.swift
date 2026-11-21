import Foundation
import LoopKit
import OmnipodKit

/// The pump the watch borrows: LoopKit's pump, hand-off and odometer APIs, and the kit's report of another
/// controller using the pod.
protocol LoanPump: PumpManager, ExclusiveDeviceControl, PumpDeliveryOdometer {
    /// After another controller used the pod, the kit runs no session at all.
    var refusesSessions: Bool { get }
    var foreignSessionDetectedAt: Date? { get }
    /// Reads the pod's status once its data is older than `age` (below `ensureCurrentPumpData`'s 6 minutes).
    func readStatusIfOlder(than age: TimeInterval, completion: @escaping (Date?) -> Void)
}

extension OmniPumpManager: LoanPump {}

/// Builds the one pump manager the watch keeps: once from the grant, afterwards only from its own saved state.
struct LoanPumpFactory {
    var adopt: (SharedDeviceConfiguration, [String: Any]?) -> LoanPump?
    var restore: ([String: Any]) -> LoanPump?

    static let omnipod = LoanPumpFactory(
        adopt: { OmniPumpManager(adopting: $0, localState: $1) },
        restore: { OmniPumpManager(rawState: $0) }
    )
}

/// The kit's callbacks for the host. Kit state is saved on the kit's queue before the callback returns.
final class WatchLoanPumpDelegate: PumpManagerDelegate {
    weak var host: WatchLoanHost?
    private let files: WatchLoanFiles
    private let records: WatchLoanRecordStore
    private let now: () -> Date
    private let linkEvents = LinkEventClock()

    init(files: WatchLoanFiles, records: WatchLoanRecordStore, now: @escaping () -> Date) {
        self.files = files
        self.records = records
        self.now = now
    }

    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {
        do {
            try files.savePlist(pumpManager.rawState, to: .pumpState)
        } catch {
            WatchLogger.shared.error(.pump, "Saving the pump state failed", error: error)
            Task { @MainActor [weak host] in host?.pumpStateNotSaved() }
        }
        guard let pump = pumpManager as? LoanPump else { return }
        let foreign = pump.refusesSessions || pump.foreignSessionDetectedAt != nil
        Task { @MainActor [weak host] in host?.pumpStateChanged(foreignSession: foreign) }
    }

    func pumpManager(
        _: PumpManager,
        hasNewPumpEvents events: [NewPumpEvent],
        lastReconciliation _: Date?,
        replacePendingEvents: Bool,
        completion: @escaping (Error?) -> Void
    ) {
        do {
            try records.storePumpEvents(events, replacePendingEvents: replacePendingEvents, at: now())
            completion(nil)
        } catch {
            WatchLogger.shared.error(.pump, "Storing pump events failed", error: error)
            completion(error)
        }
    }

    func deviceManagerControlDidBecomeReady(_ manager: DeviceManager) {
        WatchLogger.shared.info(.pump, "Pump answered: control ready")
        guard let pump = manager as? LoanPump else { return }
        Task { @MainActor [weak host] in host?.pumpControlBecameReady(pump) }
    }

    func pumpManager(_: PumpManager, didError error: PumpManagerError) {
        WatchLogger.shared.warning(.pump, "Pump reported an error", error: error)
        Task { @MainActor [weak host] in host?.deviceError(error) }
    }

    func pumpManager(_: PumpManager, didUpdate status: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
        if status.deliveryIsUncertain {
            WatchLogger.shared.warning(.pump, "Pump reports delivery uncertain")
        }
    }

    func pumpManagerBLEHeartbeatDidFire(_: PumpManager) {}
    func pumpManagerMustProvideBLEHeartbeat(_: PumpManager) -> Bool { false }
    func pumpManagerWantsDeletion(_: PumpManager) async {}
    func pumpManagerPumpWasReplaced(_: PumpManager) {}
    func pumpManager(_: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents _: Bool) {}
    func pumpManager(
        _: PumpManager,
        didReadReservoirValue _: Double,
        at _: Date,
        completion: @escaping (Result<
            (newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool),
            Error
        >)
            -> Void
    ) {
        completion(.failure(WatchLoanHostError.notStored))
    }

    func pumpManager(_: PumpManager, didAdjustPumpClockBy adjustment: TimeInterval) {
        WatchLogger.shared.info(.pump, "Pump clock adjusted by \(Int(adjustment)) s")
    }

    func pumpManager(
        _: PumpManager,
        didRequestBasalRateScheduleChange _: BasalRateSchedule,
        completion: @escaping (Error?) -> Void
    ) {
        // schedules are the phone's; the watch never changes them
        completion(WatchLoanHostError.notStored)
    }

    func startDateToFilterNewPumpEvents(for _: PumpManager) -> Date { now().addingTimeInterval(-WatchLoopPolicy.recordsRetention)
    }

    var detectedSystemTimeOffset: TimeInterval { 0 }
    var automaticDosingEnabled: Bool { true }
    var automatedTreatmentState: AutomatedTreatmentState? { nil }

    func deviceManager(
        _: DeviceManager,
        logEventForDeviceIdentifier _: String?,
        type: DeviceLogEntryType,
        message: String,
        completion: ((Error?) -> Void)?
    ) {
        WatchLogger.shared.debug(.pump, "Pump \(type): \(message)")
        if type == .connection { linkEvents.note("Pump", category: .pump) }
        completion?(nil)
    }

    // The kit's own alerts reach the user as notifications.
    @MainActor func issueAlert(_ alert: Alert) async {
        await host?.issueKitAlert(alert)
    }

    @MainActor func retractAlert(identifier: Alert.Identifier) async {
        await host?.retractKitAlert(identifier)
    }

    func doesIssuedAlertExist(identifier _: Alert.Identifier) async throws -> Bool { false }
    func lookupAllUnretracted(managerIdentifier _: String) async throws -> [PersistedAlert] { [] }
    func lookupAllUnacknowledgedUnretracted(managerIdentifier _: String) async throws -> [PersistedAlert] { [] }
    func recordRetractedAlert(_: Alert, at _: Date) async throws {}
}
