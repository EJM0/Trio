import UIKit

/// Decides, per screen, which interface orientations the app actually accepts.
///
/// Trio is a portrait app on the phone: every screen but the Home chart is laid out for a
/// tall viewport, and the Home dashboard itself budgets fixed zone heights that a ~390 pt
/// tall viewport cannot pay for. Landscape is therefore not simply switched on in
/// Info.plist — the plist only widens what iOS *may* ask the app for; this gate decides what
/// it gets. Home opens the gate, every other tab closes it, so turning the phone anywhere
/// else stays a no-op.
///
/// iPad is exempt: it has always rotated freely and its layouts are built for both
/// orientations, so the gate never speaks for it.
///
/// Read from `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`, which iOS
/// calls on the main thread whenever it re-evaluates a window's orientations.
@MainActor enum OrientationGate {
    /// True while a screen that supports landscape is on top.
    private(set) static var allowsLandscape = false

    private static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    static var mask: UIInterfaceOrientationMask {
        guard isPhone else { return .all }
        // Upside-down portrait stays in the closed set: the phones that support it at all
        // supported it here before landscape existed, and nothing about this gate changes that.
        return allowsLandscape ? .all : [.portrait, .portraitUpsideDown]
    }

    /// Opens or closes the gate, then asks iOS to re-evaluate immediately.
    ///
    /// The re-evaluation is the load-bearing half: closing the gate has to rotate the app
    /// back to portrait itself, or the screen the user just switched to stays sideways in a
    /// layout built for portrait until they physically turn the phone back.
    static func setAllowsLandscape(_ allowed: Bool) {
        guard isPhone, allowed != allowsLandscape else { return }
        allowsLandscape = allowed

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            // Opening the gate only permits landscape — iOS rotates into it on its own once
            // the device is held that way. Closing it must actively pull the app back.
            if !allowed {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }
}
