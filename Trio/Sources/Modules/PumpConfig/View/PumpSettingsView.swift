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

        func makeCoordinator() -> KitScreenToken { KitScreenToken() }

        func makeUIViewController(context: UIViewControllerRepresentableContext<PumpSettingsView>) -> UIViewController {
            if let handedOver = PumpConfig.handedOverViewController(gate: watchLoanGate) { return handedOver }
            context.coordinator.open()
            var vc = pumpManager.settingsViewController(
                bluetoothProvider: bluetoothManager,
                pumpManagerOnboardingDelegate: setupDelegate
            )
            vc.completionDelegate = completionDelegate
            return vc
        }

        func updateUIViewController(_: UIViewController, context _: UIViewControllerRepresentableContext<PumpSettingsView>) {}

        static func dismantleUIViewController(_: UIViewController, coordinator: KitScreenToken) {
            coordinator.close()
        }
    }

    /// Counts the kit settings and setup screens on screen: they command the pump directly, so Trio on Watch
    /// doesn't start under one.
    final class KitScreenToken {
        private static let lock = NSLock()
        private static var openCount = 0
        private var isOpen = false

        static var anyOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return openCount > 0
        }

        func open() {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            guard !isOpen else { return }
            isOpen = true
            Self.openCount += 1
        }

        func close() {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            guard isOpen else { return }
            isOpen = false
            Self.openCount -= 1
        }
    }

    static var isKitScreenOpen: Bool { KitScreenToken.anyOpen }

    /// Pump settings and setup command the pump directly, so they stay closed while the phone isn't its owner.
    /// Returns nil when the phone may command the pump.
    static func handedOverViewController(gate: WatchLoanGate) -> UIViewController? {
        guard let refusal = gate.refusal("Pump screen", userInitiated: true) else { return nil }
        return UIHostingController(rootView: Text(refusal).padding())
    }
}
