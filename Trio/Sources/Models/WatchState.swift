import Foundation
import SwiftUI

struct WatchState: Hashable, Equatable, Sendable, Encodable, Decodable {
    var date: Date
    var currentGlucose: String?
    var currentGlucoseColorString: String?
    var trend: String?
    var delta: String?
    var glucoseValues: [WatchGlucoseObject] = []
    var minYAxisValue: Decimal = 39.0
    var maxYAxisValue: Decimal = 200.0
    var units: GlucoseUnits = .mgdL
    var iob: String?
    var cob: String?
    var lastLoopTime: String?
    var overridePresets: [OverridePresetWatch] = []
    var tempTargetPresets: [TempTargetPresetWatch] = []

    // Safety limits
    var maxBolus: Decimal = 10.0
    var maxCarbs: Decimal = 250.0
    var maxFat: Decimal = 250.0
    var maxProtein: Decimal = 250.0

    // Bolus calculator options enabled in settings (reduced bolus: fatty meals, super bolus: sweet meals)
    var isReducedBolusAvailable: Bool = false
    var isSuperBolusAvailable: Bool = false

    // Pump specific dosing increment
    var bolusIncrement: Decimal = 0.05
    var confirmBolusFaster: Bool = false

    // Forecast options
    var showForecast: Bool = false
    var isForecastCone: Bool = false
    var forecastStartDate: Date? = nil
    var forecastConeMin: [Double] = []
    var forecastConeMax: [Double] = []
    var forecastLines: [String: [Double]] = [:] // "iob" / "cob" / "uam" / "zt" -> values

    var snoozeUntilDate: Date = .distantPast

    static func == (lhs: WatchState, rhs: WatchState) -> Bool {
        // Split into groups: a single `&&` chain over this many comparisons
        // blows past the type checker's expression budget.
        let glucoseValuesAreEqual: Bool = lhs.glucoseValues == rhs.glucoseValues

        let glucoseIsEqual = lhs.date == rhs.date &&
            lhs.currentGlucose == rhs.currentGlucose &&
            lhs.trend == rhs.trend &&
            lhs.delta == rhs.delta &&
            glucoseValuesAreEqual &&
            lhs.minYAxisValue == rhs.minYAxisValue &&
            lhs.maxYAxisValue == rhs.maxYAxisValue &&
            lhs.units == rhs.units

        let treatmentsAreEqual = lhs.iob == rhs.iob &&
            lhs.cob == rhs.cob &&
            lhs.lastLoopTime == rhs.lastLoopTime &&
            lhs.overridePresets == rhs.overridePresets &&
            lhs.tempTargetPresets == rhs.tempTargetPresets

        let limitsAreEqual = lhs.maxBolus == rhs.maxBolus &&
            lhs.maxCarbs == rhs.maxCarbs &&
            lhs.maxFat == rhs.maxFat &&
            lhs.maxProtein == rhs.maxProtein &&
            lhs.bolusIncrement == rhs.bolusIncrement &&
            lhs.confirmBolusFaster == rhs.confirmBolusFaster

        let forecastIsEqual = lhs.showForecast == rhs.showForecast &&
            lhs.isForecastCone == rhs.isForecastCone &&
            lhs.forecastStartDate == rhs.forecastStartDate &&
            lhs.forecastConeMin == rhs.forecastConeMin &&
            lhs.forecastConeMax == rhs.forecastConeMax &&
            lhs.forecastLines == rhs.forecastLines &&
            lhs.snoozeUntilDate == rhs.snoozeUntilDate

        return glucoseIsEqual && treatmentsAreEqual && limitsAreEqual && forecastIsEqual
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(date)
        hasher.combine(currentGlucose)
        hasher.combine(trend)
        hasher.combine(delta)
        hasher.combine(glucoseValues)
        hasher.combine(minYAxisValue)
        hasher.combine(maxYAxisValue)
        hasher.combine(units)
        hasher.combine(iob)
        hasher.combine(cob)
        hasher.combine(lastLoopTime)
        hasher.combine(overridePresets)
        hasher.combine(tempTargetPresets)
        hasher.combine(maxBolus)
        hasher.combine(maxCarbs)
        hasher.combine(maxFat)
        hasher.combine(maxProtein)
        hasher.combine(bolusIncrement)
        hasher.combine(confirmBolusFaster)
        hasher.combine(showForecast)
        hasher.combine(isForecastCone)
        hasher.combine(forecastStartDate)
        hasher.combine(forecastConeMin)
        hasher.combine(forecastConeMax)
        hasher.combine(forecastLines)
        hasher.combine(snoozeUntilDate)
    }
}
