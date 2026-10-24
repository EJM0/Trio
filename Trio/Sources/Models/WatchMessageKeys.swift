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
    /// The phone's absolute last successful loop time, for fallback safety checks.
    static let phoneLastLoopDate = "phoneLastLoopDate"
    /// The newest phone reading confirmed by a live fallback health response.
    static let phoneNewestReadingDate = "phoneNewestReadingDate"
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

    // Bolus calculator options, mirroring the phone's Treatments view
    /// Whether the options are enabled in the phone's settings ("fatty meals", "sweet meals").
    static let isReducedBolusAvailable = "isReducedBolusAvailable"
    static let isSuperBolusAvailable = "isSuperBolusAvailable"
    /// Sent with `requestBolusRecommendation`; at most one of the two is set.
    static let useReducedBolus = "useReducedBolus"
    static let useSuperBolus = "useSuperBolus"

    // Notification Actions
    static let snoozeDuration = "snoozeDuration"
    static let snoozeUntilDate = "snoozeUntilDate"

    // Peripherals (pump + CGM device info)
    /// Sub-dictionary wrapping every peripheral field, mirroring `forecastData`.
    /// Rides along with every watch state push, and is also sent on its own when
    /// a peripheral change has to reach a watch that is out of range.
    static let peripheralData = "peripheralData"
    static let peripheralsUpdatedAt = "peripheralsUpdatedAt"
    static let pumpName = "pumpName"
    static let pumpReservoir = "pumpReservoir"
    /// The phone's application context while the watch has the pump: only wakes the watch app.
    static let untetheredWake = "untetheredWake"
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
    static let showGlucoseBubbleWatch = "showGlucoseBubbleWatch"
    static let allowUntetheredStartWithoutPhoneWatch = "allowUntetheredStartWithoutPhoneWatch"
    static let untetheredModeWatch = "untetheredModeWatch"
    /// Whether safety alarms on the watch should use Critical Alerts.
    static let useCriticalAlertsWatch = "useCriticalAlertsWatch"
    /// Latest CGM export for the watch's own sensor link; can be absent while the phone is starting.
    static let watchSensorConfiguration = "watchSensorConfiguration"
    /// Explicit setting; independent of whether the phone's CGM manager is loaded yet.
    static let watchReadsSensor = "watchReadsSensor"
    /// mg/dL bounds, target and color scheme the watch colors its own readings and the complication by.
    static let glucoseRangeLow = "glucoseRangeLow"
    static let glucoseRangeHigh = "glucoseRangeHigh"
    static let glucoseRangeTarget = "glucoseRangeTarget"
    static let glucoseColorScheme = "glucoseColorScheme"
    /// The last 24 hours' carb entries, boluses and SMBs, as seconds since 1970: the markers on the big chart.
    static let chartCarbs = "chartCarbs"
    static let chartBoluses = "chartBoluses"
    static let chartSMBs = "chartSMBs"
    /// IOB (U) and COB (g) at each loop of the last 24 hours, with the loops' times as seconds since 1970: the
    /// values at the big chart's scrub line.
    static let chartIobCobDates = "chartIobCobDates"
    static let chartIob = "chartIob"
    static let chartCob = "chartCob"
    /// mg/dL of the phone's glucose alarms that are on, the most cautious of each; 0: none.
    static let glucoseAlarmUrgentLow = "glucoseAlarmUrgentLow"
    static let glucoseAlarmLow = "glucoseAlarmLow"
    static let glucoseAlarmHigh = "glucoseAlarmHigh"
    static let fallbackLoopWatch = "fallbackLoopWatch"
    static let untetheredWorkoutWatch = "untetheredWorkoutWatch"
    static let watchGlanceLayout = "watchGlanceLayout"
    static let watchGlanceEnabled = "watchGlanceEnabled"
    static let isForecastCone = "isForecastCone"
    static let forecastData = "forecastData"
    static let forecastStartDate = "forecastStartDate"
    static let forecastConeMin = "forecastConeMin"
    static let forecastConeMax = "forecastConeMax"
    static let forecastLines = "forecastLines"

    // Glucose history sync
    /// Only set on deltas: the newest reading the delta builds on.
    static let glucoseSyncBase = "glucoseSyncBase"
    static let glucoseWindowStart = "glucoseWindowStart"
    static let glucoseCount = "glucoseCount"
    static let glucoseChecksum = "glucoseChecksum"
    /// Units and color settings the readings were converted with.
    static let glucoseSignature = "glucoseSignature"
    static let supportsGlucoseDelta = "supportsGlucoseDelta"
    static let glucoseSince = "glucoseSince"
    /// Only on repair requests: the watch's checksum per bucket, starting at `glucoseBucketStart`.
    static let glucoseBucketStart = "glucoseBucketStart"
    static let glucoseBucketChecksums = "glucoseBucketChecksums"
    /// Only on repairs: the buckets whose readings replace the watch's.
    static let glucoseBuckets = "glucoseBuckets"
}

enum WatchGlucoseSync {
    static let readingTimestampKey = "date"
    static let readingGlucoseKey = "glucose"
    static let readingColorKey = "color"

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
        payload[WatchMessageKeys.glucoseCount] = checksum.count
        payload[WatchMessageKeys.glucoseChecksum] = checksum.transportValue
        payload[WatchMessageKeys.glucoseSignature] = signature
        if let windowStart = windowStart {
            payload[WatchMessageKeys.glucoseWindowStart] = windowStart
        }
    }

    /// Count and checksum keep describing the whole window.
    static func delta(of payload: [String: Any], since base: TimeInterval) -> [String: Any] {
        let readings = payload[WatchMessageKeys.glucoseValues] as? [[String: Any]] ?? []

        var delta = payload
        delta[WatchMessageKeys.glucoseValues] = readings.filter { reading in
            guard let timestamp = reading[readingTimestampKey] as? TimeInterval else { return false }
            return timestamp > base
        }
        delta[WatchMessageKeys.glucoseSyncBase] = base
        return delta
    }

    /// `nil` when no reading is older than `cutoff`.
    static func recentTail(of payload: [String: Any], after cutoff: TimeInterval) -> [String: Any]? {
        let readings = payload[WatchMessageKeys.glucoseValues] as? [[String: Any]] ?? []
        let base = readings
            .compactMap { $0[readingTimestampKey] as? TimeInterval }
            .filter { $0 <= cutoff }
            .max()
        guard let base = base else { return nil }
        return delta(of: payload, since: base)
    }

    static func newestTimestamp(in payload: [String: Any]) -> TimeInterval? {
        let readings = payload[WatchMessageKeys.glucoseValues] as? [[String: Any]] ?? []
        return readings.compactMap { $0[readingTimestampKey] as? TimeInterval }.max()
    }

    // MARK: - Bucket repair

    /// Measured on binary plists for 1- and 5-minute CGMs: 30 minutes keeps a request plus the repaired
    /// readings within 15 % of the smallest possible for both.
    static let bucketLength: TimeInterval = 30 * 60

    static func bucket(of timestamp: TimeInterval) -> Int {
        Int((timestamp / bucketLength).rounded(.down))
    }

    /// 32 bits are enough per bucket: a collision is still caught by the window checksum.
    static func bucketChecksums(of readings: [(timestamp: TimeInterval, glucose: Double)]) -> [Int: Int] {
        var checksums: [Int: WatchGlucoseChecksum] = [:]
        for reading in readings {
            checksums[bucket(of: reading.timestamp), default: WatchGlucoseChecksum()]
                .add(timestamp: reading.timestamp, glucose: reading.glucose)
        }
        return checksums.mapValues { Int(UInt32(truncatingIfNeeded: $0.transportValue)) }
    }

    /// Contiguous from the oldest bucket, 0 for an empty one.
    static func bucketChecksumList(of readings: [(timestamp: TimeInterval, glucose: Double)])
        -> (start: Int, checksums: [Int])?
    {
        let checksums = bucketChecksums(of: readings)
        guard let start = checksums.keys.min(), let end = checksums.keys.max() else { return nil }
        return (start, (start ... end).map { checksums[$0] ?? 0 })
    }

    /// Only the readings of the buckets that differ from the watch's, or the full payload when most of them do.
    static func repair(of payload: [String: Any], watchBucketStart: Int, watchChecksums: [Int]) -> [String: Any] {
        guard let windowStart = payload[WatchMessageKeys.glucoseWindowStart] as? TimeInterval else { return payload }
        let readings = payload[WatchMessageKeys.glucoseValues] as? [[String: Any]] ?? []
        let phone = bucketChecksums(of: readings.compactMap { reading in
            guard let timestamp = reading[readingTimestampKey] as? TimeInterval,
                  let glucose = reading[readingGlucoseKey] as? Double
            else { return nil }
            return (timestamp: timestamp, glucose: glucose)
        })
        let watch = Dictionary(
            uniqueKeysWithValues: watchChecksums.enumerated().map { (watchBucketStart + $0.offset, $0.element) }
        )

        // Older buckets have left the window: the watch trims them itself.
        let firstBucket = bucket(of: windowStart)
        let differing = Set(phone.keys).union(watch.keys)
            .filter { $0 >= firstBucket && phone[$0] ?? 0 != watch[$0] ?? 0 }

        let windowBuckets = (phone.keys.max() ?? firstBucket) - firstBucket + 1
        guard differing.count * 2 <= windowBuckets else { return payload }

        var patch = payload
        patch[WatchMessageKeys.glucoseValues] = readings.filter { reading in
            guard let timestamp = reading[readingTimestampKey] as? TimeInterval else { return false }
            return differing.contains(bucket(of: timestamp))
        }
        patch[WatchMessageKeys.glucoseBuckets] = differing.sorted()
        return patch
    }
}

/// Order-independent checksum over the raw values sent, so phone and watch match bit for bit.
struct WatchGlucoseChecksum {
    private(set) var count = 0
    private var sum: UInt64 = 0

    mutating func add(timestamp: TimeInterval, glucose: Double) {
        add(timestamp.bitPattern, glucose.bitPattern)
    }

    mutating func add(_ first: UInt64, _ second: UInt64) {
        count += 1
        sum &+= Self.mix(first ^ Self.mix(second))
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

/// One element of Extended Untethered Mode's minimal watch screen, arranged on the phone like the Live Activity's
/// widgets (`WatchGlanceLayout`).
enum WatchGlanceItem: String, CaseIterable, Codable, Hashable {
    // the middle
    case glucoseLarge
    case glucoseChart
    case chart
    // the rows
    case glucose
    case loop
    case iob
    case cob
    case iobCob
    case basalIobCob
    case tempBasal
    case eventualGlucose
    case heartRate
    case reservoir
    case lastReading
    case totalDailyDose
    case clock
    /// The slot taken by the wide element left of it.
    case continuation

    static let centerItems: [WatchGlanceItem] = [.glucoseLarge, .glucoseChart, .chart]
    static var rowItems: [WatchGlanceItem] { allCases.filter { !$0.isCenter && $0 != .continuation } }

    var isCenter: Bool { Self.centerItems.contains(self) }

    /// Slots it takes in its row.
    var width: Int {
        switch self {
        case .iobCob: return 2
        case .basalIobCob: return 3
        default: return 1
        }
    }

    /// What a combined element shows, side by side.
    var parts: [WatchGlanceItem] {
        switch self {
        case .iobCob: return [.iob, .cob]
        case .basalIobCob: return [.tempBasal, .iob, .cob]
        default: return [self]
        }
    }

    var label: String {
        switch self {
        case .glucoseLarge: return String(localized: "Glucose", comment: "Watch minimal screen: large glucose")
        case .glucoseChart: return String(
                localized: "Glucose and Chart",
                comment: "Watch minimal screen: glucose above the chart"
            )
        case .chart: return String(localized: "Chart", comment: "Watch minimal screen: glucose chart with forecast")
        case .glucose: return String(localized: "BG", comment: "Watch minimal screen: small glucose")
        case .loop: return String(localized: "Loop", comment: "Watch minimal screen: loop status")
        case .iob: return String(localized: "IOB", comment: "Watch minimal screen: insulin on board")
        case .cob: return String(localized: "COB", comment: "Watch minimal screen: carbs on board")
        case .iobCob: return String(localized: "IOB and COB", comment: "Watch minimal screen: IOB and COB together")
        case .basalIobCob: return String(localized: "Temp, IOB and COB", comment: "Watch minimal screen: temp basal, IOB and COB")
        case .tempBasal: return String(localized: "Temp", comment: "Watch minimal screen: running temp basal")
        case .eventualGlucose: return String(localized: "Eventual", comment: "Watch minimal screen: eventual glucose")
        case .heartRate: return String(localized: "BPM", comment: "Watch minimal screen: heart rate")
        case .reservoir: return String(localized: "Reservoir", comment: "Watch minimal screen: pump reservoir")
        case .lastReading: return String(localized: "Updated", comment: "Watch minimal screen: age of the newest reading")
        case .totalDailyDose: return String(localized: "TDD", comment: "Watch minimal screen: total daily dose")
        case .clock: return String(localized: "Time", comment: "Watch minimal screen: current time")
        case .continuation: return ""
        }
    }
}

/// Slot 0 is the middle, 1–2 the row above it, 3–5 the row below. A wide element takes the slots right of it in its row
/// as `continuation`; each element is placed at most once.
struct WatchGlanceLayout: Codable, Hashable {
    static let center = 0
    static let rows: [Range<Int>] = [1 ..< 3, 3 ..< 6]
    static let slotCount = 6
    static let standard = WatchGlanceLayout(slots: [.glucoseLarge, .loop, .lastReading, .tempBasal, .iob, .cob])

    private(set) var slots: [WatchGlanceItem?]

    /// Whatever arrives (another version, a hand-edited setting) is made valid: the wrong kind in a slot, a repeat, or a
    /// continuation without its element reads as empty.
    init(slots: [WatchGlanceItem?]) {
        self.slots = Array(repeating: nil, count: Self.slotCount)
        if let middle = slots.first ?? nil, middle.isCenter { self.slots[Self.center] = middle }
        for row in Self.rows {
            for slot in row where slot < slots.count {
                guard let item = slots[slot], !item.isCenter, item != .continuation else { continue }
                _ = place(item, at: slot, keepingOthers: true)
            }
        }
    }

    /// As sent to the watch: raw values, "" for an empty slot.
    init(strings: [String]) {
        self.init(slots: strings.map { WatchGlanceItem(rawValue: $0) })
    }

    var strings: [String] { slots.map { $0?.rawValue ?? "" } }

    init(from decoder: Decoder) throws {
        self.init(slots: try decoder.singleValueContainer().decode([WatchGlanceItem?].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(slots)
    }

    /// The elements of row `index`, each with the slot it starts in; an empty slot is nil.
    func row(_ index: Int) -> [(slot: Int, item: WatchGlanceItem?)] {
        Self.rows[index].compactMap { slot in slots[slot] == .continuation ? nil : (slot, slots[slot]) }
    }

    /// The element whose slots include `slot`.
    func owner(of slot: Int) -> (slot: Int, item: WatchGlanceItem)? {
        guard let row = Self.rows.first(where: { $0.contains(slot) }) else {
            return slots[slot].map { (slot, $0) }
        }
        var start = slot
        while start > row.lowerBound, slots[start] == .continuation { start -= 1 }
        guard let item = slots[start], item != .continuation else { return nil }
        return (start, item)
    }

    /// Puts `item` at `slot`, moving it if it was placed already; a wide element shifts left to fit its row and replaces
    /// what it covers. False when it cannot go there (a middle element outside the middle, or the other way round).
    @discardableResult mutating func place(_ item: WatchGlanceItem, at slot: Int) -> Bool {
        place(item, at: slot, keepingOthers: false)
    }

    private mutating func place(_ item: WatchGlanceItem, at slot: Int, keepingOthers: Bool) -> Bool {
        guard item != .continuation, slots.indices.contains(slot) else { return false }
        if item.isCenter {
            guard slot == Self.center else { return false }
            slots[slot] = item
            return true
        }
        guard let row = Self.rows.first(where: { $0.contains(slot) }), item.width <= row.count else { return false }
        let start = min(slot, row.upperBound - item.width)
        let covered = start ..< start + item.width
        if keepingOthers {
            // building from saved slots: an element that would cover another, or repeat one, is dropped
            guard !slots.contains(item), covered.allSatisfy({ slots[$0] == nil }) else { return false }
        } else {
            remove(item)
            for slot in covered { clear(slot) }
        }
        slots[start] = item
        for slot in covered.dropFirst() { slots[slot] = .continuation }
        return true
    }

    /// Where a tap adds `item`: the middle for a middle element, else the first slots of a row it fits without replacing.
    @discardableResult mutating func placeInFirstFreeSlot(_ item: WatchGlanceItem) -> Bool {
        if item.isCenter { return place(item, at: Self.center) }
        for row in Self.rows {
            for start in row where start + item.width <= row.upperBound {
                if (start ..< start + item.width).allSatisfy({ slots[$0] == nil }) { return place(item, at: start) }
            }
        }
        return false
    }

    /// Empties the element that covers `slot`, all its slots.
    mutating func clear(_ slot: Int) {
        guard let owner = owner(of: slot) else { return }
        for covered in owner.slot ..< owner.slot + owner.item.width { slots[covered] = nil }
    }

    mutating func remove(_ item: WatchGlanceItem) {
        if let slot = slots.firstIndex(of: item) { clear(slot) }
    }
}
