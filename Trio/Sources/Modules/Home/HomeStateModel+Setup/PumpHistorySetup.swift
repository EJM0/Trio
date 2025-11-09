import CoreData
import Foundation

extension Home.StateModel {
    func setupInsulinArray() {
        Task {
            do {
                let ids = try await self.fetchInsulin()
                let insulinObjects: [PumpEventStored] = try await CoreDataStack.shared
                    .getNSManagedObject(with: ids, context: viewContext)
                await updateInsulinArray(with: insulinObjects)
            } catch {
                debug(
                    .default,
                    "\(DebuggingIdentifiers.failed) Error setting up insulin array: \(error)"
                )
            }
        }
    }

    private func fetchInsulin() async throws -> [NSManagedObjectID] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: pumpHistoryFetchContext,
            predicate: NSPredicate.pumpHistoryLast24h,
            key: "timestamp",
            ascending: true,
            batchSize: 30
        )

        return try await pumpHistoryFetchContext.perform {
            guard let pumpEvents = results as? [PumpEventStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return pumpEvents.map(\.objectID)
        }
    }

    @MainActor private func updateInsulinArray(with insulinObjects: [PumpEventStored]) {
        insulinFromPersistence = insulinObjects

        manualTempBasal = apsManager.isManualTempBasal
        tempBasals = insulinFromPersistence.filter({ $0.tempBasal != nil })

        /// suspensions is a list of pump suspend and resume events
        suspensions = insulinFromPersistence.filter {
            $0.type == EventType.pumpSuspend.rawValue || $0.type == EventType.pumpResume.rawValue
        }

        let lastSuspendResume = suspensions.last
        let lastSuspendResumeWasSuspend = lastSuspendResume?.type == EventType.pumpSuspend.rawValue

        print(
            "@@@ tempBasals.last time=\(String(describing: tempBasals.last?.timestamp)), lastSuspendResume time=\(String(describing: lastSuspendResume?.timestamp)), lastSuspendResumeWasSuspend=\(lastSuspendResumeWasSuspend)"
        )

        /// This test fails to properly set pumpSuspended to true when a pump is suspended (at least for pods).
        /// Will only set pumpSuspended to true if there was a TB operation done after the pump suspend/resume event.
        pumpSuspended = tempBasals.last?.timestamp ?? Date() > lastSuspendResume?
            .timestamp ?? .distantPast && lastSuspendResumeWasSuspend
        print(
            "@@@ original calculation would have set pumpSuspended to \(pumpSuspended)"
        )

        /// Maybe this tempBasalPostSuspendResume test from Open-APS was to deal with old PM's that might allow a temp basal on
        /// a suspended pump &/or perhaps something related to traditional insulin pumps that can be suspended/resumed on the pump?
        let tempBasalPostSuspendResume = tempBasals
            .last { $0.timestamp ?? .distantPast > (lastSuspendResume?.timestamp ?? .distantPast) }
        pumpSuspended = tempBasalPostSuspendResume == nil && lastSuspendResumeWasSuspend
        print(
            "@@@ new calculation sets pumpSuspended to \(pumpSuspended)"
        )
    }

    // Setup Last Bolus to display the bolus progress bar
    // The predicate filters out all external boluses to prevent the progress bar from displaying the amount of an external bolus when an external bolus is added after a pump bolus
    func setupLastBolus() {
        Task {
            do {
                guard let id = try await self.fetchLastBolus() else { return }
                await updateLastBolus(with: id)
            } catch {
                debug(
                    .default,
                    "\(DebuggingIdentifiers.failed) Error setting up last bolus: \(error)"
                )
            }
        }
    }

    func fetchLastBolus() async throws -> NSManagedObjectID? {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: pumpHistoryFetchContext,
            predicate: NSPredicate.lastPumpBolus,
            key: "timestamp",
            ascending: false,
            fetchLimit: 1
        )

        return try await pumpHistoryFetchContext.perform {
            guard let fetchedResults = results as? [PumpEventStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return fetchedResults.map(\.objectID).first
        }
    }

    @MainActor private func updateLastBolus(with ID: NSManagedObjectID) {
        do {
            lastPumpBolus = try viewContext.existingObject(with: ID) as? PumpEventStored
        } catch {
            debugPrint(
                "Home State: \(#function) \(DebuggingIdentifiers.failed) error while updating the insulin array: \(error)"
            )
        }
    }
}
