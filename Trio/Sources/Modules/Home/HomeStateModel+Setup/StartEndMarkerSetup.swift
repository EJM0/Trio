import Foundation

extension Home.StateModel {
    /// Leading edge of the chart-feeding fetch window (chart-only; dosing
    /// reads its own storage fetches).
    var chartHistoryStartDate: Date {
        Date(timeIntervalSinceNow: -MainChartHelper.Config.chartHistorySeconds)
    }

    /// Number of 5-minute steps the chart actually draws for the current display type.
    ///
    /// The two modes have different horizons: the cone is bounded by the *shortest* curve
    /// (`minForecast`/`maxForecast` are built at that length, so the band is defined
    /// everywhere it is drawn), while the lines draw every curve in full, so the *longest*
    /// one sets how far right the ink reaches.
    private var drawnForecastSteps: Int {
        switch forecastDisplayType {
        case .cone:
            return max(min(minForecast.count, maxForecast.count) - 1, 0)
        case .lines:
            return maxForecastIndex
        }
    }

    /// When the forecast on the chart runs out, or `nil` when there is nothing to draw.
    ///
    /// Anchored to the determination the curves are drawn from rather than to `now` — the
    /// same anchor `ForecastView` uses — so the reserved space shrinks as that determination
    /// ages instead of pretending a stale forecast still reaches a fixed distance ahead.
    var forecastEndDate: Date? {
        let steps = drawnForecastSteps
        guard steps > 0, let anchor = determinationsFromPersistence.first?.deliverAt else {
            return nil
        }
        return anchor.addingTimeInterval(
            TimeInterval(steps) * MainChartHelper.Config.forecastPointInterval
        )
    }

    /// Trailing edge of the chart's domain: the end of the forecast being drawn, bounded so a
    /// missing prediction still leaves room ahead and a very long one cannot squeeze history.
    ///
    /// Deliberately carries no padding of its own. The clearance for the pinned y-axis labels
    /// is `Config.labelGutterFraction` of the *visible window*, applied by the view at
    /// `trailingOverscan` — it has to scale with zoom to stay a constant number of pixels, so
    /// adding a second, fixed pad here would both double the gap and make it drift with zoom.
    /// With the domain ending exactly at the forecast, that last point lands flush against the
    /// labels at every zoom level.
    var forecastEndMarker: Date {
        let now = Date()
        let earliest = now.addingTimeInterval(MainChartHelper.Config.minForecastHorizon)
        let latest = now.addingTimeInterval(MainChartHelper.Config.maxForecastHorizon)
        guard let end = forecastEndDate else { return earliest }
        return min(max(end, earliest), latest)
    }

    // Update start and  end marker to fix scroll update problem with x axis
    func updateStartEndMarkers() {
        startMarker = Date(timeIntervalSinceNow: -MainChartHelper.Config.chartHistorySeconds)
        endMarker = forecastEndMarker
    }
}
