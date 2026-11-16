import Foundation
import HealthKit
import LoopKit
@testable import Trio

/// The pod both controllers talk to: who holds its session, and its delivered total.
final class PodModel {
    enum Holder: Equatable {
        case nobody
        case phone
        case watch(ObjectIdentifier)
    }

    var holder: Holder = .phone
    var delivered: Double = 10
    /// Set when the phone takes the pod while the watch still believes it holds it.
    var phoneTookOver = false
}

/// A pump that fails the test when the host commands it while it isn't the owner. It implements the same LoopKit
/// protocols the watch host drives on OmnipodKit, and models the kit's foreign-session refusal and bounded adopt.
final class LoanPumpDouble: LoanPump {
    let pod: PodModel
    /// The host's ownership at the moment of a command; a command while it says no is a violation.
    var hostMayCommand: (String) -> Bool = { _ in true }
    var now: () -> Date = Date.init
    private(set) var violations: [String] = []
    private(set) var commands: [String] = []
    private(set) var takeControlCalls = 0
    private(set) var releaseCalls = 0

    var commandError: PumpManagerError?
    var makesDeliveryUncertainOnError = false
    var statusIsFresh = true
    var bolusDuration: TimeInterval = 0.2

    var isControlReleased = false
    var refusesSessions = false
    var foreignSessionDetectedAt: Date?
    private var tookControl = false

    init(pod: PodModel) {
        self.pod = pod
    }

    convenience init?(rawState: RawStateValue) {
        nil
    }

    required convenience init?(adopting _: SharedDeviceConfiguration, localState _: [String: Any]?) {
        nil
    }

    var rawState: RawStateValue { ["double": true, "released": isControlReleased] }

    // MARK: Ownership

    private var holdsPod: Bool { pod.holder == .watch(ObjectIdentifier(self)) }

    private func check(_ command: String) -> PumpManagerError? {
        commands.append(command)
        if !hostMayCommand(command) {
            violations.append("\(command) while the host doesn't hold the pump")
        }
        if refusesSessions || isControlReleased {
            violations.append("\(command) on a refusing or released kit")
            return .communication(nil)
        }
        if !holdsPod {
            // the kit's session would see the other controller: refuse and report, never send
            refuse()
            return .communication(nil)
        }
        return commandError
    }

    private func refuse() {
        refusesSessions = true
        foreignSessionDetectedAt = Date()
        notifyState()
    }

    func notifyState() {
        delegateQueue.async { self.pumpManagerDelegate?.pumpManagerDidUpdateState(self) }
    }

    func exportConfiguration() -> SharedDeviceConfiguration {
        SharedDeviceConfiguration(managerIdentifier: "LoanPumpDouble", asOf: Date(), state: [:])
    }

    func releaseControl() {
        releaseCalls += 1
        guard status.deliveryIsUncertain == false else { return }
        isControlReleased = true
        if holdsPod { pod.holder = .nobody }
    }

    /// The bounded adopt: only the session the phone released may be taken.
    func takeControl() {
        takeControlCalls += 1
        guard !refusesSessions else { return }
        if pod.holder == .phone || pod.phoneTookOver {
            refuse()
            return
        }
        pod.holder = .watch(ObjectIdentifier(self))
        tookControl = true
        isControlReleased = false
    }

    var isControlReady: Bool { holdsPod }

    // MARK: Odometer

    var deliveredUnits: (units: Double, at: Date)? { (pod.delivered, now()) }
    var deliveryPulseUnits: Double { 0.05 }
    var bolusUnderWayEndsAt: Date? { nil }

    func refreshDeliveredUnits() async -> Bool {
        holdsPod
    }

    // MARK: PumpManager

    static var onboardingMaximumBasalScheduleEntryCount: Int { 24 }
    static var onboardingSupportedBasalRates: [Double] { (0 ... 600).map { Double($0) / 20 } }
    static var onboardingSupportedBolusVolumes: [Double] { (1 ... 600).map { Double($0) / 20 } }
    static var onboardingSupportedMaximumBolusVolumes: [Double] { onboardingSupportedBolusVolumes }

    var pluginIdentifier: String { "LoanPumpDouble" }
    var localizedTitle: String { "Pump double" }
    var isOnboarded: Bool { true }
    var inSignalLoss: Bool { false }
    var isInoperable: Bool { false }
    var debugDescription: String { "LoanPumpDouble" }
    var delegateQueue: DispatchQueue! = DispatchQueue(label: "double")
    weak var pumpManagerDelegate: PumpManagerDelegate?
    var supportedBasalRates: [Double] { Self.onboardingSupportedBasalRates }
    var supportedBolusVolumes: [Double] { Self.onboardingSupportedBolusVolumes }
    var supportedMaximumBolusVolumes: [Double] { Self.onboardingSupportedMaximumBolusVolumes }
    var maximumBasalScheduleEntryCount: Int { 24 }
    var minimumBasalScheduleEntryDuration: TimeInterval { 1800 }
    var pumpRecordsBasalProfileStartEvents: Bool { false }
    var pumpReservoirCapacity: Double { 200 }
    var lastSync: Date?

    var basalDeliveryState: PumpManagerStatus.BasalDeliveryState = .active(Date())
    var bolusState: PumpManagerStatus.BolusState = .noBolus
    var deliveryIsUncertain = false

    var status: PumpManagerStatus {
        PumpManagerStatus(
            timeZone: .current,
            device: HKDevice(
                name: "Double", manufacturer: nil, model: nil, hardwareVersion: nil, firmwareVersion: nil,
                softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil
            ),
            pumpBatteryChargeRemaining: nil,
            basalDeliveryState: basalDeliveryState,
            bolusState: bolusState,
            insulinType: nil,
            deliveryIsUncertain: deliveryIsUncertain
        )
    }

    func addStatusObserver(_: PumpManagerStatusObserver, queue _: DispatchQueue) {}
    func removeStatusObserver(_: PumpManagerStatusObserver) {}

    func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        guard !refusesSessions, holdsPod else {
            if !holdsPod, !refusesSessions, tookControl { refuse() }
            completion?(lastSync)
            return
        }
        if statusIsFresh { lastSync = now() }
        completion?(lastSync)
    }

    private(set) var heartbeatRequests: [PumpHeartbeatRequest?] = []
    private(set) var mustProvideHeartbeat: [Bool] = []

    func setMustProvideBLEHeartbeat(_ value: Bool) {
        mustProvideHeartbeat.append(value)
    }

    func setBLEHeartbeatRequest(_ request: PumpHeartbeatRequest?) {
        heartbeatRequests.append(request)
    }
    func createBolusProgressReporter(reportingOn _: DispatchQueue) -> DoseProgressReporter? { nil }
    func estimatedDuration(toBolus units: Double) -> TimeInterval { units * 40 }

    func enactBolus(decisionId _: UUID?, units: Double, activationType: BolusActivationType, completion: @escaping (PumpManagerError?) -> Void) {
        if let error = check("bolus \(units) U\(activationType.isAutomatic ? " (SMB)" : "")") {
            if makesDeliveryUncertainOnError { deliveryIsUncertain = true }
            return completion(error)
        }
        pod.delivered += units
        let now = now()
        let dose = DoseEntry(type: .bolus, startDate: now, endDate: now.addingTimeInterval(bolusDuration), value: units,
                             unit: .units, decisionId: nil, deliveredUnits: units, automatic: activationType.isAutomatic)
        bolusState = .inProgress(dose)
        report(dose)
        DispatchQueue.main.asyncAfter(deadline: .now() + bolusDuration) { self.bolusState = .noBolus }
        completion(nil)
    }

    func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        if let error = check("cancel bolus") { return completion(.failure(error)) }
        bolusState = .noBolus
        completion(.success(nil))
    }

    func enactTempBasal(decisionId _: UUID?, unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (PumpManagerError?) -> Void) {
        if let error = check("temp \(unitsPerHour) U/h \(Int(duration / 60)) min") {
            if makesDeliveryUncertainOnError { deliveryIsUncertain = true }
            return completion(error)
        }
        let now = now()
        if duration == 0 {
            basalDeliveryState = .active(now)
        } else {
            let dose = DoseEntry(type: .tempBasal, startDate: now, endDate: now.addingTimeInterval(duration), value: unitsPerHour,
                                 unit: .unitsPerHour, decisionId: nil, automatic: true, isMutable: true)
            basalDeliveryState = .tempBasal(dose)
            report(dose)
        }
        completion(nil)
    }

    func suspendDelivery(completion: @escaping (Error?) -> Void) {
        if let error = check("suspend") { return completion(error) }
        basalDeliveryState = .suspended(now())
        completion(nil)
    }

    func resumeDelivery(completion: @escaping (Error?) -> Void) {
        if let error = check("resume") { return completion(error) }
        basalDeliveryState = .active(now())
        completion(nil)
    }

    func syncBasalRateSchedule(items _: [RepeatingScheduleValue<Double>], completion: @escaping (Result<BasalRateSchedule, Error>) -> Void) {
        violations.append("basal schedule sync from the watch")
        completion(.failure(WatchLoanHostError.notStored))
    }

    func syncDeliveryLimits(limits: DeliveryLimits, completion: @escaping (Result<DeliveryLimits, Error>) -> Void) {
        completion(.success(limits))
    }

    func acknowledgeAlert(alertIdentifier _: Alert.AlertIdentifier) async throws {}
    func getSoundBaseURL() -> URL? { nil }
    func getSounds() -> [Alert.Sound] { [] }

    private func report(_ dose: DoseEntry) {
        let event = NewPumpEvent(date: dose.startDate, dose: dose, raw: Data(UUID().uuidString.utf8), title: "\(dose.type)")
        let semaphore = DispatchSemaphore(value: 0)
        delegateQueue.async {
            self.pumpManagerDelegate?.pumpManager(
                self,
                hasNewPumpEvents: [event],
                lastReconciliation: nil,
                replacePendingEvents: false
            ) { _ in semaphore.signal() }
        }
        semaphore.wait()
    }
}
