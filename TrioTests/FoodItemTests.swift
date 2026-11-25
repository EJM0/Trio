import CoreData
import Foundation
import Testing

@testable import Trio

@Suite("Meal: food items and presets") struct FoodItemTests {
    @Test("Macros scale with the portion") func totalsScale() {
        let item = FoodItem(carbsPer100: 10, fatPer100: 4, proteinPer100: 2, amount: 250)
        #expect(item.carbs == 25)
        #expect(item.fat == 10)
        #expect(item.protein == 5)
    }

    @Test("The meal adds up its items") func mealTotals() {
        let meal = MealModel()
        meal.items = [
            FoodItem(carbsPer100: 10, amount: 250),
            FoodItem(carbsPer100: 60, amount: 50)
        ]
        #expect(meal.carbs == 55)
    }

    @Test("A preset saved before amounts existed adds what it always did") func legacyPreset() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        try await context.perform {
            let preset = MealPresetStored(context: context)
            preset.dish = "Pizza"
            preset.carbs = NSDecimalNumber(value: 60)
            try context.save()

            // The model default fills `amount`, so the per-100 reading gives back 60 g.
            #expect(preset.foodItem.carbs == 60)
        }
    }

    @Test("A preset round-trips through FoodItem") func roundTrip() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        let item = FoodItem(
            name: " Coffee ",
            isMl: true,
            carbsPer100: 10,
            fatPer100: 1,
            proteinPer100: 2,
            amount: 333
        )
        try await context.perform {
            let preset = MealPresetStored(context: context)
            preset.update(from: item)
            try context.save()

            let loaded = preset.foodItem
            #expect(loaded.name == "Coffee")
            #expect(loaded.isMl)
            #expect(loaded.carbsPer100 == 10)
            #expect(loaded.fatPer100 == 1)
            #expect(loaded.proteinPer100 == 2)
            #expect(loaded.amount == 333)
            #expect(loaded.servingSize == 333)
            #expect(loaded.carbs == Decimal(string: "33.3"))
        }
    }
}
