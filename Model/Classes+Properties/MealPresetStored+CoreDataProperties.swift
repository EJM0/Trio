import CoreData
import Foundation

public extension MealPresetStored {
    @nonobjc class func fetchRequest() -> NSFetchRequest<MealPresetStored> {
        NSFetchRequest<MealPresetStored>(entityName: "MealPresetStored")
    }

    /// The portion the preset adds, in g or ml (`isMl`). Presets saved before this existed get 100,
    /// which keeps their totals unchanged now that the macros below are per 100 g/ml.
    @NSManaged var amount: NSDecimalNumber?
    /// Per 100 g/ml.
    @NSManaged var carbs: NSDecimalNumber?
    @NSManaged var dish: String?
    /// Per 100 g/ml.
    @NSManaged var fat: NSDecimalNumber?
    @NSManaged var imageData: Data?
    @NSManaged var isMl: Bool
    /// Per 100 g/ml.
    @NSManaged var protein: NSDecimalNumber?
}

extension MealPresetStored: Identifiable {}
