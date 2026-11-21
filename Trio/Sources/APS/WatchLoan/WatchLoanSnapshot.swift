import CryptoKit
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

    /// "1.0.2 (27)", the same on phone and watch.
    static func appBuild(_ info: [String: Any]?) -> String {
        "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }

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

    /// Compressed size of each large part, for the log.
    func partSizes() -> [(part: String, count: Int, bytes: Int)] {
        func size(_ value: some Encodable) -> Int {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .customISO8601
            guard let json = try? encoder.encode(value),
                  let compressed = try? (json as NSData).compressed(using: .lzfse)
            else { return -1 }
            return compressed.length
        }
        var rest = self
        rest.oref.tddHistory = []
        rest.oref.glucose = []
        rest.oref.pumpHistory = []
        rest.oref.carbs = []
        rest.smoothingWindow = []
        rest.glucoseAlarms = []
        rest.pumpExport = Data()
        rest.cgmExport = Data()
        return [
            ("TDD history", oref.tddHistory.count, size(oref.tddHistory)),
            ("glucose", oref.glucose.count, size(oref.glucose)),
            ("pump history", oref.pumpHistory.count, size(oref.pumpHistory)),
            ("carbs", oref.carbs.count, size(oref.carbs)),
            ("smoothing window", smoothingWindow.count, size(smoothingWindow)),
            ("glucose alarms", glucoseAlarms.count, size(glucoseAlarms)),
            ("pump export", pumpExport.count, size(pumpExport)),
            ("CGM export", cgmExport.count, size(cgmExport)),
            ("everything else", 1, size(rest))
        ]
    }

    static func decode(_ data: Data) throws -> WatchLoanSnapshot {
        let json = try (data as NSData).decompressed(using: .lzfse) as Data
        return try JSONCoding.decoder.decode(WatchLoanSnapshot.self, from: json)
    }
}

// MARK: - Parts

/// One piece of a compressed snapshot that is too large for one message.
struct WatchLoanSnapshotPart: Codable, Equatable {
    var requestID: UUID
    var epoch: Int64
    var index: Int
    var count: Int
    var byteCount: Int
    /// SHA-256 of the whole snapshot.
    var digest: Data
}

extension WatchLoanSnapshot {
    static let partBytes = 40000
    static let maxParts = 4

    static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func split(_ data: Data, requestID: UUID, epoch: Int64) -> [(header: WatchLoanSnapshotPart, bytes: Data)] {
        let count = max(1, (data.count + partBytes - 1) / partBytes)
        let digest = digest(data)
        return (0 ..< count).map { index in
            let start = data.startIndex + index * partBytes
            let end = min(start + partBytes, data.endIndex)
            let header = WatchLoanSnapshotPart(
                requestID: requestID,
                epoch: epoch,
                index: index,
                count: count,
                byteCount: data.count,
                digest: digest
            )
            return (header, Data(data[start ..< end]))
        }
    }
}

/// Collects the pieces of one grant. A piece from another request or epoch starts over.
struct WatchLoanSnapshotAssembler {
    private(set) var header: WatchLoanSnapshotPart?
    private var pieces: [Int: Data] = [:]

    mutating func add(_ part: WatchLoanSnapshotPart, _ bytes: Data) {
        guard part.count >= 1, part.count <= WatchLoanSnapshot.maxParts, (0 ..< part.count).contains(part.index) else {
            return
        }
        if let header, header.requestID != part.requestID || header.epoch != part.epoch || header.count != part.count ||
            header.byteCount != part.byteCount || header.digest != part.digest
        {
            pieces = [:]
        }
        header = part
        pieces[part.index] = bytes
    }

    func missing(requestID: UUID, epoch: Int64) -> Int? {
        guard let header, header.requestID == requestID, header.epoch == epoch else { return nil }
        return header.count - pieces.count
    }

    func assembled(requestID: UUID, epoch: Int64) -> Data? {
        guard let header, missing(requestID: requestID, epoch: epoch) == 0 else { return nil }
        var data = Data()
        for index in 0 ..< header.count {
            guard let piece = pieces[index] else { return nil }
            data.append(piece)
        }
        guard data.count == header.byteCount, WatchLoanSnapshot.digest(data) == header.digest else { return nil }
        return data
    }

    mutating func reset() {
        header = nil
        pieces = [:]
    }
}
