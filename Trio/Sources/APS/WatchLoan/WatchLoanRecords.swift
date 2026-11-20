import Foundation
import LoopKit

/// Records the watch sends while it holds the pump, and after. Merged by sync identifier.
struct WatchLoanRecordBatch: Codable {
    static let currentVersion = 1

    /// A pump event as the kit reported it. The sync identifier is the hex of `raw`, as `NewPumpEvent` makes it.
    struct PumpEventRecord: Codable, Equatable {
        var date: Date
        var raw: Data
        var title: String
        var dose: DoseEntry
        /// The sync identifier of a dose the watch had booked for an unconfirmed command, which this kit record replaces.
        /// The phone deletes its copy of that booking.
        var replacesSyncIdentifier: String? = nil

        var newPumpEvent: NewPumpEvent { NewPumpEvent(date: date, dose: dose, raw: raw, title: title) }
    }

    /// A watch loop's determination and whether its cycle confirmed the pump's state, as the phone marks its own.
    struct DeterminationRecord: Codable, Equatable {
        var determination: Determination
        var enacted: Bool
    }

    var version: Int
    var batchID: UUID
    var epoch: Int64
    var sentAt: Date
    /// Finalized doses only.
    var pumpEvents: [PumpEventRecord]
    /// The temp basal running when the batch was sent. Shown, never stored: the watch sends it finalized once it ends.
    var runningTemp: DoseEntry?
    var carbs: [CarbsEntry]
    /// Meals removed on the watch, by id or by fpuID; sent every batch until the loan ends, the phone skips gone ones.
    var deletedCarbIDs: [String]
    var glucose: [BloodGlucose]
    /// Readings removed on the watch, by date (the watch's own readings carry their own ids).
    var deletedGlucoseDates: [Date]? = nil
    /// The watch's last confirmed loop. Nil from a watch build that doesn't send it.
    var lastLoopAt: Date?
    /// An override started on the watch during the loan (from a grant preset), with its start time, so the phone can
    /// activate it in its own store once the loan ends. Nil from a watch build that doesn't send it.
    var startedOverride: Override? = nil
    var startedOverrideAt: Date? = nil
    var startedTempTarget: TempTarget? = nil
    var startedTempTargetAt: Date? = nil
    /// The watch loop's determinations, for the phone's chart, loop status and Nightscout.
    var determinations: [DeterminationRecord]? = nil

    /// Mutable doses would be purged by the phone driver's next pending report, and a dose without
    /// a sync identifier can't be merged twice safely.
    var storablePumpEvents: [NewPumpEvent] {
        pumpEvents.filter { !$0.dose.isMutable && !$0.raw.isEmpty }.map(\.newPumpEvent)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .customISO8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> WatchLoanRecordBatch {
        try JSONCoding.decoder.decode(WatchLoanRecordBatch.self, from: data)
    }
}

/// Meals and readings changed in the phone's history while the watch holds the pump.
struct WatchLoanPhoneChanges: Codable, Equatable {
    var deletedCarbIDs: [String] = []
    var deletedGlucoseDates: [Date] = []
    /// A meal edited on the phone: its replacement and carb equivalents.
    var carbs: [CarbsEntry] = []

    /// The same reading on phone and watch: their sensor timestamps differ by seconds.
    static let sameReadingWindow: TimeInterval = 30

    static func isDeleted(_ entry: CarbsEntry, by ids: [String]) -> Bool {
        [entry.id, entry.fpuID].contains { $0.map(ids.contains) ?? false }
    }

    static func isDeleted(_ reading: BloodGlucose, by dates: [Date]) -> Bool {
        dates.contains { abs($0.timeIntervalSince(reading.dateString)) < sameReadingWindow }
    }

    /// Posted by the phone's carb and glucose storage; the object is a `WatchLoanPhoneChanges`.
    static let notification = Notification.Name("WatchLoanPhoneChanges")

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .customISO8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> WatchLoanPhoneChanges {
        try JSONCoding.decoder.decode(WatchLoanPhoneChanges.self, from: data)
    }
}

/// The phone's answer once a batch is persisted.
struct WatchLoanRecordAck: Codable, Equatable {
    var epoch: Int64
    var batchID: UUID
}

/// Message keys in a WatchConnectivity payload.
enum WatchLoanWireKey {
    /// `WatchLoanWire` data: an envelope or the stop format.
    static let message = "watchLoan"
    /// Compressed `WatchLoanSnapshot`, only next to a grant.
    static let snapshot = "watchLoanSnapshot"
    static let records = "watchLoanRecords"
    static let recordsAck = "watchLoanRecordsAck"
    /// `WatchLoanPhoneChanges` data, phone to watch.
    static let phoneChanges = "watchLoanPhoneChanges"
    /// Compressed `WatchLoanSnapshot` the phone leaves after each of its loops, for a start without it. Queued,
    /// newest only.
    static let standingCopy = "watchLoanStandingCopy"
    /// One slice of a compressed `WatchLoanSnapshot` too large for a single live message. The grant that follows
    /// carries the slice count; the watch reassembles the slices in index order before it adopts.
    static let snapshotChunk = "watchLoanSnapshotChunk"
    static let snapshotChunkIndex = "watchLoanSnapshotChunkIndex"
    static let snapshotChunkCount = "watchLoanSnapshotChunkCount"
    /// The loan epoch a chunk belongs to, so a stale slice from an earlier grant is dropped.
    static let snapshotChunkEpoch = "watchLoanSnapshotChunkEpoch"

    static let all = [message, snapshot, records, recordsAck, phoneChanges, standingCopy, snapshotChunk]

    /// Loan payloads go to the loan coordinator; every other watch message keeps its existing path.
    static func isLoanPayload(_ payload: [String: Any]) -> Bool {
        all.contains { payload[$0] != nil }
    }

    /// In the phone's reply to the watch's status query: the phone's loan epoch.
    static let phoneEpoch = "watchLoanPhoneEpoch"

    static func isStatusQuery(_ payload: [String: Any]) -> Bool {
        guard let data = payload[message] as? Data, case let .message(envelope) = WatchLoanWire.decode(data) else { return false }
        return envelope.message.kind == .statusQuery
    }
}

/// Which incoming messages the phone passes on. Persisted, so a relaunch keeps dropping what it saw.
struct WatchLoanInbox: Codable, Equatable {
    static let capacity = 512

    private(set) var seen: [UUID] = []

    /// False for a message already passed on. Marks it seen.
    mutating func accept(_ id: UUID) -> Bool {
        guard !seen.contains(id) else { return false }
        seen.append(id)
        if seen.count > Self.capacity { seen.removeFirst(seen.count - Self.capacity) }
        return true
    }

    /// Below the phone's epoch, only the kinds whose rows answer an older loan get through: a new request,
    /// a hand-back (acked again), and the stop and records, which carry what happened in that loan.
    static func passes(_ message: WatchLoanMessage, phoneEpoch: Int64?) -> Bool {
        guard let phoneEpoch, message.epoch < phoneEpoch else { return true }
        switch message.kind {
        case .handBack,
             .records,
             .request:
            return true
        case .grant,
             .grantRejected,
             .handBackAck,
             .holding,
             .refused,
             .status,
             .statusQuery:
            return false
        }
    }
}
