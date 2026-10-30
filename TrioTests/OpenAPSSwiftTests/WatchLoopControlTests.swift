import Foundation
import Testing
@testable import Trio

/// Documentation/WatchLoop/Control.md, row by row: each test sets up what the acting device sees in that row's
/// physical configuration and checks the row's result (after LoopKit/Loop#2545's LoanControlTests). A different
/// ruling for a row changes its case in WatchLoopControl.swift and its test here.
@Suite("Watch Loop control") struct WatchLoopControlTests {
    private typealias C = WatchLoopControl
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func phone(
        _ trigger: C.Trigger,
        role: C.PhoneRole = .holdsPump,
        tookOver: Date? = nil,
        sensorFresh: Bool = true,
        standingCopyOut: Bool = true
    ) -> C.Decision {
        C.decide(C.Situation(
            device: .phone,
            trigger: trigger,
            phoneRole: role,
            tookOverOnSilenceAt: tookOver,
            sensorFresh: sensorFresh,
            standingCopyOut: standingCopyOut
        ))
    }

    private func watch(_ trigger: C.Trigger, standingCopy: Bool = false, readsCGM: Bool = true) -> C.Decision {
        C.decide(C.Situation(device: .watch, trigger: trigger, watchHasStandingCopy: standingCopy, watchReadsCGM: readsCGM))
    }

    @Test("Rows 1 and 2: Start asks the phone and offers the start without it on silence") func rows1And2() {
        #expect(watch(.startTapped, standingCopy: true) == .query(.onScreen, onSilence: .prompt(.startWithoutPhone)))
        #expect(watch(.startTapped, standingCopy: false) == .query(.onScreen, onSilence: .tell(.noResponseFromPhone)))
        // a watch not reading the CGM has nothing to dose from, so no start without the phone is offered
        #expect(
            watch(.startTapped, standingCopy: true, readsCGM: false) ==
                .query(.onScreen, onSilence: .tell(.noResponseFromPhoneAndNoCGM))
        )
    }

    @Test("Row 3: the watch warns after 25 minutes without the phone and takes nothing") func row3() {
        #expect(watch(.phoneHeardWithNoSession) == .tellIfSilent(.notHearingFromPhone, after: 25 * 60))
    }

    @Test("Row 4: a clean reading changes nothing") func row4() {
        #expect(phone(.pumpReading(differenceBeyondBand: false)) == .nothing)
    }

    @Test("Rows 5 and 18: another device's insulin is queried and the pump kept on silence") func rows5And18() {
        #expect(phone(.pumpReading(differenceBeyondBand: true)) == .query(.inBackground, onSilence: .keepPumpOnSilence))
        // no standing copy out: no watch could have started without this phone
        #expect(phone(.pumpReading(differenceBeyondBand: true), standingCopyOut: false) == .nothing)
    }

    @Test("Row 6: a closed session gets the stop again") func row6() {
        #expect(phone(.watchClaims(.init(session: .closed))) == .sendStop)
        #expect(phone(.watchClaims(.init(session: .closed)), role: .standingAside) == .nothing)
    }

    @Test("Rows 7, 8 and 21: End asks the phone and is refused on silence") func rows7To8() {
        #expect(watch(.endTapped) == .query(.onScreen, onSilence: .refuse(.phoneAwayCannotHandBack)))
        #expect(C.afterQuery(.answered, onSilence: .refuse(.phoneAwayCannotHandBack)) == .nothing)
        #expect(C.afterQuery(.silence, onSilence: .refuse(.phoneAwayCannotHandBack)) == .refuse(.phoneAwayCannotHandBack))
    }

    @Test("Row 9: Take Back is the looper's decision") func row9() {
        #expect(phone(.takeBackTapped, role: .lending) == .takeOnTap)
    }

    @Test("Row 10: a silent watch is queried, then taken from") func row10() {
        #expect(
            phone(.watchReportOverdue, role: .lending) ==
                .query(.inBackground, onSilence: .takeOnSilence(.watchNotResponding))
        )
        #expect(C.afterQuery(.silence, onSilence: .takeOnSilence(.watchNotResponding)) == .takeOnSilence(.watchNotResponding))
        #expect(C.afterQuery(.answered, onSilence: .takeOnSilence(.watchNotResponding)) == .nothing)
    }

    @Test("Rows 11 and 15: away from the body the phone does nothing") func rows11And15() {
        #expect(phone(.watchReportOverdue, role: .lending, sensorFresh: false) == .nothing)
    }

    @Test("Rows 12 and 13: a watch back from off asks first") func rows12And13() {
        #expect(watch(.backFromOff) == .query(.inBackground, onSilence: .carryOn))
        #expect(C.afterQuery(.silence, onSilence: .carryOn) == .carryOn)
        #expect(phone(.watchClaims(.init(session: .closed))) == .sendStop)
    }

    @Test("Rows 14 and 20: cannot reach the pump counts as silence") func rows14And20() {
        #expect(
            C
                .afterQuery(.holdsPumpButCannotReach, onSilence: .takeOnSilence(.watchNotResponding)) ==
                .takeOnSilence(.watchNotResponding)
        )
        #expect(C.afterQuery(.holdsPumpButCannotReach, onSilence: .keepPumpOnSilence) == .keepPumpOnSilence)
        // and its report does not renew its hold
        #expect(phone(.watchClaims(.init(session: .current, pumpReachable: false)), role: .lending) == .nothing)
    }

    @Test("A watch that holds nothing is answered like silence") func holdsNothing() {
        #expect(
            C
                .afterQuery(.holdsNothing, onSilence: .takeOnSilence(.watchNotResponding)) == .takeOnSilence(.watchNotResponding)
        )
    }

    @Test("Row 16: a report on the live session renews the hold") func row16() {
        #expect(phone(.watchClaims(.init(session: .current, pumpReachable: true)), role: .lending) == .renewHold)
        #expect(phone(.watchClaims(.init(session: .current, pumpReachable: true)), role: .standingAside) == .renewHold)
    }

    @Test("Row 17: the phone stands aside for a live watch's session") func row17() {
        #expect(phone(.watchClaims(.init(session: .newer, startedAt: t0))) == .standAside)
        #expect(phone(.watchClaims(.init(session: .newer, startedAt: t0)), standingCopyOut: false) == .nothing)
    }

    @Test("Row 19: a revived claim is refused and a fresh Start honoured") func row19() {
        let tookOver = t0.addingTimeInterval(30 * 60)
        #expect(phone(.watchClaims(.init(session: .newer, startedAt: t0)), tookOver: tookOver) == .sendStop)
        #expect(
            phone(.watchClaims(.init(session: .newer, startedAt: tookOver.addingTimeInterval(60))), tookOver: tookOver) ==
                .standAside
        )
        #expect(phone(.watchClaims(.init(session: .newer, refusedBefore: true)), tookOver: tookOver) == .sendStop)
    }

    @Test("Other pairings decide nothing") func otherPairings() {
        #expect(phone(.startTapped) == .nothing)
        #expect(watch(.watchReportOverdue) == .nothing)
    }

    @Test("The waits") func waits() {
        #expect(C.Wait.onScreen.seconds == 10)
        #expect(C.Wait.inBackground.seconds == 30)
        #expect(C.watchReportOverdue == 6 * 60)
    }
}
