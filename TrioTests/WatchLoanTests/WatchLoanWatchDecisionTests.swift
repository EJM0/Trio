import Foundation
import Testing

@testable import Trio

/// One test per watch row of `docs/trio-on-watch/architecture/watch-loan-decision-table.md`.
@Suite("Watch loan: watch decision table") struct WatchLoanWatchDecisionTests {
    typealias F = LoanFixture

    private let context = WatchSideLoanContext(now: LoanFixture.now, newRequestID: LoanFixture.requestA)

    private func decide(_ state: WatchLoanState, _ event: WatchSideLoanEvent, _ context: WatchSideLoanContext? = nil)
        -> (WatchLoanState, [WatchSideLoanEffect])
    {
        WatchLoan.decide(state, event, context ?? self.context)
    }

    private func grant(epoch: Int64 = 4, requestID: UUID = LoanFixture.requestA, expiresIn: TimeInterval = 30)
        -> WatchSideLoanEvent
    {
        .received(F.message(epoch, .grant(requestID: requestID, expiresAt: F.now.addingTimeInterval(expiresIn))))
    }

    private func relaunch(
        lastCycleAt: Date = LoanFixture.now,
        phoneEpoch: Int64? = nil,
        foreign: Bool = false,
        kitHasControl: Bool = true
    ) -> WatchSideLoanEvent {
        .relaunched(lastCycleAt: lastCycleAt, phoneEpoch: phoneEpoch, podSessionForeign: foreign, kitHasControl: kitHasControl)
    }

    /// Persist, tell the user, disarm only when superseded, release the pod, report the stop.
    private func stopEffects(_ epoch: Int64, _ reason: WatchStopReason) -> [WatchSideLoanEffect] {
        let stopped = WatchLoanState.stopped(epoch: epoch, reason: reason)
        var effects: [WatchSideLoanEffect] = [.persist(stopped), .alert(.stopped(reason))]
        if reason == .superseded { effects.append(.disarm(.watchNotLooping)) }
        return effects + [.releaseControl, .sendStop(WatchLoanStop(kind: .stop, epoch: epoch))]
    }

    @Test("W1 idle + Start: persist requesting, send the request") func w1() {
        let (state, effects) = decide(.idle(epoch: 3), .startTapped)
        let requesting = WatchLoanState.requesting(epoch: 3, requestID: F.requestA)
        #expect(state == requesting)
        #expect(effects == [.persist(requesting), .send(F.message(3, .request(requestID: F.requestA)))])
    }

    @Test("W2 idle + Start refused (battery, model, notifications, flag): alert, stay idle") func w2() {
        var refused = context
        refused.startRefusal = .watchBatteryLow
        let (state, effects) = decide(.idle(epoch: 3), .startTapped, refused)
        #expect(state == .idle(epoch: 3))
        #expect(effects == [.alert(.startRefused(.watchBatteryLow))])
    }

    @Test("W3 requesting + timeout (request or grant lost): idle, alert") func w3() {
        let (state, effects) = decide(.requesting(epoch: 3, requestID: F.requestA), .requestTimedOut)
        #expect(state == .idle(epoch: 3))
        #expect(effects == [.persist(.idle(epoch: 3)), .alert(.phoneDidNotAnswer)])
    }

    @Test("W4 requesting + valid grant: arm, persist holding, then adopt, then send holding") func w4() {
        let (state, effects) = decide(.requesting(epoch: 3, requestID: F.requestA), grant())
        #expect(state == .holding(epoch: 4))
        #expect(effects == [
            .arm(.watchNotLooping),
            .persist(.holding(epoch: 4)),
            .adoptControl,
            .send(F.message(4, .holding))
        ])
    }

    @Test("W5 requesting + expired grant: reject, idle, never adopt") func w5() {
        let (state, effects) = decide(.requesting(epoch: 3, requestID: F.requestA), grant(expiresIn: 0))
        #expect(state == .idle(epoch: 3))
        #expect(effects == [
            .persist(.idle(epoch: 3)),
            .send(F.message(4, .grantRejected(requestID: F.requestA, reason: .grantExpired))),
            .alert(.startRefused(.grantExpired))
        ])
    }

    @Test("W6 requesting + grant failing host validation (snapshot, version, dosing mode, clock, time zone): reject") func w6() {
        for refusal in [LoanRefusal.snapshotIncomplete, .versionMismatch, .notClosedLoop, .clockOffset, .timeZoneMismatch] {
            var invalid = context
            invalid.grantRefusal = refusal
            let (state, effects) = decide(.requesting(epoch: 3, requestID: F.requestA), grant(), invalid)
            #expect(state == .idle(epoch: 3))
            #expect(effects.contains(.send(F.message(4, .grantRejected(requestID: F.requestA, reason: refusal)))))
            #expect(!effects.contains(.adoptControl))
        }
    }

    @Test("W7 requesting + grant with a stale epoch: reject") func w7() {
        let (state, effects) = decide(.requesting(epoch: 3, requestID: F.requestA), grant(epoch: 3))
        #expect(state == .idle(epoch: 3))
        #expect(effects.contains(.send(F.message(3, .grantRejected(requestID: F.requestA, reason: .staleEpoch)))))
    }

    @Test("W8 requesting + grant for another request: reject it, keep waiting") func w8() {
        let requesting = WatchLoanState.requesting(epoch: 3, requestID: F.requestA)
        let (state, effects) = decide(requesting, grant(requestID: F.requestB))
        #expect(state == requesting)
        #expect(effects == [.send(F.message(4, .grantRejected(requestID: F.requestB, reason: .unknownRequest)))])
    }

    @Test("W9 idle, or another loan's returning or stopped + late grant: reject, never adopt") func w9() {
        for state in [WatchLoanState.idle(epoch: 3), .returning(epoch: 2), .stopped(epoch: 2, reason: .superseded)] {
            let (next, effects) = decide(state, grant())
            #expect(next == state)
            #expect(effects == [.send(F.message(4, .grantRejected(requestID: F.requestA, reason: .unknownRequest)))])
        }
    }

    @Test("W10 holding + duplicate grant of the same loan: resend holding, don't reject") func w10() {
        let (state, effects) = decide(.holding(epoch: 4), grant())
        #expect(state == .holding(epoch: 4))
        #expect(effects == [.send(F.message(4, .holding))])
    }

    @Test("W11 requesting + phone refused Start: idle, alert with the reason") func w11() {
        let (state, effects) = decide(
            .requesting(epoch: 3, requestID: F.requestA),
            .received(F.message(3, .refused(requestID: F.requestA, reason: .bolusRunning)))
        )
        #expect(state == .idle(epoch: 3))
        #expect(effects == [.persist(.idle(epoch: 3)), .alert(.startRefused(.bolusRunning))])
    }

    @Test("W12 holding + take control failed: alert, stay holding with not-looping armed") func w12() {
        let (state, effects) = decide(.holding(epoch: 4), .takeControlResult(succeeded: false))
        #expect(state == .holding(epoch: 4))
        #expect(effects == [.alert(.podUnreachable)])
        #expect(decide(.holding(epoch: 4), .takeControlResult(succeeded: true)).1.isEmpty)
    }

    @Test("W13 holding + End: persist returning, cancel temp, refresh, release") func w13() {
        let (state, effects) = decide(.holding(epoch: 4), .endTapped)
        #expect(state == .returning(epoch: 4))
        #expect(effects == [.persist(.returning(epoch: 4)), .cancelTemp, .refreshDeliveredUnits, .releaseControl])
    }

    @Test("W14 holding + End refused (phone unreachable, bolus, unconfirmed command): alert") func w14() {
        var refused = context
        refused.endRefusal = .phoneUnreachable
        let (state, effects) = decide(.holding(epoch: 4), .endTapped, refused)
        #expect(state == .holding(epoch: 4))
        #expect(effects == [.alert(.endRefused(.phoneUnreachable))])
    }

    @Test("W15 returning + released: send the hand-back") func w15() {
        let (state, effects) = decide(.returning(epoch: 4), .releaseResult(released: true))
        #expect(state == .returning(epoch: 4))
        #expect(effects == [.send(F.message(4, .handBack))])
    }

    @Test("W16 returning + release refused: back to holding, alert") func w16() {
        let (state, effects) = decide(.returning(epoch: 4), .releaseResult(released: false))
        #expect(state == .holding(epoch: 4))
        #expect(effects == [.persist(.holding(epoch: 4)), .alert(.endRefused(.releaseRefused))])
    }

    @Test("W17 returning + no ack yet: resend the hand-back") func w17() {
        let (_, effects) = decide(.returning(epoch: 4), .handBackUnacknowledged)
        #expect(effects == [.send(F.message(4, .handBack))])
    }

    @Test("W18 returning + ack: idle, disarm not-looping after persist") func w18() {
        let (state, effects) = decide(.returning(epoch: 4), .received(F.message(4, .handBackAck)))
        #expect(state == .idle(epoch: 4))
        #expect(effects == [.persist(.idle(epoch: 4)), .disarm(.watchNotLooping)])
        #expect(decide(.returning(epoch: 4), .received(F.message(3, .handBackAck))).1.isEmpty)
    }

    @Test("W19 holding + revoke with a higher epoch: stop, tell the user, disarm, release, report") func w19() {
        let (state, effects) = decide(.holding(epoch: 4), .receivedStop(WatchLoanStop(kind: .revoke, epoch: 5)))
        #expect(state == .stopped(epoch: 4, reason: .superseded))
        #expect(effects == stopEffects(4, .superseded))
        #expect(LoanAlarm.armed(for: state).isEmpty)
    }

    @Test("W20 returning + revoke with a higher epoch: stop") func w20() {
        let (state, effects) = decide(.returning(epoch: 4), .receivedStop(WatchLoanStop(kind: .revoke, epoch: 5)))
        #expect(state == .stopped(epoch: 4, reason: .superseded))
        #expect(effects == stopEffects(4, .superseded))
    }

    @Test("W21 idle or requesting + revoke: learn the epoch, keep the request; a grant from before it is then stale") func w21() {
        let (idle, idleEffects) = decide(.idle(epoch: 3), .receivedStop(WatchLoanStop(kind: .revoke, epoch: 5)))
        #expect(idle == .idle(epoch: 5))
        #expect(idleEffects == [.persist(.idle(epoch: 5))])
        let (requesting, effects) = decide(
            .requesting(epoch: 3, requestID: F.requestA),
            .receivedStop(WatchLoanStop(kind: .revoke, epoch: 5))
        )
        #expect(requesting == .requesting(epoch: 5, requestID: F.requestA))
        #expect(effects == [.persist(requesting)])
        #expect(decide(requesting, grant(epoch: 5)).0 == .idle(epoch: 5))
        #expect(decide(requesting, grant(epoch: 6)).0 == .holding(epoch: 6))
    }

    @Test("W22 stopped + revoke: repeat the stop report and release again") func w22() {
        let stopped = WatchLoanState.stopped(epoch: 4, reason: .foreignSession)
        let (state, effects) = decide(stopped, .receivedStop(WatchLoanStop(kind: .revoke, epoch: 5)))
        #expect(state == stopped)
        #expect(effects == [.sendStop(WatchLoanStop(kind: .stop, epoch: 4)), .releaseControl])
    }

    @Test("W23 holding + revoke not above its epoch: ignored") func w23() {
        let (state, effects) = decide(.holding(epoch: 4), .receivedStop(WatchLoanStop(kind: .revoke, epoch: 4)))
        #expect(state == .holding(epoch: 4))
        #expect(effects.isEmpty)
    }

    @Test("W24 holding + foreign pod session: stop, keep the alarm, release, report") func w24() {
        let (state, effects) = decide(.holding(epoch: 4), .foreignPodSession)
        #expect(state == .stopped(epoch: 4, reason: .foreignSession))
        #expect(effects == stopEffects(4, .foreignSession))
        #expect(decide(.returning(epoch: 4), .foreignPodSession).1.isEmpty)
    }

    @Test("W25 stopped + user acknowledges: idle, disarm what is still armed") func w25() {
        let (state, effects) = decide(.stopped(epoch: 4, reason: .foreignSession), .stopAcknowledged)
        #expect(state == .idle(epoch: 4))
        #expect(effects == [.persist(.idle(epoch: 4)), .disarm(.watchNotLooping)])
        #expect(decide(.stopped(epoch: 4, reason: .superseded), .stopAcknowledged).1 == [.persist(.idle(epoch: 4))])
    }

    @Test("W26 relaunch holding, kit holds, within 6 h, no foreign session: resume without any take") func w26() {
        for phoneEpoch in [nil, Int64(4)] {
            let (state, effects) = decide(
                .holding(epoch: 4),
                relaunch(lastCycleAt: F.now.addingTimeInterval(-3600), phoneEpoch: phoneEpoch)
            )
            #expect(state == .holding(epoch: 4))
            #expect(effects == [.arm(.watchNotLooping)])
        }
    }

    @Test("W27 relaunch holding, phone has a higher epoch: stop") func w27() {
        let (state, _) = decide(.holding(epoch: 4), relaunch(phoneEpoch: 5))
        #expect(state == .stopped(epoch: 4, reason: .superseded))
    }

    @Test("W28 relaunch holding, kit refused a foreign session: stop") func w28() {
        let (state, _) = decide(.holding(epoch: 4), relaunch(foreign: true))
        #expect(state == .stopped(epoch: 4, reason: .foreignSession))
    }

    @Test("W29 relaunch holding more than 6 h after the last cycle: stop") func w29() {
        let (state, _) = decide(.holding(epoch: 4), relaunch(lastCycleAt: F.now.addingTimeInterval(-WatchLoan.resumeWindow - 1)))
        #expect(state == .stopped(epoch: 4, reason: .resumeWindowPassed))
    }

    @Test("W30 relaunch returning: release again before anything else") func w30() {
        let (state, effects) = decide(.returning(epoch: 4), relaunch())
        #expect(state == .returning(epoch: 4))
        #expect(effects == [.arm(.watchNotLooping), .releaseControl])
    }

    @Test("W31 relaunch requesting: the request is dead, idle") func w31() {
        let (state, effects) = decide(.requesting(epoch: 3, requestID: F.requestA), relaunch())
        #expect(state == .idle(epoch: 3))
        #expect(effects == [.disarm(.watchNotLooping), .persist(.idle(epoch: 3))])
    }

    @Test("W32 relaunch stopped: re-assert alarms and release again; idle: alarms only") func w32() {
        #expect(decide(.stopped(epoch: 4, reason: .foreignSession), relaunch()).1 == [.arm(.watchNotLooping), .releaseControl])
        #expect(decide(.stopped(epoch: 4, reason: .superseded), relaunch()).1 == [.disarm(.watchNotLooping), .releaseControl])
        #expect(decide(.idle(epoch: 4), relaunch()).1 == [.disarm(.watchNotLooping)])
    }

    @Test("W33 status query: answer with the current state") func w33() {
        let (_, effects) = decide(.holding(epoch: 4), .received(F.message(4, .statusQuery)))
        #expect(effects == [.send(F.message(4, .status(.holding(epoch: 4))))])
    }

    @Test("W34 returning or stopped + duplicate grant of the same loan: answer the state, don't reject") func w34() {
        for state in [WatchLoanState.returning(epoch: 4), .stopped(epoch: 4, reason: .foreignSession)] {
            let (next, effects) = decide(state, grant())
            #expect(next == state)
            #expect(effects == [.send(F.message(4, .status(state)))])
        }
    }

    @Test("W35 stopped + released: report the stop again, confirming release; a failed release reports nothing") func w35() {
        let stopped = WatchLoanState.stopped(epoch: 4, reason: .superseded)
        #expect(decide(stopped, .releaseResult(released: true)) == (stopped, [
            .sendStop(WatchLoanStop(kind: .stop, epoch: 4, released: true))
        ]))
        #expect(decide(stopped, .releaseResult(released: false)) == (stopped, []))
    }

    @Test("W36 relaunch holding before the kit adopted, phone confirms the same epoch: adopt again") func w36() {
        let (state, effects) = decide(.holding(epoch: 4), relaunch(phoneEpoch: 4, kitHasControl: false))
        #expect(state == .holding(epoch: 4))
        #expect(effects == [.arm(.watchNotLooping), .adoptControl])
    }

    @Test("W37 relaunch holding before the kit adopted, phone silent or behind: stop, never take") func w37() {
        for phoneEpoch in [nil, Int64(3)] {
            let (state, effects) = decide(.holding(epoch: 4), relaunch(phoneEpoch: phoneEpoch, kitHasControl: false))
            #expect(state == .stopped(epoch: 4, reason: .unconfirmed))
            #expect(effects == stopEffects(4, .unconfirmed))
        }
    }

    @Test("Only holding may command") func mayCommand() {
        #expect(WatchLoanState.holding(epoch: 1).mayCommandPump)
        for state in [
            WatchLoanState.idle(epoch: 1),
            .requesting(epoch: 1, requestID: F.requestA),
            .returning(epoch: 1),
            .stopped(epoch: 1, reason: .superseded)
        ] {
            #expect(!state.mayCommandPump)
        }
    }
}
