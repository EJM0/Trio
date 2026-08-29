import CGMBLEKit
import CGMBLEKitUI
import Foundation
import G7SensorKit
import LibreLoop
import LibreTransmitter
import LoopKit
import LoopKitUI

/// Vendor-specific resolution of CGM session lifetime into plain wall-clock
/// dates. Lives outside the Home module so both the home UI and the Apple
/// Watch manager derive sensor expiry from one implementation and can never
/// disagree about how much sensor life is left.
enum CGMSensorLifecycle {
    /// Sensor expiration for the home label. Prefers manager-reported
    /// dates; reverse-derives from `lifecycle.percentComplete` when not.
    /// `activatedAt` must be session start, not transmitter activation.
    static func resolveSensorExpiresAt(
        manager: CGMManagerUI?,
        glucoseSource: GlucoseSource?,
        lifecycle: DeviceLifecycleProgress?
    ) -> Date? {
        if let sim = glucoseSource as? GlucoseSimulatorSource {
            return sim.simulatedSensorExpiresAt
        }
        guard let manager else { return nil }
        // Once a G7 enters grace period, `sensorExpiresAt` is in the past
        // and would collapse the bobble countdown to "<1m" while the arc
        // (driven by lifecycle.percentComplete against `sensorEndsAt`) is
        // still mid-progress. Fall back to `sensorEndsAt` so bobble and
        // arc agree, and the user sees grace-period time remaining.
        if let g7 = manager as? G7CGMManager {
            let now = Date()
            if let exp = g7.sensorExpiresAt, exp > now { return exp }
            return g7.sensorEndsAt ?? g7.sensorExpiresAt
        }
        if let g6 = manager as? G6CGMManager, let exp = g6.latestReading?.sessionExpDate { return exp }
        if let g5 = manager as? G5CGMManager, let exp = g5.latestReading?.sessionExpDate { return exp }

        // Libre 3 / 3 Plus report time remaining rather than an expiry date, and
        // report it from the first reading — so this must not fall through to the
        // `percentComplete` derivation below, which stays nil until LibreLoop starts
        // publishing progress in the last 24 h.
        if let libreLoop = manager as? LibreLoopCGMManager {
            if case let .active(remaining, _) = libreLoop.sensorLifecycle, remaining > 0 {
                return Date().addingTimeInterval(remaining)
            }
            // Warmup / initializing / expired — no meaningful expiry yet.
            return nil
        }

        let activatedAt: Date?
        if let g7 = manager as? G7CGMManager {
            activatedAt = g7.sensorActivatedAt
        } else if let libre = manager as? LibreTransmitterManagerV3 {
            activatedAt = libre.sensorInfoObservable.activatedAt
        } else {
            activatedAt = nil
        }

        guard let activatedAt,
              let lifecycle,
              lifecycle.percentComplete > 0.001
        else { return nil }
        let elapsed = Date().timeIntervalSince(activatedAt)
        guard elapsed > 0 else { return nil }
        return activatedAt.addingTimeInterval(elapsed / lifecycle.percentComplete)
    }

    /// Wall-clock end of the sensor's warmup window; `nil` when not warming up.
    static func resolveWarmupEndsAt(manager: CGMManagerUI?) -> Date? {
        guard let manager else { return nil }
        if let g7 = manager as? G7CGMManager {
            guard let ends = g7.sensorFinishesWarmupAt, ends > Date() else { return nil }
            return ends
        }
        if let g6 = manager as? G6CGMManager, let start = g6.latestReading?.sessionStartDate {
            let window: TimeInterval = g6.isAnubis ? 50 * 60 : 2 * 60 * 60
            let ends = start.addingTimeInterval(window)
            return ends > Date() ? ends : nil
        }
        if let g5 = manager as? G5CGMManager, let start = g5.latestReading?.sessionStartDate {
            let ends = start.addingTimeInterval(2 * 60 * 60)
            return ends > Date() ? ends : nil
        }
        if let libreLoop = manager as? LibreLoopCGMManager {
            if case let .warmup(_, remaining) = libreLoop.sensorLifecycle, remaining > 0 {
                return Date().addingTimeInterval(remaining)
            }
            return nil
        }
        return nil
    }
}
