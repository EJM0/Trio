import Foundation

/// Everything untethered mode needs on the watch, written to disk on every change so a relaunch
/// (the app closed, the watch restarted) continues exactly where it left off.
struct UntetheredWatchData: Codable {
    var session = UntetheredSession()
    var grant: UntetheredGrant?

    /// The device managers as LoopKit saves them (`managerIdentifier` + `state`), binary property lists.
    var pumpRawValue: Data?
    /// Kept across sessions: the watch's own sensor link and its pairing outlive a hand-back.
    var cgmRawValue: Data?
    /// The configuration's `state` the CGM manager was built from; a different one (new sensor or code) rebuilds it.
    var cgmBuiltFrom: Data?
    /// This watch's own knowledge of each device (e.g. its Bluetooth handle), by plugin identifier.
    var localStates: [String: Data] = [:]

    // What the algorithm reads, trimmed to the last 24 h.
    var pumpHistory: [PumpHistoryEvent] = []
    /// Raw readings, as the phone stores them.
    var glucose: [BloodGlucose] = []
    /// Smoothed value per reading id while smoothing is on; the algorithm reads these, the screens the raw ones.
    var smoothedGlucose: [String: Decimal] = [:]
    var carbs: [CarbsEntry] = []
    var tempTargets: [TempTarget] = []
    var activeOverride: Override?
    /// The record keys that started the running override and temp target; their end is a new version.
    var activeOverrideKey: String?
    var activeTempTargetKey: String?
    var autosens: Autosens?
    var reservoir: Decimal?
    /// Pump history in the shape TDD is calculated from, the last day.
    var tddPumpHistory: [PumpHistoryEvent] = []
    /// Pump events still in progress; a complete pending report drops the ones it no longer contains.
    var mutablePumpEventIDs: Set<String> = []
    /// TDD rows of the last two hours (the phone's, then the watch's own) and the running ten-day sum and count.
    var tddRows: [UntetheredTDD] = []
    var tddTenDaySum: Decimal = 0
    var tddTenDayCount = 0

    // What the screens show.
    var lastDetermination: Determination?
    var lastLoopDate: Date?
    /// The newest reading a dosing loop has seen, the phone's last one included: each reading loops once.
    var lastLoopGlucose: Date?
    var lastLoopError: String?
    var lastError: String?
    /// The pod was deactivated or discarded here: no loop until the phone, which pairs the next one, takes over.
    var podEnded = false
    var pendingPumpAlerts: [PendingPumpAlert] = []

    // History on its way to the phone, per session.
    /// Versions the phone hasn't confirmed yet: dropped as soon as it has stored them.
    var pending: [Int: [String: UntetheredRecord]] = [:]
    /// The latest version of every key, payload-free, for the bucket checksums.
    var entries: [Int: [String: UntetheredSyncEntry]] = [:]
    /// Versions not handed to WatchConnectivity yet.
    var unsent: Set<UUID> = []

    struct PendingPumpAlert: Codable, Equatable, Identifiable {
        let managerIdentifier: String
        let alertIdentifier: String
        let title: String
        let body: String
        /// When a scheduled alert becomes due; nil shows it at once.
        var due: Date?
        var id: String { managerIdentifier + "." + alertIdentifier }
    }
}

final class UntetheredStore {
    private let url: URL
    private(set) var data: UntetheredWatchData

    init(fileName: String = "untethered-watch.json") {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(fileName)
        data = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(UntetheredWatchData.self, from: $0) }
            ?? UntetheredWatchData()
    }

    @discardableResult func update<T>(_ change: (inout UntetheredWatchData) -> T) -> T {
        let result = change(&data)
        do {
            try JSONEncoder().encode(data).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Task { await WatchLogger.shared.log("⌚️ Untethered: saving failed: \(error)", force: true) }
        }
        return result
    }

    /// Keeps a new version for the phone and in the checksums.
    func record(_ record: UntetheredRecord, epoch: Int) {
        update {
            $0.pending[epoch, default: [:]][record.key] = record
            $0.entries[epoch, default: [:]][record.key] = record.syncEntry
            $0.unsent.insert(record.id)
        }
    }

    /// Drops what is older than a day from the algorithm's inputs.
    func trim(now: Date) {
        let dayAgo = now.addingTimeInterval(-24 * 60 * 60)
        update {
            $0.pumpHistory.removeAll { $0.timestamp < dayAgo }
            $0.tddPumpHistory.removeAll { $0.timestamp < dayAgo }
            $0.tddRows.removeAll { $0.date < now.addingTimeInterval(-2 * 60 * 60) }
            $0.glucose.removeAll { $0.dateString < dayAgo }
            let kept = Set($0.glucose.map(\.id))
            $0.smoothedGlucose = $0.smoothedGlucose.filter { kept.contains($0.key) }
            $0.carbs.removeAll { ($0.actualDate ?? $0.createdAt) < dayAgo }
            $0.tempTargets.removeAll { $0.createdAt < dayAgo }
        }
    }
}
