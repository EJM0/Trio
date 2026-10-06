import AccuChekKit
import CGMBLEKit
import CGMBLEKitUI
import EversenseKit
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
    /// Sensor expiration for the home label, as reported by the CGM manager.
    static func resolveSensorExpiresAt(
        manager: CGMManagerUI?,
        glucoseSource: GlucoseSource?
    ) -> Date? {
        if let sim = glucoseSource as? GlucoseSimulatorSource {
            return sim.simulatedSensorExpiresAt
        }

        switch manager {
        case let g7 as G7CGMManager:
            // Once a G7 enters grace period, `sensorExpiresAt` is in the past
            // and would collapse the bobble countdown to "<1m" while the arc
            // (driven by lifecycle.percentComplete against `sensorEndsAt`) is
            // still mid-progress. Fall back to `sensorEndsAt` so bobble and
            // arc agree, and the user sees grace-period time remaining.
            if let exp = g7.sensorExpiresAt, exp > Date.now {
                return exp
            }
            return g7.sensorEndsAt ?? g7.sensorExpiresAt

        case let g6 as G6CGMManager:
            return g6.latestReading?.sessionExpDate

        case let g5 as G5CGMManager:
            return g5.latestReading?.sessionExpDate

        case let libreTransmitter as LibreTransmitterManagerV3:
            return libreTransmitter.sensorInfoObservable.expiresAt

        case let libreLoop as LibreLoopCGMManager:
            if case let .active(remaining, _) = libreLoop.sensorLifecycle, remaining > 0 {
                return Date().addingTimeInterval(remaining)
            }
            // Warmup / initializing / expired: no meaningful expiry yet.
            return nil

        case let eversense as EversenseCGMManager:
            return eversense.state.expiresAt

        case let accuChek as AccuChekCgmManager:
            return accuChek.state.cgmEndTime

        default:
            return nil
        }
    }

    /// Wall-clock end of the sensor's warmup window; `nil` when not warming up.
    /// Note: Libre 2 & Eversense do not emit/have warming up periods
    static func resolveWarmupEndsAt(manager: CGMManagerUI?) -> Date? {
        switch manager {
        case let g7 as G7CGMManager:
            guard let ends = g7.sensorFinishesWarmupAt, ends > Date.now else {
                return nil
            }

            return ends

        case let g6 as G6CGMManager:
            guard let start = g6.latestReading?.sessionStartDate else {
                return nil
            }

            let window: TimeInterval = g6.isAnubis ? 50 * 60 : 2 * 60 * 60
            let ends = start.addingTimeInterval(window)
            return ends > Date.now ? ends : nil

        case let g5 as G5CGMManager:
            guard let start = g5.latestReading?.sessionStartDate else {
                return nil
            }

            let ends = start.addingTimeInterval(2 * 60 * 60)
            return ends > Date.now ? ends : nil

        case let libreLoop as LibreLoopCGMManager:
            if case let .warmup(_, remaining) = libreLoop.sensorLifecycle, remaining > 0 {
                return Date.now.addingTimeInterval(remaining)
            }
            return nil

        case let accuChek as AccuChekCgmManager:
            if accuChek.state.calibrationPhase != .done, let warmupCompleted = accuChek.state.cgmWarmupCompleted {
                return warmupCompleted
            }
            return nil

        default:
            return nil
        }
    }
}
