enum WatchMessageKeys {
    // Request/Response Keys
    static let date = "date"
    static let units = "units"
    /// Carb entries of the last 24 hours, as times (seconds since 1970), for the watch chart's markers.
    static let chartCarbs = "chartCarbs"
    /// Boluses of the last 24 hours: `["date": seconds since 1970, "smb": Bool]`, for the watch chart's markers.
    static let chartBoluses = "chartBoluses"
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

    // Watch reads the G7 itself (step 1 of watch independence: display and alerts only)
    /// The G7 the phone reads directly ("DXCMxx"); empty when it reads none.
    static let g7DirectSensorName = "g7DirectSensorName"
    /// That sensor's 4-digit pairing code, so the watch can pair in its own slot.
    static let g7DirectPairingCode = "g7DirectPairingCode"
    /// Thresholds for the watch's own alerts in mg/dL; 0 = no such alarm.
    static let watchAlertUrgentLowMgDL = "watchAlertUrgentLowMgDL"
    static let watchAlertLowMgDL = "watchAlertLowMgDL"
    static let watchAlertHighMgDL = "watchAlertHighMgDL"
    /// The user's glucose units, sent with every update, also when the rest of the state is empty.
    static let watchDisplayUnits = "watchDisplayUnits"
    /// The phone's application context while the watch has the pump: only wakes the watch app.
    static let untetheredWake = "untetheredWake"
    /// Settings › Apple Watch › Allow Start Without iPhone, with every watch state.
    static let allowUntetheredStartWithoutPhoneWatch = "allowUntetheredStartWithoutPhoneWatch"
    /// Settings › Notifications › Critical Alerts, with every watch state: the watch's own safety alarms follow it.
    static let useCriticalAlertsWatch = "useCriticalAlertsWatch"

    // Forecast
    static let showForecastWatch = "showForecastWatch"
    static let untetheredModeWatch = "untetheredModeWatch"
    /// The phone app's version and build (`UntetheredVersion.current`), with every watch state.
    static let phoneAppVersion = "phoneAppVersion"
    static let isForecastCone = "isForecastCone"
    static let forecastData = "forecastData"
    static let forecastStartDate = "forecastStartDate"
    static let forecastConeMin = "forecastConeMin"
    static let forecastConeMax = "forecastConeMax"
    static let forecastLines = "forecastLines"
}
