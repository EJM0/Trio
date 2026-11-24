import Foundation
import G7SensorKit
import LoopKit
import WatchKit

/// The G7 manager the watch keeps while it holds the pump: built once from the phone's configuration (the sensor is
/// shared, the phone keeps reading it), then only from its own saved state. Only the kit's public API is used here.
@MainActor final class WatchLoanCGM: NSObject, LoanCGMSource {
    private let files: WatchLoanFiles
    private var manager: G7CGMManager?
    private let delegateQueue = DispatchQueue(label: "org.nightscout.Trio.watch.cgm")
    private nonisolated let linkEvents = LinkEventClock()
    /// shortcut: in memory only, so a relaunch forgets timed sensor alerts it may need to retract at End; persist if
    /// a stale sensor notice after a loan is reported.
    private var issued: Set<Alert.Identifier> = []
    weak var host: WatchLoanHost?

    init(files: WatchLoanFiles) {
        self.files = files
        super.init()
        // a new pairing can end in the system's Bluetooth pairing request, which shows only with Trio in front
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive), name: WKApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillResignActive), name: WKApplication.willResignActiveNotification, object: nil
        )
    }

    var isActive: Bool { manager != nil }

    /// The watch has no key for this sensor yet, so its next connection pairs.
    var needsPairing: Bool {
        manager.map { $0.localState == nil } ?? false
    }

    @objc private func appBecameActive() {
        guard let manager else { return }
        manager.pairingAllowed = true
        if needsPairing { manager.recheckAcquisition() }
    }

    @objc private func appWillResignActive() {
        manager?.pairingAllowed = false
    }

    func adopt(export: Data) async {
        guard let raw = WatchLoanSnapshot.configuration(from: export),
              let configuration = SharedDeviceConfiguration(rawValue: raw)
        else {
            WatchLogger.shared.error(.cgm, "No CGM configuration in the grant")
            return
        }
        // the old managers go first: a new central beside one with the same restore identifier never powers on
        await retire()
        let lentKey = await WatchCGMHost.shared.lendSensor()
        // the watch's own key for this sensor, from its own reading or an earlier loan: without it every loan pairs
        // again, and that pairing needs the system prompt answered with Trio in front
        let files = files
        let savedKey = try? await WatchLoanFiles.io { try files.loadPlist(from: .cgmLocalState) }
        let localState = lentKey ?? savedKey
        guard let adopted = G7CGMManager(adopting: configuration, localState: localState) else {
            WatchLogger.shared.error(.cgm, "The grant's CGM configuration can't be read on the watch")
            return
        }
        install(adopted)
        let rawState = adopted.rawState
        WatchLoanFiles.later("the CGM state") { try files.savePlist(rawState, to: .cgmState) }
        WatchLogger.shared.info(
            .cgm,
            "CGM manager built from the grant\(adopted.localState != nil ? ", with this watch's key from an earlier loan" : "")"
        )
    }

    func restore() {
        guard manager == nil else { return }
        do {
            guard let raw = try files.loadPlist(from: .cgmState), let restored = G7CGMManager(rawState: raw) else { return }
            install(restored)
            WatchLogger.shared.info(.cgm, "CGM manager restored from its saved state")
        } catch {
            WatchLogger.shared.error(.cgm, "The saved CGM state can't be read", error: error)
        }
    }

    /// Any wake the sensor didn't cause.
    func recheckAcquisition() {
        manager?.recheckAcquisition()
    }

    func retire() async {
        // the kit's own retractions in delete() come after its delegate is gone; the phone keeps the sensor's alerts
        for identifier in issued { await host?.retractKitAlert(identifier) }
        issued = []
        guard let previous = manager else { return }
        previous.cgmManagerDelegate = nil
        manager = nil
        let files = files
        if let local = previous.localState {
            try? await WatchLoanFiles.io { try files.savePlist(local, to: .cgmLocalState) }
        }
        try? await WatchLoanFiles.io { try files.remove(.cgmState) }
        await previous.delete()
        WatchLogger.shared.info(.cgm, "CGM manager let go")
        WatchCGMHost.shared.sensorReturned(localState: previous.localState)
    }

    private func install(_ manager: G7CGMManager) {
        manager.pairingAllowed = WKApplication.shared().applicationState == .active
        manager.delegateQueue = delegateQueue
        manager.cgmManagerDelegate = self
        self.manager = manager
    }

    private nonisolated func save(_ manager: CGMManager) {
        do {
            try files.savePlist(manager.rawState, to: .cgmState)
        } catch {
            WatchLogger.shared.error(.cgm, "Saving the CGM state failed", error: error)
        }
    }

    nonisolated static func readings(from samples: [NewGlucoseSample]) -> [BloodGlucose] {
        samples.filter { !$0.wasUserEntered && !$0.isDisplayOnly }.map { sample in
            OrefInputs.bloodGlucose(
                id: nil,
                date: sample.date,
                glucose: Int16(clamping: Int(sample.quantity.doubleValue(for: .milligramsPerDeciliter).rounded())),
                smoothedGlucose: nil,
                isManual: false,
                direction: direction(sample.trend)?.rawValue,
                shouldSmoothGlucose: false,
                roundingBehavior: NSDecimalNumberHandler(
                    roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false,
                    raiseOnUnderflow: false, raiseOnDivideByZero: false
                )
            )
        }
    }

    private nonisolated static func direction(_ trend: GlucoseTrend?) -> BloodGlucose.Direction? {
        switch trend {
        case .upUpUp: return .doubleUp
        case .upUp: return .singleUp
        case .up: return .fortyFiveUp
        case .flat: return .flat
        case .down: return .fortyFiveDown
        case .downDown: return .singleDown
        case .downDownDown: return .doubleDown
        case nil: return nil
        }
    }
}

extension WatchLoanCGM: CGMManagerDelegate {
    nonisolated func startDateToFilterNewData(for _: CGMManager) -> Date? { nil }

    nonisolated func cgmManager(_: CGMManager, hasNew readingResult: CGMReadingResult) {
        switch readingResult {
        case let .newData(samples):
            let readings = Self.readings(from: samples)
            guard !readings.isEmpty else { return }
            Task { @MainActor [weak self] in await self?.host?.receiveReadings(readings) }
        case let .error(error):
            WatchLogger.shared.warning(.cgm, "CGM reading failed", error: error)
            Task { @MainActor [weak self] in self?.host?.deviceError(error) }
        case .noData,
             .unreliableData:
            break
        }
    }

    nonisolated func cgmManager(_: CGMManager, hasNew _: [PersistedCgmEvent]) {}
    nonisolated func cgmManagerWantsDeletion(_: CGMManager) async {}

    nonisolated func cgmManagerDidUpdateState(_ manager: CGMManager) {
        save(manager)
    }

    nonisolated func credentialStoragePrefix(for _: CGMManager) -> String { "org.nightscout.Trio.WatchLoan" }
    nonisolated func cgmManager(_: CGMManager, didUpdate _: CGMManagerStatus) {}

    nonisolated func deviceManager(
        _: DeviceManager,
        logEventForDeviceIdentifier _: String?,
        type: DeviceLogEntryType,
        message: String,
        completion: ((Error?) -> Void)?
    ) {
        WatchLogger.shared.debug(.cgm, "CGM \(type): \(message)")
        if type == .connection { linkEvents.note("CGM", category: .cgm) }
        if message.hasPrefix("RESTORED by the system") {
            // the kit's willRestoreState: the system relaunched Trio for the sensor's Bluetooth link
            WatchLogger.shared.info(.cgm, "CGM Bluetooth state restored by the system, app \(WatchAppState.current)")
        }
        completion?(nil)
    }

    func issueAlert(_ alert: Alert) async {
        issued.insert(alert.identifier)
        await host?.issueSensorAlert(alert)
    }

    func retractAlert(identifier: Alert.Identifier) async {
        issued.remove(identifier)
        await host?.retractKitAlert(identifier)
    }

    nonisolated func doesIssuedAlertExist(identifier _: Alert.Identifier) async throws -> Bool { false }
    nonisolated func lookupAllUnretracted(managerIdentifier _: String) async throws -> [PersistedAlert] { [] }
    nonisolated func lookupAllUnacknowledgedUnretracted(managerIdentifier _: String) async throws -> [PersistedAlert] { [] }
    nonisolated func recordRetractedAlert(_: Alert, at _: Date) async throws {}
}
