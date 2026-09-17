import CoreData
import Foundation
import UIKit

// MARK: - Meal Preset Conversion

extension FoodItem {
    /// Builds a food item from a saved meal preset.
    ///
    /// This replaces four hand-written conversions that had drifted apart: two set `brand`
    /// and `isManualEntry`, two did not, and the preset editor ignored `isMl` and always used
    /// a per-100 g basis — so a millilitre-based preset was re-read as grams when edited.
    /// `isManualEntry` drives `isCurrentItemMealPreset`, which decides what the nutrition
    /// editor shows, so the variants also disagreed about that.
    init(preset: MealPresetStored) {
        var imageSource: ImageSource = .none
        if let data = preset.imageData, let image = UIImage(data: data) {
            imageSource = .image(image)
        }

        self.init(
            barcode: nil,
            name: preset.dish ?? String(localized: "Preset"),
            brand: String(localized: "Preset"),
            imageSource: imageSource,
            servingQuantity: preset.amount,
            servingQuantityUnit: preset.isMl ? "ml" : "g",
            nutriments: .init(
                basis: preset.isMl ? .per100ml : .per100g,
                carbohydratesPer100g: (preset.carbs as NSDecimalNumber?)?.doubleValue,
                fatPer100g: (preset.fat as NSDecimalNumber?)?.doubleValue,
                proteinPer100g: (preset.protein as NSDecimalNumber?)?.doubleValue
            ),
            amount: preset.amount,
            isMlInput: preset.isMl,
            isManualEntry: true
        )
    }
}
