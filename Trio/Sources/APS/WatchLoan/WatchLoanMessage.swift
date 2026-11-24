import Foundation

enum LoanRefusal: String, Codable, Equatable, Hashable {
    // Start preconditions, checked by the host
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
    case unsupportedDevice
    /// The CGM can be read on the watch, but its Read on Apple Watch setting is off.
    case cgmNotShared
    case pumpScreenOpen
    case indefiniteOverride
    case notClosedLoop
    // Hand-off
    case busy
    case releaseRefused
    case unknownRequest
    case staleEpoch
    case grantExpired
    // Grant validation, checked by the watch host
    case snapshotIncomplete
    case clockOffset
    case timeZoneMismatch
    // Start without the phone
    case noUsableCopy
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

    let epoch: Int64
    let kind: Kind
}

/// Stop (watch to phone) and revoke (phone to watch). Its wire format never changes, so any protocol version
/// can parse it: only add optional keys. `released` confirms the stopped watch let go of the pod; absent means false.
struct WatchLoanStop: Codable, Equatable, Hashable {
    enum Kind: String, Codable, Equatable, Hashable {
        case stop
        case revoke
    }

    let kind: Kind
    let epoch: Int64
    let released: Bool

    init(kind: Kind, epoch: Int64, released: Bool = false) {
        self.kind = kind
        self.epoch = epoch
        self.released = released
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        epoch = try container.decode(Int64.self, forKey: .epoch)
        released = try container.decodeIfPresent(Bool.self, forKey: .released) ?? false
    }
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

    /// The parts of an envelope that never change, so a hand-back still works across versions.
    private struct HandBackProbe: Decodable {
        struct Message: Decodable {
            let epoch: Int64
            let kind: [String: [String: Int]]
        }

        let protocolVersion: Int
        let messageID: UUID
        let sentAt: Date
        let message: Message
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
            return handBack(in: data) ?? .unsupportedVersion(probe.protocolVersion)
        }
        guard let envelope = try? decoder.decode(WatchLoanEnvelope.self, from: data) else { return .malformed }
        return .message(envelope)
    }

    private static func handBack(in data: Data) -> Decoded? {
        guard let probe = try? JSONDecoder().decode(HandBackProbe.self, from: data) else { return nil }
        let kind: WatchLoanMessage.Kind
        switch Array(probe.message.kind.keys) {
        case ["handBack"]: kind = .handBack
        case ["handBackAck"]: kind = .handBackAck
        default: return nil
        }
        return .message(WatchLoanEnvelope(
            protocolVersion: probe.protocolVersion,
            messageID: probe.messageID,
            sentAt: probe.sentAt,
            message: WatchLoanMessage(epoch: probe.message.epoch, kind: kind)
        ))
    }
}
