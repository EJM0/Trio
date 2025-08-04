import Foundation

extension TrioRemoteControl {
    func logError(_ errorMessage: String, pushMessage: PushMessage? = nil) async {
        var note = errorMessage
        if let pushMessage = pushMessage {
            note += " Details: \(pushMessage.humanReadableDescription())"

            // Send error notification back to LoopFollow if return info exists
            if let returnInfo = pushMessage.returnNotification {
                await RemoteNotificationResponseManager.shared.sendResponseNotification(
                    to: returnInfo,
                    commandType: pushMessage.commandType,
                    success: false,
                    message: errorMessage
                )
            }
        }
        debug(.remoteControl, note)
        await nightscoutManager.uploadNoteTreatment(note: note)
    }

    func logSuccess(_ message: String, pushMessage: PushMessage) async {
        debug(.remoteControl, message)

        // Send success notification back to LoopFollow if return info exists
        if let returnInfo = pushMessage.returnNotification {
            await RemoteNotificationResponseManager.shared.sendResponseNotification(
                to: returnInfo,
                commandType: pushMessage.commandType,
                success: true,
                message: "\(pushMessage.commandType.description) completed successfully"
            )
        }
    }
}
