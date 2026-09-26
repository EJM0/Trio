import Foundation

/// The watch's copy of the phone's glucose window, kept in step through full
/// histories and deltas (see `WatchGlucoseSync`).
///
/// Readings are stored exactly as the phone sent them, so delta bases and the
/// checksum compare bit for bit with the phone's values.
struct WatchGlucoseHistory {
    struct Reading: Equatable, Codable {
        let timestamp: TimeInterval
        let glucose: Double
        let color: String
    }

    enum MergeResult: Equatable {
        /// The payload carried no glucose readings; nothing changed.
        case unchanged
        /// The history changed and matches the phone's window.
        case updated
        /// A full history was adopted, but it does not match its own checksum.
        /// The readings are still the phone's, but deltas can't be trusted.
        case updatedUnverified
        /// A delta was merged, but the result does not match the phone's window.
        case mismatch
        /// The delta starts after the newest local reading: readings are missing.
        case needsBackfill
        /// The delta can't be applied to the local history at all.
        case needsFullHistory(reason: String)
    }

    /// Oldest first.
    private(set) var readings: [Reading] = []
    /// Settings the readings were converted and colored with; `nil` until a
    /// history with a signature arrived (older phone builds send none).
    private(set) var signature: String?

    var newestTimestamp: TimeInterval? { readings.last?.timestamp }

    init() {}

    // MARK: - Persistence

    /// What is written to disk: enough to show the chart at launch and to ask
    /// the phone for only the readings after the newest one.
    private struct Stored: Codable {
        let readings: [Reading]
        let signature: String?
    }

    /// Restores a history saved with `encoded()`; `nil` if the data can't be read.
    init?(data: Data) {
        guard let stored = try? PropertyListDecoder().decode(Stored.self, from: data) else { return nil }
        readings = stored.readings.sorted { $0.timestamp < $1.timestamp }
        signature = stored.signature
    }

    func encoded() -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(Stored(readings: readings, signature: signature))
    }

    // MARK: - Merging

    mutating func merge(_ payload: [String: Any]) -> MergeResult {
        guard let encoded = payload[WatchMessageKeys.glucoseValues] as? [[String: Any]] else { return .unchanged }
        let incoming = Self.decode(encoded)
        let payloadSignature = payload[WatchMessageKeys.glucoseSignature] as? String

        guard payload[WatchMessageKeys.glucoseSyncMode] as? String == WatchGlucoseSync.modeDelta else {
            // Full history: the phone's window as is. Phones without delta
            // support always send this, without any metadata to verify.
            readings = incoming
            signature = payloadSignature
            trim(to: payload)
            return verify(against: payload, requireMetadata: false) ? .updated : .updatedUnverified
        }

        guard let signature = signature, payloadSignature == signature else {
            return .needsFullHistory(reason: "glucose settings changed")
        }
        guard let base = payload[WatchMessageKeys.glucoseSyncBase] as? TimeInterval else {
            return .needsFullHistory(reason: "delta without base")
        }
        guard let newest = newestTimestamp else {
            return .needsFullHistory(reason: "no local history")
        }
        guard base <= newest else {
            return .needsBackfill
        }

        // Readings deleted on the phone: a delta only adds, so it names them.
        if let deleted = payload[WatchMessageKeys.glucoseDeleted] as? [TimeInterval], !deleted.isEmpty {
            let deletedSet = Set(deleted)
            readings.removeAll { deletedSet.contains($0.timestamp) }
        }

        // Everything up to `newest` is already here; the delta may overlap it
        // when the watch got ahead of the delta's base in the meantime.
        readings.append(contentsOf: incoming.filter { $0.timestamp > newest })
        trim(to: payload)
        return verify(against: payload, requireMetadata: true) ? .updated : .mismatch
    }

    /// Drops readings the phone no longer has in its window. Uses the phone's
    /// window start, never the watch's clock, so both sides count the same set.
    private mutating func trim(to payload: [String: Any]) {
        guard let windowStart = payload[WatchMessageKeys.glucoseWindowStart] as? TimeInterval else { return }
        readings.removeAll { $0.timestamp < windowStart }
    }

    private func verify(against payload: [String: Any], requireMetadata: Bool) -> Bool {
        guard let expectedCount = payload[WatchMessageKeys.glucoseCount] as? Int,
              let expectedChecksum = payload[WatchMessageKeys.glucoseChecksum] as? Int64
        else { return !requireMetadata }

        var checksum = WatchGlucoseChecksum()
        for reading in readings {
            checksum.add(timestamp: reading.timestamp, glucose: reading.glucose)
        }
        return checksum.count == expectedCount && checksum.transportValue == expectedChecksum
    }

    private static func decode(_ encoded: [[String: Any]]) -> [Reading] {
        encoded.compactMap { entry -> Reading? in
            guard let timestamp = entry[WatchGlucoseSync.readingTimestampKey] as? TimeInterval,
                  let glucose = entry[WatchGlucoseSync.readingGlucoseKey] as? Double,
                  let color = entry[WatchGlucoseSync.readingColorKey] as? String
            else { return nil }
            return Reading(timestamp: timestamp, glucose: glucose, color: color)
        }
        .sorted { $0.timestamp < $1.timestamp }
    }
}
