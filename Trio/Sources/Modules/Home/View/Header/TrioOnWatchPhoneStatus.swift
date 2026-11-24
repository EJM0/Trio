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
    /// The watch's loop age turns from fresh to old.
    static let loopAging: TimeInterval = 10 * 60
    /// A take-back still running after this has most likely not reached the pod (P21).
    static let takeBackStuckAfter: TimeInterval = 60

    var phase: Phase = .home
    var lastUpdate: Date?
    /// The watch's last confirmed loop: what the pill shows, as the watch's own control line does.
    var lastLoop: Date?
    var watchReachable = false
    var podRefusesSessions = false
    /// The phone's pump is a Medtrum patch: the texts say "patch", not "pod".
    var pumpIsPatch = false
    /// The pump is released while this iPhone is home, with no other device seen: it waits for the user to take it.
    var podReleasedAtHome = false
    /// A paired watch with Trio installed: the glucose can be dragged onto it to start.
    var watchAppInstalled = false

    /// Hold and drag the glucose onto the watch: only at home, in a build with Trio on Watch.
    var offersDragToStart: Bool {
        #if TRIO_ON_WATCH
            return phase == .home && watchAppInstalled
        #else
            return false
        #endif
    }

    /// `since` is when the screens first saw the current state.
    static func make(
        state: PhoneLoanState,
        lastBatchAt: Date?,
        lastLoopAt: Date? = nil,
        since: Date,
        now: Date,
        watchReachable: Bool,
        podRefusesSessions: Bool
    ) -> TrioOnWatchPhoneStatus {
        var status = TrioOnWatchPhoneStatus(
            lastUpdate: lastBatchAt,
            lastLoop: lastLoopAt,
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
        /// For large text: the age alone where there is one.
        var compactText: String = ""
    }

    func pill(now: Date) -> Pill {
        var pill = fullPill(now: now)
        let age = lastLoop?.formattedTimeAgo() ?? "--"
        pill.compactText = phase == .inControl || phase == .noUpdates ? age : pill.text
        return pill
    }

    private func fullPill(now: Date) -> Pill {
        let age = lastLoop?.formattedTimeAgo() ?? "--"
        let spokenAge = lastLoop.map {
            String(
                localized: "last loop \($0.formattedSpokenTimeAgo())",
                comment: "Accessibility: age of the last loop on Apple Watch"
            )
        } ?? String(localized: "no loop yet", comment: "Accessibility: no loop on Apple Watch yet")
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
            let old = now.timeIntervalSince(lastLoop ?? .distantPast) > Self.loopAging
            return Pill(
                symbol: "applewatch",
                text: String(
                    localized: "Watch · \(age)",
                    comment: "Home pill: Apple Watch in control, then the age of its last loop"
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
                    comment: "Home pill: Apple Watch in control, then the age of its last loop"
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
                title: podReleasedAtHome
                    ? (
                        pumpIsPatch
                            ? String(
                                localized: "Your Patch Is Released",
                                comment: "Home banner title for a patch released at home"
                            )
                            : String(localized: "Your Pod Is Released", comment: "Home banner title for a pod released at home")
                    )
                    : (
                        pumpIsPatch
                            ? String(localized: "Another Device Used Your Patch", comment: "Home banner title")
                            : String(localized: "Another Device Used Your Pod", comment: "Home banner title")
                    ),
                subtitle: pumpIsPatch ? String(
                    localized: "Tap to use the patch on this iPhone.",
                    comment: "Home banner subtitle"
                ) : String(localized: "Tap to use the pod on this iPhone.", comment: "Home banner subtitle"),
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
                subtitle: pumpIsPatch ? String(
                    localized: "Keep your iPhone close to your patch.",
                    comment: "Home banner subtitle"
                ) : String(localized: "Keep your iPhone close to your pod.", comment: "Home banner subtitle"),
                tint: .insulin,
                isCritical: false
            )
        case .takingBackStuck:
            return Banner(
                symbol: "exclamationmark.triangle.fill",
                title: String(localized: "Can't Reach Your Pump", comment: "Home banner title"),
                subtitle: pumpIsPatch ? String(
                    localized: "Keep your iPhone close to your patch. Nothing is giving insulin automatically.",
                    comment: "Home banner subtitle"
                ) : String(
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

    /// The sheet's line under its title; the banner's "Tap…" hints don't belong there.
    var sheetDetail: String? {
        switch phase {
        case .starting,
             .takingBack,
             .takingBackStuck:
            return banner(now: Date()).subtitle
        case .startUnconfirmed:
            return String(
                localized: "Your iPhone may already have released your pump, and Apple Watch didn't confirm it has it. Nothing may be giving insulin automatically.",
                comment: "Trio on Watch sheet after an unconfirmed start"
            )
        case .unreadable:
            return String(
                localized: "Trio can't tell which device controls your pump, so this iPhone sends no pump commands.",
                comment: "Trio on Watch sheet when the loan state can't be read"
            )
        case .home,
             .inControl,
             .noUpdates,
             .podRefused:
            return nil
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

    static func takeBackMessage(_ context: TakeBackContext, patch: Bool = false) -> String {
        switch context {
        case .watchReachable:
            return String(
                localized: "Your watch is still running Trio on Watch. Ending it on your watch is safer because your history comes back first. Take back anyway?",
                comment: "Take Back confirmation while the watch is reachable"
            )
        case .watchUnreachable:
            return (patch ? String(
                localized: "Take back your pump from Apple Watch? Do this if your watch is off, lost or out of battery. If your watch is still running, end Trio on Watch there as soon as you can: with a patch, your watch may not notice right away that it no longer has the pump.",
                comment: "Take Back confirmation while the watch isn't reachable"
            ) : String(
                localized: "Take back your pump from Apple Watch? Do this if your watch is off, lost or out of battery. If your watch is still running, it stops when it next reaches your pod.",
                comment: "Take Back confirmation while the watch isn't reachable"
            ))
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
        let lastLoopAt = await coordinator.watchLoopAt
        if !Self.sameCase(next, state) { since = now }
        state = next
        let pump = resolver?.resolve(DeviceDataManager.self).flatMap { WatchLoanPumpAdapter($0.pumpManager) }
        // a pump released while the phone is home commands nothing until the user takes it back, as after a refusal
        var releasedAtHome = false
        if case .home = next, pump?.isReleased == true { releasedAtHome = true }
        let refuses = (pump?.refusesSessions ?? false) || releasedAtHome
        let session = WCSession.isSupported() ? WCSession.default : nil
        let updated = TrioOnWatchPhoneStatus.make(
            state: next,
            lastBatchAt: lastBatchAt,
            lastLoopAt: lastLoopAt,
            since: since,
            now: now,
            watchReachable: session?.activationState == .activated && session?.isReachable == true,
            podRefusesSessions: refuses
        )
        var withPump = updated
        withPump.pumpIsPatch = pump?.pluginIdentifier == "Medtrum"
        withPump.podReleasedAtHome = releasedAtHome && pump?.refusesSessions != true
        withPump.watchAppInstalled = session?.isPaired == true && session?.isWatchAppInstalled == true
        if withPump != status { status = withPump }
    }

    /// The phone's drag-to-watch Start: this phone's checks, then the watch's, which then asks for the pump as when
    /// Start is tapped on it.
    func startFromPhone() async -> TrioOnWatchPhoneStart.Answer {
        guard let coordinator = resolver?.resolve(WatchLoanCoordinator.self) else { return .refused(.featureOff) }
        if let refusal = await coordinator.host.startRefusal() { return .refused(refusal) }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            return .watchAsleep
        }
        let answer = await TrioOnWatchPhoneStart.ask(WCSession.default)
        info(.watch, "Drag-to-watch Start: the watch answered \(answer)")
        return answer
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

/// Starting Trio on Watch by dragging the glucose onto the watch on Home.
enum TrioOnWatchPhoneStart {
    enum Answer: Equatable, CustomStringConvertible {
        case requested
        case refused(LoanRefusal)
        /// Trio isn't open on the watch: a live message can't reach it.
        case watchAsleep
        case noAnswer

        var description: String {
            switch self {
            case .requested: return "requested"
            case let .refused(reason): return "refused (\(reason.rawValue))"
            case .watchAsleep: return "not reachable"
            case .noAnswer: return "no answer"
            }
        }
    }

    enum Stage: Equatable {
        case handingOver
        /// The watch has the pump: the check. Its first loop comes with its next sensor reading.
        case done
        case stillWaiting
        case failed(String)
    }

    static let answerTimeout: TimeInterval = 10
    /// After the watch said it asked, how long the phone waits for the request before giving up on it.
    static let requestArrivalTimeout: TimeInterval = 30

    /// What the hand-off card shows. `elapsed` counts from the drop.
    static func stage(
        answer: Answer?,
        phase: TrioOnWatchPhoneStatus.Phase,
        elapsed: TimeInterval,
        patch: Bool
    ) -> Stage {
        guard let answer else { return .handingOver }
        switch answer {
        case let .refused(reason):
            return .failed(refusalText(reason, patch: patch))
        case .watchAsleep:
            return .failed(String(
                localized: "Open Trio on your watch, then drag again.",
                comment: "Drag-to-watch Start: the watch app isn't open"
            ))
        case .noAnswer:
            // the answer can be lost after the watch sent its request: go by the loan state until it is clear
            if phase == .home || phase == .podRefused {
                return elapsed < requestArrivalTimeout ? .handingOver : .failed(String(
                    localized: "Your watch didn't answer. Open Trio on your watch and try again.",
                    comment: "Drag-to-watch Start: no answer from the watch"
                ))
            }
        case .requested:
            break
        }
        switch phase {
        case .inControl,
             .noUpdates:
            return .done
        case .starting:
            return .handingOver
        case .startUnconfirmed:
            return .stillWaiting
        case .home,
             .podRefused:
            return elapsed < requestArrivalTimeout ? .handingOver : .failed(String(
                localized: "Your watch didn't start. Open Trio on your watch to see why.",
                comment: "Drag-to-watch Start: the request never arrived or was turned down"
            ))
        case .takingBack,
             .takingBackStuck:
            return .failed(patch ? String(
                localized: "Your watch couldn't take over, so your iPhone is taking the patch back.",
                comment: "Drag-to-watch Start: the watch rejected the grant"
            ) : String(
                localized: "Your watch couldn't take over, so your iPhone is taking the pod back.",
                comment: "Drag-to-watch Start: the watch rejected the grant"
            ))
        case .unreadable:
            return .failed(String(
                localized: "Trio can't tell which device controls your pump. Open the Trio on Watch screen to check.",
                comment: "Drag-to-watch Start: the loan state can't be read"
            ))
        }
    }

    static func refusalText(_ reason: LoanRefusal, patch: Bool) -> String {
        switch reason {
        case .notClosedLoop:
            return String(localized: "Turn on Closed Loop to start Trio on Watch.", comment: "Drag-to-watch Start refusal")
        case .unsupportedDevice:
            return String(
                localized: "Trio on Watch works with an Omnipod DASH pod or a Medtrum Nano patch, and a Dexcom G7.",
                comment: "Drag-to-watch Start refusal"
            )
        case .cgmNotShared:
            return String(
                localized: "Turn on Read on Apple Watch in your CGM's settings, then try again.",
                comment: "Drag-to-watch Start refusal: the CGM's Read on Apple Watch setting is off"
            )
        case .pumpScreenOpen:
            return String(localized: "Close the pump screen and try again.", comment: "Drag-to-watch Start refusal")
        case .bolusRunning:
            return String(localized: "A bolus is running. Try again when it's finished.", comment: "Drag-to-watch Start refusal")
        case .deliveryUncertain,
             .releaseRefused,
             .unconfirmedCommand:
            return String(
                localized: "Your pump hasn't confirmed its last command. Try again once it has.",
                comment: "Drag-to-watch Start refusal"
            )
        case .pumpStatusStale:
            return patch ? String(
                localized: "Your iPhone hasn't heard from your patch recently. Keep it close and try again.",
                comment: "Drag-to-watch Start refusal"
            ) : String(
                localized: "Your iPhone hasn't heard from your pod recently. Keep it close and try again.",
                comment: "Drag-to-watch Start refusal"
            )
        case .indefiniteOverride:
            return String(
                localized: "End the override that has no end time, or give it one, then try again.",
                comment: "Drag-to-watch Start refusal"
            )
        case .watchBatteryLow:
            return String(localized: "Charge your watch to at least 30 % to start.", comment: "Drag-to-watch Start refusal")
        case .notificationsOff:
            return String(
                localized: "Allow notifications and time-sensitive notifications for Trio on your watch to start.",
                comment: "Drag-to-watch Start refusal"
            )
        case .unsupportedWatch:
            return String(
                localized: "Trio on Watch needs Apple Watch Series 6 or later, or SE (2nd generation) or later.",
                comment: "Drag-to-watch Start refusal"
            )
        case .phoneUnreachable:
            return String(localized: "Bring your watch close and try again.", comment: "Drag-to-watch Start refusal")
        case .versionMismatch:
            return String(
                localized: "Update Trio on your iPhone and watch to the same version.",
                comment: "Drag-to-watch Start refusal"
            )
        case .featureOff:
            return String(
                localized: "This version of Trio doesn't include Trio on Watch.",
                comment: "Drag-to-watch Start refusal"
            )
        case .busy,
             .clockOffset,
             .grantExpired,
             .snapshotIncomplete,
             .staleEpoch,
             .timeZoneMismatch,
             .unknownRequest:
            return String(
                localized: "Your watch can't start right now. Open Trio on your watch to see why.",
                comment: "Drag-to-watch Start refusal"
            )
        }
    }

    /// Asks the watch, live, to start as if Start was tapped on it.
    static func ask(_ session: WCSession) async -> Answer {
        await withCheckedContinuation { continuation in
            let once = OnceGate()
            func finish(_ answer: Answer) {
                if once.pass() { continuation.resume(returning: answer) }
            }
            session.sendMessage([WatchLoanWireKey.startAsk: true], replyHandler: { reply in
                finish(answer(from: reply))
            }, errorHandler: { error in
                warning(.watch, "Drag-to-watch Start: asking the watch failed", error: error)
                finish(.noAnswer)
            })
            DispatchQueue.main.asyncAfter(deadline: .now() + answerTimeout) { finish(.noAnswer) }
        }
    }

    static func answer(from reply: [String: Any]) -> Answer {
        guard let raw = reply[WatchLoanWireKey.startAnswer] as? String else { return .noAnswer }
        if raw == WatchLoanWireKey.startRequested { return .requested }
        return LoanRefusal(rawValue: raw).map { .refused($0) } ?? .noAnswer
    }

    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var passed = false
        func pass() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if passed { return false }
            passed = true
            return true
        }
    }
}
