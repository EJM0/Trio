import LoopKitUI
import SwiftUI
import UIKit

extension PumpConfig {
    struct PumpSettingsView: UIViewControllerRepresentable {
        let pumpManager: PumpManagerUI
        let bluetoothManager: BluetoothStateManager
        weak var completionDelegate: CompletionDelegate?
        weak var setupDelegate: PumpManagerOnboardingDelegate?

        func makeUIViewController(context _: UIViewControllerRepresentableContext<PumpSettingsView>) -> UIViewController {
            if let handedOver = PumpConfig.handedOverViewController() { return handedOver }
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
    static func handedOverViewController(gate: WatchLoanGate = WatchLoanGate()) -> UIViewController? {
        guard !gate.phoneMayCommandPump else { return nil }
        return UIHostingController(rootView: Text(gate.refusalMessage).padding())
    }
}
