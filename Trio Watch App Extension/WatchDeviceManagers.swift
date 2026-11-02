import G7SensorKit
import LoopKit
import OmnipodKit

// The device managers the watch can be passed, by identifier, for managers built from another controller's exported
// configuration. The one place the watch names a device kit (as LoopKit/Loop#2545's WatchDeviceManagers).

/// Keyed by each manager's `pluginIdentifier`, which is what its export carries.
let watchCGMManagersByIdentifier: [String: (CGMManager & DeviceConfigurationSharing).Type] = [
    G7CGMManager.pluginIdentifier: G7CGMManager.self
]

let watchPumpManagersByIdentifier: [String: (PumpManager & DeviceConfigurationSharing).Type] = [
    OmniPumpManager.pluginIdentifier: OmniPumpManager.self
]

/// A pump manager built from the phone's export and this watch's saved `localState` (the pod's handle here).
func watchPumpManager(adopting configuration: SharedDeviceConfiguration, localState: [String: Any]?) -> PumpManager? {
    watchPumpManagersByIdentifier[configuration.managerIdentifier]?.init(adopting: configuration, localState: localState)
}

/// A pump manager restored from its saved `managerIdentifier` and `state`, after a relaunch mid-session.
func watchPumpManager(rawValue: [String: Any]) -> PumpManager? {
    guard let identifier = rawValue["managerIdentifier"] as? String,
          let rawState = rawValue["state"] as? PumpManager.RawStateValue else { return nil }
    return watchPumpManagersByIdentifier[identifier]?.init(rawState: rawState)
}

/// What the pump kit keeps of its own on this watch (the pod's Bluetooth handle), for the next adopt.
func watchPumpLocalState(_ manager: PumpManager?) -> [String: Any]? {
    (manager as? OmniPumpManager)?.localState
}

/// The pod's reservoir, when the pod reports one (above 50 U it reports none).
func watchPumpReservoir(_ manager: PumpManager?) -> Double? {
    (manager as? OmniPumpManager)?.state.podState?.lastInsulinMeasurements?.reservoirLevel
}

func watchPumpExpiresAt(_ manager: PumpManager?) -> Date? {
    (manager as? OmniPumpManager)?.state.podState?.expiresAt
}

/// A CGM manager built from another controller's export and this watch's saved `localState`.
func watchCGMManager(adopting configuration: SharedDeviceConfiguration, localState: [String: Any]?) -> CGMManager? {
    watchCGMManagersByIdentifier[configuration.managerIdentifier]?.init(adopting: configuration, localState: localState)
}

/// A CGM manager restored from its saved `managerIdentifier` and `state`.
func watchCGMManager(rawValue: [String: Any]) -> CGMManager? {
    guard let identifier = rawValue["managerIdentifier"] as? String,
          let rawState = rawValue["state"] as? CGMManager.RawStateValue else { return nil }
    return watchCGMManagersByIdentifier[identifier]?.init(rawState: rawState)
}

/// On a wake that is not the CGM's own, its acquisition re-checks itself (G7: a lost Bluetooth callback can leave no
/// connect standing and nothing to notice).
func watchCGMRecheckAcquisition(_ manager: CGMManager?) {
    (manager as? G7CGMManager)?.recheckAcquisition()
}

/// What the watch's CGM needs from the user (a code, or the app kept open while it searches).
func watchCGMStatusNote(_ manager: CGMManager?) -> String? {
    guard let g7 = manager as? G7CGMManager else { return nil }
    return G7WatchDirectRead.needsCodeNote(for: g7.needsCodeForSensor) ?? G7WatchDirectRead.searchingNote(g7.isSearchingForSensor)
}

let watchCGMStatusDidChange = G7CGMManager.statusDidChange

func watchCGMSensorName(_ manager: CGMManager?) -> String? {
    (manager as? G7CGMManager)?.sensorName
}

/// When the watch last had a link to the sensor, readings or not (none during warmup).
func watchCGMLastConnection(_ manager: CGMManager?) -> Date? {
    (manager as? G7CGMManager)?.lastConnect ?? manager?.cgmManagerStatus.lastCommunicationDate
}

/// The sensor itself needs a look: warming up, failed, expired or in its grace period. Shown as the yellow triangle,
/// and no reading taken in this state starts a fallback.
func watchCGMHasSensorProblem(_ manager: CGMManager?) -> Bool {
    guard let g7 = manager as? G7CGMManager else { return false }
    switch g7.lifecycleState {
    case .expired,
         .failed,
         .gracePeriod,
         .warmup: return true
    default: return false
    }
}

/// Follows the G7's link for `watchWaitForSensorLink`.
func watchTrackSensorLink(on manager: CGMManager?) {
    sensorLink.track(manager as? G7CGMManager)
}

/// While the G7's link is up (at most 12 s), and until 3 s after it closed, the watch's own pod commands wait: the two
/// share the watch's one radio, and a pod command cut off then began every pod stall (as on feat/direct-to-watch,
/// f34b595). Returns how long the link was still up. OmnipodKit's own commands go as in Sport Mode.
@discardableResult func watchWaitForSensorLink() async -> TimeInterval {
    let start = Date()
    while sensorLink.isUp, Date().timeIntervalSince(start) < 12 {
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
    let linkOpen = Date().timeIntervalSince(start)
    let tail = 3 - sensorLink.secondsSinceUp
    if tail > 0 { try? await Task.sleep(nanoseconds: UInt64(tail * 1_000_000_000)) }
    return linkOpen
}

private let sensorLink = SensorLink()

/// The G7's link and when it was last up: every change the manager reports marks it, the close included.
private final class SensorLink: G7StateObserver, @unchecked Sendable {
    private let lock = NSLock()
    private weak var g7: G7CGMManager?
    private var lastUp = Date.distantPast

    func track(_ manager: G7CGMManager?) {
        lock.lock()
        g7 = manager
        lock.unlock()
        manager?.addStateObserver(self, queue: .main)
    }

    var isUp: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let g7, g7.isConnected else { return false }
        lastUp = Date()
        return true
    }

    var secondsSinceUp: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastUp)
    }

    func g7StateDidUpdate(_: G7CGMManagerState?) {}

    func g7ConnectionStatusDidChange() {
        lock.lock()
        lastUp = Date()
        lock.unlock()
    }
}

extension DeviceManager {
    /// What the watch saves, as the phone saves a manager: `managerIdentifier` and `state`.
    var watchRawValue: [String: Any] {
        ["managerIdentifier": pluginIdentifier, "state": rawState]
    }
}
