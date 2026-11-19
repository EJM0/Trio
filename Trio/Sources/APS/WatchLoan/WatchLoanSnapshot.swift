import Foundation

/// What the watch needs to loop with the phone's exact inputs. Travels with the grant.
struct WatchLoanSnapshot: Codable {
    static let currentSchemaVersion = 1
    /// The largest payload `WCSession.sendMessage` carries, for the whole message.
    static let maxMessageBytes = 65536
    /// A grant uses at most this much, leaving room for the dictionary encoding `sendMessage` adds.
    static let grantBudgetBytes = maxMessageBytes * 4 / 5
    static let maxClockOffset: TimeInterval = 60
    static let endingSoonWindow: TimeInterval = 6 * 60 * 60

    struct Versions: Codable, Equatable {
        var schema: Int
        var protocolVersion: Int
        var appBuild: String
        var pumpManager: String
        var pumpStateVersion: Int?
        var cgmManager: String
        var cgmStateVersion: Int?
    }

    /// An override or temp target running at the grant. `endsAt` nil means it has no end.
    struct Adjustment: Codable, Equatable {
        var name: String?
        var startedAt: Date
        var endsAt: Date?
    }

    struct BolusCalculatorSettings: Codable, Equatable {
        var units: GlucoseUnits
        var fraction: Decimal
        var fattyMealFactor: Decimal
        var sweetMealFactor: Decimal
        var maxCarbs: Decimal
        var supportedBolusVolumes: [Double]
        /// The phone's "confirm bolus" setting; nil in grants from builds before it was sent.
        var confirmBolus: Bool?
    }

    /// A stored CGM reading before smoothing, for the watch to smooth its own readings with the phone's history.
    struct RawReading: Codable, Equatable {
        var id: UUID
        var date: Date
        var glucose: Int16
    }

    struct OdometerReading: Codable, Equatable {
        var units: Double
        var at: Date
    }

    var versions: Versions
    var requestID: UUID
    var epoch: Int64
    var expiresAt: Date
    var phoneTime: Date
    var timeZoneIdentifier: String

    /// The phone's oref inputs at the grant: settings, preferences, schedules, adjustments, 10 days of TDD rows,
    /// and the glucose, pump event and carb windows of `OrefInputs+Selection`.
    var oref: OrefInputs
    var overrideAtGrant: Adjustment?
    var tempTargetAtGrant: Adjustment?
    var bolusCalculator: BolusCalculatorSettings
    var glucoseAlarms: [GlucoseAlert]
    var glucoseAlarmConfiguration: GlucoseAlertConfiguration

    /// `SharedDeviceConfiguration.rawValue` as a binary property list, exported after the release.
    var pumpExport: Data
    var cgmExport: Data
    var deliveryPulseUnits: Double
    /// The pump's delivered total read just before the release.
    var releaseReading: OdometerReading
    var podEndsAt: Date?
    var sensorEndsAt: Date?
    /// The phone's glucose smoothing setting, and its smoothing window (24 h of CGM readings, raw) when it is on.
    var smoothGlucose = false
    var smoothingWindow: [RawReading] = []

    var timeZone: TimeZone? { TimeZone(identifier: timeZoneIdentifier) }

    func podEndsSoon(now: Date) -> Bool { Self.endsSoon(podEndsAt, now: now) }
    func sensorEndsSoon(now: Date) -> Bool { Self.endsSoon(sensorEndsAt, now: now) }

    static func endsSoon(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        return date.timeIntervalSince(now) < endingSoonWindow
    }
}

// MARK: - Validation, shared by both devices

extension WatchLoanSnapshot {
    /// What the receiver expects: the grant it asked for, its own build, clock and time zone.
    struct Expectation {
        var requestID: UUID
        var epoch: Int64
        var appBuild: String
        var now: Date
        var timeZone: TimeZone
    }

    /// The parts that are missing or empty. An empty list means complete.
    var missingParts: [String] {
        var missing: [String] = []
        if oref.basalProfile.isEmpty { missing.append("basal profile") }
        if oref.insulinSensitivities.sensitivities.isEmpty { missing.append("insulin sensitivities") }
        if oref.carbRatios.schedule.isEmpty { missing.append("carb ratios") }
        if oref.bgTargets.targets.isEmpty { missing.append("glucose targets") }
        if oref.glucose.isEmpty { missing.append("glucose") }
        if oref.supportedBasalRates.isEmpty { missing.append("supported basal rates") }
        if bolusCalculator.supportedBolusVolumes.isEmpty { missing.append("supported bolus volumes") }
        if Self.configuration(from: pumpExport) == nil { missing.append("pump export") }
        if Self.configuration(from: cgmExport) == nil { missing.append("CGM export") }
        if deliveryPulseUnits <= 0 { missing.append("delivery pulse") }
        if timeZone == nil { missing.append("time zone") }
        if versions.appBuild.isEmpty || versions.pumpManager.isEmpty || versions.cgmManager.isEmpty {
            missing.append("versions")
        }
        return missing
    }

    /// Nil when the receiver may adopt; otherwise why not. The grant's expiry is the state machine's check.
    func refusal(for expected: Expectation) -> LoanRefusal? {
        guard versions.schema == Self.currentSchemaVersion,
              versions.protocolVersion == WatchLoanEnvelope.currentProtocolVersion,
              versions.appBuild == expected.appBuild
        else { return .versionMismatch }
        guard requestID == expected.requestID, epoch == expected.epoch, missingParts.isEmpty else {
            return .snapshotIncomplete
        }
        guard oref.dosingMode == .closed else { return .notClosedLoop }
        guard abs(phoneTime.timeIntervalSince(expected.now)) <= Self.maxClockOffset else { return .clockOffset }
        guard timeZone?.identifier == expected.timeZone.identifier else { return .timeZoneMismatch }
        return nil
    }

    /// A `SharedDeviceConfiguration.rawValue` from its property list, if it has the keys every export carries.
    static func configuration(from data: Data) -> [String: Any]? {
        guard let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              raw["managerIdentifier"] is String, raw["asOf"] is Date, raw["state"] is [String: Any]
        else { return nil }
        return raw
    }
}

// MARK: - Wire

extension WatchLoanSnapshot {
    /// Compact JSON with Trio's date format, compressed. The receiver decodes with `decode(_:)`.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .customISO8601
        return try (encoder.encode(self) as NSData).compressed(using: .lzfse) as Data
    }

    static func decode(_ data: Data) throws -> WatchLoanSnapshot {
        let json = try (data as NSData).decompressed(using: .lzfse) as Data
        return try JSONCoding.decoder.decode(WatchLoanSnapshot.self, from: json)
    }
}

// MARK: - Chunking

extension WatchLoanSnapshot {
    /// Bytes per snapshot slice. Under `grantBudgetBytes`, leaving room for the chunk's own keys and the dictionary
    /// encoding `sendMessage` adds, so every slice fits one live message.
    static let chunkBytes = 45000

    /// Splits compressed snapshot data into live-message-sized slices, in order. A snapshot within one slice yields
    /// a single element, so a small grant is one chunk like before.
    static func chunk(_ data: Data) -> [Data] {
        guard data.count > chunkBytes else { return [data] }
        var slices: [Data] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data.index(start, offsetBy: chunkBytes, limitedBy: data.endIndex) ?? data.endIndex
            slices.append(data.subdata(in: start ..< end))
            start = end
        }
        return slices
    }

    /// Collects snapshot slices for one loan epoch until every index has arrived, then hands back the joined data.
    /// A slice from a different epoch or a changed count starts the collection over, so a stale grant never mixes in.
    struct ChunkAssembler {
        private(set) var epoch: Int64?
        private var count = 0
        private var slices: [Int: Data] = [:]

        /// Adds a slice. A slice from a different epoch or count starts the collection over.
        mutating func add(_ slice: Data, index: Int, count totalCount: Int, epoch sliceEpoch: Int64) {
            if epoch != sliceEpoch || count != totalCount {
                epoch = sliceEpoch
                count = totalCount
                slices = [:]
            }
            guard index >= 0, index < totalCount else { return }
            slices[index] = slice
        }

        /// The joined snapshot data when every slice of `expectedCount` for `epoch` is present, otherwise nil.
        func joined(expectedCount: Int, epoch expectedEpoch: Int64) -> Data? {
            guard epoch == expectedEpoch, count == expectedCount, slices.count == expectedCount else { return nil }
            var joined = Data()
            for i in 0 ..< expectedCount {
                guard let part = slices[i] else { return nil }
                joined.append(part)
            }
            return joined
        }

        mutating func reset() {
            epoch = nil
            count = 0
            slices = [:]
        }
    }
}
