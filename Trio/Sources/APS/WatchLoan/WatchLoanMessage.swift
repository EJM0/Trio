import Foundation

enum LoanRefusal: String, Codable, Equatable, Hashable {
    // Start preconditions (SR-4, V2-2, V2-18), checked by the host
    case featureOff
    case bolusRunning
    case unconfirmedCommand
    case deliveryUncertain
    case pumpStatusStale
    case versionMismatch
    case watchBatteryLow
    case notificationsOff
    case unsupportedWatch
    case phoneUnreachable
    // Hand-off
    case busy
    case releaseRefused
    case unknownRequest
    case staleEpoch
    case grantExpired
    // Grant validation (§4), checked by the watch host
    case snapshotIncomplete
    case clockOffset
    case timeZoneMismatch
}

/// A loan message. `epoch` is the sender's loan epoch; for a grant it's the new loan's epoch.
struct WatchLoanMessage: Codable, Equatable, Hashable {
    enum Kind: Codable, Equatable, Hashable {
        // Watch to phone
        case request(requestID: UUID)
        case grantRejected(requestID: UUID, reason: LoanRefusal)
        case holding
        case records
        case handBack
        case status(WatchLoanState)
        // Phone to watch
        case grant(requestID: UUID, expiresAt: Date)
        case refused(requestID: UUID, reason: LoanRefusal)
        case handBackAck
        case statusQuery
    }

    let epoch: Int
    let kind: Kind
}

/// Stop (watch to phone) and revoke (phone to watch). Its wire format never changes,
/// so any protocol version can parse it (V2-10).
struct WatchLoanStop: Codable, Equatable, Hashable {
    enum Kind: String, Codable, Equatable, Hashable {
        case stop
        case revoke
    }

    let kind: Kind
    let epoch: Int
}

struct WatchLoanEnvelope: Codable, Equatable {
    static let currentProtocolVersion = 1

    let protocolVersion: Int
    let messageID: UUID
    let sentAt: Date
    let message: WatchLoanMessage
}

enum WatchLoanWire {
    enum Decoded: Equatable {
        case stop(WatchLoanStop)
        case message(WatchLoanEnvelope)
        case unsupportedVersion(Int)
        case malformed
    }

    private struct StopWrapper: Codable {
        let stop: WatchLoanStop
    }

    private struct VersionProbe: Decodable {
        let protocolVersion: Int
    }

    static func encode(_ envelope: WatchLoanEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    static func encode(_ stop: WatchLoanStop) throws -> Data {
        try JSONEncoder().encode(StopWrapper(stop: stop))
    }

    static func decode(_ data: Data) -> Decoded {
        let decoder = JSONDecoder()
        if let wrapper = try? decoder.decode(StopWrapper.self, from: data) {
            return .stop(wrapper.stop)
        }
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else { return .malformed }
        guard probe.protocolVersion == WatchLoanEnvelope.currentProtocolVersion else {
            return .unsupportedVersion(probe.protocolVersion)
        }
        guard let envelope = try? decoder.decode(WatchLoanEnvelope.self, from: data) else { return .malformed }
        return .message(envelope)
    }
}
