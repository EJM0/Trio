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
        // New readings are the one input the memo below cannot see for itself — an edited
        // value changes neither the count nor either end — so drop it and let the peaks be
        // derived again.
        lastPeakInputs = nil
        updateGlucosePeaks()
        rebuildGlucoseDots()
    }

    /// Resolves the readings into what the chart actually draws: display-unit value, dynamic
    /// colour, smoothed value.
    ///
    /// Every one of these was derived per reading *per canvas layout* while the glucose series
    /// was a `PointMark` each — a full pass over the window on every zoom commit, several times
    /// per pinch, plus a Core Data property access per point. Doing it here instead means it
    /// happens once per data change; the draw loop then walks plain structs.
    ///
    /// Call it wherever an input moves: new readings (above), the display unit, or any of the
    /// four values the dynamic colour is derived from.
    @MainActor func rebuildGlucoseDots() {
        let isMgdL = units == .mgdL
        // TODO: workaround for now: set low value to 55, to have dynamic color shades between 55 and user-set low (approx. 70); same for high glucose
        let hardCodedLow = Decimal(55)
        let hardCodedHigh = Decimal(220)
        let isDynamicColorScheme = glucoseColorScheme == .dynamicColor
        let highColorValue = isDynamicColorScheme ? hardCodedHigh : highGlucose
        let lowColorValue = isDynamicColorScheme ? hardCodedLow : lowGlucose

        glucoseDots = glucoseFromPersistence.compactMap { entry in
            guard let date = entry.date else { return nil }
            let mgdl = Decimal(entry.glucose)
            let smoothed = entry.smoothedGlucose.flatMap { value -> Decimal? in
                let decimal = value.decimalValue
                guard decimal != 0 else { return nil }
                return isMgdL ? decimal : decimal.asMmolL
            }
            return GlucoseDot(
                date: date,
                value: isMgdL ? mgdl : mgdl.asMmolL,
                smoothed: smoothed,
                isManual: entry.isManual,
                color: getDynamicGlucoseColor(
                    glucoseValue: mgdl,
                    highGlucoseColorValue: highColorValue,
                    lowGlucoseColorValue: lowColorValue,
                    targetGlucose: currentGlucoseTarget,
                    glucoseColorScheme: glucoseColorScheme
                )
            )
        }
    }

    /// Recomputes the peak set, but only when an input it actually depends on has moved.
    ///
    /// The chart calls this whenever the zoom commits, and a single pinch commits several
    /// times. Each run is a full pass over the 72 h history — a `filter`, a `sorted`, and two
    /// monotonic deques — and, worse, assigning `glucosePeaks` invalidates the canvas a
    /// second time on top of the re-layout the zoom itself caused. Writing the same peaks
    /// again still counts as a mutation to Observation, so the guard has to be here rather
    /// than in the caller.
    func updateGlucosePeaks() {
        guard showGlucosePeaks else {
            if !glucosePeaks.isEmpty { glucosePeaks = [] }
            lastPeakInputs = nil
            return
        }

        let windowHours = MainChartHelper.peakWindowHours(visibleHours: chartVisibleHours)
        // The readings themselves are identified by count plus both ends: a new reading moves
        // the newest, ageing one out of the 72 h window moves the oldest, and an edited value
        // in place moves neither — which is why `updateGlucoseFromController` clears the memo
        // outright rather than relying on this alone.
        let inputs = PeakInputs(
            windowHours: windowHours,
            count: glucoseFromPersistence.count,
            oldest: glucoseFromPersistence.first?.date,
            newest: glucoseFromPersistence.last?.date
        )
        guard inputs != lastPeakInputs else { return }
        lastPeakInputs = inputs

        glucosePeaks = PeakPicker.pick(data: glucoseFromPersistence, windowHours: windowHours)
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
