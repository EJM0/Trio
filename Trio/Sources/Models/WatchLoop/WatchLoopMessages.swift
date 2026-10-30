import Foundation

/// Everything the watch needs to run the loop: the pump and CGM, the therapy settings and enough history for the
/// first cycle. A standing copy is the same, kept by the watch to start without the phone.
struct WatchLoopGrant: Codable {
    /// Increases with every grant; both sides refuse any other.
    let session: Int
    let issuedAt: Date
    /// A takeover that hasn't reached the pump by then gives up (`WatchLoopControl.takeoverLease`).
    let leaseExpiresAt: Date
    /// LoopKit `SharedDeviceConfiguration.rawValue`, as binary property lists.
    let pumpConfiguration: Data
    let cgmConfiguration: Data?

    let pumpSettings: PumpSettings
    let bgTargets: BGTargets
    let basalProfile: [BasalProfileEntry]
    let insulinSensitivities: InsulinSensitivities
    let carbRatios: CarbRatios
    let preferences: Preferences
    let dosingMode: DosingMode
    let smoothGlucose: Bool
    let units: GlucoseUnits
    let tdd: OrefPipeline.TDDSummary
    /// Without enough days of TDD the dynamic ISF formulas stay off, as on the phone.
    let hasSufficientTDD: Bool
    let autosens: Autosens?
    let maxBolus: Decimal
    let maxCarbs: Decimal
    let bolusCalculator: WatchLoopBolusSettings
    /// mg/dL
    let lowGlucose: Decimal
    let highGlucose: Decimal

    /// The last day, as the algorithm reads it.
    let pumpHistory: [PumpHistoryEvent]
    let glucose: [BloodGlucose]
    let carbs: [CarbsEntry]
    let activeOverride: Override?
    /// The temp targets file the algorithm reads; the newest entry decides.
    let tempTargets: [TempTarget]
    let overridePresets: [Override]
    let tempTargetPresets: [TempTarget]
    /// The phone's last loop, so the watch shows IOB, COB and the forecast until its own first loop.
    let lastDetermination: Determination?
}

extension WatchLoopGrant: Equatable {
    /// Some of the therapy models aren't Equatable; two grants are the same when they encode the same.
    static func == (lhs: WatchLoopGrant, rhs: WatchLoopGrant) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }
}

/// The phone's bolus calculator settings, so the watch recommends what the phone would.
struct WatchLoopBolusSettings: Codable, Equatable {
    let fraction: Decimal
    let fattyMeals: Bool
    let fattyMealFactor: Decimal
    let sweetMeals: Bool
    let sweetMealFactor: Decimal
}

/// The watch asking for the pump.
struct WatchLoopRequest: Codable, Equatable {
    /// Lets the phone recognise a redelivered copy of the same request.
    let id: UUID
    /// A request that sat in a queue is not granted.
    let sentAt: Date
    /// The highest session the watch knows, so the phone grants above it.
    let highestSession: Int
}

/// What the watch shows of its loop, for the phone's banner, glow and chart between records.
struct WatchLoopLiveStatus: Codable, Equatable {
    let lastLoopAt: Date?
    let glucose: Int?
    let iob: Decimal?
    let cob: Decimal?
    let tempBasalRate: Decimal?
    let reservoir: Decimal?
    let pumpExpiresAt: Date?
    /// Closed loop on the watch; off, the watch suggests and the looper enacts.
    let closedLoop: Bool
}

/// What the watch recorded since the last acknowledgement. Sent every cycle, empty or not, as the sign of life; a
/// cycle that cannot reach the pump sends none (control row 14).
struct WatchLoopCheckpoint: Codable, Equatable {
    let session: Int
    /// Sign of life is judged by send time, not arrival.
    let sentAt: Date
    let startedAt: Date
    let records: [WatchLoopRecord]
    let status: WatchLoopLiveStatus?
}

/// The watch offering the pump back: resent until acknowledged, harmless to receive twice.
struct WatchLoopHandBack: Codable, Equatable {
    let session: Int
    let records: [WatchLoopRecord]
    let odometer: WatchLoopOdometer?
}

/// The answer to a status query, and the watch's report after a relaunch.
struct WatchLoopStatusReport: Codable, Equatable {
    /// The query answered; nil for an unasked report.
    let replyTo: UUID?
    let session: Int?
    let holdsPump: Bool
    let startedAt: Date?
    /// With `holdsPump`: whether the watch reached the pump in its last cycle. A holder that cannot reach it is
    /// answered like silence.
    let pumpReachable: Bool?
}

/// Every message the two apps exchange about the Watch Loop, roughly in the order a session uses them.
enum WatchLoopMessage: Codable, Equatable {
    case request(WatchLoopRequest)
    case grant(WatchLoopGrant)
    case startRefused(requestID: UUID, reason: String)
    /// The standing copy, outside any session.
    case standingCopy(WatchLoopGrant)
    case checkpoint(WatchLoopCheckpoint)
    /// Records the phone has stored; the watch stops resending them.
    case ack(session: Int, recordIDs: [UUID])
    case handBack(WatchLoopHandBack)
    case handBackAck(session: Int)
    /// The phone has the pump: the watch stands aside before any dose.
    case stop(session: Int)
    case statusQuery(id: UUID)
    case statusReport(WatchLoopStatusReport)

    var kind: String {
        switch self {
        case .request: return "request"
        case .grant: return "grant"
        case .startRefused: return "startRefused"
        case .standingCopy: return "standingCopy"
        case .checkpoint: return "checkpoint"
        case .ack: return "ack"
        case .handBack: return "handBack"
        case .handBackAck: return "handBackAck"
        case .stop: return "stop"
        case .statusQuery: return "statusQuery"
        case .statusReport: return "statusReport"
        }
    }
}

/// Wire rules shared by both apps (as LoopKit/Loop#2545's LoanTransport).
enum WatchLoopTransport {
    /// The WatchConnectivity key carrying a Watch Loop message; anything else on the channel is the regular watch
    /// state traffic.
    static let key = "watchLoop"
    /// Bumped only for a change the other side could not survive; additive changes use optional fields.
    static let version = 1
    /// The live channel silently refuses payloads near 65 KB; above this a message goes queued only.
    static let maxUrgentBytes = 60000

    struct Envelope: Codable, Equatable {
        let version: Int
        /// Both sides drop the later of two copies that came by both channels.
        let id: UUID
        let message: WatchLoopMessage
    }

    enum TransportError: Error, Equatable {
        case versionMismatch(seen: Int)
    }

    static func encode(_ message: WatchLoopMessage, id: UUID = UUID()) throws -> [String: Any] {
        [key: try JSONCoding.encoder.encode(Envelope(version: version, id: id, message: message))]
    }

    /// nil: not a Watch Loop message. Throws: ours but unreadable, or from a build the other side can't read.
    static func decode(_ userInfo: [String: Any]) throws -> Envelope? {
        guard let data = userInfo[key] as? Data else { return nil }
        struct VersionOnly: Decodable { let version: Int }
        let seen = try JSONCoding.decoder.decode(VersionOnly.self, from: data).version
        guard seen == version else { throw TransportError.versionMismatch(seen: seen) }
        return try JSONCoding.decoder.decode(Envelope.self, from: data)
    }

    /// Sent by the live path and queued as well: what a person or a query waits through, and the stop. A live
    /// message is lost if the sending app goes inactive before delivery; the queued copy survives that. Bookkeeping
    /// (checkpoints, acknowledgements, standing copies) only queues, which survives a relaunch.
    static func ridesBothChannels(_ message: WatchLoopMessage) -> Bool {
        switch message {
        case .grant,
             .handBack,
             .handBackAck,
             .request,
             .startRefused,
             .statusQuery,
             .statusReport,
             .stop:
            return true
        case .ack,
             .checkpoint,
             .standingCopy:
            return false
        }
    }

    /// Whether a payload may go by the live path at all.
    static func fitsLivePath(_ userInfo: [String: Any]) -> Bool {
        ((userInfo[key] as? Data)?.count ?? 0) <= maxUrgentBytes
    }
}

/// Remembers the envelopes already handled, so the copy that rode the other channel is dropped.
struct WatchLoopSeenEnvelopes {
    private(set) var ids: [UUID] = []
    private let capacity = 64

    /// True the first time an id is seen.
    mutating func firstSighting(of id: UUID) -> Bool {
        guard !ids.contains(id) else { return false }
        ids.append(id)
        if ids.count > capacity { ids.removeFirst(ids.count - capacity) }
        return true
    }
}
