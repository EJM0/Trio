import Foundation
import G7SensorKit
import LoopKit
import OmnipodKit

// The only place the watch names device kits, keyed by `pluginIdentifier` (what an export carries).
// A pump or CGM missing here makes the watch refuse the grant with a clear reason.
// ponytail: Omnipod Eros needs a RileyLink the watch doesn't have; its takeover fails within the lease
// and the phone keeps the pod.

let watchPumpManagers: [String: (PumpManager & ExclusiveDeviceControl).Type] = [
    OmniPumpManager.pluginIdentifier: OmniPumpManager.self
]

let watchCGMManagers: [String: (CGMManager & DeviceConfigurationSharing).Type] = [
    G7CGMManager.pluginIdentifier: G7CGMManager.self
]

/// On a wake that isn't the sensor's own, the G7's acquisition re-checks itself: a lost Bluetooth
/// callback can leave no connect standing and nothing that notices.
func watchCGMRecheckAcquisition(_ manager: CGMManager?) {
    (manager as? G7CGMManager)?.recheckAcquisition()
}

/// The sensor's link is up right now: a reading or its backfill is on the radio.
func watchCGMIsConnected(_ manager: CGMManager?) -> Bool {
    (manager as? G7CGMManager)?.isConnected ?? false
}

/// The pod's reservoir as the phone shows it: the measured level up to 50 U, above that the phone's "50+ U"
/// marker; nil for a pump without one.
func watchPumpReservoir(_ pump: PumpManager?) -> Decimal? {
    guard let pod = (pump as? OmniPumpManager)?.state.podState else { return nil }
    if let level = pod.lastInsulinMeasurements?.reservoirLevel, level <= 50 { return Decimal(level) }
    return Decimal(UInt32(0xDEAD_BEEF))
}

/// When the pod expires; nil for a pump without one.
func watchPumpExpiresAt(_ pump: PumpManager?) -> Date? {
    (pump as? OmniPumpManager)?.state.podState?.expiresAt
}

/// Deactivates and forgets the pod, as the phone's deactivate screen does; false for a pump this can't do.
func watchDeactivatePod(_ pump: PumpManager, completion: @escaping (Error?) -> Void) -> Bool {
    guard let omni = pump as? OmniPumpManager else { return false }
    omni.deactivateAndForgetPod(completion: completion)
    return true
}

/// Forgets a pod that doesn't answer; false for a pump this can't do.
func watchDiscardPod(_ pump: PumpManager, completion: @escaping () -> Void) -> Bool {
    guard let omni = pump as? OmniPumpManager else { return false }
    omni.discardPod(completion: completion)
    return true
}
