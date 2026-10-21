import SwiftUI
import UserNotifications

@main struct TrioWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @WKApplicationDelegateAdaptor private var delegate: TrioWatchAppDelegate

    init() {
        _ = WatchState.shared
        // restores a running untethered session and its devices
        _ = UntetheredWatchManager.shared
        WatchNotificationHandler.shared.configure()
        OpenMealBolusIntent.onPerform = { WatchShortcut.openMealBolus() }
    }

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView()
                .onOpenURL { url in
                    WatchShortcut.handle(url)
                }
        }
        .onChange(of: scenePhase, initial: true) { _, newScenePhase in
            WatchState.shared.setAppActive(newScenePhase == .active)
            // wrist down (inactive) or another app (background): either can freeze the app next
            if newScenePhase != .active {
                UntetheredWatchManager.shared.appLeavingScreen()
            }
            if newScenePhase == .background {
                let untethered = UntetheredWatchManager.shared
                if !untethered.holdsSensorLink {
                    Task { await WatchLogger.shared.flushPersistedLogs() }
                } else if untethered.mayStreamToPhone {
                    Task { await WatchLogger.shared.flushPersistedLogs() }
                }
            } else if newScenePhase == .active {
                WatchState.shared.refreshIfNeeded()
                // with the phone away, looking at the watch is the one wake left
                let untethered = UntetheredWatchManager.shared
                // Mark G7 foreground state before rechecking, so a missed-burst scan can start here.
                untethered.appBecameActive()
                untethered.recheckCGM(trigger: "scene-active")
                // a sensor pairing that is due keeps Trio in front from here
                // what loops in the background did, without waiting for the phone link
                untethered.refresh()
            }
        }
    }
}
