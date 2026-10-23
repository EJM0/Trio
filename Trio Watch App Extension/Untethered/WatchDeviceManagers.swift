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

/// The G7 resumes foreground-only acquisition work before the next acquisition recheck.
func watchCGMAppBecameActive(_ manager: CGMManager?) {
    (manager as? G7CGMManager)?.appBecameActive()
}

/// The app is leaving the screen: the CGM puts its next connect in before watchOS freezes the app.
func watchCGMAppLeavingScreen(_ manager: CGMManager?) {
    (manager as? G7CGMManager)?.appLeavingScreen()
}

/// While the G7's link is up, and 3 s after it closed, a pod command's connect waits (at most 15 s, in OmnipodKit):
/// the two share the watch's one radio, and a pod command cut off then began every pod stall. Before (Trio 53ddccc)
/// only the loop waited; on 23 October 12 of 48 pod connects still came at the sensor's link-up, and one of them
/// started the stall at 12:40:56.
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

/// The sensor's link is up right now: a reading or its backfill is on the radio.
func watchCGMIsConnected(_ manager: CGMManager?) -> Bool {
    (manager as? G7CGMManager)?.isConnected ?? false
}

/// The Devices page as the phone fills it (`AppleWatchManager.gatherPeripherals`), from the watch's own
/// pump and sensor, so it looks the same untethered.
func publishWatchPeripherals(pump: PumpManager?, cgm: CGMManager?, reservoir: Decimal?, to state: WatchState) {
    state.peripheralsUpdatedAt = Date()
    state.pumpName = pump?.localizedTitle
    state.pumpActivatedAt = nil
    state.pumpBatteryPercent = nil
    if let omni = pump as? OmniPumpManager {
        state.pumpExpiresAt = omni.state.podState?.expiresAt
        // as the phone: above 50 U the pod doesn't measure; the fill-based estimate, else the "50+ U" sentinel
        if let level = omni.state.podState?.lastInsulinMeasurements?.reservoirLevel, level <= 50 {
            state.pumpReservoir = Decimal(level)
        } else if let estimate = omni.state.estimatedReservoirLevel {
            state.pumpReservoir = Decimal(estimate)
        } else {
            state.pumpReservoir = Decimal(UInt32(0xDEAD_BEEF))
        }
    } else {
        state.pumpExpiresAt = nil
        state.pumpReservoir = reservoir
    }
    if case .suspended = pump?.status.basalDeliveryState {
        state.pumpStatusMessage = String(localized: "Insulin Suspended")
    } else {
        state.pumpStatusMessage = nil
    }

    state.cgmName = cgm?.localizedTitle
    if let g7 = cgm as? G7CGMManager {
        // as `CGMSensorLifecycle.resolveSensorExpiresAt`: in the grace period, its end
        if let expires = g7.sensorExpiresAt, expires > Date() {
            state.cgmSensorExpiresAt = expires
        } else {
            state.cgmSensorExpiresAt = g7.sensorEndsAt ?? g7.sensorExpiresAt
        }
        let progress = g7LifecycleProgress(g7)
        state.cgmProgressPercent = progress?.percentComplete
        state.cgmProgressState = progress?.state.rawValue
        state.cgmStatusMessage = g7.isSearchingForSensor ? String(localized: "Searching for sensor") : nil
    } else {
        state.cgmSensorExpiresAt = nil
        state.cgmProgressPercent = nil
        state.cgmProgressState = nil
        state.cgmStatusMessage = nil
    }
    state.hasReceivedPeripheralData = true
}

/// G7SensorKitUI's `cgmLifecycleProgress`; the watch doesn't link the UI kit.
private func g7LifecycleProgress(_ g7: G7CGMManager) -> (percentComplete: Double, state: DeviceLifecycleProgressState)? {
    switch g7.lifecycleState {
    case .ok:
        // not before the sensor reported its session length: the 10-day default misleads a 15-day sensor
        guard g7.state.extendedVersion != nil, let expiration = g7.sensorExpiresAt else { return nil }
        let remaining = max(0, expiration.timeIntervalSinceNow)
        guard remaining < 48 * 60 * 60 else { return nil }
        return (1 - remaining / g7.lifetime, remaining < 24 * 60 * 60 ? .warning : .normalCGM)
    case .gracePeriod:
        guard let end = g7.sensorEndsAt else { return nil }
        return (1 - max(0, end.timeIntervalSinceNow) / G7Sensor.gracePeriod, .critical)
    case .expired:
        return (1, .critical)
    default:
        return nil
    }
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
