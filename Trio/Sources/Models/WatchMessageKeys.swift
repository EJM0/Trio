import Foundation

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

    // Glucose history sync (see `WatchGlucoseSync`)
    /// `WatchGlucoseSync.modeFull` or `.modeDelta`. Payloads without it (older
    /// phone builds) carry the full history.
    static let glucoseSyncMode = "glucoseSyncMode"
    /// Delta only: timestamp of the newest reading the delta builds on.
    static let glucoseSyncBase = "glucoseSyncBase"
    /// Start of the phone's glucose window; older readings are dropped.
    static let glucoseWindowStart = "glucoseWindowStart"
    /// Reading count and `WatchGlucoseChecksum` of the phone's whole window, so
    /// the watch can verify its merged copy.
    static let glucoseCount = "glucoseCount"
    static let glucoseChecksum = "glucoseChecksum"
    /// Units and color settings the readings were converted and colored with.
    /// Readings from different settings must never be mixed.
    static let glucoseSignature = "glucoseSignature"
    /// Request only: the watch can merge deltas, and the newest reading it holds.
    static let supportsGlucoseDelta = "supportsGlucoseDelta"
    static let glucoseSince = "glucoseSince"
}

/// Glucose history sync between phone and watch.
///
/// The application context always carries the phone's full glucose window, so
/// a launching watch app has it right away. Messages and request replies to a
/// watch that supports it carry only the readings newer than a base timestamp
/// the watch is expected to hold (a delta). Every payload also states the
/// window's start, reading count and checksum: after merging, the watch checks
/// its copy against them and asks for the full history when it drifted, and it
/// asks for the missing readings when a delta does not connect to its newest one.
enum WatchGlucoseSync {
    static let modeFull = "full"
    static let modeDelta = "delta"

    /// Key of a reading's timestamp inside an encoded reading.
    static let readingTimestampKey = "date"
    static let readingGlucoseKey = "glucose"
    static let readingColorKey = "color"

    /// Adds the sync metadata for the full history `readings` (encoded exactly as
    /// sent) to a watch state payload.
    static func annotateFullHistory(
        _ payload: inout [String: Any],
        readings: [[String: Any]],
        windowStart: TimeInterval?,
        signature: String
    ) {
        var checksum = WatchGlucoseChecksum()
        for reading in readings {
            guard let timestamp = reading[readingTimestampKey] as? TimeInterval,
                  let glucose = reading[readingGlucoseKey] as? Double
            else { continue }
            checksum.add(timestamp: timestamp, glucose: glucose)
        }

        payload[WatchMessageKeys.glucoseValues] = readings
        payload[WatchMessageKeys.glucoseSyncMode] = modeFull
        payload[WatchMessageKeys.glucoseCount] = checksum.count
        payload[WatchMessageKeys.glucoseChecksum] = checksum.transportValue
        payload[WatchMessageKeys.glucoseSignature] = signature
        if let windowStart = windowStart {
            payload[WatchMessageKeys.glucoseWindowStart] = windowStart
        }
    }

    /// A copy of an annotated full-history payload that carries only the
    /// readings newer than `base`. Count and checksum keep describing the whole
    /// window, which is what the watch verifies its merged copy against.
    static func delta(of payload: [String: Any], since base: TimeInterval) -> [String: Any] {
        let readings = payload[WatchMessageKeys.glucoseValues] as? [[String: Any]] ?? []

        var delta = payload
        delta[WatchMessageKeys.glucoseValues] = readings.filter { reading in
            guard let timestamp = reading[readingTimestampKey] as? TimeInterval else { return false }
            return timestamp > base
        }
        delta[WatchMessageKeys.glucoseSyncMode] = modeDelta
        delta[WatchMessageKeys.glucoseSyncBase] = base
        return delta
    }

    /// Timestamp of the newest reading in an annotated payload, the base of the
    /// next delta.
    static func newestTimestamp(in payload: [String: Any]) -> TimeInterval? {
        let readings = payload[WatchMessageKeys.glucoseValues] as? [[String: Any]] ?? []
        return readings.compactMap { $0[readingTimestampKey] as? TimeInterval }.max()
    }
}

/// Order-independent checksum over glucose readings.
///
/// Built from the raw `TimeInterval` and `Double` values that travel in the
/// payload, so phone and watch arrive at the same result bit for bit, without
/// any rounding or `Date` conversion in between.
struct WatchGlucoseChecksum {
    private(set) var count = 0
    private var sum: UInt64 = 0

    mutating func add(timestamp: TimeInterval, glucose: Double) {
        count += 1
        sum &+= Self.mix(timestamp.bitPattern ^ Self.mix(glucose.bitPattern))
    }

    /// Property lists only hold signed integers.
    var transportValue: Int64 { Int64(bitPattern: sum) }

    /// SplitMix64 finalizer: spreads every input bit over the whole result.
    private static func mix(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
