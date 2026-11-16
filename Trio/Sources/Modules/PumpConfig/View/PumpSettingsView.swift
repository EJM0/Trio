import LoopKitUI
import SwiftUI
import UIKit

extension PumpConfig {
    struct PumpSettingsView: UIViewControllerRepresentable {
        let pumpManager: PumpManagerUI
        let bluetoothManager: BluetoothStateManager
        let watchLoanGate: WatchLoanGate
        weak var completionDelegate: CompletionDelegate?
        weak var setupDelegate: PumpManagerOnboardingDelegate?

        func makeUIViewController(context _: UIViewControllerRepresentableContext<PumpSettingsView>) -> UIViewController {
            if let handedOver = PumpConfig.handedOverViewController(gate: watchLoanGate) { return handedOver }
            var vc = pumpManager.settingsViewController(
                bluetoothProvider: bluetoothManager,
                pumpManagerOnboardingDelegate: setupDelegate
            )
            vc.completionDelegate = completionDelegate
            return vc
        }

        func updateUIViewController(_: UIViewController, context _: UIViewControllerRepresentableContext<PumpSettingsView>) {}
    }

    /// Pump settings and setup command the pump directly, so they stay closed while the phone isn't its owner.
    /// Returns nil when the phone may command the pump.
    static func handedOverViewController(gate: WatchLoanGate) -> UIViewController? {
        guard let refusal = gate.refusal("Pump screen", userInitiated: true) else { return nil }
        return UIHostingController(rootView: Text(refusal).padding())
    }
}
