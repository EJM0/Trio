import Foundation

/// Read-only values the phone's Trio on Watch screens show.
extension WatchLoanCoordinator {
    /// When the last record batch from Apple Watch arrived during this loan.
    var lastBatchAt: Date? { ledger.lastBatchAt }
}
