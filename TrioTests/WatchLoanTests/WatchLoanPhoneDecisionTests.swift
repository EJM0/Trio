import Foundation
import Testing

@testable import Trio

enum LoanFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let requestA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let requestB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let phone = PhoneLoanContext(now: now)
    static let window = now.addingTimeInterval(WatchLoan.resumeWindow)

    static func message(_ epoch: Int, _ kind: WatchLoanMessage.Kind) -> WatchLoanMessage {
        WatchLoanMessage(epoch: epoch, kind: kind)
    }
}

/// One test per phone row of `docs/trio-on-watch/architecture/watch-loan-decision-table.md`.
@Suite("Watch loan: phone decision table") struct WatchLoanPhoneDecisionTests {
    typealias F = LoanFixture

    private func decide(_ state: PhoneLoanState, _ event: PhoneLoanEvent, _ context: PhoneLoanContext = F.phone)
        -> (PhoneLoanState, [PhoneLoanEffect])
    {
        WatchLoan.decide(state, event, context)
    }

    @Test("P1 home + request: persist lending, then drain, cancel temp, refresh, release") func p1() {
        let (state, effects) = decide(.home(epoch: 3, lastLoan: nil), .received(F.message(3, .request(requestID: F.requestA))))
        let lending = PhoneLoanState.lending(epoch: 4, requestID: F.requestA)
        #expect(state == lending)
        #expect(effects == [.persist(lending), .awaitPumpIdle, .cancelTemp, .refreshDeliveredUnits, .releaseControl])
    }

    @Test("P2 home + request while Start is refused (incl. TRIO_ON_WATCH off): refuse, stay home") func p2() {
        for refusal in [LoanRefusal.featureOff, .bolusRunning, .pumpStatusStale] {
            let home = PhoneLoanState.home(epoch: 3, lastLoan: nil)
            let (state, effects) = decide(
                home,
                .received(F.message(3, .request(requestID: F.requestA))),
                PhoneLoanContext(now: F.now, startRefusal: refusal)
            )
            #expect(state == home)
            #expect(effects == [.send(F.message(3, .refused(requestID: F.requestA, reason: refusal)))])
        }
    }

    @Test("P3 home + request with a higher watch epoch: the new epoch exceeds both") func p3() {
        let (state, _) = decide(.home(epoch: 2, lastLoan: nil), .received(F.message(7, .request(requestID: F.requestA))))
        #expect(state == .lending(epoch: 8, requestID: F.requestA))
    }

    @Test("P4 lending + duplicate request: no-op") func p4() {
        let lending = PhoneLoanState.lending(epoch: 4, requestID: F.requestA)
        let (state, effects) = decide(lending, .received(F.message(3, .request(requestID: F.requestA))))
        #expect(state == lending)
        #expect(effects.isEmpty)
    }

    @Test("P5 not home + another request: refuse as busy") func p5() {
        for busy in [
            PhoneLoanState.lent(epoch: 4),
            .takingBack(epoch: 5, loan: LoanRecord(epoch: 4)),
            .lending(epoch: 4, requestID: F.requestA)
        ] {
            let (state, effects) = decide(busy, .received(F.message(4, .request(requestID: F.requestB))))
            #expect(state == busy)
            #expect(effects == [.send(F.message(busy.epoch ?? 0, .refused(requestID: F.requestB, reason: .busy)))])
        }
    }

    @Test("P6 lending + released: send the grant, expiring 30 s from now") func p6() {
        let lending = PhoneLoanState.lending(epoch: 4, requestID: F.requestA)
        let (state, effects) = decide(lending, .releaseResult(epoch: 4, released: true))
        #expect(state == lending)
        #expect(effects == [.send(F.message(4, .grant(requestID: F.requestA, expiresAt: F.now.addingTimeInterval(30))))])
    }

    @Test("P7 lending + release refused: back home, refuse Start") func p7() {
        let (state, effects) = decide(.lending(epoch: 4, requestID: F.requestA), .releaseResult(epoch: 4, released: false))
        let home = PhoneLoanState.home(epoch: 4, lastLoan: nil)
        #expect(state == home)
        #expect(effects == [.persist(home), .send(F.message(4, .refused(requestID: F.requestA, reason: .releaseRefused)))])
    }

    @Test("P8 lending + holding: lent; arm the watch-silence alarm before persist, disarm not-looping after") func p8() {
        let (state, effects) = decide(.lending(epoch: 4, requestID: F.requestA), .received(F.message(4, .holding)))
        #expect(state == .lent(epoch: 4))
        #expect(effects == [.arm(.phoneNoWatchUpdates), .persist(.lent(epoch: 4)), .disarm(.phoneNotLooping)])
    }

    @Test("P9 lending + record batch (holding lost): lent") func p9() {
        let (state, effects) = decide(.lending(epoch: 4, requestID: F.requestA), .received(F.message(4, .records)))
        #expect(state == .lent(epoch: 4))
        #expect(effects == [.arm(.phoneNoWatchUpdates), .persist(.lent(epoch: 4)), .disarm(.phoneNotLooping)])
    }

    @Test("P10 lending + holding of another epoch: ignored") func p10() {
        let lending = PhoneLoanState.lending(epoch: 4, requestID: F.requestA)
        let (state, effects) = decide(lending, .received(F.message(3, .holding)))
        #expect(state == lending)
        #expect(effects.isEmpty)
    }

    @Test("P11 lending + grantRejected (N-4): take the pod back without a tap, no takeover context") func p11() {
        let (state, effects) = decide(
            .lending(epoch: 4, requestID: F.requestA),
            .received(F.message(4, .grantRejected(requestID: F.requestA, reason: .grantExpired)))
        )
        let takingBack = PhoneLoanState.takingBack(epoch: 5, loan: LoanRecord(epoch: 4))
        #expect(state == takingBack)
        #expect(effects == [
            .cancelOutstandingTransfers,
            .persist(takingBack),
            .sendStop(WatchLoanStop(kind: .revoke, epoch: 5)),
            .takeControl
        ])
    }

    @Test("P12 lending + grantRejected for another request: ignored") func p12() {
        let lending = PhoneLoanState.lending(epoch: 4, requestID: F.requestA)
        let (state, effects) = decide(
            lending,
            .received(F.message(4, .grantRejected(requestID: F.requestB, reason: .unknownRequest)))
        )
        #expect(state == lending)
        #expect(effects.isEmpty)
    }

    @Test("P13 lending + grant unconfirmed: alert, no takeover") func p13() {
        let lending = PhoneLoanState.lending(epoch: 4, requestID: F.requestA)
        let (state, effects) = decide(lending, .grantUnconfirmed)
        #expect(state == lending)
        #expect(effects == [.alert(.watchDidNotConfirm)])
    }

    @Test("P14 lending + Take Back, watch answers holding: lent, point to End") func p14() {
        let (state, effects) = decide(
            .lending(epoch: 4, requestID: F.requestA),
            .takeBackTapped(watchAnswer: .holding(epoch: 4))
        )
        #expect(state == .lent(epoch: 4))
        #expect(effects == [
            .arm(.phoneNoWatchUpdates),
            .persist(.lent(epoch: 4)),
            .disarm(.phoneNotLooping),
            .alert(.takeBackUseEnd)
        ])
    }

    @Test("P15 lending + Take Back, watch silent or not holding: take back with a 6 h takeover context") func p15() {
        for answer in [nil, WatchLoanState.idle(epoch: 3), .requesting(epoch: 3, requestID: F.requestA)] {
            let (state, effects) = decide(.lending(epoch: 4, requestID: F.requestA), .takeBackTapped(watchAnswer: answer))
            let takingBack = PhoneLoanState.takingBack(epoch: 5, loan: LoanRecord(epoch: 4, supersededUntil: F.window))
            #expect(state == takingBack)
            #expect(effects == [
                .cancelOutstandingTransfers,
                .persist(takingBack),
                .sendStop(WatchLoanStop(kind: .revoke, epoch: 5)),
                .takeControl
            ])
        }
    }

    @Test("P16 lent + Take Back (V2-7b step 1-2): cancel transfers, persist, revoke, take control") func p16() {
        let (state, effects) = decide(.lent(epoch: 4), .takeBackTapped(watchAnswer: nil))
        let takingBack = PhoneLoanState.takingBack(epoch: 5, loan: LoanRecord(epoch: 4, supersededUntil: F.window))
        #expect(state == takingBack)
        #expect(effects == [
            .cancelOutstandingTransfers,
            .arm(.phoneNotLooping),
            .persist(takingBack),
            .disarm(.phoneNoWatchUpdates),
            .sendStop(WatchLoanStop(kind: .revoke, epoch: 5)),
            .takeControl
        ])
    }

    @Test("P17 lent + hand-back: persist takingBack, ack, then take control; no takeover context") func p17() {
        let (state, effects) = decide(.lent(epoch: 4), .received(F.message(4, .handBack)))
        let takingBack = PhoneLoanState.takingBack(epoch: 5, loan: LoanRecord(epoch: 4))
        #expect(state == takingBack)
        #expect(effects == [
            .arm(.phoneNotLooping),
            .persist(takingBack),
            .disarm(.phoneNoWatchUpdates),
            .send(F.message(4, .handBackAck)),
            .takeControl
        ])
    }

    @Test("P18 lending + hand-back (holding lost): same as from lent") func p18() {
        let (state, effects) = decide(.lending(epoch: 4, requestID: F.requestA), .received(F.message(4, .handBack)))
        let takingBack = PhoneLoanState.takingBack(epoch: 5, loan: LoanRecord(epoch: 4))
        #expect(state == takingBack)
        #expect(effects == [.persist(takingBack), .send(F.message(4, .handBackAck)), .takeControl])
    }

    @Test("P19 later state + repeated hand-back: re-ack idempotently") func p19() {
        for later in [
            PhoneLoanState.takingBack(epoch: 5, loan: LoanRecord(epoch: 4)),
            .home(epoch: 5, lastLoan: LoanRecord(epoch: 4))
        ] {
            let (state, effects) = decide(later, .received(F.message(4, .handBack)))
            #expect(state == later)
            #expect(effects == [.send(F.message(4, .handBackAck))])
        }
    }

    @Test("P20 takingBack + took control: cancel temp (R-1), refresh, audit (R-2), then persist home") func p20() {
        let loan = LoanRecord(epoch: 4, supersededUntil: F.window)
        let (state, effects) = decide(.takingBack(epoch: 5, loan: loan), .takeControlResult(epoch: 5, succeeded: true))
        let home = PhoneLoanState.home(epoch: 5, lastLoan: loan)
        #expect(state == home)
        #expect(effects == [.cancelTemp, .refreshDeliveredUnits, .audit(loanEpoch: 4), .persist(home)])
    }

    @Test("P21 takingBack + pod unreachable: stay, alert") func p21() {
        let takingBack = PhoneLoanState.takingBack(epoch: 5, loan: LoanRecord(epoch: 4))
        let (state, effects) = decide(takingBack, .takeControlResult(epoch: 5, succeeded: false))
        #expect(state == takingBack)
        #expect(effects == [.alert(.takeBackPodUnreachable)])
    }

    @Test("P22 takingBack + Take Back again: retry take control only") func p22() {
        let takingBack = PhoneLoanState.takingBack(epoch: 5, loan: LoanRecord(epoch: 4))
        let (state, effects) = decide(takingBack, .takeBackTapped(watchAnswer: nil))
        #expect(state == takingBack)
        #expect(effects == [.takeControl])
    }

    @Test("P23 takingBack without a known loan + took control: no audit possible, alert") func p23() {
        let (state, effects) = decide(.takingBack(epoch: 99, loan: nil), .takeControlResult(epoch: 99, succeeded: true))
        #expect(state == .home(epoch: 99, lastLoan: nil))
        #expect(
            effects ==
                [.cancelTemp, .refreshDeliveredUnits, .alert(.auditUnavailable), .persist(.home(epoch: 99, lastLoan: nil))]
        )
    }

    @Test("P24 unreadable + Take Back: epoch above any counted one, no takeover context") func p24() {
        let (state, effects) = decide(.unreadable, .takeBackTapped(watchAnswer: nil))
        let epoch = Int(F.now.timeIntervalSince1970)
        let takingBack = PhoneLoanState.takingBack(epoch: epoch, loan: nil)
        #expect(state == takingBack)
        #expect(effects == [
            .cancelOutstandingTransfers,
            .persist(takingBack),
            .sendStop(WatchLoanStop(kind: .revoke, epoch: epoch)),
            .takeControl
        ])
    }

    @Test("P25 home inside the takeover window + foreign session (C-1): keep commanding, audit, alert") func p25() {
        let home = PhoneLoanState.home(epoch: 5, lastLoan: LoanRecord(epoch: 4, supersededUntil: F.window))
        let (state, effects) = decide(home, .foreignPodSession)
        #expect(state == home)
        #expect(effects == [.podSession(.keepCommanding), .audit(loanEpoch: 4), .alert(.watchContactedPodAfterTakeBack)])
        // Every reported session, not only the first
        #expect(decide(state, .foreignPodSession).1 == effects)
    }

    @Test("P26 home after the window + foreign session (C-1): refuse, audit, alert") func p26() {
        let home = PhoneLoanState.home(epoch: 5, lastLoan: LoanRecord(epoch: 4, supersededUntil: F.now))
        let (state, effects) = decide(home, .foreignPodSession)
        #expect(state == home)
        #expect(effects == [.podSession(.refuse), .audit(loanEpoch: 4), .alert(.unexpectedPodSession)])
    }

    @Test("P27 home after a normal End or N-4 retake + foreign session (C-1): refuse, audit, alert") func p27() {
        let (_, effects) = decide(.home(epoch: 5, lastLoan: LoanRecord(epoch: 4)), .foreignPodSession)
        #expect(effects == [.podSession(.refuse), .audit(loanEpoch: 4), .alert(.unexpectedPodSession)])
    }

    @Test("P28 home, never lent + foreign session: refuse, alert") func p28() {
        let (_, effects) = decide(.initial, .foreignPodSession)
        #expect(effects == [.podSession(.refuse), .alert(.unexpectedPodSession)])
    }

    @Test("P29 takingBack with takeover context + foreign session: keep commanding, audit, alert") func p29() {
        let takingBack = PhoneLoanState.takingBack(epoch: 5, loan: LoanRecord(epoch: 4, supersededUntil: F.window))
        let (_, effects) = decide(takingBack, .foreignPodSession)
        #expect(effects == [.podSession(.keepCommanding), .audit(loanEpoch: 4), .alert(.watchContactedPodAfterTakeBack)])
    }

    @Test("P30 lending or lent + foreign session: the phone isn't commanding, ignored") func p30() {
        for released in [PhoneLoanState.lending(epoch: 4, requestID: F.requestA), .lent(epoch: 4)] {
            #expect(decide(released, .foreignPodSession).1.isEmpty)
        }
    }

    @Test("P31 home with takeover context + watch acknowledges stopped: clear the context (C-1)") func p31() {
        let (state, effects) = decide(
            .home(epoch: 5, lastLoan: LoanRecord(epoch: 4, supersededUntil: F.window)),
            .receivedStop(WatchLoanStop(kind: .stop, epoch: 4))
        )
        let cleared = PhoneLoanState.home(epoch: 5, lastLoan: LoanRecord(epoch: 4))
        #expect(state == cleared)
        #expect(effects == [.persist(cleared)])
        #expect(decide(cleared, .foreignPodSession).1.first == .podSession(.refuse))
    }

    @Test("P32 takingBack with takeover context + watch acknowledges stopped: clear the context") func p32() {
        let (state, effects) = decide(
            .takingBack(epoch: 5, loan: LoanRecord(epoch: 4, supersededUntil: F.window)),
            .receivedStop(WatchLoanStop(kind: .stop, epoch: 4))
        )
        let cleared = PhoneLoanState.takingBack(epoch: 5, loan: LoanRecord(epoch: 4))
        #expect(state == cleared)
        #expect(effects == [.persist(cleared)])
    }

    @Test("P33 lent + watch reports stopped: alert, the user decides on Take Back") func p33() {
        let (state, effects) = decide(.lent(epoch: 4), .receivedStop(WatchLoanStop(kind: .stop, epoch: 4)))
        #expect(state == .lent(epoch: 4))
        #expect(effects == [.alert(.watchStopped)])
    }

    @Test("P34 relaunch home: today's behaviour, not-looping armed") func p34() {
        let (state, effects) = decide(.initial, .relaunched)
        #expect(state == .initial)
        #expect(effects == [.arm(.phoneNotLooping), .disarm(.phoneNoWatchUpdates)])
    }

    @Test("P35 relaunch lending: gate stays closed, alert that Start didn't finish") func p35() {
        let lending = PhoneLoanState.lending(epoch: 4, requestID: F.requestA)
        let (state, effects) = decide(lending, .relaunched)
        #expect(state == lending)
        #expect(effects == [.arm(.phoneNotLooping), .disarm(.phoneNoWatchUpdates), .alert(.startDidNotFinish)])
    }

    @Test("P36 relaunch lent: watch-silence alarm armed, not-looping disarmed") func p36() {
        let (state, effects) = decide(.lent(epoch: 4), .relaunched)
        #expect(state == .lent(epoch: 4))
        #expect(effects == [.arm(.phoneNoWatchUpdates), .disarm(.phoneNotLooping)])
    }

    @Test("P37 relaunch takingBack (C-3): redo take control; its result redoes temp cancel, refresh, audit") func p37() {
        let loan = LoanRecord(epoch: 4, supersededUntil: F.window)
        let takingBack = PhoneLoanState.takingBack(epoch: 5, loan: loan)
        let (state, effects) = decide(takingBack, .relaunched)
        #expect(state == takingBack)
        #expect(effects == [.arm(.phoneNotLooping), .disarm(.phoneNoWatchUpdates), .takeControl])

        // Same audit input as an uninterrupted take-back, so the recompute replaces rather than adds
        let (_, finish) = decide(state, .takeControlResult(epoch: 5, succeeded: true))
        let (_, firstRun) = decide(takingBack, .takeControlResult(epoch: 5, succeeded: true))
        #expect(finish == firstRun)
        #expect(finish == [.cancelTemp, .refreshDeliveredUnits, .audit(loanEpoch: 4), .persist(.home(epoch: 5, lastLoan: loan))])
    }

    @Test("P38 relaunch unreadable: alert, not-looping armed") func p38() {
        let (state, effects) = decide(.unreadable, .relaunched)
        #expect(state == .unreadable)
        #expect(effects == [.arm(.phoneNotLooping), .disarm(.phoneNoWatchUpdates), .alert(.loanStateUnreadable)])
    }

    @Test("P39 TRIO_ON_WATCH off with a persisted lent (D-2): gate closed, Take Back still works") func p39() {
        let flagOff = PhoneLoanContext(now: F.now, startRefusal: .featureOff)
        let (relaunched, _) = decide(.lent(epoch: 4), .relaunched, flagOff)
        #expect(relaunched == .lent(epoch: 4))
        #expect(!relaunched.mayCommandPump)
        let (takingBack, _) = decide(relaunched, .takeBackTapped(watchAnswer: nil), flagOff)
        let (home, _) = decide(takingBack, .takeControlResult(epoch: 5, succeeded: true), flagOff)
        #expect(home.mayCommandPump)
        // Start stays refused
        #expect(decide(home, .received(F.message(4, .request(requestID: F.requestB))), flagOff).0 == home)
    }

    @Test("P40 home + Take Back or results without a hand-off: no-op") func p40() {
        let home = PhoneLoanState.home(epoch: 5, lastLoan: nil)
        for event in [
            PhoneLoanEvent.takeBackTapped(watchAnswer: nil),
            .releaseResult(epoch: 5, released: true),
            .takeControlResult(epoch: 5, succeeded: true),
            .grantUnconfirmed,
            .received(F.message(5, .holding))
        ] {
            let (state, effects) = decide(home, event)
            #expect(state == home)
            #expect(effects.isEmpty)
        }
    }

    @Test("P42 a result from an earlier hand-off (stale epoch): ignored") func p42() {
        let lending = PhoneLoanState.lending(epoch: 3, requestID: F.requestB)
        #expect(decide(lending, .releaseResult(epoch: 1, released: true)) == (lending, []))
        #expect(decide(lending, .releaseResult(epoch: 1, released: false)) == (lending, []))
        let takingBack = PhoneLoanState.takingBack(epoch: 5, loan: LoanRecord(epoch: 4))
        #expect(decide(takingBack, .takeControlResult(epoch: 2, succeeded: true)) == (takingBack, []))
    }

    @Test("P41 unreadable + foreign session: refuse, alert") func p41() {
        let (_, effects) = decide(.unreadable, .foreignPodSession)
        #expect(effects == [.podSession(.refuse), .alert(.unexpectedPodSession)])
    }

    @Test("Only home may command; unreadable is never persisted") func mayCommand() {
        #expect(PhoneLoanState.initial.mayCommandPump)
        #expect(!PhoneLoanState.lending(epoch: 1, requestID: F.requestA).mayCommandPump)
        #expect(!PhoneLoanState.lent(epoch: 1).mayCommandPump)
        #expect(!PhoneLoanState.takingBack(epoch: 2, loan: nil).mayCommandPump)
        #expect(!PhoneLoanState.unreadable.mayCommandPump)
    }

    @Test("N-4: the watch's request timeout exceeds a worst-case lend plus the grant's lifetime") func n4Timeout() {
        #expect(WatchLoan.watchRequestTimeout > WatchLoan.phoneWorstCaseLend + WatchLoan.grantLifetime)
    }
}
