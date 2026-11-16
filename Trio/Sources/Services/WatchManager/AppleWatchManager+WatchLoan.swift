import Foundation
import WatchConnectivity

extension BaseWatchManager: WatchLoanTransport {
    func forwardLoanPayload(_ payload: [String: Any]) {
        guard let coordinator = watchLoanCoordinator else { return }
        Task { await coordinator.receive(payload) }
    }

    /// The watch asks after a relaunch whether the loan it holds still stands.
    func answerLoanStatusQuery(_ replyHandler: @escaping ([String: Any]) -> Void) {
        guard let coordinator = watchLoanCoordinator else { return replyHandler([:]) }
        Task { replyHandler(await coordinator.statusAnswer()) }
    }

    var isReachable: Bool { session?.isReachable ?? false }

    func sendLive(_ payload: [String: Any]) -> Bool {
        guard let session, session.activationState == .activated, session.isReachable else { return false }
        session.sendMessage(payload, replyHandler: nil) { error in
            warning(.watch, "Sending a watch loan message failed", error: error)
        }
        return true
    }

    func send(_ payload: [String: Any]) {
        guard let session, session.activationState == .activated else {
            warning(.watch, "Watch loan message not sent: no active watch session")
            return
        }
        guard session.isReachable else {
            session.transferUserInfo(payload)
            return
        }
        // the receiver drops duplicates, so a retry after a failed live send is safe
        session.sendMessage(payload, replyHandler: nil) { error in
            warning(.watch, "Sending a watch loan message failed; queued instead", error: error)
            session.transferUserInfo(payload)
        }
    }

    func cancelOutstandingLoanTransfers() {
        guard let session else { return }
        let loanTransfers = session.outstandingUserInfoTransfers.filter { transfer in
            WatchLoanWireKey.isLoanPayload(transfer.userInfo)
        }
        loanTransfers.forEach { $0.cancel() }
        if !loanTransfers.isEmpty { info(.watch, "Cancelled \(loanTransfers.count) queued watch loan messages") }
    }
}
