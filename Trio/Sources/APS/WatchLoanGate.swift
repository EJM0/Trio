import Foundation
import LoopKit
import Swinject

/// Whether the phone may command the pump. It reads the persisted loan state on every check and fails
/// closed when the file can't be read (V2-15). No file means the phone has never lent and always may.
final class WatchLoanGate {
    private let store: WatchLoanStore<PhoneLoanState>
    // lazy to avoid a cycle: TrioAlertManager checks the gate itself
    private let resolver: Resolver?
    @SyncAccess private var didAlertUnreadable = false

    init(resolver: Resolver? = nil, store: WatchLoanStore<PhoneLoanState> = .phone) {
        self.resolver = resolver
        self.store = store
    }

    var phoneState: PhoneLoanState {
        switch store.load() {
        case let .success(state):
            didAlertUnreadable = false
            return state ?? .initial
        case let .failure(loadError):
            if !didAlertUnreadable {
                didAlertUnreadable = true
                error(.pump, "Pump commands paused: the watch loan state can't be read", error: loadError)
                issueUnreadableAlert()
            }
            return .unreadable
        }
    }

    var phoneMayCommandPump: Bool { phoneState.mayCommandPump }

    /// `action` names the refused command in the log.
    func permits(_ action: String) -> Bool {
        let state = phoneState
        guard !state.mayCommandPump else { return true }
        debug(.pump, "\(action) not sent to the pump: the phone doesn't control it")
        return false
    }

    var refusalMessage: String {
        if case .unreadable = phoneState {
            return String(localized: "Trio couldn't read which device controls your pump, so it won't send pump commands.")
        }
        return String(localized: "Your pump is handed over to Apple Watch, so iPhone won't send pump commands.")
    }

    private func issueUnreadableAlert() {
        let content = Alert.Content(
            title: String(localized: "Trio stopped sending pump commands"),
            body: String(
                localized: "Trio couldn't read which device controls your pump. Your pump finishes any running temp basal and then follows its basal schedule."
            ),
            acknowledgeActionButtonLabel: String(localized: "OK")
        )
        resolver?.resolve(TrioAlertManager.self)?.issueAlert(Alert(
            identifier: Alert.Identifier(managerIdentifier: "trio.watchloan", alertIdentifier: "loanStateUnreadable"),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: .timeSensitive
        ))
    }
}
