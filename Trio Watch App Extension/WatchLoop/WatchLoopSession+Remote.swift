import Foundation
import WatchKit

/// A remote bolus or meal (LoopFollow, Nightscout) the phone passed on while the watch has the pump: checked as the
/// phone checks one, with the watch's own IOB and history, which are the current ones now (after Kristin Kandschur's
/// untethered-pr-plus, e3380c504).
extension WatchLoopSession {
    static let remoteMealNote = "📡"
    private static let handledRemoteKey = "watchLoop.handledRemoteTreatments"

    func handleRemoteTreatment(_ treatment: WatchLoopRemoteTreatment) async {
        // sent twice, live and queued: the second copy, even in a new process, finds the first handled
        guard Self.claimRemoteTreatment(treatment.id) else { return }
        WatchLogger.shared.info(.treatments, "Watch Loop remote command: \(treatment.summary)")
        func answer(_ delivered: Bool, _ message: String) {
            WatchLogger.shared.info(.treatments, "Watch Loop remote command \(delivered ? "done" : "refused"): \(message)")
            send(.remoteTreatmentResult(id: treatment.id, delivered: delivered, message: message))
        }
        func refuse(_ reason: String) {
            answer(false, reason)
            notify(String(localized: "Remote Command Refused"), reason)
        }
        let now = Date()
        guard state.phase == .active, pumpManager != nil, let grant = state.grant else {
            return refuse(String(localized: "Command rejected: the Apple Watch doesn't have the pump right now."))
        }
        if let reason = treatment.ageRejection(now: now) { return refuse(reason) }

        let carbs = treatment.carbs ?? 0, fat = treatment.fat ?? 0, protein = treatment.protein ?? 0
        let isMeal = carbs > 0 || fat > 0 || protein > 0
        if isMeal {
            if carbs > grant.maxCarbs {
                return refuse(String(
                    localized: "Command rejected: carbs amount (\(carbs.description)g) exceeds the maximum allowed (\(grant.maxCarbs.description)g)."
                ))
            }
            // as the phone: only entries already in the past can mean the command is a replay
            if state.allCarbs
                .contains(where: { ($0.actualDate ?? $0.createdAt) > treatment.sentAt && ($0.actualDate ?? $0.createdAt) <= now
                })
            {
                return refuse(
                    String(localized: "Command rejected: newer carb entries have been logged since the command was sent.")
                )
            }
            addCarbs(
                carbs,
                fat: fat,
                protein: protein,
                at: treatment.carbsDate ?? now,
                note: Self.remoteMealNote,
                id: treatment.mealID
            )
        }
        guard let units = treatment.bolus, units > 0 else {
            notify(String(localized: "Remote Meal Logged"), treatment.summary)
            return answer(true, String(localized: "Meal logged on the Apple Watch"))
        }
        // as the phone, after the meal is logged: the bolus is checked on its own
        if let reason = WatchLoopRemoteTreatment.bolusRejection(
            units,
            sentAt: treatment.sentAt,
            now: now,
            maxBolus: grant.maxBolus,
            maxIOB: grant.preferences.clamped(for: grant.dosingMode).maxIOB,
            iob: state.lastDetermination?.iob,
            iobAt: state.lastLoopAt,
            history: state.pumpHistory
        ) {
            return refuse(isMeal ? String(localized: "Meal logged, bolus not given. \(reason)") : reason)
        }
        if let failure = await bolus(NSDecimalNumber(decimal: units).doubleValue) {
            notify(String(localized: "Remote Bolus Failed"), failure)
            return answer(false, failure)
        }
        notify(String(localized: "Remote Bolus Started"), String(localized: "\(units.formatted()) U is being delivered."))
        WKInterfaceDevice.current().play(.notification)
        answer(true, String(localized: "Bolus started on the Apple Watch"))
    }

    /// Remembered across relaunches for as long as a command can be acted on: the queued copy may wake a new process.
    private static func claimRemoteTreatment(_ id: UUID) -> Bool {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        var handled = (defaults.dictionary(forKey: handledRemoteKey) as? [String: Double] ?? [:])
            .filter { now - $0.value < WatchLoopRemoteTreatment.window * 2 }
        guard handled[id.uuidString] == nil else { return false }
        handled[id.uuidString] = now
        defaults.set(handled, forKey: handledRemoteKey)
        return true
    }
}
