/// MealManager module: entering meals by barcode, nutrition label, OpenFoodFacts search
/// or saved meal presets.
enum MealManager {
    enum Config {}

    /// The Meal Manager sheet's three tabs. Module-level so anything opening the sheet can say
    /// which one it wants -- this used to be a `showListView` Bool plus a separate `@State`
    /// plus a `showListInitially` init parameter, three things encoding one selection.
    enum ListTab: String, CaseIterable {
        case scanner = "Scanner"
        case scanned = "Meal"
        case presets = "Presets"
    }
}

/// Provider protocol for MealManager module
protocol MealManagerProvider: Provider {
    var scaleManager: ScaleManager { get }
    var openFoodFacts: OpenFoodFactsClient { get }
}
