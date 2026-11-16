import Foundation

@testable import Trio

/// Phone and watch running `WatchLoan.decide`, joined by lossy, reorderable inboxes, and one pod both kits talk to.
/// Cancelling transfers cancels nothing here, so messages already sent can still arrive. Effects are applied in list
/// order; pump results come back as pending events. Alarms are OS-held and kit state is persisted, so both survive
/// a crash.
struct LoanWorld: Hashable {
    enum Device: Hashable { case phone, watch }

    enum Pending: Hashable {
        case release(epoch: Int64)
        case take(epoch: Int64, until: Date?)
        case adopt
    }

    /// A pump driver as the kit review describes it. A take handshakes at once and lifts any refusal, so the pod's
    /// session moves to this controller without a detection. Any other controller's next session then sees a foreign
    /// session: inside its superseding window it keeps commanding, otherwise it refuses before sending anything.
    /// An adopt accepts only the session the lender released: if the lender has taken the pod since, it is foreign.
    struct Kit: Hashable {
        var hasControl: Bool
        var refuses = false
        var supersedingUntil: Date?

        func isSuperseding(at now: Date) -> Bool { supersedingUntil.map { now < $0 } ?? false }
    }

    var phone = PhoneLoanState.initial
    var phoneDisk: PhoneLoanState?
    var watch = WatchLoanState.initial
    var watchDisk: WatchLoanState?
    var phoneAlarms = LoanAlarm.armed(for: PhoneLoanState.initial)
    var watchAlarms = Set<LoanAlarm>()
    var phoneKit = Kit(hasControl: true)
    var watchKit = Kit(hasControl: false)
    var podSessionHolder = Device.phone
    var toPhone: [WatchLoanMessage] = []
    var toWatch: [WatchLoanMessage] = []
    var stopsToPhone: [WatchLoanStop] = []
    var stopsToWatch: [WatchLoanStop] = []
    var phonePending: [Pending] = []
    var watchPending: [Pending] = []
    var requestCount = 0
    var violations: [String] = []
    /// Effects of the last event, so a search only crashes inside lists that exist. Cleared before hashing.
    var lastEffectCount = 0

    static let now = LoanFixture.now

    // MARK: Invariants

    /// The gates read the persisted state, so a decision counts once it is on disk.
    var phoneOnDisk: PhoneLoanState { phoneDisk ?? .initial }
    var watchOnDisk: WatchLoanState { watchDisk ?? .initial }

    /// Its gate lets it command and its kit's next session would go through.
    func commands(_ device: Device) -> Bool {
        let (permits, kit) = device == .phone
            ? (phoneOnDisk.mayCommandPump, phoneKit)
            : (watchOnDisk.mayCommandPump, watchKit)
        return permits && kit.hasControl && !kit.refuses && (podSessionHolder == device || kit.isSuperseding(at: Self.now))
    }

    var nobodyMayDose: Bool { !commands(.phone) && !commands(.watch) }

    mutating func check(_ label: @autoclosure () -> String) {
        if commands(.phone), commands(.watch) {
            violations.append("\(label()): two commanders (\(phoneOnDisk), \(watchOnDisk), pod session \(podSessionHolder))")
        }
        if nobodyMayDose, phoneAlarms.isEmpty, watchAlarms.isEmpty {
            violations.append("\(label()): nobody doses and no not-looping alarm is armed (\(phoneOnDisk), \(watchOnDisk))")
        }
        switch watchOnDisk {
        case .holding,
             .returning:
            if !watchAlarms.contains(.watchNotLooping) {
                violations.append("\(label()): watch \(watchOnDisk) without its not-looping alarm")
            }
        default:
            break
        }
    }

    // MARK: Events

    /// Applies `event`; with `crashAfter`, only that many effects run before the device crashes and relaunches.
    mutating func onPhone(_ event: PhoneLoanEvent, crashAfter: Int? = nil) {
        let (next, effects) = WatchLoan.decide(phone, event, PhoneLoanContext(now: Self.now))
        phone = next
        run(effects.map { AnyEffect.phone($0) }, on: .phone, crashAfter: crashAfter, label: "\(event)")
    }

    mutating func onWatch(_ event: WatchSideLoanEvent, crashAfter: Int? = nil) {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", requestCount + 1))!
        if event == .startTapped { requestCount += 1 }
        let (next, effects) = WatchLoan.decide(watch, event, WatchSideLoanContext(now: Self.now, newRequestID: id))
        watch = next
        run(effects.map { AnyEffect.watch($0) }, on: .watch, crashAfter: crashAfter, label: "\(event)")
    }

    mutating func crash(_ device: Device, phoneAnswers: Bool = true) {
        switch device {
        case .phone:
            phone = phoneDisk ?? .initial
            phonePending = []
            onPhone(.relaunched)
        case .watch:
            watch = watchDisk ?? .initial
            watchPending = []
            onWatch(.relaunched(
                lastCycleAt: Self.now,
                phoneEpoch: phoneAnswers ? phoneOnDisk.epoch : nil,
                podSessionForeign: watchKit.refuses,
                kitHasControl: watchKit.hasControl
            ))
        }
    }

    /// The phone's state file becomes unreadable, and the phone relaunches on it.
    mutating func corruptPhoneFile() {
        phoneDisk = .unreadable
        phone = .unreadable
        phonePending = []
        onPhone(.relaunched)
    }

    /// The kit talks to the pod (a command or a status read). A foreign session is reported to the host.
    mutating func session(_ device: Device) {
        var kit = device == .phone ? phoneKit : watchKit
        guard kit.hasControl, !kit.refuses, podSessionHolder != device else { return }
        if kit.isSuperseding(at: Self.now) {
            podSessionHolder = device
        } else {
            kit.refuses = true
        }
        if device == .phone { phoneKit = kit } else { watchKit = kit }
        if device == .phone { onPhone(.foreignPodSession) } else { onWatch(.foreignPodSession) }
    }

    // MARK: Delivery

    mutating func deliverToPhone(_ index: Int = 0, crashAfter: Int? = nil) {
        onPhone(.received(toPhone.remove(at: index)), crashAfter: crashAfter)
    }

    mutating func deliverToWatch(_ index: Int = 0, crashAfter: Int? = nil) {
        onWatch(.received(toWatch.remove(at: index)), crashAfter: crashAfter)
    }

    mutating func deliverStopToPhone(_ index: Int = 0, crashAfter: Int? = nil) {
        onPhone(.receivedStop(stopsToPhone.remove(at: index)), crashAfter: crashAfter)
    }

    mutating func deliverStopToWatch(_ index: Int = 0, crashAfter: Int? = nil) {
        onWatch(.receivedStop(stopsToWatch.remove(at: index)), crashAfter: crashAfter)
    }

    mutating func completePhone(_ index: Int = 0, succeeded: Bool = true, crashAfter: Int? = nil) {
        let pending = phonePending.remove(at: index)
        if succeeded { complete(pending, on: .phone) }
        switch pending {
        case let .release(epoch): onPhone(.releaseResult(epoch: epoch, released: succeeded), crashAfter: crashAfter)
        case let .take(epoch, _): onPhone(.takeControlResult(epoch: epoch, succeeded: succeeded), crashAfter: crashAfter)
        case .adopt: break
        }
    }

    mutating func completeWatch(_ index: Int = 0, succeeded: Bool = true, crashAfter: Int? = nil) {
        let pending = watchPending.remove(at: index)
        if pending == .adopt, succeeded, phoneKit.hasControl {
            // The phone took the pod after releasing it: the adopt sees a newer session and refuses
            watchKit.hasControl = true
            watchKit.refuses = true
            onWatch(.foreignPodSession)
            onWatch(.takeControlResult(succeeded: false), crashAfter: crashAfter)
            return
        }
        if succeeded { complete(pending, on: .watch) }
        switch pending {
        case .release: onWatch(.releaseResult(released: succeeded), crashAfter: crashAfter)
        case .adopt,
             .take: onWatch(.takeControlResult(succeeded: succeeded), crashAfter: crashAfter)
        }
    }

    private mutating func complete(_ pending: Pending, on device: Device) {
        var kit = device == .phone ? phoneKit : watchKit
        switch pending {
        case .release:
            kit.hasControl = false
        case .adopt:
            kit.hasControl = true
            kit.refuses = false
            podSessionHolder = device
        case let .take(_, until):
            kit.hasControl = true
            kit.refuses = false
            // A take without a window never ends an existing one
            kit.supersedingUntil = until ?? kit.supersedingUntil
            podSessionHolder = device
        }
        if device == .phone { phoneKit = kit } else { watchKit = kit }
        check("\(device) kit \(pending)")
    }

    /// Delivers everything in a fixed order until nothing is left.
    mutating func settle() {
        for _ in 0 ..< 100 {
            if !phonePending.isEmpty { completePhone() }
            else if !watchPending.isEmpty { completeWatch() }
            else if !toPhone.isEmpty { deliverToPhone() }
            else if !toWatch.isEmpty { deliverToWatch() }
            else if !stopsToPhone.isEmpty { deliverStopToPhone() }
            else if !stopsToWatch.isEmpty { deliverStopToWatch() }
            else { return }
        }
        violations.append("settle did not finish")
    }

    /// What the user, timers and both kits' next pod contact do after a fault, in doc order.
    mutating func recover() {
        settle()
        if case .requesting = watch { onWatch(.requestTimedOut) }
        if case .returning = watch { onWatch(.handBackUnacknowledged) }
        if case let .lending(epoch, _) = phone, watch == .holding(epoch: epoch) {
            toPhone.append(WatchLoanMessage(epoch: epoch, kind: .records))
        }
        settle()
        if case .lending = phone {
            onPhone(.grantUnconfirmed)
            let answer = watch
            onPhone(.takeBackTapped(watchAnswer: answer))
        }
        settle()
        if case .takingBack = phone, phonePending.isEmpty { onPhone(.takeBackTapped(watchAnswer: nil)) }
        settle()
        session(.watch)
        settle()
        session(.phone)
        settle()
        if case .stopped = watch { onWatch(.stopAcknowledged) }
        if case .home = phone, phoneKit.refuses { onPhone(.usePodOnThisPhoneConfirmed) }
        settle()
    }

    /// One commander whose kit holds the pod, or the phone home with the watch out, and alarms matching both states.
    var isSettledAndConsistent: Bool {
        let owner: Bool
        switch (phone, watch) {
        case let (.lent(epoch), .holding(watchEpoch)): owner = epoch == watchEpoch && commands(.watch) && !phoneKit.hasControl
        case (.home, .idle): owner = commands(.phone) && !watchKit.hasControl
        default: owner = false
        }
        return owner && toPhone.isEmpty && toWatch.isEmpty && phonePending.isEmpty && watchPending.isEmpty
            && phoneAlarms == LoanAlarm.armed(for: phone) && watchAlarms == LoanAlarm.armed(for: watch)
    }

    // MARK: Effects

    private enum AnyEffect {
        case phone(PhoneLoanEffect)
        case watch(WatchSideLoanEffect)
    }

    private mutating func run(_ effects: [AnyEffect], on device: Device, crashAfter: Int?, label: @autoclosure () -> String) {
        lastEffectCount = effects.count
        for (index, effect) in effects.enumerated() {
            if let crashAfter, index == crashAfter {
                check("\(label()), crash after \(index) effects")
                crash(device)
                return
            }
            apply(effect)
            check("\(label()), effect \(index)")
        }
        if let crashAfter, crashAfter >= effects.count {
            crash(device)
        }
        check(label())
    }

    private mutating func apply(_ effect: AnyEffect) {
        switch effect {
        case let .phone(effect):
            switch effect {
            case let .persist(state): phoneDisk = state
            case .releaseControl: phonePending.append(.release(epoch: phone.epoch ?? 0))
            case let .takeControl(until): phonePending.append(.take(epoch: phone.epoch ?? 0, until: until))
            case .podSession(.refuse): phoneKit.refuses = true
            case let .send(message): toWatch.append(message)
            case let .sendStop(stop): stopsToWatch.append(stop)
            case let .arm(alarm): phoneAlarms.insert(alarm)
            case let .disarm(alarm): phoneAlarms.remove(alarm)
            default: break
            }
        case let .watch(effect):
            switch effect {
            case let .persist(state): watchDisk = state
            case .releaseControl: watchPending.append(.release(epoch: watch.epoch))
            case let .takeControl(until): watchPending.append(.take(epoch: watch.epoch, until: until))
            case .adoptControl: watchPending.append(.adopt)
            case let .send(message): toPhone.append(message)
            case let .sendStop(stop): stopsToPhone.append(stop)
            case let .arm(alarm): watchAlarms.insert(alarm)
            case let .disarm(alarm): watchAlarms.remove(alarm)
            default: break
            }
        }
    }

    // MARK: Shapes for assertions

    enum PhoneKind: Hashable { case home, lending, lent, takingBack, unreadable }
    enum WatchKind: Hashable { case idle, requesting, holding, returning, stopped }

    var phoneKind: PhoneKind {
        switch phone {
        case .home: return .home
        case .lending: return .lending
        case .lent: return .lent
        case .takingBack: return .takingBack
        case .unreadable: return .unreadable
        }
    }

    var watchKind: WatchKind {
        switch watch {
        case .idle: return .idle
        case .requesting: return .requesting
        case .holding: return .holding
        case .returning: return .returning
        case .stopped: return .stopped
        }
    }

    /// A world with phone `lent(1)` and watch `holding(1)`, reached by a clean Start.
    static func lent() -> LoanWorld {
        var world = LoanWorld()
        world.onWatch(.startTapped)
        world.settle()
        return world
    }
}
