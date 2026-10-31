import AppIntents
import Foundation

/// Entry points that open the watch app straight into a treatment flow: the "Meal & Bolus" complication (a deep
/// link) and the App Intent behind Siri, the Shortcuts app, the Action button and Smart Stack suggestions.
enum WatchShortcut {
    /// Must match the URL the "Meal & Bolus" complication opens (Trio Watch Complication extension).
    static let mealBolusURL = URL(string: "trio-watch://meal-bolus")!

    /// Asks the main view to open the "Meal & Bolus" flow, whether the app was running or just launched.
    @MainActor static func openMealBolus() {
        WatchState.shared.isMealBolusShortcutPending = true
        WatchLogger.shared.info(.bolus, "Opening Meal & Bolus from a shortcut")
    }

    /// Handles a deep link; returns `false` for URLs that are not a watch shortcut.
    @MainActor @discardableResult static func handle(_ url: URL) -> Bool {
        guard url.scheme == mealBolusURL.scheme, url.host == mealBolusURL.host else { return false }
        openMealBolus()
        return true
    }
}

struct TrioWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMealBolusIntent(),
            phrases: [
                "\(.applicationName) meal and bolus",
                "Log a meal in \(.applicationName)",
                "\(.applicationName) Mahlzeit und Bolus",
                "\(.applicationName) Mahlzeit"
            ],
            shortTitle: "Meal & Bolus",
            systemImageName: "fork.knife"
        )
        AppShortcut(
            intent: StartWatchLoopIntent(),
            phrases: [
                "Start \(.applicationName) Watch Loop",
                "\(.applicationName) Watch Loop starten"
            ],
            shortTitle: "Start Watch Loop",
            systemImageName: "applewatch"
        )
    }
}

/// Asks the phone for the pod, as the Watch Loop page's Start does; the app opens, and the page shows the answer.
struct StartWatchLoopIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Watch Loop"
    static var description = IntentDescription("Asks your iPhone to hand the pod to the watch, which then loops.")
    static var openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        WatchLoopSession.shared.start()
        return .result()
    }
}
