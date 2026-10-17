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
        .onChange(of: scenePhase) { _, newScenePhase in
            WatchState.shared.setAppActive(newScenePhase == .active)
            if newScenePhase == .background {
                Task {
                    await WatchLogger.shared.flushPersistedLogs()
                }
            } else if newScenePhase == .active {
                WatchState.shared.refreshIfNeeded()
                // with the phone away, looking at the watch is the one wake left
                UntetheredWatchManager.shared.recheckCGM()
                // what loops in the background did, without waiting for the phone link
                UntetheredWatchManager.shared.refresh()
            }
        }
    }
}
