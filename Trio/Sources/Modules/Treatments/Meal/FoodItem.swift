import Foundation
import UIKit

/// One food in the meal being entered, or the draft a meal preset is edited as.
///
/// Macros are per 100 g (or 100 ml when `isMl`); `amount` is the portion in the same unit.
struct FoodItem: Identifiable, Equatable {
    let id: UUID
    var name: String
    /// JPEG, already downscaled by `FoodItem.imageData(from:)`.
    var imageData: Data?
    // ponytail: g and ml are treated 1:1, add a density per item if anyone logs oil by weight
    var isMl: Bool
    var carbsPer100: Decimal
    var fatPer100: Decimal
    var proteinPer100: Decimal
    var amount: Decimal
    /// What one portion is, for the row's portion stepper. Nil hides the stepper.
    var servingSize: Decimal?

    init(
        id: UUID = UUID(),
        name: String = "",
        imageData: Data? = nil,
        isMl: Bool = false,
        carbsPer100: Decimal = 0,
        fatPer100: Decimal = 0,
        proteinPer100: Decimal = 0,
        amount: Decimal = 100,
        servingSize: Decimal? = nil
    ) {
        self.id = id
        self.name = name
        self.imageData = imageData
        self.isMl = isMl
        self.carbsPer100 = carbsPer100
        self.fatPer100 = fatPer100
        self.proteinPer100 = proteinPer100
        self.amount = amount
        self.servingSize = servingSize
    }

    var carbs: Decimal { carbsPer100 * amount / 100 }
    var fat: Decimal { fatPer100 * amount / 100 }
    var protein: Decimal { proteinPer100 * amount / 100 }

    var unit: String { isMl ? String(localized: "ml") : String(localized: "g") }

    /// Downscales to at most 512 px and encodes once, so saving a preset again does not
    /// recompress an image that did not change.
    static func imageData(from image: UIImage) -> Data? {
        let maxDimension: CGFloat = 512
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.5)
    }
}

extension MealPresetStored {
    /// A new item each time (fresh id), so the same preset can be in the meal twice.
    var foodItem: FoodItem {
        let portion = amount?.decimalValue ?? 100
        return FoodItem(
            name: dish ?? "",
            imageData: imageData,
            isMl: isMl,
            carbsPer100: carbs?.decimalValue ?? 0,
            fatPer100: fat?.decimalValue ?? 0,
            proteinPer100: protein?.decimalValue ?? 0,
            amount: portion,
            servingSize: portion
        )
    }

    func update(from item: FoodItem) {
        dish = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        imageData = item.imageData
        isMl = item.isMl
        carbs = item.carbsPer100 as NSDecimalNumber
        fat = item.fatPer100 as NSDecimalNumber
        protein = item.proteinPer100 as NSDecimalNumber
        amount = item.amount as NSDecimalNumber
    }
}

/// The meal being put together on the Treatments screen, shared with the meal sheet.
@Observable final class MealModel {
    enum Tab: Hashable {
        case meal
        case presets
    }

    var items: [FoodItem] = []
    var searchQuery = ""
    var tab: Tab = .meal

    var carbs: Decimal { items.reduce(0) { $0 + $1.carbs } }
    var fat: Decimal { items.reduce(0) { $0 + $1.fat } }
    var protein: Decimal { items.reduce(0) { $0 + $1.protein } }
}
