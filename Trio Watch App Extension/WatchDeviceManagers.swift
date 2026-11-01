import G7SensorKit
import LoopKit
import OmnipodKit

// The device managers the watch can be passed, by identifier, for managers built from another controller's exported
// configuration. The one place the watch names a device kit (as LoopKit/Loop#2545's WatchDeviceManagers).

/// Keyed by each manager's `pluginIdentifier`, which is what its export carries. Stated, as Trio's device catalog
/// does: LoopKit exposes it only per instance.
let watchCGMManagersByIdentifier: [String: (CGMManager & DeviceConfigurationSharing).Type] = [
    "G7CGMManager": G7CGMManager.self
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

/// Deactivates the pod from the watch and forgets it.
func watchDeactivatePod(_ manager: PumpManager?, completion: @escaping (Error?) -> Void) {
    guard let omni = manager as? OmniPumpManager else { return completion(nil) }
    omni.deactivateAndForgetPod(completion: completion)
}

/// Forgets a pod that can't be reached to deactivate (it keeps beeping until removed).
func watchDiscardPod(_ manager: PumpManager?, completion: @escaping () -> Void) {
    guard let omni = manager as? OmniPumpManager else { return completion() }
    omni.discardPod(completion: completion)
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

/// The sensor's link is up right now: a reading or its backfill is on the radio.
func watchCGMIsConnected(_ manager: CGMManager?) -> Bool {
    (manager as? G7CGMManager)?.isConnected ?? false
}

/// While the G7's link is up, and 3 s after it closed, every pod command's connect waits (at most 15 s, in
/// OmnipodKit), not only the loop's: the two share the watch's one radio, and a pod command cut off then began every
/// pod stall (as on feat/direct-to-watch, f34b595).
func watchGatePodCommands(on manager: CGMManager?) {
    guard let g7 = manager as? G7CGMManager else {
        OmniPumpManager.commandConnectDelay = nil
        return
    }
    let lastSeen = SensorLinkClock()
    OmniPumpManager.commandConnectDelay = { [weak g7] in
        guard let g7 else { return 0 }
        if g7.isConnected {
            lastSeen.mark()
            return 1
        }
        return max(0, 3 - lastSeen.secondsSince)
    }
}

/// When the sensor's link was last seen up; read and written from OmnipodKit's queue.
private final class SensorLinkClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date.distantPast
    func mark() { lock.lock(); date = Date(); lock.unlock() }
    var secondsSince: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(date) }
}

extension DeviceManager {
    /// What the watch saves, as the phone saves a manager: `managerIdentifier` and `state`.
    var watchRawValue: [String: Any] {
        ["managerIdentifier": pluginIdentifier, "state": rawState]
    }
}
