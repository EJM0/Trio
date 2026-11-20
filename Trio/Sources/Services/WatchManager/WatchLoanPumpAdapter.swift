import Foundation
import LoopKit
import LoopKitUI
import OmnipodKit

/// A pump that can be lent to Apple Watch and taken back (OmnipodKit's controller hand-off).
protocol SupersedingDeviceControl: ExclusiveDeviceControl {
    var refusesSessions: Bool { get }
    var foreignSessionDetectedAt: Date? { get }
    func takeControl(supersedingAnotherControllerUntil until: Date?)
    func takeControlLiftingRefusal()
    func stopSupersedingAnotherController()
    /// When the pump started delivering, for an audit over its whole life.
    var deliveryStartedAt: Date? { get }
    var deliveryEndsAt: Date? { get }
    /// A faulted pump delivers nothing more; its delivered total is its last.
    var deliveredUnitsAreFinal: Bool { get }
}

typealias LoanablePump = PumpDeliveryOdometer & PumpManagerUI & SupersedingDeviceControl

extension OmniPumpManager: SupersedingDeviceControl {
    var deliveryStartedAt: Date? { state.podState?.activatedAt }
    var deliveryEndsAt: Date? { state.podState?.expiresAt }
}

/// Every kit call of a hand-off goes through here, so a kit API change touches this file only.
/// Calls that wait out a pod session run off the main thread.
final class WatchLoanPumpAdapter {
    enum Take: Equatable {
        /// After an acknowledged hand-back, or a retake the watch never adopted.
        case plain
        /// A user take from a watch that may not know yet: its sessions don't stop this phone until then.
        case superseding(until: Date)
        /// The user chose this phone after an unknown device used the pod.
        case liftingRefusal
    }

    let manager: LoanablePump

    init(_ manager: LoanablePump) {
        self.manager = manager
    }

    init?(_ pumpManager: PumpManager?) {
        guard let manager = pumpManager as? LoanablePump else { return nil }
        self.manager = manager
    }

    var status: PumpManagerStatus { manager.status }
    var pluginIdentifier: String { manager.pluginIdentifier }
    var rawState: [String: Any] { manager.rawState }
    var supportedBasalRates: [Double] { manager.supportedBasalRates }
    var supportedBolusVolumes: [Double] { manager.supportedBolusVolumes }
    var isReleased: Bool { manager.isControlReleased }
    var refusesSessions: Bool { manager.refusesSessions }
    /// Not released and not refusing: the kit would run this phone's next session.
    var holdsPod: Bool { !isReleased && !refusesSessions }
    var foreignSessionDetectedAt: Date? { manager.foreignSessionDetectedAt }
    var deliveredUnits: (units: Double, at: Date)? { manager.deliveredUnits }
    var pulse: Double { manager.deliveryPulseUnits }
    var startedAt: Date? { manager.deliveryStartedAt }
    var endsAt: Date? { manager.deliveryEndsAt }
    var isFaulted: Bool { manager.deliveredUnitsAreFinal }

    func cancelTempBasal() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.enactTempBasal(decisionId: nil, unitsPerHour: 0, for: 0) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func refreshDeliveredUnits() async -> Bool {
        await manager.refreshDeliveredUnits()
    }

    /// True when the kit holds the release (it refuses while a command is unconfirmed).
    func release() async -> Bool {
        await offMain { self.manager.releaseControl() }
        return manager.isControlReleased
    }

    /// True when the kit holds the pod afterwards.
    func take(_ take: Take) async -> Bool {
        await offMain {
            switch take {
            case .plain: self.manager.takeControl()
            case let .superseding(until): self.manager.takeControl(supersedingAnotherControllerUntil: until)
            case .liftingRefusal: self.manager.takeControlLiftingRefusal()
            }
        }
        return holdsPod
    }

    /// The kit's scope normally outlives a foreign session; restore it only if the kit lost it.
    func keepSuperseding(until: Date) async {
        guard refusesSessions else { return }
        _ = await take(.superseding(until: until))
    }

    /// The watch deactivated the faulted pod and booked its end: forgotten here without booking a discard.
    func forgetDeactivatedElsewhere() async {
        await (manager as? OmniPumpManager)?.forgetDeviceDeactivatedElsewhere()
    }

    /// The superseded watch confirmed its release, or the window ended: a further foreign session stops this phone.
    func endSuperseding() async {
        await offMain { self.manager.stopSupersedingAnotherController() }
    }

    /// Binary property lists of the pump's export (only after the release held) and of `cgm`'s.
    func exportedConfiguration() throws -> Data {
        guard isReleased else { throw WatchLoanPumpAdapterError.notReleased }
        return try PropertyListSerialization.data(
            fromPropertyList: manager.exportConfiguration().rawValue,
            format: .binary,
            options: 0
        )
    }

    /// The copy a watch may start from without the phone, exported while this phone still holds the pod: the kit marks
    /// the pod shared, so it refuses a session another controller made since instead of resyncing to it.
    func copyConfiguration() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: manager.exportConfiguration().rawValue,
            format: .binary,
            options: 0
        )
    }

    /// What a bolus under way at `reading` has still to deliver, in whole pulses. OmnipodKit derives the end
    /// time from the pod's `bolusNotDelivered` at that status read, at the rate `estimatedDuration` uses.
    func bolusRemainder(at reading: Date) -> Double {
        guard let endsAt = manager.bolusUnderWayEndsAt, endsAt > reading else { return 0 }
        let secondsPerUnit = manager.estimatedDuration(toBolus: 1)
        guard secondsPerUnit > 0, pulse > 0 else { return 0 }
        return (endsAt.timeIntervalSince(reading) / secondsPerUnit / pulse).rounded() * pulse
    }

    private func offMain(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                work()
                continuation.resume()
            }
        }
    }
}

enum WatchLoanPumpAdapterError: Error {
    case notReleased
}
