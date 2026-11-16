import Foundation
import LoopKit
import Swinject

/// Whether the phone may command the pump. It reads the persisted loan state on every check and fails
/// closed when the file can't be read. No file means the phone has never lent and always may.
final class WatchLoanGate {
    private let store: WatchLoanStore<PhoneLoanState>
    // lazy to avoid a cycle: TrioAlertManager checks the gate itself
    private let resolver: Resolver?
    private let alertLock = NSLock()
    private var didAlertUnreadable = false

    init(resolver: Resolver? = nil, store: WatchLoanStore<PhoneLoanState> = .phone) {
        self.resolver = resolver
        self.store = store
    }

    var phoneState: PhoneLoanState {
        switch store.load() {
        case let .success(state):
            return state ?? .initial
        case let .failure(loadError):
            alertUnreadableOnce(loadError)
            return .unreadable
        }
    }

    var phoneMayCommandPump: Bool { phoneState.mayCommandPump }

    func permits(_ action: String, userInitiated: Bool = false) -> Bool {
        refusal(action, userInitiated: userInitiated) == nil
    }

    /// Nil when the phone may command the pump, otherwise the reason to show. `action` names the command in the log.
    func refusal(_ action: String, userInitiated: Bool = false) -> String? {
        let state = phoneState
        guard !state.mayCommandPump else { return nil }
        if userInitiated {
            info(.pump, "\(action) not sent to the pump: the phone doesn't control it")
        } else {
            debug(.pump, "\(action) not sent to the pump: the phone doesn't control it")
        }
        if case .unreadable = state {
            return String(localized: "Trio couldn't read which device controls your pump, so it won't send pump commands.")
        }
        return String(localized: "Your pump is handed over to Apple Watch, so iPhone won't send pump commands.")
    }

    /// Once per process, so concurrent or flapping reads don't repeat it.
    private func alertUnreadableOnce(_ loadError: Error) {
        alertLock.lock()
        let isFirst = !didAlertUnreadable
        didAlertUnreadable = true
        alertLock.unlock()
        guard isFirst else { return }

        error(.pump, "Pump commands paused: the watch loan state can't be read", error: loadError)
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
