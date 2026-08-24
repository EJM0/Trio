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
        updateGlucosePeaks()
    }

    func updateGlucosePeaks() {
        if showGlucosePeaks {
            glucosePeaks = PeakPicker.pick(
                data: glucoseFromPersistence,
                windowHours: chartVisibleHours / 4
            )
        } else {
            glucosePeaks = []
        }
    }

    /// Folds the fetched window into the sustained-excursion markers.
    ///
    /// The scan itself lives in `episodeStore`, which persists the episodes it has already
    /// found and only looks at what has arrived since — see `GlucoseEpisodeStore` for why they
    /// are stored rather than re-derived (an excursion that predates the window's leading edge
    /// would otherwise lose its start, and its length, reading by reading) and for how a
    /// threshold change forces the whole window to be scanned again.
    @MainActor func updateGlucoseEpisodes() {
        let readings = glucoseFromPersistence.compactMap { entry -> GlucoseReading? in
            guard let date = entry.date else { return nil }
            return GlucoseReading(value: Int(entry.glucose), date: date)
        }
        let low = lowGlucose
        let high = highGlucose
        Task { @MainActor in
            glucoseEpisodes = await episodeStore.update(with: readings, lowThreshold: low, highThreshold: high)
        }
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
            // fixed consensus TIR bound (StatStateModel.highLimit), not the user's
            // chart threshold, so the banner always matches the Stats screen
            highLimit: 180,
            timeInRangeType: timeInRangeType
        )
    }
}
