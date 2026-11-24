import Foundation
import LoopKit
import WatchKit

/// Reads the phone's CGM directly while the phone shares its configuration (the CGM's Read on Apple Watch setting):
/// the watch builds its own manager from that export, keeps it across launches and shows its readings beside the
/// phone's (as LoopKit/Loop#2545's WatchCGMHost).
@MainActor @Observable final class WatchCGMHost {
    static let shared = WatchCGMHost()

    private static let storageKey = "WatchCGMManager"
    private static let lentKey = "WatchCGMHostLent"
    private static let localStateKey = "WatchCGMHostLocalState"

    @ObservationIgnored private(set) var cgmManager: (any WatchReadableCGM)?
    @ObservationIgnored private var statusObserver: NSObjectProtocol?
    /// The export's `state` the manager was built from; a different one builds a new manager.
    @ObservationIgnored private var builtFrom: [String: Any]?
    /// Replacing or dropping the manager, until the old one has let go of the sensor.
    @ObservationIgnored private var swap: Task<Void, Never>?
    /// A pairing's Bluetooth bond never finished (the app was in the background); the kit retracts it on a reading.
    @ObservationIgnored private var pairingUnfinished = false

    /// For the glucose bubble.
    private(set) var isReadingDirectly = false
    /// The watch's link to the sensor is up: the radio waves of the left indicator.
    private(set) var isTalkingToSensor = false
    /// When the sensor's link last came up, from this host's manager or the one lent to Trio on Watch: a background
    /// wake has about 10 s of Bluetooth from then; pod messages after that count toward a watchOS limit that cuts all
    /// of Trio's links (kristinkand, 19 November).
    @ObservationIgnored private(set) var linkUpAt: Date?
    private(set) var sensorStateText: String?
    /// After the reading's age while the loop is on time: a state that needs nothing done.
    private(set) var sensorNote: String?
    /// While the sensor warms up, its end: counted down under the bubble.
    private(set) var warmupEndsAt: Date?
    /// The sensor needs a look; set by its lifecycle and by a reading the sensor marks unreliable.
    private(set) var hasSensorProblem = false

    /// The watch holds a CGM that is set up and paired (connected to the sensor). Whether the sensor currently has a
    /// problem or a stale reading does not matter here: once the sensor is set up with the watch, an adopt need not
    /// wait for a brand-new first reading. The "Waiting for first reading" screen is only for a watch that still has
    /// no sensor set up.
    var hasReadySensorLink: Bool {
        isReadingDirectly && !pairingUnfinished
    }
    /// The sensor gives no more readings (failed, expired).
    private(set) var sensorHasEnded = false

    /// A background refresh this long after each reading re-checks acquisition, in case watchOS froze the app before
    /// it lodged the next connect. Past the G7's 35 s tail clearance, so a connect never lands in its advertising tail.
    static let acquisitionBackstopDelay: TimeInterval = 60

    /// Trio on Watch reads the sensor while it holds the pump; this host builds nothing until the sensor is back.
    private var isLent: Bool { UserDefaults.standard.bool(forKey: Self.lentKey) }

    private init() {
        if !UserDefaults.standard.bool(forKey: Self.lentKey),
           let raw = UserDefaults.standard.dictionary(forKey: Self.storageKey), let manager = watchCGMManager(rawValue: raw)
        {
            builtFrom = raw["builtFrom"] as? [String: Any]
            install(manager)
        }
    }

    /// The phone's settings arrived. Builds a manager when its export names a different sensor or code, lets go of
    /// the sensor when the phone stopped sharing, and otherwise treats it as a wake.
    func update(from state: WatchState) {
        // a state arriving mid-swap is dropped; the phone sends the next within minutes
        guard swap == nil, !isLent else { return }
        guard state.watchReadsSensor, let data = state.sensorConfiguration,
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let configuration = SharedDeviceConfiguration(rawValue: raw)
        else {
            if cgmManager != nil {
                WatchLogger.shared.info(.data, "The phone stopped sharing its CGM; letting go of the sensor")
                swap = Task {
                    await remove()
                    swap = nil
                }
            }
            return
        }
        if let cgmManager, let builtFrom, cgmManager.pluginIdentifier == configuration.managerIdentifier,
           type(of: cgmManager).sameSensor(builtFrom, configuration.state)
        {
            recheckAcquisition()
            return
        }
        if cgmManager != nil {
            WatchLogger.shared.info(.data, "The phone's CGM changed (a new sensor or code): building the watch's manager again")
        }
        // The old manager goes first: both centrals share one restore identifier, and a new one built beside the
        // old never powered on, so the watch stopped acquiring until relaunched.
        swap = Task {
            await remove()
            build(from: configuration)
            swap = nil
        }
    }

    /// Lets go of the sensor for Trio on Watch, which reads it while the watch holds the pump. A manager for the
    /// grant's sensor is lent itself, with its connection: a second manager's central beside it never powers on.
    /// Otherwise this watch's key for the sensor, so the loan needs no new pairing.
    func lendSensor(for configuration: SharedDeviceConfiguration) async
        -> (manager: (any WatchReadableCGM)?, localState: [String: Any]?)
    {
        while let swap { await swap.value }
        UserDefaults.standard.set(true, forKey: Self.lentKey)
        if let local = cgmManager?.localState { keepLocalState(local) }
        var lent: (any WatchReadableCGM)?
        if let cgmManager, let builtFrom, cgmManager.pluginIdentifier == configuration.managerIdentifier,
           type(of: cgmManager).sameSensor(builtFrom, configuration.state)
        {
            lent = detach()
        } else {
            await remove()
        }
        WatchLogger.shared.info(.data, "The sensor is lent to Trio on Watch\(lent != nil ? ", with its connection" : "")")
        return (lent, UserDefaults.standard.dictionary(forKey: Self.localStateKey))
    }

    /// Trio on Watch hands its manager back with the connection. False when this host can't keep it; the caller
    /// then deletes it.
    func takeBack(_ manager: any WatchReadableCGM, builtFrom: [String: Any]) -> Bool {
        guard isLent, cgmManager == nil else { return false }
        self.builtFrom = builtFrom
        install(manager)
        save(manager)
        return true
    }

    /// Trio on Watch let go of the sensor: the phone's next state builds the manager again, with the loan's key.
    func sensorReturned(localState: [String: Any]?) {
        if let localState { keepLocalState(localState) }
        guard isLent else { return }
        UserDefaults.standard.removeObject(forKey: Self.lentKey)
        WatchLogger.shared.info(.data, "The sensor is back from Trio on Watch")
    }

    /// The kit matches it to the sensor: a key for another sensor is ignored.
    private func keepLocalState(_ localState: [String: Any]) {
        UserDefaults.standard.set(localState, forKey: Self.localStateKey)
    }

    private func build(from configuration: SharedDeviceConfiguration) {
        let localState = UserDefaults.standard.dictionary(forKey: Self.localStateKey)
        guard let manager = watchCGMManager(adopting: configuration, localState: localState) else {
            WatchLogger.shared.warning(.data, "The phone's CGM (\(configuration.managerIdentifier)) can't be read from the watch")
            return
        }
        WatchLogger.shared.info(.data, "CGM manager built from the phone's configuration (\(configuration.managerIdentifier))")
        builtFrom = configuration.state
        install(manager)
        save(manager)
    }

    /// Any wake that is not the sensor's own.
    func recheckAcquisition() {
        cgmManager?.recheckAcquisition()
    }

    private func install(_ manager: any WatchReadableCGM) {
        manager.delegateQueue = .main
        manager.cgmManagerDelegate = self
        cgmManager = manager
        statusObserver = NotificationCenter.default.addObserver(
            forName: type(of: manager).statusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        updateStatus()
    }

    /// Returns once the manager has let go of the sensor.
    private func remove() async {
        await detach()?.delete()
    }

    /// Drops the manager, which keeps its connection.
    private func detach() -> (any WatchReadableCGM)? {
        guard let previous = cgmManager else { return nil }
        previous.cgmManagerDelegate = nil
        statusObserver.map(NotificationCenter.default.removeObserver)
        statusObserver = nil
        cgmManager = nil
        builtFrom = nil
        pairingUnfinished = false
        isTalkingToSensor = false
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        updateStatus()
        return previous
    }

    private func save(_ manager: any WatchReadableCGM) {
        var raw = manager.watchRawValue
        raw["builtFrom"] = builtFrom
        UserDefaults.standard.set(raw, forKey: Self.storageKey)
    }

    private func updateStatus() {
        isReadingDirectly = cgmManager != nil
        sensorStateText = pairingUnfinished
            ? String(localized: "Pairing: keep Trio open at the next reading")
            : cgmManager?.watchSensorStateText
        WatchState.shared.noteSensorState(sensorStateText)
        sensorNote = cgmManager?.watchSensorNote
        sensorHasEnded = cgmManager?.watchSensorHasEnded ?? false
        warmupEndsAt = pairingUnfinished ? nil : cgmManager?.watchWarmupEndsAt
        noteSensorProblem(cgmManager?.watchHasSensorProblem ?? false)
    }

    private func noteSensorProblem(_ problem: Bool) {
        hasSensorProblem = problem
    }

    private func scheduleAcquisitionBackstop() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: Self.acquisitionBackstopDelay),
            userInfo: nil
        ) { error in
            if let error {
                WatchLogger.shared.warning(.lifecycle, "Could not schedule the acquisition backstop", error: error)
            }
        }
    }

    private static func direction(_ trend: GlucoseTrend?) -> BloodGlucose.Direction {
        switch trend {
        case .upUpUp: return .doubleUp
        case .upUp: return .singleUp
        case .up: return .fortyFiveUp
        case .flat: return .flat
        case .down: return .fortyFiveDown
        case .downDown: return .singleDown
        case .downDownDown: return .doubleDown
        default: return .none
        }
    }

    /// The watch's own readings in the form the phone sends them.
    static func readings(from samples: [NewGlucoseSample]) -> [BloodGlucose] {
        samples.filter { !$0.wasUserEntered }.map { sample in
            let value = Int(sample.quantity.doubleValue(for: .milligramsPerDeciliter))
            return BloodGlucose(
                id: UUID().uuidString,
                sgv: value,
                direction: direction(sample.trend),
                date: Decimal(Int64(sample.date.timeIntervalSince1970 * 1000)),
                dateString: sample.date,
                unfiltered: Decimal(value),
                glucose: value,
                type: "sgv"
            )
        }
    }
}

extension WatchCGMHost: CGMManagerDelegate {
    nonisolated func startDateToFilterNewData(for _: CGMManager) -> Date? { nil }

    nonisolated func cgmManager(_: CGMManager, hasNew readingResult: CGMReadingResult) {
        MainActor.assumeIsolated {
            switch readingResult {
            case let .newData(samples):
                let readings = Self.readings(from: samples)
                guard !readings.isEmpty else { return }
                WatchLogger.shared.info(.data, "Direct reading: \(readings.count) sample(s)")
                updateStatus()
                WatchState.shared.applyOwnReadings(readings)
                WatchAlarms.shared.check(own: readings)
                scheduleAcquisitionBackstop()
            case .unreliableData:
                noteSensorProblem(true)
            case let .error(error):
                WatchLogger.shared.warning(.data, "CGM reading failed", error: error)
                // a reading the sensor withholds arrives as an error
                updateStatus()
            case .noData:
                break
            }
        }
    }

    nonisolated func cgmManager(_: CGMManager, hasNew _: [PersistedCgmEvent]) {}

    /// The phone owns the sensor; a manager passed its configuration lets go when the phone stops sharing.
    nonisolated func cgmManagerWantsDeletion(_: CGMManager) async {}

    nonisolated func cgmManagerDidUpdateState(_ manager: CGMManager) {
        MainActor.assumeIsolated {
            guard let cgmManager, manager === cgmManager else { return }
            save(cgmManager)
            updateStatus()
        }
    }

    nonisolated func credentialStoragePrefix(for _: CGMManager) -> String {
        "org.nightscout.Trio.WatchCGMHost"
    }

    nonisolated func cgmManager(_ manager: CGMManager, didUpdate _: CGMManagerStatus) {
        MainActor.assumeIsolated {
            guard let cgmManager, manager === cgmManager else { return }
            updateStatus()
        }
    }

    nonisolated func deviceManager(
        _: DeviceManager,
        logEventForDeviceIdentifier _: String?,
        type: DeviceLogEntryType,
        message: String,
        completion: ((Error?) -> Void)?
    ) {
        WatchLogger.shared.debug(.data, "CGM \(type): \(message)")
        completion?(nil)
        guard type == .connection else { return }
        // in order with the manager's other news, which comes on main
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.noteLink(afterLog: message) }
        }
    }

    private func noteLink(afterLog message: String) {
        guard let cgmManager, let linkIsUp = type(of: cgmManager).watchLinkIsUp(afterLog: message) else { return }
        if linkIsUp, !isTalkingToSensor { linkUpAt = Date() }
        isTalkingToSensor = linkIsUp
    }

    /// The manager lent to Trio on Watch logs to the loan, not here: its link-up still starts the wake's Bluetooth
    /// window. True at a new link-up.
    @discardableResult func noteLoanLink(linkIsUp: Bool) -> Bool {
        defer { isTalkingToSensor = linkIsUp }
        guard linkIsUp, !isTalkingToSensor else { return false }
        linkUpAt = Date()
        return true
    }

    nonisolated func deviceManager(_: DeviceManager, recordAnalyticsEvent _: String, properties _: [AnyHashable: Any]?) {}

    // The phone issues the sensor's alerts; the watch only logs them.
    nonisolated func issueAlert(_ alert: Alert) async {
        WatchLogger.shared.info(.data, "Alert from the watch's CGM, not shown: \(alert.identifier.value)")
        await setPairingUnfinished(alert.identifier, true)
    }

    nonisolated func retractAlert(identifier: Alert.Identifier) async {
        await setPairingUnfinished(identifier, false)
    }

    /// The one alert the watch keeps as a note: a pairing it must finish with the app open.
    private func setPairingUnfinished(_ identifier: Alert.Identifier, _ unfinished: Bool) {
        guard identifier.alertIdentifier == "pairingUnfinished", cgmManager != nil else { return }
        pairingUnfinished = unfinished
        updateStatus()
    }

    nonisolated func doesIssuedAlertExist(identifier _: Alert.Identifier) async throws -> Bool { false }

    nonisolated func lookupAllUnretracted(managerIdentifier _: String) async throws -> [PersistedAlert] { [] }

    nonisolated func lookupAllUnacknowledgedUnretracted(managerIdentifier _: String) async throws -> [PersistedAlert] { [] }

    nonisolated func recordRetractedAlert(_: Alert, at _: Date) async throws {}
}
