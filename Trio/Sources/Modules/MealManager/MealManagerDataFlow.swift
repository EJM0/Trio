import CoreGraphics

/// MealManager module: entering meals by barcode, nutrition label, OpenFoodFacts search
/// or saved meal presets.
enum MealManager {
    enum Config {}

    /// The metrics every row in this module shares. Thumbnails used to be 44, 58 and 60 points
    /// across the three row types and corner radii ran 8, 10, 12, 16 and 20 with no reason for
    /// any of it.
    enum Layout {
        /// Full-size row thumbnail: the meal list and the preset list.
        static let thumbnail: CGFloat = 56
        /// Compact row thumbnail: search results.
        static let thumbnailCompact: CGFloat = 44
        static let cornerRadius: CGFloat = 12
        static let cornerRadiusCompact: CGFloat = 8
        /// The vertical rhythm of the sheet's header: nav bar to tab selector, tab selector to
        /// whatever the tab shows, and the header block down to the list are all this one gap.
        /// Applied once each, so the three tabs cannot drift apart -- they used to bring their
        /// own top insets (20, 8 and none) and the selector used a system default on top.
        static let contentTopSpacing: CGFloat = 16
    }

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
