import CoreData
import Foundation

extension Home.StateModel {
    @MainActor func setupGlucoseController() {
        glucoseControllerDelegate.onContentChange = { [weak self] in
            Task { @MainActor in
                self?.updateGlucoseFromController()
            }
        }

        do {
            try glucoseController.performFetch()
            updateGlucoseFromController()
        } catch {
            debug(.default, "\(DebuggingIdentifiers.failed) Failed to perform glucose fetch: \(error)")
        }
    }

    @MainActor func updateGlucoseFromController() {
        guard let objects = glucoseController.fetchedObjects else { return }
        glucoseFromPersistence = objects
        latestTwoGlucoseValues = Array(objects.suffix(2))
        updateGlucoseChartYAxis(glucoseValues: objects)
        updateGlucoseEpisodes()
    }

    /// Rebuilds the sustained-excursion markers from the fetched window.
    ///
    /// The episodes are a pure function of the readings and the current thresholds, so they
    /// are derived here rather than persisted: a single pass over the 72 h window costs
    /// nothing next to the fetch that precedes it, and it makes the markers structurally
    /// incapable of disagreeing with the curve they annotate — including after a threshold
    /// change or a backfill, where stored episodes would have to be found and rewritten.
    /// Eviction comes from the same place the readings' does: the controller's 72 h predicate.
    @MainActor func updateGlucoseEpisodes() {
        let readings = glucoseFromPersistence.compactMap { entry -> GlucoseReading? in
            guard let date = entry.date else { return nil }
            return GlucoseReading(value: Int(entry.glucose), date: date)
        }
        glucoseEpisodes = GlucoseEpisode.detect(
            in: readings,
            lowThreshold: lowGlucose,
            highThreshold: highGlucose
        )
    }

    /// Called from `MainChartView` on `.onChange(of: units)` to recompute the glucose-derived chart state.
    func setupGlucoseArray() {
        Task { @MainActor in
            updateGlucoseFromController()
        }
    }
}

extension Home.StateModel {
    func addManualGlucose(_ amount: Decimal) {
        let glucose = units == .mmolL ? amount.asMgdL : amount
        glucoseStorage.addManualGlucose(glucose: Int(glucose))
    }

    /// Today's glucose range distribution for the stats banner.
    var todayGlucoseDistribution: GlucoseDailyDistributionStats {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let readings = glucoseFromPersistence
            .filter { ($0.date ?? .distantPast) >= startOfDay }
            .map { GlucoseReading(value: Int($0.glucose), date: $0.date ?? startOfDay) }
        // first render happens before service injection
        let timeInRangeType = settingsManager?.settings.timeInRangeType ?? .timeInTightRange
        return GlucoseDailyDistributionStats.compute(
            date: startOfDay,
            readings: readings,
            highLimit: highGlucose,
            timeInRangeType: timeInRangeType
        )
    }
}
