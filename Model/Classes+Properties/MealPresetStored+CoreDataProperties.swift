import CoreData
import Foundation

public extension MealPresetStored {
    @nonobjc class func fetchRequest() -> NSFetchRequest<MealPresetStored> {
        NSFetchRequest<MealPresetStored>(entityName: "MealPresetStored")
    }

    @NSManaged var carbs: NSDecimalNumber?
    @NSManaged var dish: String?
    @NSManaged var fat: NSDecimalNumber?
    @NSManaged var protein: NSDecimalNumber?
    @NSManaged var imageData: Data?
    @NSManaged var isMl: Bool
    @NSManaged var amount: Double
}

extension MealPresetStored: Identifiable {}
