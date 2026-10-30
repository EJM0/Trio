import SwiftUI
import UserNotifications

@main struct TrioWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @WKApplicationDelegateAdaptor private var delegate: TrioWatchAppDelegate

    init() {
        _ = WatchState.shared
        // restores the watch's own link to the sensor
        _ = WatchCGMHost.shared
        // a session that was running resumes with its pump
        _ = WatchLoopSession.shared
        WatchNotificationHandler.shared.configure()
        OpenMealBolusIntent.onPerform = { WatchShortcut.openMealBolus() }
        WatchLogger.shared.info(.lifecycle, "App launched")
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
            if newScenePhase == .background {
                WatchLogger.shared.info(.lifecycle, "App moved to background")
                WatchLogger.shared.didEnterBackground()
            } else if newScenePhase == .active {
                WatchState.shared.refreshIfNeeded()
                // looking at the watch is a wake that is not the sensor's own
                WatchCGMHost.shared.recheckAcquisition()
            }
        }
    }
}
