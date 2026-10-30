import G7SensorKit
import LoopKit

// The device managers the watch can be passed, by identifier, for managers built from another controller's exported
// configuration. The one place the watch names a device kit (as LoopKit/Loop#2545's WatchDeviceManagers).

/// Keyed by each manager's `pluginIdentifier`, which is what its export carries.
let watchCGMManagersByIdentifier: [String: (CGMManager & DeviceConfigurationSharing).Type] = [
    G7CGMManager.pluginIdentifier: G7CGMManager.self
]

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

extension DeviceManager {
    /// What the watch saves, as the phone saves a manager: `managerIdentifier` and `state`.
    var watchRawValue: [String: Any] {
        ["managerIdentifier": pluginIdentifier, "state": rawState]
    }
}
