import Foundation
import HealthKit
import LoopKit
import LoopKitUI
import Testing
import UIKit

@testable import Trio

/// A lendable pump that records every command and fails the running test when one arrives while this
/// controller doesn't hold the pod (released, or refusing after a foreign session).
final class LoanPumpDouble: PumpManagerUI, SupersedingDeviceControl, PumpDeliveryOdometer {
    private let lock = NSLock()
    private var _commands: [String] = []

    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _commands
    }

    private func record(_ command: String, isPumpCommand: Bool = true) {
        lock.lock()
        _commands.append(command)
        let owner = !_released && !_refusesSessions
        lock.unlock()
        if isPumpCommand, !owner {
            Issue.record("Pump command \(command) while this controller doesn't hold the pod")
        }
    }

    private var _released = false
    private var _refusesSessions = false

    // MARK: Controls for tests

    var refuseRelease = false
    var failTempBasal = false
    var refreshSucceeds = true
    /// What the pod reports as delivered at the next read.
    var odometer = 10.0
    var bolusUnderWayEndsAt: Date?
    var deliveredUnits: (units: Double, at: Date)?
    var deliveryStartedAt: Date? = Date(timeIntervalSince1970: 1_799_900_000)
    var deliveryEndsAt: Date?
    var foreignSessionDetectedAt: Date?
    var clock: () -> Date = Date.init

    func simulateForeignSessionRefusal() {
        lock.lock()
        _refusesSessions = true
        lock.unlock()
    }

    var status = PumpManagerStatus(
        timeZone: TimeZone(identifier: "Europe/Berlin")!,
        device: HKDevice(
            name: "LoanPumpDouble",
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

    // MARK: ExclusiveDeviceControl and the superseding take

    var isControlReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _released
    }

    var refusesSessions: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _refusesSessions
    }

    func releaseControl() {
        record("releaseControl", isPumpCommand: false)
        guard !refuseRelease else { return }
        lock.lock()
        _released = true
        lock.unlock()
    }

    func takeControl() {
        record("takeControl", isPumpCommand: false)
        lock.lock()
        // as the kit: a plain take never lifts a refusal
        if !_refusesSessions { _released = false }
        lock.unlock()
    }

    func takeControl(supersedingAnotherControllerUntil until: Date?) {
        record(until.map { "takeControlSuperseding(\(Int($0.timeIntervalSince1970)))" } ?? "takeControl", isPumpCommand: false)
        lock.lock()
        if until != nil { _refusesSessions = false }
        if !_refusesSessions { _released = false }
        lock.unlock()
    }

    func takeControlLiftingRefusal() {
        record("takeControlLiftingRefusal", isPumpCommand: false)
        lock.lock()
        _refusesSessions = false
        _released = false
        lock.unlock()
    }

    func stopSupersedingAnotherController() {
        record("stopSuperseding", isPumpCommand: false)
    }

    func exportConfiguration() -> SharedDeviceConfiguration {
        record("export", isPumpCommand: false)
        return SharedDeviceConfiguration(managerIdentifier: pluginIdentifier, asOf: clock(), deliveredUnits: odometer, state: [
            "version": 1
        ])
    }

    init() {}
    init?(rawState _: RawStateValue) {}
    init?(adopting _: SharedDeviceConfiguration, localState _: [String: Any]?) { nil }

    // MARK: PumpDeliveryOdometer

    var deliveryPulseUnits: Double { 0.05 }

    func refreshDeliveredUnits() async -> Bool {
        record("refreshDeliveredUnits")
        guard refreshSucceeds else { return false }
        deliveredUnits = (odometer, clock())
        return true
    }

    // MARK: DeviceManager

    static let onboardingImage: UIImage? = nil
    var smallImage: UIImage? { nil }
    var pluginIdentifier: String { "LoanPumpDouble" }
    var localizedTitle: String { "Loan pump double" }
    var debugDescription: String { "LoanPumpDouble" }
    var rawState: RawStateValue { ["version": 1] }
    var isOnboarded: Bool { true }
    var inSignalLoss: Bool { false }
    var isInoperable: Bool { false }

    func acknowledgeAlert(alertIdentifier _: Alert.AlertIdentifier) async throws { record("acknowledgeAlert") }
    func getSoundBaseURL() -> URL? { nil }
    func getSounds() -> [Alert.Sound] { [] }

    // MARK: PumpManager

    static let onboardingMaximumBasalScheduleEntryCount = 24
    static let onboardingSupportedBasalRates: [Double] = (0 ... 600).map { Double($0) / 20 }
    static let onboardingSupportedBolusVolumes: [Double] = (1 ... 600).map { Double($0) / 20 }
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
        units: Double,
        activationType _: BolusActivationType,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        record("bolus(\(units))")
        completion(nil)
    }

    func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        record("cancelBolus")
        completion(.success(nil))
    }

    func enactTempBasal(
        decisionId _: UUID?,
        unitsPerHour: Double,
        for _: TimeInterval,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        record("tempBasal(\(unitsPerHour))")
        completion(failTempBasal ? .communication(nil) : nil)
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
        .createdAndOnboarded(LoanPumpDouble())
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
