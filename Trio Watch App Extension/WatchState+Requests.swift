import Foundation
import WatchConnectivity

// MARK: - Send Data to Phone

extension WatchState {
    /// While the watch holds the pod, a treatment goes to its session instead of the phone. From the UI, on main.
    private func watchLoopTakes(_ action: @MainActor(WatchLoopSession) -> Void) -> Bool {
        MainActor.assumeIsolated {
            let session = WatchLoopSession.shared
            guard session.state.phase == .active else { return false }
            action(session)
            return true
        }
    }

    /// Sends a bolus insulin request to the paired iPhone
    /// - Parameters:
    ///   - amount: The insulin amount to be delivered
    func sendBolusRequest(_ amount: Decimal) {
        if watchLoopTakes({ session in
            Task {
                if let failure = await session.bolus(NSDecimalNumber(decimal: amount).doubleValue) {
                    self.reportSendFailure(failure)
                } else {
                    self.handleAcknowledgment(success: true, message: String(localized: "Bolus given by the watch."))
                }
            }
        }) { return }
        guard let session = session, session.isReachable else {
            WatchLogger.shared.info(.bolus, "Bolus request aborted: session unreachable")
            reportSendFailure(String(localized: "iPhone not reachable. Nothing was sent."))
            return
        }

        WatchLogger.shared.info(.bolus, "Bolus of \(amount) U requested")

        let message: [String: Any] = [
            WatchMessageKeys.bolus: amount
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            WatchLogger.shared.info(.bolus, "Error sending bolus request: \(error)")
            self.reportSendFailure(String(localized: "Sending to iPhone failed. Please try again."))
        }

        // Display pending communication animation
        showCommsAnimation = true
    }

    /// Sends a carbohydrate entry request to the paired iPhone
    /// - Parameters:
    ///   - amount: The amount of carbs in grams
    ///   - date: The timestamp for the carb entry (defaults to current time)
    /// - Parameter acknowledge: false when a bolus follows at once, as the
    ///   phone's combo answers once.
    func sendCarbsRequest(_ amount: Int, _ date: Date = Date(), acknowledge _: Bool = true) {
        if watchLoopTakes({ $0.addCarbs(Decimal(amount), at: date) }) {
            DispatchQueue.main.async {
                self.handleAcknowledgment(success: true, message: String(localized: "Carbs logged on the watch."))
            }
            return
        }
        guard let session = session, session.isReachable else {
            WatchLogger.shared.info(.treatments, "Carbs request aborted: session unreachable")
            reportSendFailure(String(localized: "iPhone not reachable. Nothing was sent."))
            return
        }

        WatchLogger.shared.info(.treatments, "Carbs of \(amount) g requested for \(date)")

        let message: [String: Any] = [
            WatchMessageKeys.carbs: amount,
            WatchMessageKeys.date: date.timeIntervalSince1970
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            WatchLogger.shared.info(.treatments, "Error sending carbs request: \(error)")
            self.reportSendFailure(String(localized: "Sending to iPhone failed. Please try again."))
        }

        // Display pending communication animation
        showCommsAnimation = true
    }

    /// Shows the failure on the pending screen; without it a request that never left the watch looks sent.
    private func reportSendFailure(_ message: String) {
        DispatchQueue.main.async {
            self.handleAcknowledgment(success: false, message: message)
        }
    }

    /// Sends a request to cancel the current override preset to the paired iPhone
    func sendCancelOverrideRequest() {
        if watchLoopTakes({ $0.setOverride(nil) }) { return }
        guard let session = session, session.isReachable else {
            WatchLogger.shared.warning(.treatments, "Override cancel not sent, phone unreachable")
            return
        }

        WatchLogger.shared.info(.treatments, "Override cancel requested")

        let message: [String: Any] = [
            WatchMessageKeys.cancelOverride: true
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            WatchLogger.shared.error(.treatments, "Sending override cancel failed", error: error)
        }

        // Display pending communication animation
        showCommsAnimation = true
    }

    /// Sends a request to activate an override preset to the paired iPhone
    /// - Parameter presetName: The name of the override preset to activate
    func sendActivateOverrideRequest(presetName: String) {
        if watchLoopTakes({ $0.startOverride(presetName: presetName) }) { return }
        guard let session = session, session.isReachable else {
            WatchLogger.shared.warning(.treatments, "Override request not sent, phone unreachable")
            return
        }

        WatchLogger.shared.info(.treatments, "Override preset \(presetName) requested")

        let message: [String: Any] = [
            WatchMessageKeys.activateOverride: presetName
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            WatchLogger.shared.error(.treatments, "Sending override request failed", error: error)
        }

        // Display pending communication animation
        showCommsAnimation = true
    }

    /// Sends a request to cancel the current temporary target to the paired iPhone
    func sendCancelTempTargetRequest() {
        if watchLoopTakes({ $0.setTempTarget(nil) }) { return }
        guard let session = session, session.isReachable else {
            WatchLogger.shared.warning(.treatments, "Temp target cancel not sent, phone unreachable")
            return
        }

        WatchLogger.shared.info(.treatments, "Temp target cancel requested")

        let message: [String: Any] = [
            WatchMessageKeys.cancelTempTarget: true
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            WatchLogger.shared.error(.treatments, "Sending temp target cancel failed", error: error)
        }

        // Display pending communication animation
        showCommsAnimation = true
    }

    /// Sends a request to activate a temporary target preset to the paired iPhone
    /// - Parameter presetName: The name of the temporary target preset to activate
    func sendActivateTempTargetRequest(presetName: String) {
        if watchLoopTakes({ $0.startTempTarget(presetName: presetName) }) { return }
        guard let session = session, session.isReachable else {
            WatchLogger.shared.warning(.treatments, "Temp target request not sent, phone unreachable")
            return
        }

        WatchLogger.shared.info(.treatments, "Temp target preset \(presetName) requested")

        let message: [String: Any] = [
            WatchMessageKeys.activateTempTarget: presetName
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            WatchLogger.shared.error(.treatments, "Sending temp target request failed", error: error)
        }

        // Display pending communication animation
        showCommsAnimation = true
    }

    /// Sends a request to calculate a bolus recommendation based on the current carbs amount
    func requestBolusRecommendation() {
        guard let session = session, session.isReachable else {
            WatchLogger.shared.warning(.bolus, "Bolus recommendation not requested, phone unreachable")
            return
        }

        WatchLogger.shared.debug(.bolus, "Bolus recommendation requested for \(carbsAmount) g carbs")

        // Show a progress indicator until the phone replies. This keeps the user from
        // tapping the (0 U) "Log Carbs" button before the recommendation has landed.
        DispatchQueue.main.async {
            self.showBolusCalculationProgress = true
        }

        // The phone drops the reply silently if its session is unreachable at reply
        // time, so there is no guaranteed response to clear the flag. Fall back to a
        // timeout that reveals the normal UI.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.showBolusCalculationProgress {
                self.showBolusCalculationProgress = false
            }
        }

        let message: [String: Any] = [
            WatchMessageKeys.requestBolusRecommendation: true,
            WatchMessageKeys.carbs: carbsAmount,
            WatchMessageKeys.useReducedBolus: useReducedBolus,
            WatchMessageKeys.useSuperBolus: useSuperBolus
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            WatchLogger.shared.warning(.bolus, "Requesting bolus recommendation failed", error: error)
            DispatchQueue.main.async {
                self.showBolusCalculationProgress = false
            }
        }
    }

    /// - Parameter completion: Called on the main queue with `true` if the phone answered.
    /// - Returns: `true` if the request was sent.
    @discardableResult func requestWatchStateUpdate(completion: ((_ answered: Bool) -> Void)? = nil) -> Bool {
        guard let session = session else {
            WatchLogger.shared.info(.connectivity, "No session available for state update")
            return false
        }

        guard session.activationState == .activated else {
            WatchLogger.shared.debug(.connectivity, "Session not activated, activating")
            session.activate()
            return false
        }

        if session.isReachable {
            WatchLogger.shared.debug(.data, "Requesting a state update from the phone")

            var message: [String: Any] = [WatchMessageKeys.requestWatchUpdate: WatchMessageKeys.watchState]
            message.merge(glucoseSyncRequestFields()) { _, new in new }

            session.sendMessage(message, replyHandler: { reply in
                DispatchQueue.main.async {
                    // Empty reply: the phone could not build a state.
                    if reply.isEmpty || !self.acceptWatchStatePayload(reply) {
                        self.showSyncingAnimation = false
                    }
                    completion?(true)
                }
            }, errorHandler: { error in
                WatchLogger.shared.info(.connectivity, "Error requesting WatchState update: \(error)")
                DispatchQueue.main.async {
                    self.showSyncingAnimation = false
                    completion?(false)
                }
            })
            return true
        } else {
            WatchLogger.shared.info(.connectivity, "Phone not reachable for WatchState update")
            return false
        }
    }

    /// Snoozes all alarms on the iPhone for the given duration. A duration of 0 ends the snooze.
    func sendSnoozeRequest(minutes: Int) {
        WatchLogger.shared.info(.connectivity, "Sending snooze request: \(minutes) min")

        snoozeUntilDate = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : .distantPast
        WatchNotificationHandler.shared.sendSnoozeRequest(minutes: minutes)
    }
}
