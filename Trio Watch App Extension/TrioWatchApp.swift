import SwiftUI
import UserNotifications
import WatchKit

@main struct TrioWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if TRIO_ON_WATCH
        @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    #endif

    init() {
        algorithmLogSink = WatchLogger.shared.algorithm
        _ = WatchState.shared
        WatchNotificationHandler.shared.configure()
        WatchLogger.shared.info(.lifecycle, "App launched")
        WatchLoanRuntime.start()
    }

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            WatchAppState.set(newScenePhase == .active ? "foreground" : newScenePhase == .background ? "background" : "inactive")
            WatchState.shared.setAppActive(newScenePhase == .active)
            if newScenePhase == .background {
                WatchLogger.shared.info(.lifecycle, "App moved to background")
                WatchLogger.shared.didEnterBackground()
            } else if newScenePhase == .active {
                WatchState.shared.refreshIfNeeded()
            }
        }
    }
}
