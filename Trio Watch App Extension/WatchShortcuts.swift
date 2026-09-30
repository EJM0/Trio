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
        Task {
            await WatchLogger.shared.log("⌚️ Opening Meal & Bolus from a shortcut")
        }
    }

    /// Handles a deep link; returns `false` for URLs that are not a watch shortcut.
    @MainActor @discardableResult static func handle(_ url: URL) -> Bool {
        guard url.scheme == mealBolusURL.scheme, url.host == mealBolusURL.host else { return false }
        openMealBolus()
        return true
    }
}

/// Opens the watch app on the carbs entry of the "Meal & Bolus" flow. It only navigates: the bolus amount starts
/// at 0 and still has to be confirmed as usual.
struct OpenMealBolusIntent: AppIntent {
    static var title: LocalizedStringResource = "Meal & Bolus"
    static var description = IntentDescription("Opens Trio on the watch to log a meal and a bolus.")
    static var openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        WatchShortcut.openMealBolus()
        return .result()
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
    }
}
