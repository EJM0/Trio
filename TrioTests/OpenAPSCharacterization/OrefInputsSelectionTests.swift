import CoreData
import Foundation
import Swinject
import Testing
@testable import Trio

/// The phone selects rows with Core Data predicates; `OrefInputs` selects with Swift filters.
/// These cases pin both to the same rows, edges included.
@Suite("OrefInputs selection matches the phone's fetches", .serialized) struct OrefInputsSelectionTests {
    let resolver: Resolver
    let stack: CoreDataStack

    init() async throws {
        resolver = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly()
        ]).resolver
        stack = try await CoreDataStack.createForTests()
    }

    private func insertTDD(_ rows: [(date: Date, total: Decimal?)]) async throws {
        let context = stack.newTaskContext()
        try await context.perform {
            for row in rows {
                let object = TDDStored(context: context)
                object.id = UUID()
                object.date = row.date
                object.total = row.total.map { NSDecimalNumber(decimal: $0) }
            }
            try context.save()
        }
    }

    @Test("TDD history: after the 10-day start, total above 0, oldest first") func tddHistory() async throws {
        let now = Date()
        let start = OrefInputs.tddHistoryStart(now: now)
        let rows: [(date: Date, total: Decimal?)] = [
            (start.addingTimeInterval(-1), 30),
            (start, 30),
            (start.addingTimeInterval(1), 30),
            (start.addingTimeInterval(2), 0),
            (start.addingTimeInterval(3), nil),
            (now.addingTimeInterval(-3599), 30),
            (now.addingTimeInterval(-3600), Decimal(string: "0.01"))
        ]
        try await insertTDD(rows)

        let openAPS = OpenAPS(
            storage: InMemoryFileStorage(),
            tddStorage: BaseTDDStorage(resolver: resolver),
            glucoseStorage: BaseGlucoseStorage(resolver: resolver),
            carbsStorage: BaseCarbsStorage(resolver: resolver)
        )
        let context = stack.newTaskContext()
        let fetched = try await context.perform {
            try openAPS.fetchHistoricalTDDData(from: start, on: context).map {
                OrefInputs.TDDRow(date: $0["date"] as? Date, total: ($0["total"] as? NSDecimalNumber)?.decimalValue)
            }
        }
        let selected = OrefInputs.tddHistory(rows.map { OrefInputs.TDDRow(date: $0.date, total: $0.total) }, now: now)

        #expect(fetched.count == 3)
        #expect(fetched.map(\.date) == selected.map(\.date))
        #expect(fetched.map(\.total) == selected.map(\.total))
    }

    @Test("TDD sufficiency: same threshold and window", arguments: [0, 1]) func sufficientTDD(extraRows: Int) async throws {
        let now = Date()
        let count = OrefInputs.sufficientTDDRowCount - 1 + extraRows
        var rows: [(date: Date, total: Decimal?)] = (0 ..< count).map { (now.addingTimeInterval(-Double($0 * 300 + 60)), 30) }
        // never counted: zero total, and older than 7 days
        rows.append((now.addingTimeInterval(-600), 0))
        rows.append((OrefInputs.sufficientTDDStart(now: now).addingTimeInterval(-60), 30))
        try await insertTDD(rows)

        let phone = try await BaseTDDStorage.hasSufficientTDD(context: stack.newTaskContext())
        let selected = OrefInputs.hasSufficientTDD(rows.map { OrefInputs.TDDRow(date: $0.date, total: $0.total) }, now: now)

        #expect(phone == selected)
        #expect(selected == (extraRows == 1))
    }

    @Test("Glucose: same window and order", arguments: [
        OrefInputs.autosensGlucoseHours,
        Decimal(string: "6.5")!
    ]) func glucose(hours: Decimal) async throws {
        let now = Date()
        let start = OrefInputs.glucoseStart(hours: hours, now: now)
        // a minute either side of the edge, since the phone reads its own Date()
        let dates = [
            start.addingTimeInterval(-60),
            start.addingTimeInterval(60),
            now.addingTimeInterval(-600),
            now.addingTimeInterval(-300)
        ]
        let context = stack.newTaskContext()
        try await context.perform {
            for (index, date) in dates.enumerated() {
                let object = GlucoseStored(context: context)
                object.id = UUID()
                object.date = date
                object.glucose = Int16(100 + index)
                object.isManual = false
            }
            try context.save()
        }

        let phone = try await BaseGlucoseStorage(resolver: resolver, contextProvider: { stack.newTaskContext() })
            .getGlucoseForAlgorithm(shouldSmoothGlucose: false, fetchHours: hours)
        let selected = OrefInputs.glucose(
            dates.map { BloodGlucose(sgv: 100, direction: nil, date: 0, dateString: $0, glucose: nil, type: "sgv") },
            since: start
        )

        #expect(phone.count == 3)
        #expect(phone.map(\.dateString) == selected.map(\.dateString))
    }

    @Test("Carbs: same one-day window and order") func carbs() async throws {
        let now = Date()
        let start = OrefInputs.carbsStart(now: now, timeZone: TimeZone.current)
        let dates = [start.addingTimeInterval(-60), start.addingTimeInterval(60), now.addingTimeInterval(-600)]
        let context = stack.newTaskContext()
        try await context.perform {
            for date in dates {
                let object = CarbEntryStored(context: context)
                object.id = UUID()
                object.date = date
                object.carbs = 20
            }
            try context.save()
        }

        let phone = try await BaseCarbsStorage(resolver: resolver, contextProvider: { stack.newTaskContext() })
            .getCarbsForAlgorithm()
        let selected = OrefInputs.carbs(
            dates.map { OrefInputs.carbsEntry(id: nil, date: $0, carbs: 20, fat: 0, protein: 0, isFPU: false) },
            now: now,
            timeZone: TimeZone.current
        )

        #expect(phone.count == 2)
        #expect(phone.map(\.createdAt) == selected.map(\.createdAt))
    }
}
