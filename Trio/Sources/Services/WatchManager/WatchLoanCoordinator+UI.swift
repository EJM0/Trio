import Foundation

/// Read-only values the phone's Trio on Watch screens show.
extension WatchLoanCoordinator {
    /// When the last record batch from Apple Watch arrived during this loan.
    var lastBatchAt: Date? { ledger.lastBatchAt }

    /// The watch's last confirmed loop in this loan.
    var watchLoopAt: Date? { ledger.watchLoop.flatMap { $0.epoch == state.epoch ? $0.at : nil } }
}
