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

    // Pump specific dosing increment
    var bolusIncrement: Decimal = 0.05
    var confirmBolusFaster: Bool = false

    // Peripherals (pump + CGM device info)
    var peripheralsUpdatedAt: Date? = nil
    var pumpName: String? = nil
    /// Raw reservoir units. The `0xDEAD_BEEF` "50+ U" sentinel is preserved
    /// end-to-end and interpreted by the watch view, as `PumpView` does.
    var pumpReservoir: Decimal? = nil
    /// Only populated for pumps that actually report a battery — patch pumps
    /// (Omnipod, Medtrum) return `nil` and get a pod-life countdown instead.
    var pumpBatteryPercent: Int? = nil
    var pumpExpiresAt: Date? = nil
    var pumpActivatedAt: Date? = nil
    var pumpStatusMessage: String? = nil
    var cgmName: String? = nil
    var cgmSensorExpiresAt: Date? = nil
    var cgmProgressPercent: Double? = nil
    /// `DeviceLifecycleProgressState` raw value; drives the sensor ring color.
    var cgmProgressState: String? = nil
    var cgmStatusMessage: String? = nil

    // Forecast options
    var showForecast: Bool = false
    var isForecastCone: Bool = false
    var forecastStartDate: Date? = nil
    var forecastConeMin: [Double] = []
    var forecastConeMax: [Double] = []
    var forecastLines: [String: [Double]] = [:] // "iob" / "cob" / "uam" / "zt" -> values

    static func == (lhs: WatchState, rhs: WatchState) -> Bool {
        // Split into groups: a single `&&` chain over this many comparisons
        // blows past the type checker's expression budget.
        // `elementsEqual` covers the count check. Closure parameters are typed
        // explicitly: leaving them to inference is what makes this comparison
        // expensive enough to stall the type checker.
        let glucoseValuesAreEqual: Bool = lhs.glucoseValues
            .elementsEqual(rhs.glucoseValues) { (a: WatchGlucoseObject, b: WatchGlucoseObject) -> Bool in
                a.date == b.date && a.glucose == b.glucose && a.color == b.color
            }

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

        // Kept as its own group rather than folded into `limitsAreEqual`: the
        // split exists to keep each boolean chain short enough for the type
        // checker, and the forecast fields are what pushed it over before.
        let forecastIsEqual = lhs.showForecast == rhs.showForecast &&
            lhs.isForecastCone == rhs.isForecastCone &&
            lhs.forecastStartDate == rhs.forecastStartDate &&
            lhs.forecastConeMin == rhs.forecastConeMin &&
            lhs.forecastConeMax == rhs.forecastConeMax &&
            lhs.forecastLines == rhs.forecastLines

        let pumpIsEqual = lhs.pumpName == rhs.pumpName &&
            lhs.pumpReservoir == rhs.pumpReservoir &&
            lhs.pumpBatteryPercent == rhs.pumpBatteryPercent &&
            lhs.pumpExpiresAt == rhs.pumpExpiresAt &&
            lhs.pumpActivatedAt == rhs.pumpActivatedAt &&
            lhs.pumpStatusMessage == rhs.pumpStatusMessage

        let cgmIsEqual = lhs.cgmName == rhs.cgmName &&
            lhs.cgmSensorExpiresAt == rhs.cgmSensorExpiresAt &&
            lhs.cgmProgressPercent == rhs.cgmProgressPercent &&
            lhs.cgmProgressState == rhs.cgmProgressState &&
            lhs.cgmStatusMessage == rhs.cgmStatusMessage

        return glucoseIsEqual && treatmentsAreEqual && limitsAreEqual &&
            forecastIsEqual && pumpIsEqual && cgmIsEqual
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(date)
        hasher.combine(currentGlucose)
        hasher.combine(trend)
        hasher.combine(delta)
        for value in glucoseValues {
            hasher.combine(value.date)
            hasher.combine(value.glucose)
            hasher.combine(value.color)
        }
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
        // `peripheralsUpdatedAt` is deliberately excluded from both `==` and
        // `hash(into:)`: it is a send stamp, not content, and including it
        // would make every snapshot compare unequal.
        hasher.combine(pumpName)
        hasher.combine(pumpReservoir)
        hasher.combine(pumpBatteryPercent)
        hasher.combine(pumpExpiresAt)
        hasher.combine(pumpActivatedAt)
        hasher.combine(pumpStatusMessage)
        hasher.combine(cgmName)
        hasher.combine(cgmSensorExpiresAt)
        hasher.combine(cgmProgressPercent)
        hasher.combine(cgmProgressState)
        hasher.combine(cgmStatusMessage)
    }
}
