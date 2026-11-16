import Foundation

/// The loan the phone took back. A foreign pod session is attributed to it only while
/// `supersededUntil` is set, which only Take Back does (C-1).
struct LoanRecord: Codable, Equatable, Hashable {
    let epoch: Int
    var supersededUntil: Date?
}

/// Who may command the pump, from the phone's side. Only `home` may.
enum PhoneLoanState: Codable, Equatable, Hashable {
    case home(epoch: Int, lastLoan: LoanRecord?)
    case lending(epoch: Int, requestID: UUID)
    case lent(epoch: Int)
    case takingBack(epoch: Int, loan: LoanRecord?)
    /// The state file exists but can't be read (V2-15). Never persisted.
    case unreadable

    /// No state file: the phone has never lent, which is today's behaviour.
    static let initial = PhoneLoanState.home(epoch: 0, lastLoan: nil)

    var mayCommandPump: Bool {
        if case .home = self { return true }
        return false
    }

    var epoch: Int? {
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
    /// The phone revoked the loan with a higher epoch.
    case superseded
    /// The pod reported a session this watch didn't start (V2-6).
    case foreignSession
    /// Relaunched more than `WatchLoan.resumeWindow` after the last cycle (V2-11).
    case resumeWindowPassed
}

/// Who may command the pump, from the watch's side. Only `holding` may.
enum WatchLoanState: Codable, Equatable, Hashable {
    case idle(epoch: Int)
    case requesting(epoch: Int, requestID: UUID)
    case holding(epoch: Int)
    case returning(epoch: Int)
    case stopped(epoch: Int, reason: WatchStopReason)

    static let initial = WatchLoanState.idle(epoch: 0)

    var mayCommandPump: Bool {
        if case .holding = self { return true }
        return false
    }

    var epoch: Int {
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
