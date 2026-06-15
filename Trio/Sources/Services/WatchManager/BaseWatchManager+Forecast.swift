import CoreData
import Foundation

// MARK: - Forecast fetch

extension BaseWatchManager {
    /// Fetches the latest determination (within 30 min) with its forecast
    /// relationships pre-loaded, then compresses each forecast series into a
    /// polynomial and returns a ready-to-send `WatchForecastData`.
    ///
    /// Returns `nil` when no recent determination exists.
    func fetchForecastData(units: GlucoseUnits) async throws -> WatchForecastData? {
        // Reuse the same background context used elsewhere in WatchManager.
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OrefDetermination.self,
            onContext: backgroundContext,
            predicate: NSPredicate.predicateFor30MinAgoForDetermination,
            key: "deliverAt",
            ascending: false,
            fetchLimit: 1,
            relationshipKeyPathsForPrefetching: ["forecasts", "forecasts.forecastValues"]
        )

        return try await backgroundContext.perform { [weak self] () -> WatchForecastData? in
            guard let self else { return nil }

            guard let determinationResults = results as? [OrefDetermination],
                  let determination = determinationResults.first
            else { return nil }

            let startDate = determination.deliverAt ?? Date()

            // Collect per-type arrays, capped at 18 steps (= 1.5 h) — same cap as LiveActivity.
            var forecastLines = [(type: String, values: [Int])]()
            if let forecasts = determination.forecasts {
                for forecast in forecasts.sorted(by: { ($0.type ?? "") < ($1.type ?? "") }) {
                    let values = forecast.forecastValuesArray.prefix(24).map { forecastValue -> Int in
                        let mgdl = Int(forecastValue.value)
                        if units == .mmolL {
                            return Int(truncating: mgdl.asMmolL as NSNumber)
                        }
                        return mgdl
                    }
                    guard !values.isEmpty, let type = forecast.type else { continue }
                    forecastLines.append((type: type, values: Array(values)))
                }
            }

            guard !forecastLines.isEmpty else { return nil }

            // The Watch App locally determines whether to display the cone or the lines.
            // We just pass `showCone: false` as a placeholder.
            let showCone = false

            return WatchForecastData.build(
                forecastLines: forecastLines,
                startDate: startDate,
                showCone: showCone
            )
        }
    }
}

// MARK: - Wire forecast into setupWatchState

/*
 In setupWatchState(), after the existing `backgroundContext.perform { … }` block
 that builds and returns `watchState`, add the forecast fetch in parallel (or
 sequentially to keep threading simple).

 Replace the final `return await backgroundContext.perform { … }` pattern with the
 version below so that forecast data is appended before the state is returned.

 ─────────────────────────────────────────────────────────────────────────────
 BEFORE (inside the do { } block, end of setupWatchState):

     return await backgroundContext.perform {
         // … existing code building watchState …
         return watchState
     }

 AFTER:

     var watchState = await backgroundContext.perform {
         // … existing code building watchState … (unchanged)
         return watchState
     }

     // Append forecast data (non-fatal: missing forecast is acceptable).
     watchState.forecast = try? await fetchForecastData()

     return watchState
 ─────────────────────────────────────────────────────────────────────────────
 */

// MARK: - Serialise forecast into the wire dictionary

extension BaseWatchManager {
    /// Call this inside `watchStateToDictionary(from:)` to produce the
    /// serialised forecast entry.  Returns `nil` when there is no forecast.
    func encodeForecast(_ forecast: WatchForecastData, showCone: Bool) -> [String: Any]? {
        guard !forecast.isEmpty else { return nil }

        func encodePoly(_ poly: WatchForecastPolynomial) -> [String: Any] {
            [
                "type": poly.type,
                "coefficients": poly.coefficients,
                "startDate": poly.startDate.timeIntervalSince1970,
                "endMinutes": poly.endMinutes,
                "pointCount": poly.pointCount
            ]
        }

        var dict: [String: Any] = [
            "showCone": showCone,
            "forecastLines": forecast.forecastLines.map(encodePoly)
        ]

        if let coneMin = forecast.coneMin { dict["coneMin"] = encodePoly(coneMin) }
        if let coneMax = forecast.coneMax { dict["coneMax"] = encodePoly(coneMax) }

        return dict
    }
}

/*
 ─────────────────────────────────────────────────────────────────────────────
 ADD to watchStateToDictionary(from:) inside the returned dictionary literal:

     WatchMessageKeys.forecast: state.forecast.flatMap { encodeForecast($0) } as Any,

 ─────────────────────────────────────────────────────────────────────────────

 ADD to WatchMessageKeys (wherever the other keys are declared):

     static let forecast = "forecast"
 ─────────────────────────────────────────────────────────────────────────────
 */
