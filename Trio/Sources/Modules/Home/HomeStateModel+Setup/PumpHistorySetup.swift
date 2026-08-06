import CoreData
import Foundation

extension Home.StateModel {
    // MARK: - Insulin / Pump History

    @MainActor func setupInsulinController() {
        insulinControllerDelegate.onContentChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateInsulinFromController()
                self.displayPumpStatusHighlightMessage()
                self.displayPumpStatusBadge()
            }
        }

        do {
            try insulinController.performFetch()
            updateInsulinFromController()
        } catch {
            debug(.default, "\(DebuggingIdentifiers.failed) Failed to perform insulin fetch: \(error)")
        }
    }

    @MainActor func updateInsulinFromController() {
        guard let objects = insulinController.fetchedObjects else { return }
        insulinFromPersistence = objects

        manualTempBasal = apsManager.isManualTempBasal
        tempBasals = objects.filter { $0.tempBasal != nil }
        suspendAndResumeEvents = objects.filter {
            $0.type == EventType.pumpSuspend.rawValue || $0.type == EventType.pumpResume.rawValue
        }
        updateSMBBolusDisplayCutoff()
    }

    /// Recomputes the bolus-label cutoff for `.aboveAverageSMBFactor`. Called when a new pump
    /// event arrives (so a new SMB shifts the average) and when the setting changes — never
    /// from the chart, which only compares each bolus against the cached result.
    @MainActor func updateSMBBolusDisplayCutoff() {
        guard bolusDisplayThreshold == .aboveAverageSMBFactor else {
            smbBolusDisplayCutoff = nil
            return
        }

        let smbAmounts = insulinFromPersistence.compactMap { insulin -> Decimal? in
            guard insulin.bolus?.isSMB == true, let amount = insulin.bolus?.amount as Decimal? else {
                return nil
            }
            return amount
        }

        guard !smbAmounts.isEmpty else {
            smbBolusDisplayCutoff = nil
            return
        }

        let average = smbAmounts.reduce(Decimal.zero, +) / Decimal(smbAmounts.count)
        smbBolusDisplayCutoff = average * bolusDisplayThresholdMultiplier
    }

    // MARK: - Last Bolus

    //
    // Drives the bolus progress bar. The predicate filters out external boluses so the progress bar
    // does not display the amount of an external bolus added after a pump bolus.

    @MainActor func setupLastBolusController() {
        lastBolusControllerDelegate.onContentChange = { [weak self] in
            Task { @MainActor in
                self?.updateLastBolusFromController()
            }
        }

        do {
            try lastBolusController.performFetch()
            updateLastBolusFromController()
        } catch {
            debug(.default, "\(DebuggingIdentifiers.failed) Failed to perform last bolus fetch: \(error)")
        }
    }

    @MainActor private func updateLastBolusFromController() {
        lastPumpBolus = lastBolusController.fetchedObjects?.first
    }
}
