import AppIntents

/// Opens the watch app on the carbs entry of the "Meal & Bolus" flow. It only navigates: the bolus amount starts
/// at 0 and still has to be confirmed as usual.
///
/// Part of both the watch app and the complication extension: the "Meal & Bolus" control (Control Center, Smart
/// Stack, Action button) runs it, and since it opens the app, the system performs it in the app, where
/// `onPerform` is set.
struct OpenMealBolusIntent: AppIntent {
    static var title: LocalizedStringResource = "Meal & Bolus"
    static var description = IntentDescription("Opens Trio on the watch to log a meal and a bolus.")
    static var openAppWhenRun = true

    /// Set by the watch app at launch; unset in the complication extension.
    @MainActor static var onPerform: (() -> Void)?

    @MainActor func perform() async throws -> some IntentResult {
        Self.onPerform?()
        return .result()
    }
}
