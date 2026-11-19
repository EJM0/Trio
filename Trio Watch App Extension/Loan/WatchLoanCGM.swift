import Foundation
import LoopKit

/// The loan's view of the watch's one G7 link, `WatchCGMHost`: the loan builds no manager of its own, so the sensor
/// is never held by two centrals. The host passes this object its readings, errors and alerts while a loan runs.
@MainActor final class WatchLoanCGM: LoanCGMSource {
    /// shortcut: in memory only, so a relaunch forgets timed sensor alerts it may need to retract at End; persist if
    /// a stale sensor notice after a loan is reported.
    private var issued: Set<Alert.Identifier> = []
    weak var host: WatchLoanHost?

    /// The grant's configuration builds the host's manager only when the phone isn't already sharing its CGM.
    func adopt(export: Data) async {
        let configuration = WatchLoanSnapshot.configuration(from: export).flatMap(SharedDeviceConfiguration.init(rawValue:))
        if configuration == nil {
            WatchLogger.shared.error(.cgm, "No CGM configuration in the grant")
        }
        WatchCGMHost.shared.lend(to: self, configuration: configuration)
    }

    /// The host restored its own manager at launch.
    func restore() {
        WatchCGMHost.shared.lend(to: self, configuration: nil)
    }

    /// Any wake the sensor didn't cause.
    func recheckAcquisition() {
        WatchCGMHost.shared.recheckAcquisition()
    }

    func retire() async {
        // the phone keeps the sensor's alerts after the loan
        for identifier in issued { await host?.retractKitAlert(identifier) }
        issued = []
        WatchCGMHost.shared.endLoan(self)
    }

    // MARK: - From WatchCGMHost

    func received(_ samples: [NewGlucoseSample]) {
        let readings = Self.readings(from: samples)
        guard !readings.isEmpty else { return }
        Task { [weak self] in await self?.host?.receiveReadings(readings) }
    }

    func failed(_ error: Error) {
        host?.deviceError(error)
    }

    func issueAlert(_ alert: Alert) async {
        issued.insert(alert.identifier)
        await host?.issueSensorAlert(alert)
    }

    func retractAlert(identifier: Alert.Identifier) async {
        issued.remove(identifier)
        await host?.retractKitAlert(identifier)
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
