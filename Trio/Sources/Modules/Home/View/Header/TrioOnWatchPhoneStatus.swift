import Foundation
import Observation
import SwiftUI
import Swinject
import WatchConnectivity

/// What the phone shows while Apple Watch has the pump, is getting it, or is giving it back.
struct TrioOnWatchPhoneStatus: Equatable {
    enum Phase: Equatable {
        case home
        /// Home, but the kit refuses the pod after another device used it (P26–P28, P43).
        case podRefused
        case starting
        case startUnconfirmed
        case inControl
        case noUpdates
        case takingBack
        case takingBackStuck
        case unreadable
    }

    /// The phone's grant-unconfirmed timer (P13).
    static let startConfirmTimeout: TimeInterval = 60
    /// The phone's silence alarm (V2-14).
    static let noUpdatesAfter: TimeInterval = 30 * 60
    /// "Last update" turns from fresh to old.
    static let updateAging: TimeInterval = 10 * 60
    /// A take-back still running after this has most likely not reached the pod (P21).
    static let takeBackStuckAfter: TimeInterval = 60

    var phase: Phase = .home
    var lastUpdate: Date?
    var watchReachable = false
    var podRefusesSessions = false

    /// `since` is when the screens first saw the current state.
    static func make(
        state: PhoneLoanState,
        lastBatchAt: Date?,
        since: Date,
        now: Date,
        watchReachable: Bool,
        podRefusesSessions: Bool
    ) -> TrioOnWatchPhoneStatus {
        var status = TrioOnWatchPhoneStatus(
            lastUpdate: lastBatchAt,
            watchReachable: watchReachable,
            podRefusesSessions: podRefusesSessions
        )
        switch state {
        case .home:
            status.phase = podRefusesSessions ? .podRefused : .home
        case .lending:
            status.phase = now.timeIntervalSince(since) >= startConfirmTimeout ? .startUnconfirmed : .starting
        case .lent:
            status.phase = now.timeIntervalSince(lastBatchAt ?? since) >= noUpdatesAfter ? .noUpdates : .inControl
        case .takingBack:
            status.phase = podRefusesSessions || now.timeIntervalSince(since) >= takeBackStuckAfter
                ? .takingBackStuck : .takingBack
        case .unreadable:
            status.phase = .unreadable
        }
        return status
    }

    /// The pill replaces the loop ring in every state but home: the phone's own loop age means nothing then.
    var replacesLoopRing: Bool { phase != .home && phase != .podRefused }
    var showsBanner: Bool { phase != .home }
    var offersTakeBack: Bool {
        switch phase {
        case .inControl,
             .noUpdates,
             .starting,
             .startUnconfirmed,
             .takingBackStuck,
             .unreadable: return true
        case .home,
             .podRefused,
             .takingBack: return false
        }
    }

    var offersUsePod: Bool { podRefusesSessions && (phase == .podRefused || phase == .takingBackStuck) }

    // MARK: Pill (P1)

    struct Pill: Equatable {
        var symbol: String
        var text: String
        var tint: Color
        var accessibilityLabel: String
    }

    func pill(now: Date) -> Pill {
        let age = lastUpdate?.formattedTimeAgo() ?? "--"
        let spokenAge = lastUpdate.map {
            String(
                localized: "last update \($0.formattedSpokenTimeAgo())",
                comment: "Accessibility: age of the last update from Apple Watch"
            )
        } ?? String(localized: "no update yet", comment: "Accessibility: no update from Apple Watch yet")
        switch phase {
        case .home,
             .podRefused:
            return Pill(symbol: "iphone", text: "", tint: .secondary, accessibilityLabel: "")
        case .starting:
            return Pill(
                symbol: "applewatch",
                text: String(localized: "Starting…", comment: "Home pill while Trio on Watch starts"),
                tint: .secondary,
                accessibilityLabel: String(localized: "Trio on Watch is starting", comment: "Accessibility: Home pill")
            )
        case .startUnconfirmed:
            return Pill(
                symbol: "exclamationmark.triangle.fill",
                text: String(localized: "Not confirmed", comment: "Home pill when Apple Watch didn't confirm the start"),
                tint: .orange,
                accessibilityLabel: String(
                    localized: "Apple Watch didn't confirm the start of Trio on Watch",
                    comment: "Accessibility: Home pill"
                )
            )
        case .inControl:
            let old = now.timeIntervalSince(lastUpdate ?? .distantPast) > Self.updateAging
            return Pill(
                symbol: "applewatch",
                text: String(
                    localized: "Watch · \(age)",
                    comment: "Home pill: Apple Watch in control, then the age of its last update"
                ),
                tint: old ? .orange : .loopGreen,
                accessibilityLabel: String(
                    localized: "Apple Watch is in control, \(spokenAge)",
                    comment: "Accessibility: Home pill while Apple Watch is in control"
                )
            )
        case .noUpdates:
            return Pill(
                symbol: "exclamationmark.triangle.fill",
                text: String(
                    localized: "Watch · \(age)",
                    comment: "Home pill: Apple Watch in control, then the age of its last update"
                ),
                tint: .loopRed,
                accessibilityLabel: String(
                    localized: "No updates from Apple Watch, \(spokenAge)",
                    comment: "Accessibility: Home pill when Apple Watch went quiet"
                )
            )
        case .takingBack:
            return Pill(
                symbol: "iphone",
                text: String(localized: "Taking back…", comment: "Home pill while the phone takes the pump back"),
                tint: .secondary,
                accessibilityLabel: String(localized: "Taking back your pump", comment: "Accessibility: Home pill")
            )
        case .takingBackStuck:
            return Pill(
                symbol: "exclamationmark.triangle.fill",
                text: String(localized: "No pump", comment: "Home pill when the take-back can't reach the pump"),
                tint: .loopRed,
                accessibilityLabel: String(localized: "Can't reach your pump", comment: "Accessibility: Home pill")
            )
        case .unreadable:
            return Pill(
                symbol: "exclamationmark.triangle.fill",
                text: String(localized: "Unknown", comment: "Home pill when the loan state can't be read"),
                tint: .loopRed,
                accessibilityLabel: String(
                    localized: "Trio can't tell which device controls your pump",
                    comment: "Accessibility: Home pill"
                )
            )
        }
    }

    // MARK: Banner (P1)

    struct Banner: Equatable {
        var symbol: String
        var title: String
        var subtitle: String
        var tint: Color
        var isCritical: Bool
    }

    func banner(now _: Date) -> Banner {
        let age = lastUpdate?.formattedTimeAgo()
        switch phase {
        case .home:
            return Banner(symbol: "applewatch", title: "", subtitle: "", tint: .secondary, isCritical: false)
        case .podRefused:
            return Banner(
                symbol: "exclamationmark.triangle.fill",
                title: String(localized: "Another Device Used Your Pod", comment: "Home banner title"),
                subtitle: String(localized: "Tap to use the pod on this iPhone.", comment: "Home banner subtitle"),
                tint: .orange,
                isCritical: false
            )
        case .starting:
            return Banner(
                symbol: "applewatch",
                title: String(localized: "Starting Trio on Watch", comment: "Home banner title"),
                subtitle: String(localized: "Keep your iPhone close to your watch.", comment: "Home banner subtitle"),
                tint: .insulin,
                isCritical: false
            )
        case .startUnconfirmed:
            return Banner(
                symbol: "exclamationmark.triangle.fill",
                title: String(localized: "Apple Watch Didn't Confirm", comment: "Home banner title"),
                subtitle: String(localized: "Tap to check, or take back your pump.", comment: "Home banner subtitle"),
                tint: .orange,
                isCritical: false
            )
        case .inControl:
            return Banner(
                symbol: "applewatch",
                title: String(localized: "Apple Watch Is in Control", comment: "Home banner title"),
                subtitle: age.map {
                    String(
                        localized: "Last update \($0) ago. Tap for details.",
                        comment: "Home banner subtitle; the value is an age like 3m"
                    )
                } ?? String(localized: "No update from Apple Watch yet. Tap for details.", comment: "Home banner subtitle"),
                tint: .insulin,
                isCritical: false
            )
        case .noUpdates:
            return Banner(
                symbol: "exclamationmark.triangle.fill",
                title: String(localized: "No Updates from Apple Watch", comment: "Home banner title (G-6a)"),
                subtitle: String(
                    localized: "Trio on Watch hasn't reported for \(age ?? "30m"). Tap to check.",
                    comment: "Home banner subtitle; the value is an age like 34m"
                ),
                tint: .loopRed,
                isCritical: true
            )
        case .takingBack:
            return Banner(
                symbol: "iphone",
                title: String(localized: "Taking Back Your Pump", comment: "Home banner title"),
                subtitle: String(localized: "Keep your iPhone close to your pod.", comment: "Home banner subtitle"),
                tint: .insulin,
                isCritical: false
            )
        case .takingBackStuck:
            return Banner(
                symbol: "exclamationmark.triangle.fill",
                title: String(localized: "Can't Reach Your Pump", comment: "Home banner title"),
                subtitle: String(
                    localized: "Keep your iPhone close to your pod. Nothing is giving insulin automatically.",
                    comment: "Home banner subtitle"
                ),
                tint: .loopRed,
                isCritical: true
            )
        case .unreadable:
            return Banner(
                symbol: "exclamationmark.triangle.fill",
                title: String(localized: "Pump Commands Paused", comment: "Home banner title"),
                subtitle: String(
                    localized: "Trio can't tell which device controls your pump. Tap to take it back.",
                    comment: "Home banner subtitle"
                ),
                tint: .loopRed,
                isCritical: true
            )
        }
    }

    // MARK: Take Back dialog (P3)

    enum TakeBackContext: Equatable {
        case watchReachable
        case watchUnreachable
        case startUnconfirmed
    }

    var takeBackContext: TakeBackContext {
        if phase == .startUnconfirmed || phase == .starting { return .startUnconfirmed }
        return watchReachable ? .watchReachable : .watchUnreachable
    }

    static func takeBackMessage(_ context: TakeBackContext) -> String {
        switch context {
        case .watchReachable:
            return String(
                localized: "Your watch is still running Trio on Watch. Ending it on your watch is safer because your history comes back first. Take back anyway?",
                comment: "Take Back confirmation while the watch is reachable"
            )
        case .watchUnreachable:
            return String(
                localized: "Take back your pump from Apple Watch? Do this if your watch is off, lost or out of battery. If your watch is still running, it stops when it next reaches your pod.",
                comment: "Take Back confirmation while the watch isn't reachable"
            )
        case .startUnconfirmed:
            return String(
                localized: "Your watch didn't confirm the start. Take back your pump on this iPhone?",
                comment: "Take Back confirmation after an unconfirmed start"
            )
        }
    }

    static func takeBackButton(_ context: TakeBackContext) -> String {
        context == .watchReachable
            ? String(localized: "Take Back Anyway", comment: "Take Back confirmation button while the watch is reachable")
            : String(localized: "Take Back Pump", comment: "Take Back confirmation button")
    }
}

/// Polls the loan coordinator for the Home screen. Reads only; the two actions are the user's own taps.
@MainActor @Observable final class TrioOnWatchPhoneModel {
    private(set) var status = TrioOnWatchPhoneStatus()
    private var state: PhoneLoanState = .initial
    private var since = Date()
    @ObservationIgnored private var resolver: Resolver?
    #if DEBUG
        @ObservationIgnored let fixture = TrioOnWatchPhoneFixture.current
    #endif

    func attach(_ resolver: Resolver) {
        self.resolver = resolver
    }

    func refresh(now: Date = Date()) async {
        #if DEBUG
            if let fixture {
                status = fixture.status
                return
            }
        #endif
        guard let coordinator = resolver?.resolve(WatchLoanCoordinator.self) else { return }
        let next = await coordinator.state
        let lastBatchAt = await coordinator.lastBatchAt
        if !Self.sameCase(next, state) { since = now }
        state = next
        let refuses = resolver?.resolve(DeviceDataManager.self).flatMap { WatchLoanPumpAdapter($0.pumpManager) }?
            .refusesSessions ?? false
        let session = WCSession.isSupported() ? WCSession.default : nil
        let updated = TrioOnWatchPhoneStatus.make(
            state: next,
            lastBatchAt: lastBatchAt,
            since: since,
            now: now,
            watchReachable: session?.activationState == .activated && session?.isReachable == true,
            podRefusesSessions: refuses
        )
        if updated != status { status = updated }
    }

    func takeBack() async {
        guard let coordinator = resolver?.resolve(WatchLoanCoordinator.self) else { return }
        await coordinator.takeBack()
        await refresh()
    }

    func usePodOnThisPhone() async {
        guard let coordinator = resolver?.resolve(WatchLoanCoordinator.self) else { return }
        await coordinator.usePodOnThisPhone()
        await refresh()
    }

    private static func sameCase(_ lhs: PhoneLoanState, _ rhs: PhoneLoanState) -> Bool {
        switch (lhs, rhs) {
        case (.home, .home),
             (.lending, .lending),
             (.lent, .lent),
             (.takingBack, .takingBack),
             (.unreadable, .unreadable): return lhs.epoch == rhs.epoch
        default: return false
        }
    }
}
