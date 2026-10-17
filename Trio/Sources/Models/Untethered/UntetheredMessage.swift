import Foundation

/// What the phone and the watch tell each other about untethered watch mode.
enum UntetheredMessage: Codable, Equatable {
    case prepare(UntetheredGrant)
    case prepared
    case rejected(reason: String)
    case commit
    case takeoverComplete(UntetheredPodStatus)
    case takeoverFailed(reason: String)
    case records([UntetheredRecord])
    /// The phone stored these record versions; the watch drops their payloads and keeps only the sync entries.
    case recordsStored([UUID])
    case syncRequest(bucketStart: Int, checksums: [Int])
    case syncDone
    case endRequest
    case handback(UntetheredPodStatus?)
    case handbackAck
    case revoke
    /// The watch let go of the pump in an emergency stop.
    case released(UntetheredPodStatus?)
    case statusQuery
    /// The takeover status while the watch holds the pump, nil when it doesn't.
    case statusReport(holding: UntetheredPodStatus?)
    /// Started from the wrist: the phone runs its own start, as from its settings.
    case startRequest
    /// The phone's checks refused the start asked for from the wrist.
    case startRefused(reason: String)
    /// Cancelled on the phone: the override or temp target that started at `start` ends at `at` on the watch too.
    case adjustmentCancelled(UntetheredAdjustment, start: Date, at: Date)
}

enum UntetheredAdjustment: String, Codable {
    case override
    case tempTarget
}

struct UntetheredPodStatus: Codable, Equatable {
    let date: Date
    let deliveredUnits: Double?
    let reservoir: Double?
}

/// Everything the watch needs to run the loop: the pump and CGM, therapy settings and 24 h of history.
struct UntetheredGrant: Codable, Equatable {
    let leaseExpiresAt: Date
    /// LoopKit `SharedDeviceConfiguration.rawValue`, as binary property lists.
    let pumpConfiguration: Data
    let cgmConfiguration: Data

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
    /// The phone's TDD rows of the last two hours, and the sum and count of the last ten days, so the watch
    /// keeps the averages moving with its own rows.
    let tddRecentRows: [UntetheredTDD]
    let tddTenDaySum: Decimal
    let tddTenDayCount: Int
    /// The last day of pump history in the shape TDD is calculated from (`PumpHistoryStorage.getPumpHistory`).
    let tddPumpHistory: [PumpHistoryEvent]
    let autosens: Autosens?
    let reservoir: Decimal?
    let maxBolus: Decimal
    let maxCarbs: Decimal
    let bolusCalculator: UntetheredBolusCalculatorSettings
    /// `GlucoseColorScheme.rawValue`, so the watch colors readings as the phone does.
    let glucoseColorScheme: String
    /// The phone's last loop, so the watch shows IOB, COB and the forecast until its own first loop.
    let lastDetermination: Determination?
    let lastLoopDate: Date?
    /// mg/dL
    let lowGlucose: Decimal
    let highGlucose: Decimal

    let pumpHistory: [PumpHistoryEvent]
    /// Raw readings, so the phone gets the originals back.
    let glucose: [BloodGlucose]
    /// The phone's smoothed value per reading id, when smoothing is on.
    let smoothedGlucose: [String: Decimal]
    let carbs: [CarbsEntry]
    let activeOverride: Override?
    /// The temp targets file the algorithm reads; the newest entry decides.
    let tempTargets: [TempTarget]
    let overridePresets: [Override]
    let tempTargetPresets: [TempTarget]
    let linkedOverrideID: String?
}

/// One TDD calculation, as `TDDStored` keeps it.
struct UntetheredTDD: Codable, Equatable {
    let date: Date
    let total: Decimal
    let bolus: Decimal
    let tempBasal: Decimal
    let scheduledBasal: Decimal
    let weightedAverage: Decimal?
}

/// The phone's bolus calculator settings, so the watch recommends what the phone would.
struct UntetheredBolusCalculatorSettings: Codable, Equatable {
    let fraction: Decimal
    let fattyMeals: Bool
    let fattyMealFactor: Decimal
    let sweetMeals: Bool
    let sweetMealFactor: Decimal
}

/// One message on the wire: LZFSE-compressed JSON under a single WatchConnectivity key.
struct UntetheredEnvelope: Codable, Equatable {
    static let key = "untethered"

    let epoch: Int
    let message: UntetheredMessage

    func payload() throws -> [String: Any] {
        let json = try JSONEncoder().encode(self)
        return [Self.key: try (json as NSData).compressed(using: .lzfse) as Data]
    }

    /// nil: not an untethered message.
    static func decode(_ payload: [String: Any]) throws -> UntetheredEnvelope? {
        guard let data = payload[key] as? Data else { return nil }
        let json = try (data as NSData).decompressed(using: .lzfse) as Data
        return try JSONDecoder().decode(UntetheredEnvelope.self, from: json)
    }
}

/// A large envelope (the grant) travels as several interactive messages: WatchConnectivity refuses one
/// near 65 KB. The receiver reassembles them in any order; the reply of the completing part answers.
enum UntetheredChunks {
    static let key = "untetheredChunk"
    static let partSize = 48000

    /// nil when the payload fits one message.
    static func split(_ payload: [String: Any]) -> [[String: Any]]? {
        guard let data = payload[UntetheredEnvelope.key] as? Data, data.count > partSize else { return nil }
        let id = UUID().uuidString
        let parts = stride(from: 0, to: data.count, by: partSize).map { data.subdata(in: $0 ..< min($0 + partSize, data.count)) }
        return parts.enumerated().map { index, part in
            [key: part, "id": id, "index": index, "count": parts.count]
        }
    }

    final class Assembler {
        private var parts: [String: [Int: Data]] = [:]

        /// The whole payload once its last part arrived.
        func add(_ message: [String: Any]) -> [String: Any]? {
            guard let part = message[key] as? Data, let id = message["id"] as? String,
                  let index = message["index"] as? Int, let count = message["count"] as? Int
            else { return nil }
            parts[id, default: [:]][index] = part
            guard let received = parts[id], received.count == count else { return nil }
            parts[id] = nil
            return [UntetheredEnvelope.key: (0 ..< count).compactMap { received[$0] }.reduce(Data(), +)]
        }
    }
}
