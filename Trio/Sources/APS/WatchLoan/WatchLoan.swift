import Foundation

/// The not-looping alarms each device arms while nobody may be dosing (V2-12).
enum LoanAlarm: String, Codable, CaseIterable, Equatable, Hashable {
    /// The phone's existing `NotLoopingMonitor`. Armed in every phone state except `lent`.
    case phoneNotLooping
    /// "No updates from Apple Watch" (V2-14). Armed only in `lent`.
    case phoneNoWatchUpdates
    /// The watch's not-looping series (V2-13). Armed from `holding` until `idle`.
    case watchNotLooping

    static func armed(for state: PhoneLoanState) -> Set<LoanAlarm> {
        if case .lent = state { return [.phoneNoWatchUpdates] }
        return [.phoneNotLooping]
    }

    static func armed(for state: WatchLoanState) -> Set<LoanAlarm> {
        switch state {
        case .holding,
             .returning,
             .stopped:
            return [.watchNotLooping]
        case .idle,
             .requesting:
            return []
        }
    }
}

enum LoanAlert: Equatable, Hashable {
    // Phone
    case watchDidNotConfirm
    case startDidNotFinish
    case takeBackPodUnreachable
    case takeBackUseEnd
    case watchStopped
    case watchContactedPodAfterTakeBack
    case unexpectedPodSession
    case auditUnavailable
    case loanStateUnreadable
    // Watch
    case phoneDidNotAnswer
    case startRefused(LoanRefusal)
    case endRefused(LoanRefusal)
    case stopped(WatchStopReason)
    case podUnreachable
}

/// What the host tells the kit after a foreign pod session (C-1).
enum PodSessionVerdict: Equatable, Hashable {
    /// The session is the watch this phone superseded by Take Back. Keep commanding.
    case keepCommanding
    /// Nobody this phone knows of. The kit refuses commands.
    case refuse
}

/// Run in list order. Persist-before-act: a list that changes state persists before any pump action,
/// except finishing a take-back, which acts under the persisted `takingBack` and persists `home` last.
enum WatchLoanEffect<State: Equatable & Hashable>: Equatable, Hashable {
    case persist(State)
    /// Wait for an in-flight loop, pump event storage and bolus to finish (V2-2).
    case awaitPumpIdle
    case cancelTemp
    case refreshDeliveredUnits
    case releaseControl
    case takeControl
    /// Recompute and replace the tagged audit bolus of this loan (V2-8). Idempotent: booked doses of the
    /// loan, including booked intents (C-4), count as expected, so repeating it never books twice.
    case audit(loanEpoch: Int)
    case podSession(PodSessionVerdict)
    case cancelOutstandingTransfers
    case send(WatchLoanMessage)
    case sendStop(WatchLoanStop)
    case arm(LoanAlarm)
    case disarm(LoanAlarm)
    case alert(LoanAlert)
}

typealias PhoneLoanEffect = WatchLoanEffect<PhoneLoanState>
typealias WatchSideLoanEffect = WatchLoanEffect<WatchLoanState>

enum PhoneLoanEvent: Equatable, Hashable {
    case received(WatchLoanMessage)
    case receivedStop(WatchLoanStop)
    /// Results carry the epoch of the state that asked for them, so a late one from an earlier hand-off is ignored.
    case releaseResult(epoch: Int, released: Bool)
    case takeControlResult(epoch: Int, succeeded: Bool)
    /// `WatchLoan.grantConfirmTimeout` after the grant was sent.
    case grantUnconfirmed
    /// `watchAnswer` is the watch's reply to a status query, nil when it didn't answer.
    case takeBackTapped(watchAnswer: WatchLoanState?)
    case foreignPodSession
    case relaunched
}

struct PhoneLoanContext: Equatable {
    var now: Date
    /// Why Start is refused (preconditions or `TRIO_ON_WATCH` off), nil when it may proceed.
    var startRefusal: LoanRefusal?

    init(now: Date, startRefusal: LoanRefusal? = nil) {
        self.now = now
        self.startRefusal = startRefusal
    }
}

enum WatchSideLoanEvent: Equatable, Hashable {
    case startTapped
    case requestTimedOut
    case received(WatchLoanMessage)
    case receivedStop(WatchLoanStop)
    case takeControlResult(succeeded: Bool)
    case endTapped
    case releaseResult(released: Bool)
    case handBackUnacknowledged
    case foreignPodSession
    case stopAcknowledged
    /// `phoneEpoch` is the phone's answer to the relaunch query, nil when it didn't answer (V2-11).
    case relaunched(lastCycleAt: Date, phoneEpoch: Int?, podSessionForeign: Bool)
}

struct WatchSideLoanContext: Equatable {
    /// Watch time corrected by the measured clock offset to the phone.
    var now: Date
    var newRequestID: UUID
    var startRefusal: LoanRefusal?
    var endRefusal: LoanRefusal?
    /// The host's grant validation (snapshot, versions, clock, time zone), nil when it passed.
    var grantRefusal: LoanRefusal?

    init(
        now: Date,
        newRequestID: UUID = UUID(),
        startRefusal: LoanRefusal? = nil,
        endRefusal: LoanRefusal? = nil,
        grantRefusal: LoanRefusal? = nil
    ) {
        self.now = now
        self.newRequestID = newRequestID
        self.startRefusal = startRefusal
        self.endRefusal = endRefusal
        self.grantRefusal = grantRefusal
    }
}

enum WatchLoan {
    /// A grant is valid this long after the phone sent it (V2-1).
    static let grantLifetime: TimeInterval = 30
    /// Upper bound of drain plus release on the phone (V2-2). The phone coordinator enforces it.
    static let phoneWorstCaseLend: TimeInterval = 60
    /// Longer than a worst-case lend plus the grant's lifetime, so a slow lend isn't refused (N-4).
    static let watchRequestTimeout: TimeInterval = 120
    static let grantConfirmTimeout: TimeInterval = 60
    /// How long a superseded watch may still come back (V2-11), and the phone's takeover window (C-1).
    static let resumeWindow: TimeInterval = 6 * 60 * 60

    // MARK: - Phone

    static func decide(
        _ state: PhoneLoanState,
        _ event: PhoneLoanEvent,
        _ context: PhoneLoanContext
    ) -> (PhoneLoanState, [PhoneLoanEffect]) {
        switch event {
        case let .received(message):
            return phoneReceived(state, message, context)

        case let .receivedStop(stop):
            guard stop.kind == .stop else { return (state, []) }
            switch state {
            case let .lending(epoch, _) where epoch == stop.epoch,
                 let .lent(epoch) where epoch == stop.epoch:
                return (state, [.alert(.watchStopped)])
            case let .home(epoch, loan?) where loan.epoch == stop.epoch && loan.supersededUntil != nil:
                let next = PhoneLoanState.home(epoch: epoch, lastLoan: LoanRecord(epoch: loan.epoch))
                return (next, [.persist(next)])
            case let .takingBack(epoch, loan?) where loan.epoch == stop.epoch && loan.supersededUntil != nil:
                let next = PhoneLoanState.takingBack(epoch: epoch, loan: LoanRecord(epoch: loan.epoch))
                return (next, [.persist(next)])
            default:
                return (state, [])
            }

        case let .releaseResult(resultEpoch, released):
            guard case let .lending(epoch, requestID) = state, epoch == resultEpoch else { return (state, []) }
            if released {
                let grant = WatchLoanMessage(
                    epoch: epoch,
                    kind: .grant(requestID: requestID, expiresAt: context.now.addingTimeInterval(grantLifetime))
                )
                return (state, [.send(grant)])
            }
            let next = PhoneLoanState.home(epoch: epoch, lastLoan: nil)
            return (next, [
                .persist(next),
                .send(WatchLoanMessage(epoch: epoch, kind: .refused(requestID: requestID, reason: .releaseRefused)))
            ])

        case let .takeControlResult(resultEpoch, succeeded):
            guard case let .takingBack(epoch, loan) = state, epoch == resultEpoch else { return (state, []) }
            guard succeeded else { return (state, [.alert(.takeBackPodUnreachable)]) }
            let next = PhoneLoanState.home(epoch: epoch, lastLoan: loan)
            let audit: PhoneLoanEffect = loan.map { .audit(loanEpoch: $0.epoch) } ?? .alert(.auditUnavailable)
            return (next, [.cancelTemp, .refreshDeliveredUnits, audit, .persist(next)])

        case .grantUnconfirmed:
            guard case .lending = state else { return (state, []) }
            return (state, [.alert(.watchDidNotConfirm)])

        case let .takeBackTapped(watchAnswer):
            switch state {
            case .home:
                return (state, [])
            case let .lending(epoch, _):
                if watchAnswer == .holding(epoch: epoch) {
                    let (next, effects) = enterLent(from: state, epoch: epoch)
                    return (next, effects + [.alert(.takeBackUseEnd)])
                }
                return startTakeBack(from: state, loan: LoanRecord(
                    epoch: epoch,
                    supersededUntil: context.now.addingTimeInterval(resumeWindow)
                ), newEpoch: epoch + 1)
            case let .lent(epoch):
                return startTakeBack(from: state, loan: LoanRecord(
                    epoch: epoch,
                    supersededUntil: context.now.addingTimeInterval(resumeWindow)
                ), newEpoch: epoch + 1)
            case .takingBack:
                return (state, [.takeControl])
            case .unreadable:
                // The last epoch is lost; seconds since 1970 exceed any epoch reached by counting
                return startTakeBack(
                    from: state,
                    loan: nil,
                    newEpoch: max(1, Int(context.now.timeIntervalSince1970))
                )
            }

        case .foreignPodSession:
            let loan: LoanRecord?
            switch state {
            case let .home(_, lastLoan):
                loan = lastLoan
            case let .takingBack(_, takingBackLoan):
                loan = takingBackLoan
            case .unreadable:
                loan = nil
            case .lending,
                 .lent:
                return (state, [])
            }
            if let loan, let until = loan.supersededUntil, context.now < until {
                return (state, [
                    .podSession(.keepCommanding),
                    .audit(loanEpoch: loan.epoch),
                    .alert(.watchContactedPodAfterTakeBack)
                ])
            }
            var effects: [PhoneLoanEffect] = [.podSession(.refuse)]
            if let loan { effects.append(.audit(loanEpoch: loan.epoch)) }
            effects.append(.alert(.unexpectedPodSession))
            return (state, effects)

        case .relaunched:
            let alarms = PhoneLoanEffect.reassert(LoanAlarm.armed(for: state), of: phoneAlarms)
            switch state {
            case .lending:
                return (state, alarms + [.alert(.startDidNotFinish)])
            case .takingBack:
                // C-3: redo take control; the result redoes cancel temp, refresh and the audit
                return (state, alarms + [.takeControl])
            case .unreadable:
                return (state, alarms + [.alert(.loanStateUnreadable)])
            case .home,
                 .lent:
                return (state, alarms)
            }
        }
    }

    private static let phoneAlarms: [LoanAlarm] = [.phoneNotLooping, .phoneNoWatchUpdates]

    private static func phoneReceived(
        _ state: PhoneLoanState,
        _ message: WatchLoanMessage,
        _ context: PhoneLoanContext
    ) -> (PhoneLoanState, [PhoneLoanEffect]) {
        switch message.kind {
        case let .request(requestID):
            switch state {
            case let .home(epoch, _):
                if let refusal = context.startRefusal {
                    return (state, [.send(WatchLoanMessage(epoch: epoch, kind: .refused(requestID: requestID, reason: refusal)))])
                }
                let next = PhoneLoanState.lending(epoch: max(epoch, message.epoch) + 1, requestID: requestID)
                return (next, [.persist(next), .awaitPumpIdle, .cancelTemp, .refreshDeliveredUnits, .releaseControl])
            case let .lending(_, current) where current == requestID:
                return (state, [])
            default:
                return (state, [.send(WatchLoanMessage(
                    epoch: state.epoch ?? 0,
                    kind: .refused(requestID: requestID, reason: .busy)
                ))])
            }

        case let .grantRejected(requestID, _):
            guard case let .lending(epoch, current) = state, current == requestID else { return (state, []) }
            // N-4: the watch never adopted this grant, so the phone takes the pod back without a tap
            return startTakeBack(from: state, loan: LoanRecord(epoch: epoch), newEpoch: epoch + 1)

        case .holding,
             .records:
            guard case let .lending(epoch, _) = state, epoch == message.epoch else { return (state, []) }
            return enterLent(from: state, epoch: epoch)

        case .handBack:
            switch state {
            case let .lending(epoch, _) where epoch == message.epoch,
                 let .lent(epoch) where epoch == message.epoch:
                let next = PhoneLoanState.takingBack(epoch: epoch + 1, loan: LoanRecord(epoch: epoch))
                let alarms = PhoneLoanEffect.alarmTransition(from: LoanAlarm.armed(for: state), to: LoanAlarm.armed(for: next))
                let ack = WatchLoanMessage(epoch: epoch, kind: .handBackAck)
                let effects: [PhoneLoanEffect] = alarms.arm + [.persist(next)] + alarms.disarm + [.send(ack), .takeControl]
                return (next, effects)
            default:
                guard let epoch = state.epoch, message.epoch < epoch else { return (state, []) }
                return (state, [.send(WatchLoanMessage(epoch: message.epoch, kind: .handBackAck))])
            }

        case .grant,
             .handBackAck,
             .refused,
             .status,
             .statusQuery:
            return (state, [])
        }
    }

    private static func enterLent(from state: PhoneLoanState, epoch: Int) -> (PhoneLoanState, [PhoneLoanEffect]) {
        let next = PhoneLoanState.lent(epoch: epoch)
        let alarms = PhoneLoanEffect.alarmTransition(from: LoanAlarm.armed(for: state), to: LoanAlarm.armed(for: next))
        let effects: [PhoneLoanEffect] = alarms.arm + [.persist(next)] + alarms.disarm
        return (next, effects)
    }

    /// V2-7b: cancel transfers, persist `takingBack`, revoke, take control.
    private static func startTakeBack(
        from state: PhoneLoanState,
        loan: LoanRecord?,
        newEpoch: Int
    ) -> (PhoneLoanState, [PhoneLoanEffect]) {
        let next = PhoneLoanState.takingBack(epoch: newEpoch, loan: loan)
        let alarms = PhoneLoanEffect.alarmTransition(from: LoanAlarm.armed(for: state), to: LoanAlarm.armed(for: next))
        let revoke = WatchLoanStop(kind: .revoke, epoch: newEpoch)
        var effects: [PhoneLoanEffect] = [.cancelOutstandingTransfers]
        effects += alarms.arm + [.persist(next)] + alarms.disarm
        effects += [.sendStop(revoke), .takeControl]
        return (next, effects)
    }

    // MARK: - Watch

    static func decide(
        _ state: WatchLoanState,
        _ event: WatchSideLoanEvent,
        _ context: WatchSideLoanContext
    ) -> (WatchLoanState, [WatchSideLoanEffect]) {
        switch event {
        case .startTapped:
            guard case let .idle(epoch) = state else { return (state, []) }
            if let refusal = context.startRefusal {
                return (state, [.alert(.startRefused(refusal))])
            }
            let next = WatchLoanState.requesting(epoch: epoch, requestID: context.newRequestID)
            return (
                next,
                [.persist(next), .send(WatchLoanMessage(epoch: epoch, kind: .request(requestID: context.newRequestID)))]
            )

        case .requestTimedOut:
            guard case let .requesting(epoch, _) = state else { return (state, []) }
            let next = WatchLoanState.idle(epoch: epoch)
            return (next, [.persist(next), .alert(.phoneDidNotAnswer)])

        case let .received(message):
            return watchReceived(state, message, context)

        case let .receivedStop(stop):
            guard stop.kind == .revoke else { return (state, []) }
            switch state {
            case let .holding(epoch) where stop.epoch > epoch,
                 let .returning(epoch) where stop.epoch > epoch:
                return stopWatch(epoch: epoch, reason: .superseded)
            case let .idle(epoch) where stop.epoch > epoch,
                 let .requesting(epoch, _) where stop.epoch > epoch:
                let next = WatchLoanState.idle(epoch: stop.epoch)
                return (next, [.persist(next)])
            case let .stopped(epoch, _):
                return (state, [.sendStop(WatchLoanStop(kind: .stop, epoch: epoch))])
            default:
                return (state, [])
            }

        case let .takeControlResult(succeeded):
            guard case .holding = state, !succeeded else { return (state, []) }
            return (state, [.alert(.podUnreachable)])

        case .endTapped:
            guard case let .holding(epoch) = state else { return (state, []) }
            if let refusal = context.endRefusal {
                return (state, [.alert(.endRefused(refusal))])
            }
            let next = WatchLoanState.returning(epoch: epoch)
            return (next, [.persist(next), .cancelTemp, .refreshDeliveredUnits, .releaseControl])

        case let .releaseResult(released):
            guard case let .returning(epoch) = state else { return (state, []) }
            if released {
                return (state, [.send(WatchLoanMessage(epoch: epoch, kind: .handBack))])
            }
            let next = WatchLoanState.holding(epoch: epoch)
            return (next, [.persist(next), .alert(.endRefused(.releaseRefused))])

        case .handBackUnacknowledged:
            guard case let .returning(epoch) = state else { return (state, []) }
            return (state, [.send(WatchLoanMessage(epoch: epoch, kind: .handBack))])

        case .foreignPodSession:
            guard case let .holding(epoch) = state else { return (state, []) }
            return stopWatch(epoch: epoch, reason: .foreignSession)

        case .stopAcknowledged:
            guard case let .stopped(epoch, _) = state else { return (state, []) }
            let next = WatchLoanState.idle(epoch: epoch)
            return (next, [.persist(next), .disarm(.watchNotLooping)])

        case let .relaunched(lastCycleAt, phoneEpoch, podSessionForeign):
            let alarms = WatchSideLoanEffect.reassert(LoanAlarm.armed(for: state), of: [.watchNotLooping])
            switch state {
            case let .holding(epoch):
                if let phoneEpoch, phoneEpoch > epoch {
                    return stopWatch(epoch: epoch, reason: .superseded)
                }
                if podSessionForeign {
                    return stopWatch(epoch: epoch, reason: .foreignSession)
                }
                if context.now.timeIntervalSince(lastCycleAt) > resumeWindow {
                    return stopWatch(epoch: epoch, reason: .resumeWindowPassed)
                }
                // A crash may have come between persisting `holding` and taking control
                return (state, alarms + [.takeControl])
            case .returning:
                // V2-3: release again before anything else; the result resends the hand-back
                return (state, alarms + [.releaseControl])
            case let .requesting(epoch, _):
                let next = WatchLoanState.idle(epoch: epoch)
                return (next, alarms + [.persist(next)])
            case .idle,
                 .stopped:
                return (state, alarms)
            }
        }
    }

    private static func watchReceived(
        _ state: WatchLoanState,
        _ message: WatchLoanMessage,
        _ context: WatchSideLoanContext
    ) -> (WatchLoanState, [WatchSideLoanEffect]) {
        switch message.kind {
        case let .grant(requestID, expiresAt):
            func reject(_ reason: LoanRefusal) -> WatchSideLoanEffect {
                .send(WatchLoanMessage(epoch: message.epoch, kind: .grantRejected(requestID: requestID, reason: reason)))
            }
            switch state {
            case let .holding(epoch) where epoch == message.epoch:
                return (state, [.send(WatchLoanMessage(epoch: epoch, kind: .holding))])
            case let .requesting(epoch, current) where current == requestID:
                let refusal: LoanRefusal? = message.epoch <= epoch ? .staleEpoch
                    : context.now >= expiresAt ? .grantExpired
                    : context.grantRefusal
                if let refusal {
                    let next = WatchLoanState.idle(epoch: epoch)
                    return (next, [.persist(next), reject(refusal), .alert(.startRefused(refusal))])
                }
                let next = WatchLoanState.holding(epoch: message.epoch)
                return (next, [
                    .arm(.watchNotLooping),
                    .persist(next),
                    .takeControl,
                    .send(WatchLoanMessage(epoch: message.epoch, kind: .holding))
                ])
            default:
                return (state, [reject(.unknownRequest)])
            }

        case let .refused(requestID, reason):
            guard case let .requesting(epoch, current) = state, current == requestID else { return (state, []) }
            let next = WatchLoanState.idle(epoch: epoch)
            return (next, [.persist(next), .alert(.startRefused(reason))])

        case .handBackAck:
            guard case let .returning(epoch) = state, epoch == message.epoch else { return (state, []) }
            let next = WatchLoanState.idle(epoch: epoch)
            return (next, [.persist(next), .disarm(.watchNotLooping)])

        case .statusQuery:
            return (state, [.send(WatchLoanMessage(epoch: state.epoch, kind: .status(state)))])

        case .grantRejected,
             .handBack,
             .holding,
             .records,
             .request,
             .status:
            return (state, [])
        }
    }

    private static func stopWatch(epoch: Int, reason: WatchStopReason) -> (WatchLoanState, [WatchSideLoanEffect]) {
        let next = WatchLoanState.stopped(epoch: epoch, reason: reason)
        return (next, [
            .arm(.watchNotLooping),
            .persist(next),
            .alert(.stopped(reason)),
            .sendStop(WatchLoanStop(kind: .stop, epoch: epoch))
        ])
    }
}

extension WatchLoanEffect {
    /// Arms go before the persist and disarms after it, so a crash in between leaves an extra alarm, never a missing one.
    static func alarmTransition(from old: Set<LoanAlarm>, to new: Set<LoanAlarm>) -> (arm: [Self], disarm: [Self]) {
        let arm = LoanAlarm.allCases.filter { new.contains($0) && !old.contains($0) }.map { Self.arm($0) }
        let disarm = LoanAlarm.allCases.filter { old.contains($0) && !new.contains($0) }.map { Self.disarm($0) }
        return (arm, disarm)
    }

    /// On relaunch, re-assert every alarm of the device: arm what the state needs, disarm the rest.
    static func reassert(_ armed: Set<LoanAlarm>, of device: [LoanAlarm]) -> [Self] {
        let arm = device.filter { armed.contains($0) }.map { Self.arm($0) }
        let disarm = device.filter { !armed.contains($0) }.map { Self.disarm($0) }
        return arm + disarm
    }
}
