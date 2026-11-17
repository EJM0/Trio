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
        #expect(status.pill(now: now).text.hasSuffix(status.lastLoop!.formattedTimeAgo()))
        #expect(status.pill(now: now).accessibilityLabel.contains(status.lastLoop!.formattedSpokenTimeAgo()))
        // at large text only the age remains, never cut (G-M11)
        #expect(status.pill(now: now).compactText == status.lastLoop?.formattedTimeAgo())
        status.lastLoop = nil
        #expect(status.pill(now: now).compactText == "--")
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
        let messages = Set(contexts.map(TrioOnWatchPhoneStatus.takeBackMessage))
        #expect(messages.count == 3)
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

    @Test("Every phone screenshot fixture resolves") func fixtures() {
        for name in [
            "starting", "start-unconfirmed+sheet+takeback", "in-control", "in-control-reachable+sheet+takeback",
            "in-control+sheet+takeback", "no-updates", "taking-back", "taking-back-stuck+sheet", "pod-refused+sheet+usepod",
            "unreadable+sheet", "in-control+treatments", "in-control+adjustments", "in-control+settings"
        ] {
            #expect(TrioOnWatchPhoneFixture.named(name, now: now) != nil, "\(name)")
        }
    }
}
