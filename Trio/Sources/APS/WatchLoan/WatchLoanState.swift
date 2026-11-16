import Foundation

/// The loan the phone took back. `epoch` is nil when the peer is unknown; its audit then covers the pod's whole life.
/// A foreign pod session is attributed to it only inside the superseding window, which only a user take sets.
struct LoanRecord: Codable, Equatable, Hashable {
    let epoch: Int64?
    var supersededUntil: Date?
    var takenAt: Date?

    init(epoch: Int64?, supersededUntil: Date? = nil, takenAt: Date? = nil) {
        self.epoch = epoch
        self.supersededUntil = supersededUntil
        self.takenAt = takenAt
    }

    static func superseding(epoch: Int64?, at now: Date) -> LoanRecord {
        LoanRecord(epoch: epoch, supersededUntil: now.addingTimeInterval(WatchLoan.resumeWindow), takenAt: now)
    }

    /// A clock set back before the take ends the window rather than stretching it.
    func isSuperseding(at now: Date) -> Bool {
        guard let supersededUntil, let takenAt else { return false }
        return takenAt <= now && now < supersededUntil
    }

    var audit: AuditScope { epoch.map { .loan(epoch: $0) } ?? .podLifetime }

    var withoutWindow: LoanRecord { LoanRecord(epoch: epoch) }
}

/// Who may command the pump, from the phone's side. Only `home` may.
enum PhoneLoanState: Codable, Equatable, Hashable {
    case home(epoch: Int64, lastLoan: LoanRecord?)
    case lending(epoch: Int64, requestID: UUID)
    case lent(epoch: Int64)
    case takingBack(epoch: Int64, loan: LoanRecord)
    /// The state file exists but can't be read. Never persisted.
    case unreadable

    /// No state file: the phone has never lent, which is today's behaviour.
    static let initial = PhoneLoanState.home(epoch: 0, lastLoan: nil)

    var mayCommandPump: Bool {
        if case .home = self { return true }
        return false
    }

    var epoch: Int64? {
        switch self {
        case let .home(epoch, _),
             let .lending(epoch, _),
             let .lent(epoch),
             let .takingBack(epoch, _):
            return epoch
        case .unreadable:
            return nil
        }
    }
}

enum WatchStopReason: String, Codable, Equatable, Hashable {
    /// The phone has the pod at a higher epoch.
    case superseded
    /// The pod reported a session this watch didn't start.
    case foreignSession
    /// Relaunched too long after the last cycle.
    case resumeWindowPassed
    /// Relaunched before taking control, and the phone didn't confirm the loan.
    case unconfirmed
}

/// Who may command the pump, from the watch's side. Only `holding` may.
enum WatchLoanState: Codable, Equatable, Hashable {
    case idle(epoch: Int64)
    case requesting(epoch: Int64, requestID: UUID)
    case holding(epoch: Int64)
    case returning(epoch: Int64)
    case stopped(epoch: Int64, reason: WatchStopReason)

    static let initial = WatchLoanState.idle(epoch: 0)

    var mayCommandPump: Bool {
        if case .holding = self { return true }
        return false
    }

    var epoch: Int64 {
        switch self {
        case let .holding(epoch),
             let .idle(epoch),
             let .requesting(epoch, _),
             let .returning(epoch),
             let .stopped(epoch, _):
            return epoch
        }
    }
}
