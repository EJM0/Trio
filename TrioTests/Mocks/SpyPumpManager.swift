import Foundation
import HealthKit
import LoopKit
import LoopKitUI
import UIKit

/// Records every command it receives and answers success. Status is settable.
final class SpyPumpManager: PumpManagerUI {
    private let lock = NSLock()
    private var _commands: [String] = []

    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _commands
    }

    private func record(_ command: String) {
        lock.lock()
        _commands.append(command)
        lock.unlock()
    }

    var status = PumpManagerStatus(
        timeZone: .current,
        device: HKDevice(
            name: "Spy",
            manufacturer: nil,
            model: nil,
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: nil,
            udiDeviceIdentifier: nil
        ),
        pumpBatteryChargeRemaining: nil,
        basalDeliveryState: .active(Date()),
        bolusState: .noBolus,
        insulinType: .novolog
    )

    // MARK: DeviceManager

    static let onboardingImage: UIImage? = nil
    var smallImage: UIImage? { nil }
    var pluginIdentifier: String { "SpyPumpManager" }
    var localizedTitle: String { "Spy" }
    var debugDescription: String { "SpyPumpManager" }
    var rawState: RawStateValue { [:] }
    var isOnboarded: Bool { true }
    var inSignalLoss: Bool { false }
    var isInoperable: Bool { false }

    init() {}
    init?(rawState _: RawStateValue) {}

    func acknowledgeAlert(alertIdentifier _: Alert.AlertIdentifier) async throws { record("acknowledgeAlert") }
    func getSoundBaseURL() -> URL? { nil }
    func getSounds() -> [Alert.Sound] { [] }

    // MARK: PumpManager

    static let onboardingMaximumBasalScheduleEntryCount = 24
    static let onboardingSupportedBasalRates: [Double] = (1 ... 300).map { Double($0) / 10 }
    // 0.1 U first, so setting the spy leaves the stored bolus increment at its default
    static let onboardingSupportedBolusVolumes: [Double] = (1 ... 300).map { Double($0) / 10 }
    static let onboardingSupportedMaximumBolusVolumes: [Double] = onboardingSupportedBolusVolumes

    var delegateQueue: DispatchQueue!
    var supportedBasalRates: [Double] { Self.onboardingSupportedBasalRates }
    var supportedBolusVolumes: [Double] { Self.onboardingSupportedBolusVolumes }
    var supportedMaximumBolusVolumes: [Double] { Self.onboardingSupportedMaximumBolusVolumes }
    var maximumBasalScheduleEntryCount: Int { 24 }
    var minimumBasalScheduleEntryDuration: TimeInterval { 30 * 60 }
    weak var pumpManagerDelegate: PumpManagerDelegate?
    var pumpRecordsBasalProfileStartEvents: Bool { false }
    var pumpReservoirCapacity: Double { 200 }
    var lastSync: Date?

    func addStatusObserver(_: PumpManagerStatusObserver, queue _: DispatchQueue) {}
    func removeStatusObserver(_: PumpManagerStatusObserver) {}

    func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        record("ensureCurrentPumpData")
        completion?(Date())
    }

    func setMustProvideBLEHeartbeat(_: Bool) { record("setMustProvideBLEHeartbeat") }
    func setBLEHeartbeatRequest(_: PumpHeartbeatRequest?) { record("setBLEHeartbeatRequest") }
    func createBolusProgressReporter(reportingOn _: DispatchQueue) -> DoseProgressReporter? { nil }
    func estimatedDuration(toBolus units: Double) -> TimeInterval { units * 40 }

    func enactBolus(
        decisionId _: UUID?,
        units _: Double,
        activationType _: BolusActivationType,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        record("enactBolus")
        completion(nil)
    }

    func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        record("cancelBolus")
        completion(.success(nil))
    }

    func enactTempBasal(
        decisionId _: UUID?,
        unitsPerHour _: Double,
        for _: TimeInterval,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        record("enactTempBasal")
        completion(nil)
    }

    func suspendDelivery(completion: @escaping (Error?) -> Void) {
        record("suspendDelivery")
        completion(nil)
    }

    func resumeDelivery(completion: @escaping (Error?) -> Void) {
        record("resumeDelivery")
        completion(nil)
    }

    func syncBasalRateSchedule(
        items scheduleItems: [RepeatingScheduleValue<Double>],
        completion: @escaping (Result<BasalRateSchedule, Error>) -> Void
    ) {
        record("syncBasalRateSchedule")
        if let schedule = BasalRateSchedule(dailyItems: scheduleItems, timeZone: .current) {
            completion(.success(schedule))
        } else {
            completion(.failure(PumpManagerError.configuration(nil)))
        }
    }

    func syncDeliveryLimits(limits: DeliveryLimits, completion: @escaping (Result<DeliveryLimits, Error>) -> Void) {
        record("syncDeliveryLimits")
        completion(.success(limits))
    }

    // MARK: PumpManagerUI

    var pumpStatusHighlight: PumpStatusHighlight? { nil }
    var pumpLifecycleProgress: DeviceLifecycleProgress? { nil }
    var pumpStatusBadge: DeviceStatusBadge? { nil }

    static func setupViewController(
        initialSettings _: PumpManagerSetupSettings,
        bluetoothProvider _: BluetoothProvider,
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool,
        prefersToSkipUserInteraction _: Bool,
        allowedInsulinTypes _: [InsulinType]
    ) -> SetupUIResult<PumpManagerViewController, PumpManagerUI> {
        .createdAndOnboarded(SpyPumpManager())
    }

    func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool,
        allowedInsulinTypes _: [InsulinType]
    ) -> PumpManagerViewController {
        fatalError("Not used in tests")
    }

    func deliveryUncertaintyRecoveryViewController(
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool
    ) -> (UIViewController & CompletionNotifying) {
        fatalError("Not used in tests")
    }

    func hudProvider(
        bluetoothProvider _: BluetoothProvider,
        colorPalette _: LoopUIColorPalette,
        allowedInsulinTypes _: [InsulinType]
    ) -> HUDProvider? { nil }

    static func createHUDView(rawValue _: HUDProvider.HUDViewRawState) -> BaseHUDView? { nil }
}
