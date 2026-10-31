import Foundation

extension TrioRemoteControl {
    /// While the Apple Watch has the pump the phone doesn't dose: a remote bolus or meal goes on to the watch, which
    /// checks it with its own IOB, history and limits (the phone's are behind) and delivers it; the answer goes back to
    /// the sender. The phone checks what only it knows first (the fat and protein limits). Every other command would
    /// change only the phone and is refused (after Kristin Kandschur's untethered-pr-plus, e3380c504).
    func handleWhileWatchLoops(_ payload: CommandPayload) async {
        switch payload.commandType {
        case .bolus,
             .meal:
            await forwardToWatch(payload)
        default:
            await logError(
                "Command rejected: the Apple Watch is running the loop. Only boluses and meals reach it.",
                payload: payload,
                ack: RemoteCommandAck(commandId: payload.commandId, mealId: payload.mealId, result: .rejected)
            )
        }
    }

    private func forwardToWatch(_ payload: CommandPayload) async {
        let isMeal = payload.commandType == .meal
        let carbs = isMeal ? payload.carbs.map { Decimal($0) } : nil
        let fat = isMeal ? payload.fat.map { Decimal($0) } : nil
        let protein = isMeal ? payload.protein.map { Decimal($0) } : nil
        if isMeal {
            guard carbs != nil || fat != nil || protein != nil else {
                return await logError("Command rejected: meal data is incomplete or invalid.", payload: payload)
            }
            let limits = settings.settings
            if let fat, fat > limits.maxFat {
                return await logError(
                    "Command rejected: fat amount (\(fat)g) exceeds the maximum allowed (\(limits.maxFat)g).",
                    payload: payload
                )
            }
            if let protein, protein > limits.maxProtein {
                return await logError(
                    "Command rejected: protein amount (\(protein)g) exceeds the maximum allowed (\(limits.maxProtein)g).",
                    payload: payload
                )
            }
        } else {
            guard let amount = payload.bolusAmount, amount > 0 else {
                return await logError("Command rejected: bolus amount is missing or invalid.", payload: payload)
            }
        }
        guard let watchLoop = TrioApp.resolver.resolve(WatchLoopPhoneManager.self) else {
            return await logError("Command rejected: the Apple Watch is running the loop and can't be reached.", payload: payload)
        }
        let treatment = WatchLoopRemoteTreatment(
            id: UUID(),
            sentAt: Date(timeIntervalSince1970: payload.timestamp),
            bolus: payload.bolusAmount,
            carbs: carbs,
            fat: fat,
            protein: protein,
            carbsDate: payload.scheduledTime.map { Date(timeIntervalSince1970: $0) },
            mealID: payload.mealId
        )
        let answer = await watchLoop.forwardRemoteTreatment(treatment) { [weak self] late in
            Task { await self?.reportWatchAnswer(late, payload: payload, late: true) }
        }
        await reportWatchAnswer(answer, payload: payload, late: false)
    }

    private func reportWatchAnswer(_ answer: WatchLoopRemoteAnswer, payload: CommandPayload, late: Bool) async {
        switch answer {
        case let .delivered(message):
            await logSuccess(
                "Remote command processed on the Apple Watch\(late ? " (late answer)" : ""). \(payload.humanReadableDescription())",
                payload: payload,
                customNotificationMessage: message
            )
        case let .refused(message):
            await logError(message, payload: payload)
        case .noAnswer:
            // not a failure: the watch may still get it, and acts on it until the command is 10 minutes old
            await logError(
                "No answer from the Apple Watch yet. It may still deliver this within 10 minutes of sending: check IOB before sending again.",
                payload: payload
            )
        }
    }
}
