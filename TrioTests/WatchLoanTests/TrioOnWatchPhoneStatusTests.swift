import Foundation
import Testing

@testable import Trio

@Suite("Trio on Watch phone screens: state mapping") struct TrioOnWatchPhoneStatusTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func make(
        _ state: PhoneLoanState,
        lastBatchAt: Date? = nil,
        sinceMinutes: Double = 0,
        reachable: Bool = false,
        refuses: Bool = false
    ) -> TrioOnWatchPhoneStatus {
        TrioOnWatchPhoneStatus.make(
            state: state,
            lastBatchAt: lastBatchAt,
            since: now.addingTimeInterval(-sinceMinutes * 60),
            now: now,
            watchReachable: reachable,
            podRefusesSessions: refuses
        )
    }

    @Test("Phone loan states map to what Home shows") func phases() {
        #expect(make(.home(epoch: 0, lastLoan: nil)).phase == .home)
        #expect(make(.home(epoch: 3, lastLoan: nil), refuses: true).phase == .podRefused)
        #expect(make(.lending(epoch: 1, requestID: UUID()), sinceMinutes: 0.5).phase == .starting)
        #expect(make(.lending(epoch: 1, requestID: UUID()), sinceMinutes: 1).phase == .startUnconfirmed)
        #expect(make(.lent(epoch: 1), lastBatchAt: now.addingTimeInterval(-5 * 60), sinceMinutes: 60).phase == .inControl)
        #expect(make(.lent(epoch: 1), lastBatchAt: now.addingTimeInterval(-30 * 60)).phase == .noUpdates)
        // no batch yet: counted from when the loan was first seen
        #expect(make(.lent(epoch: 1), sinceMinutes: 29).phase == .inControl)
        #expect(make(.lent(epoch: 1), sinceMinutes: 31).phase == .noUpdates)
        let loan = LoanRecord(epoch: 1)
        #expect(make(.takingBack(epoch: 2, loan: loan), sinceMinutes: 0.5).phase == .takingBack)
        #expect(make(.takingBack(epoch: 2, loan: loan), sinceMinutes: 2).phase == .takingBackStuck)
        #expect(make(.takingBack(epoch: 2, loan: loan), refuses: true).phase == .takingBackStuck)
        #expect(make(.unreadable).phase == .unreadable)
    }

    static let shown: [TrioOnWatchPhoneStatus.Phase] = [
        .starting, .startUnconfirmed, .inControl, .noUpdates, .takingBack, .takingBackStuck, .unreadable
    ]

    @Test("Pill and banner: words, symbol and a VoiceOver label in every state") func pillAndBanner() {
        for phase in Self.shown {
            var status = TrioOnWatchPhoneStatus(lastUpdate: now.addingTimeInterval(-180))
            status.phase = phase
            #expect(status.replacesLoopRing)
            let pill = status.pill(now: now)
            #expect(!pill.symbol.isEmpty)
            #expect(!pill.text.isEmpty)
            #expect(!pill.accessibilityLabel.isEmpty)
            let banner = status.banner(now: now)
            #expect(!banner.title.isEmpty)
            #expect(!banner.subtitle.isEmpty)
            // "silent" reads as Silent Mode (G-6a)
            #expect(!banner.title.lowercased().contains("silent"))
        }
        var refused = TrioOnWatchPhoneStatus()
        refused.phase = .podRefused
        #expect(!refused.replacesLoopRing)
        #expect(refused.showsBanner)
        #expect(!TrioOnWatchPhoneStatus().showsBanner)
    }

    @Test("Pill shows the watch's loop age: orange after 10 min, red with no updates") func pillTint() {
        var status = TrioOnWatchPhoneStatus(lastUpdate: now.addingTimeInterval(-60), lastLoop: now.addingTimeInterval(-5 * 60))
        status.phase = .inControl
        #expect(status.pill(now: now).tint == .loopGreen)
        // a fresh batch doesn't make an old loop look fresh (G-2)
        status.lastLoop = now.addingTimeInterval(-11 * 60)
        #expect(status.pill(now: now).tint == .orange)
        // the watch icon says who loops; the text is only the age of its last loop, as on the loop pill
        #expect(status.pill(now: now).symbol == "applewatch")
        #expect(status.pill(now: now).text == status.lastLoop!.formattedTimeAgo())
        #expect(status.pill(now: now).accessibilityLabel.contains(status.lastLoop!.formattedSpokenTimeAgo()))
        status.lastLoop = nil
        #expect(status.pill(now: now).text == "--")
        status.phase = .noUpdates
        #expect(status.pill(now: now).tint == .loopRed)
        #expect(status.banner(now: now).isCritical)
    }

    @Test("Take Back: context wording, and destructive only when the watch is reachable") func takeBack() {
        var status = TrioOnWatchPhoneStatus()
        status.phase = .inControl
        status.watchReachable = true
        #expect(status.takeBackContext == .watchReachable)
        status.watchReachable = false
        #expect(status.takeBackContext == .watchUnreachable)
        status.phase = .startUnconfirmed
        status.watchReachable = true
        #expect(status.takeBackContext == .startUnconfirmed)

        let contexts: [TrioOnWatchPhoneStatus.TakeBackContext] = [.watchReachable, .watchUnreachable, .startUnconfirmed]
        let messages = Set(contexts.map { TrioOnWatchPhoneStatus.takeBackMessage($0) })
        #expect(messages.count == 3)
        #expect(TrioOnWatchPhoneStatus.takeBackMessage(.watchUnreachable, patch: true).contains("patch"))
        #expect(TrioOnWatchPhoneStatus.takeBackButton(.watchReachable) == "Take Back Anyway")
        #expect(TrioOnWatchPhoneStatus.takeBackButton(.watchUnreachable) == "Take Back Pump")
    }

    @Test("Take Back is offered whenever the phone isn't in control; using the pod only when the kit refuses") func offers() {
        for phase in Self.shown where phase != .takingBack {
            var status = TrioOnWatchPhoneStatus()
            status.phase = phase
            #expect(status.offersTakeBack, "\(phase)")
        }
        var refused = TrioOnWatchPhoneStatus(podRefusesSessions: true)
        refused.phase = .podRefused
        #expect(refused.offersUsePod)
        #expect(!refused.offersTakeBack)
        var lent = TrioOnWatchPhoneStatus(podRefusesSessions: false)
        lent.phase = .inControl
        #expect(!lent.offersUsePod)
    }

    @Test("Banner ranks below Notifications Disabled and above everything else (DD-4)") func panelRank() {
        func resolve(notifications: Bool, trioOnWatch: Bool) -> MultiUsePanelState {
            MultiUsePanelState.resolve(
                notificationsDisabled: notifications,
                pumpTimeMismatch: true,
                lastGlucoseDate: nil,
                maxIOB: 0,
                tidepoolLoginRequired: true,
                hasUnacknowledgedReleaseNotes: true,
                dosingMode: .closed,
                trioOnWatch: trioOnWatch,
                now: now
            )
        }
        #expect(resolve(notifications: true, trioOnWatch: true) == .notificationsDisabled)
        #expect(resolve(notifications: false, trioOnWatch: true) == .trioOnWatch)
        #expect(resolve(notifications: false, trioOnWatch: false) == .pumpTimeMismatch)
    }

    @Test("Blocked notes and the sheet's list have plain text") func notes() {
        for message in [TrioOnWatchBlockedNote.treatments, TrioOnWatchBlockedNote.adjustments, TrioOnWatchBlockedNote.settings] {
            #expect(!message.isEmpty)
        }
        #expect(TrioOnWatchSheet.blockedActions.count == 4)
    }

    @Test("Low-glucose bolus warning: the Treatments rule, shared with the watch (DD-8)") func lowGlucoseWarning() {
        #expect(LowGlucoseBolusWarning.message(currentBG: 54, minPredBG: 54) == nil)
        #expect(LowGlucoseBolusWarning.message(currentBG: 53, minPredBG: 40) == "Glucose is very low.")
        #expect(LowGlucoseBolusWarning.message(currentBG: 120, minPredBG: 53) == "Glucose forecast is very low.")
        #expect(!LowGlucoseBolusWarning.shouldConfirm(confirmBolus: false, currentBG: 40, minPredBG: 40))
        #expect(LowGlucoseBolusWarning.shouldConfirm(confirmBolus: true, currentBG: 120, minPredBG: 50))
        #expect(!LowGlucoseBolusWarning.shouldConfirm(confirmBolus: true, currentBG: 120, minPredBG: 80))
    }

    @Test("Low-glucose bolus warning matches nightscout/dev's Treatments rule at every boundary") func lowGlucoseWarningAsDev() {
        // TreatmentsRootView.bolusWarning on nightscout/dev 7e2fa52cb, verbatim; its pump-only guard and colour are unchanged
        func dev(confirmBolus: Bool, currentBG: Decimal, minPredBG: Decimal) -> (shouldConfirm: Bool, message: String) {
            let isGlucoseVeryLow = currentBG < 54
            let isForecastVeryLow = minPredBG < 54
            let warningMessage = isGlucoseVeryLow ? String(localized: "Glucose is very low.") :
                isForecastVeryLow ? String(localized: "Glucose forecast is very low.") :
                ""
            return (confirmBolus && (isGlucoseVeryLow || isForecastVeryLow), warningMessage)
        }
        let values: [Decimal] = [-1, 0, 39, 53, 53.9, 54, 54.1, 70, 400]
        for confirmBolus in [true, false] {
            for currentBG in values {
                for minPredBG in values {
                    let expected = dev(confirmBolus: confirmBolus, currentBG: currentBG, minPredBG: minPredBG)
                    #expect(LowGlucoseBolusWarning.message(currentBG: currentBG, minPredBG: minPredBG) ?? "" == expected.message)
                    #expect(
                        LowGlucoseBolusWarning.shouldConfirm(
                            confirmBolus: confirmBolus,
                            currentBG: currentBG,
                            minPredBG: minPredBG
                        )
                            == expected.shouldConfirm
                    )
                }
            }
        }
    }

    @Test("Every phone screenshot fixture resolves") func fixtures() {
        for name in [
            "starting", "start-unconfirmed+sheet+takeback", "in-control", "in-control-reachable+sheet+takeback",
            "in-control+sheet+takeback", "no-updates", "taking-back", "taking-back-stuck+sheet", "pod-refused+sheet+usepod",
            "unreadable+sheet", "in-control+treatments", "in-control+adjustments", "in-control+settings"
        ] {
            #expect(TrioOnWatchPhoneFixture.named(name, now: now) != nil, "\(name)")
        }
    }

    @Test("Drag-to-watch Start: the watch's answer, then the loan state, decide the hand-off card") func dragToStart() {
        typealias Start = TrioOnWatchPhoneStart
        #expect(Start.stage(answer: nil, phase: .home, elapsed: 0, patch: true) == .handingOver)
        #expect(Start.stage(answer: .requested, phase: .home, elapsed: 5, patch: true) == .handingOver)
        #expect(Start.stage(answer: .requested, phase: .starting, elapsed: 8, patch: true) == .handingOver)
        // the check comes once the watch has the patch, not with its first loop
        #expect(Start.stage(answer: .requested, phase: .inControl, elapsed: 12, patch: true) == .done)
        #expect(Start.stage(answer: .requested, phase: .startUnconfirmed, elapsed: 70, patch: true) == .stillWaiting)
        #expect(Start.stage(answer: .requested, phase: .home, elapsed: 31, patch: true).isFailed)
        #expect(Start.stage(answer: .requested, phase: .takingBack, elapsed: 20, patch: true).isFailed)
        #expect(Start.stage(answer: .watchAsleep, phase: .home, elapsed: 0, patch: false).isFailed)
        // a lost answer goes by the loan state: the watch may have sent its request anyway
        #expect(Start.stage(answer: .noAnswer, phase: .home, elapsed: 10, patch: false) == .handingOver)
        #expect(Start.stage(answer: .noAnswer, phase: .home, elapsed: 31, patch: false).isFailed)
        #expect(Start.stage(answer: .noAnswer, phase: .starting, elapsed: 12, patch: false) == .handingOver)
        #expect(Start.stage(answer: .noAnswer, phase: .inControl, elapsed: 15, patch: false) == .done)
        #expect(
            Start.stage(answer: .refused(.watchBatteryLow), phase: .home, elapsed: 1, patch: false)
                == .failed(Start.refusalText(.watchBatteryLow, patch: false))
        )

        #expect(Start.answer(from: [WatchLoanWireKey.startAnswer: WatchLoanWireKey.startRequested]) == .requested)
        #expect(Start.answer(from: [WatchLoanWireKey.startAnswer: "notificationsOff"]) == .refused(.notificationsOff))
        #expect(Start.answer(from: [:]) == .noAnswer)
        #expect(Start.answer(from: [WatchLoanWireKey.startAnswer: "something new"]) == .noAnswer)
    }

    @Test(
        "Drag-to-watch Start: the glucose drops on the watch's screen at Home's bottom edge"
    ) @MainActor func dragGeometry() {
        let drag = TrioOnWatchStartDrag()
        drag.ringFrame = CGRect(x: 130, y: 100, width: 130, height: 130)
        #expect(!drag.isOverTarget, "no target before the overlay knows Home's frame")
        drag.screenFrame = CGRect(x: 0, y: 0, width: 393, height: 852)
        #expect(!drag.isOverTarget)
        // the ring's centre starts at (195, 165); the watch's screen spans about x 63-330, y 540-852
        drag.translation = CGSize(width: 4, height: 400)
        #expect(drag.isOverTarget)
        drag.translation = CGSize(width: 130, height: 600)
        #expect(drag.isOverTarget, "the screen's lower right")
        drag.translation = CGSize(width: 0, height: 350)
        #expect(!drag.isOverTarget, "on the band above the screen")
        drag.translation = CGSize(width: -150, height: 500)
        #expect(!drag.isOverTarget, "beside the screen")
    }

    @Test("Drag-to-watch Start: only from home, with Trio on the watch") func dragOffered() {
        var status = make(.home(epoch: 0, lastLoan: nil))
        #expect(!status.offersDragToStart)
        status.watchAppInstalled = true
        #if TRIO_ON_WATCH
            #expect(status.offersDragToStart)
        #endif
        #expect(!make(.lent(epoch: 1)).offersDragToStart)
    }
}

extension TrioOnWatchPhoneStart.Stage {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
