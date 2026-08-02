enum WatchMessageKeys {
    // Request/Response Keys
    static let date = "date"
    static let units = "units"
    static let requestWatchUpdate = "requestWatchUpdate"
    static let watchState = "watchState"
    static let acknowledged = "acknowledged"
    static let ackCode = "ackCode"
    static let message = "message"

    // Treatment Keys
    static let bolus = "bolus"
    static let carbs = "carbs"
    static let cancelBolus = "cancelBolus"
    static let bolusCanceled = "bolusCanceled"
    static let bolusProgress = "bolusProgress"
    static let activeBolusAmount = "activeBolusAmount"
    static let deliveredAmount = "deliveredAmount"
    static let bolusProgressTimestamp = "bolusProgressTimestamp"

    // Recommendation Keys
    static let requestBolusRecommendation = "requestBolusRecommendation"
    static let recommendedBolus = "recommendedBolus"

    // Override Keys
    static let cancelOverride = "cancelOverride"
    static let activateOverride = "activateOverride"

    // Temp Target Keys
    static let cancelTempTarget = "cancelTempTarget"
    static let activateTempTarget = "activateTempTarget"

    // Watch State Data Keys
    static let currentGlucose = "currentGlucose"
    static let currentGlucoseColorString = "currentGlucoseColorString"
    static let trend = "trend"
    static let delta = "delta"
    static let iob = "iob"
    static let cob = "cob"
    static let lastLoopTime = "lastLoopTime"
    static let glucoseValues = "glucoseValues"
    static let minYAxisValue = "minYAxisValue"
    static let maxYAxisValue = "maxYAxisValue"
    static let overridePresets = "overridePresets"
    static let tempTargetPresets = "tempTargetPresets"

    // Limits and Settings Keys
    static let maxBolus = "maxBolus"
    static let maxCarbs = "maxCarbs"
    static let maxFat = "maxFat"
    static let maxProtein = "maxProtein"
    static let bolusIncrement = "bolusIncrement"
    static let confirmBolusFaster = "confirmBolusFaster"

    // Notification Actions
    static let snoozeDuration = "snoozeDuration"

    // Peripherals (pump + CGM device info)
    /// Sub-dictionary wrapping every peripheral field, mirroring `forecastData`.
    /// Rides along with every watch state push, and is also sent on its own when
    /// a peripheral change has to reach a watch that is out of range.
    static let peripheralData = "peripheralData"
    static let peripheralsUpdatedAt = "peripheralsUpdatedAt"
    static let pumpName = "pumpName"
    static let pumpReservoir = "pumpReservoir"
    static let pumpBatteryPercent = "pumpBatteryPercent"
    static let pumpExpiresAt = "pumpExpiresAt"
    static let pumpActivatedAt = "pumpActivatedAt"
    static let pumpStatusMessage = "pumpStatusMessage"
    static let cgmName = "cgmName"
    static let cgmSensorExpiresAt = "cgmSensorExpiresAt"
    static let cgmProgressPercent = "cgmProgressPercent"
    static let cgmProgressState = "cgmProgressState"
    static let cgmStatusMessage = "cgmStatusMessage"

    // Forecast
    static let showForecastWatch = "showForecastWatch"
    static let isForecastCone = "isForecastCone"
    static let forecastData = "forecastData"
    static let forecastStartDate = "forecastStartDate"
    static let forecastConeMin = "forecastConeMin"
    static let forecastConeMax = "forecastConeMax"
    static let forecastLines = "forecastLines"
}
