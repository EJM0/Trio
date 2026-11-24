import Foundation
import SwiftUI
import Testing
@testable import Trio

@Suite("Trio on Watch screens: state mapping") struct TrioOnWatchStatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    func status(_ phase: TrioOnWatchStatus.Phase) -> TrioOnWatchStatus {
        var status = TrioOnWatchStatus()
        status.phase = phase
        status.lastLoopAt = ago(2)
        status.readings = [.init(date: ago(3), mgdl: 112), .init(date: ago(8), mgdl: 109)]
        status.pumpLastContact = ago(2)
        status.reservoir = 86
        status.podEndsAt = now.addingTimeInterval(27 * 3600)
        status.sensorEndsAt = now.addingTimeInterval(52 * 3600)
        return status
    }

    static let phases: [TrioOnWatchStatus.Phase] = [
        .phone, .starting, .waitingForReading, .inControl, .ending,
        .stopped(.superseded), .stopped(.foreignSession), .stopped(.resumeWindowPassed), .stopped(.unconfirmed)
    ]

    @Test("Loop age uses the iOS ring rules, with the 30 s grace") func loopTier() {
        #expect(TrioOnWatchRules.loopTier(lastLoopAt: nil, now: now) == .unknown)
        #expect(TrioOnWatchRules.loopTier(lastLoopAt: now.addingTimeInterval(-330), now: now) == .fresh)
        #expect(TrioOnWatchRules.loopTier(lastLoopAt: now.addingTimeInterval(-331), now: now) == .aging)
        #expect(TrioOnWatchRules.loopTier(lastLoopAt: now.addingTimeInterval(-630), now: now) == .aging)
        #expect(TrioOnWatchRules.loopTier(lastLoopAt: now.addingTimeInterval(-631), now: now) == .stale)
    }

    @Test("The phone's loop age reads like every other age, not as the phone sent it (G-R3)") func phoneLoopAge() {
        let real = Date()
        let line = status(.phone).controlLine(now: real, phoneLoopText: "4 min")
        #expect(line.text == "iPhone · " + real.addingTimeInterval(-240).formattedTimeAgo())
        #expect(line.accessibilityLabel.contains(real.addingTimeInterval(-240).formattedSpokenTimeAgo()))
        #expect(status(.phone).controlLine(now: real, phoneLoopText: "--").text == "iPhone · --")
    }

    @Test("Control line: a symbol and a word for every state, never colour alone") func controlLine() {
        for phase in Self.phases {
            let line = status(phase).controlLine(now: now, phoneLoopText: "2 min")
            #expect(!line.symbol.isEmpty)
            #expect(!line.text.isEmpty)
            #expect(!line.accessibilityLabel.isEmpty)
        }
        #expect(status(.phone).controlLine(now: now, phoneLoopText: "2 min").symbol == "iphone")
        #expect(status(.inControl).controlLine(now: now, phoneLoopText: nil).symbol == "applewatch")
        #expect(status(.inControl).controlLine(now: now, phoneLoopText: nil).tier == .fresh)
        // before the first watch reading the watch doesn't claim control (V3-8)
        #expect(status(.waitingForReading).controlLine(now: now, phoneLoopText: nil).tier == .unknown)
        #expect(status(.stopped(.superseded)).controlLine(now: now, phoneLoopText: nil).tier == .stale)
        var noLoop = status(.inControl)
        noLoop.lastLoopAt = nil
        #expect(noLoop.controlLine(now: now, phoneLoopText: nil).tier == .unknown)
    }

    @Test("Control line: a pump condition wins over the loop age (G-M3)") func pumpCondition() {
        var watch = status(.inControl)
        #expect(watch.pumpCondition == nil)
        watch.insulinPaused = true
        #expect(watch.controlLine(now: now, phoneLoopText: nil).tier == .warning)
        watch.podUnreachable = true
        #expect(watch.controlLine(now: now, phoneLoopText: nil).tier == .stale)
        watch.insulinSuspended = true
        #expect(watch.controlLine(now: now, phoneLoopText: nil).text == "Insulin suspended")
        watch.podFaulted = true
        let line = watch.controlLine(now: now, phoneLoopText: nil)
        #expect(line.text == "Pod stopped")
        #expect(line.symbol == "exclamationmark.triangle.fill")
        #expect(line.accessibilityLabel.contains("not giving insulin"))
    }

    @Test("Main values: the watch's own reading, masked at 12 min") func mainValues() {
        let fresh = status(.inControl).mainValues(now: now)
        #expect(!fresh.isStale)
        #expect(fresh.glucose != "--")
        // the delta alone fits in the ring
        #expect(!fresh.detail.contains("·"))
        #expect(fresh.detail == Decimal(3).formattedDelta(for: .mgdL))
        #expect(!fresh.accessibilityLabel.isEmpty)

        var withIOB = status(.inControl)
        withIOB.iob = Decimal(string: "7.995")
        #expect(
            withIOB.mainValues(now: now).iob == Formatter.decimalFormatterWithTwoFractionDigits
                .string(from: 7.995 as NSNumber)
        )

        var old = status(.inControl)
        old.readings = [.init(date: ago(13), mgdl: 112)]
        let stale = old.mainValues(now: now)
        #expect(stale.isStale)
        #expect(stale.glucose == "--")
        #expect(stale.iob == "--")
    }

    @Test("Status page: tiles in watch mode, rows only for what they don't show, each one VoiceOver element") func rows() {
        #expect(!status(.phone).showsTiles && !status(.starting).showsTiles)
        #expect(status(.inControl).showsTiles && status(.stopped(.superseded)).showsTiles)
        #expect(status(.phone).rows(now: now).isEmpty)
        #expect(status(.starting).rows(now: now).isEmpty)
        let rows = status(.inControl).rows(now: now)
        #expect(rows.map(\.id) == ["sensor", "pump"], "the end times; ages and reservoir are in the tiles")
        var quiet = status(.inControl)
        quiet.podEndsAt = nil
        quiet.sensorEndsAt = nil
        #expect(quiet.rows(now: now).isEmpty)
        for phase in Self.phases {
            for row in status(phase).rows(now: now) {
                #expect(!row.accessibilityLabel.isEmpty)
                #expect(!row.lines.isEmpty)
            }
        }
    }

    @Test("Status page: battery only below 30 %, pod and unconfirmed notices") func notices() {
        var watch = status(.inControl)
        watch.battery = 0.31
        #expect(!watch.rows(now: now).contains { $0.id == "battery" })
        watch.battery = 0.22
        #expect(watch.rows(now: now).contains { $0.id == "battery" })

        let pumpLines = { (status: TrioOnWatchStatus) in status.rows(now: now).first { $0.id == "pump" }?.lines ?? [] }
        let plain = pumpLines(watch).count
        watch.podUnreachable = true
        watch.insulinPaused = true
        watch.insulinSuspended = true
        #expect(pumpLines(watch).count == plain + 2, "suspended shows in the temp basal tile")
        #expect(watch.rows(now: now).first { $0.id == "pump" }?.tint == .loopRed)

        #expect(!watch.rows(now: now).contains { $0.id == "loop" })
        watch.lastCycleAt = now
        #expect((watch.rows(now: now).first { $0.id == "loop" }?.lines.count ?? 0) == 1)
    }

    @Test("An Omnipod reservoir above 50 U shows as 50+, as on the phone") func reservoirAboveLimit() {
        var watch = status(.inControl)
        watch.reservoir = 51.15
        watch.reservoirAboveReadingLimit = true
        #expect(watch.reservoirText.contains("50+"))
        #expect(!watch.reservoirText.contains("51"))
        watch.reservoirAboveReadingLimit = false
        #expect(watch.reservoirText.contains("51"))
    }

    @Test("While the watch still has to pair with the sensor, the sensor row asks to keep Trio open") func sensorPairing() {
        var watch = status(.waitingForReading)
        let sensorLines = { (status: TrioOnWatchStatus) in status.rows(now: now).first { $0.id == "sensor" }?.lines ?? [] }
        let plain = sensorLines(watch).count
        watch.sensorNeedsPairing = true
        #expect(sensorLines(watch).count == plain + 1)
        #expect(watch.rows(now: now).first { $0.id == "sensor" }?.tint == .orange)
    }

    @Test("The arrow follows the watch's latest reading while it is fresh") func trendArrow() {
        var watch = status(.inControl)
        watch.readings = [.init(date: ago(3), mgdl: 112, direction: "FortyFiveUp")]
        #expect(watch.trend(now: now) == "FortyFiveUp")
        #expect(GlucoseTrendView.degrees(for: watch.trend(now: now)) == -45)
        watch.readings = [.init(date: ago(13), mgdl: 112, direction: "FortyFiveUp")]
        #expect(watch.trend(now: now) == nil, "a stale reading hides the arrow")
    }

    @Test("Reading age colours: green to 6 min, yellow to 12, red beyond") func readingTier() {
        #expect(TrioOnWatchRules.readingTier(lastReadingAt: ago(5), now: now) == .fresh)
        #expect(TrioOnWatchRules.readingTier(lastReadingAt: ago(9), now: now) == .aging)
        #expect(TrioOnWatchRules.readingTier(lastReadingAt: ago(13), now: now) == .stale)
        #expect(TrioOnWatchRules.readingTier(lastReadingAt: nil, now: now) == .unknown)
    }

    @Test("With a Medtrum patch the texts say patch, not pod") func patchWording() {
        var watch = status(.inControl)
        watch.podFaulted = true
        #expect(watch.controlLine(now: now, phoneLoopText: nil).text.lowercased().contains("pod"))
        watch.pumpIsPatch = true
        let line = watch.controlLine(now: now, phoneLoopText: nil)
        #expect(line.text.lowercased().contains("patch") && !line.text.lowercased().contains("pod"))
        #expect(watch.rows(now: now).allSatisfy { row in row.lines.allSatisfy { !$0.lowercased().contains(" pod") } })
        #expect(TrioOnWatchStatus.stopReason(.foreignSession, patch: true).contains("patch"))
    }

    @Test("In watch mode the graph shows the watch's readings and forecast") func watchModeGraph() {
        var watch = status(.inControl)
        let phone: [(date: Date, glucose: Double, color: Color)] = [
            (ago(60), 102, .green),
            (ago(55), 240, .orange),
            (ago(10), 101, .green)
        ]
        let limits = { (mgdl: Int) -> Color in mgdl < 70 ? .red : mgdl > 180 ? .orange : .green }
        #expect(watch.chartValues(phone: phone, color: limits).count == 3)

        watch.chartReadings = [.init(date: ago(10), mgdl: 101), .init(date: ago(5), mgdl: 235), .init(date: ago(0), mgdl: 55)]
        let values = watch.chartValues(phone: phone, color: limits)
        #expect(values.map(\.date) == [ago(60), ago(55), ago(10), ago(5), ago(0)])
        #expect(values[3].glucose == 235 && values[3].color == .orange)
        // a low the phone never showed is coloured by the phone's limits
        #expect(values[4].glucose == 55 && values[4].color == .red)

        #expect(watch.chartForecast(cone: true).start == nil)
        watch.forecast = .init(start: now, lines: ["iob": [100, 110], "zt": [90]])
        let cone = watch.chartForecast(cone: true)
        #expect(cone.start == now && cone.coneMin == [90] && cone.coneMax == [100])
        #expect(watch.chartForecast(cone: false).lines["iob"] == [100, 110])
    }

    @Test("Loop page counts: done out of one possible every 5 minutes since watch mode started") func loopPageCounts() {
        var watch = status(.inControl)
        #expect(watch.count(2, now: now) == nil)
        watch.watchModeSince = ago(17)
        #expect(watch.count(2, now: now)! == (2, 3))
        #expect(watch.count(4, now: now)! == (4, 4))
    }

    @Test("Loop page: the phone's readings count as readings, shown apart") func phoneReadingCount() {
        var watch = status(.inControl)
        watch.watchModeSince = ago(50)
        watch.watchReadings = 9
        watch.phoneReadings = 2
        let count = watch.count(watch.watchReadings, now: now)!
        #expect(count == (9, 10))
    }

    @Test("Loop page: what the last cycle did") func cycleResult() {
        typealias Result = TrioOnWatchStatus.CycleResult
        #expect(Result.enacted(.init(), tempConfirmed: nil, bolusConfirmed: nil) == "No change needed.")
        let temp = Result.enacted(
            .init(tempBasal: .init(unitsPerHour: 1.2, minutes: 30)),
            tempConfirmed: true,
            bolusConfirmed: nil
        )
        #expect(temp.contains("30 min") && !temp.contains("confirm"))
        let unconfirmed = Result.enacted(.init(bolus: 0.3), tempConfirmed: nil, bolusConfirmed: false)
        #expect(unconfirmed.contains("SMB") && unconfirmed.contains("didn't confirm"))
        #expect(Result.enacted(.init(heldBack: [.pumpSuspended]), tempConfirmed: nil, bolusConfirmed: nil).contains("suspended"))
        #expect(Result.noPumpStatus(patch: true).contains("patch"))
    }

    @Test("Primary action and footer by state") func primaryAndFooter() {
        #expect(status(.phone).primaryAction == .start)
        #expect(status(.starting).primaryAction == nil)
        #expect(status(.waitingForReading).primaryAction == .end)
        #expect(status(.inControl).primaryAction == .end)
        #expect(status(.ending).primaryAction == nil)
        #expect(status(.stopped(.superseded)).primaryAction == .acknowledgeStop)

        var away = status(.inControl)
        away.phoneReachable = false
        #expect(away.footer() != status(.inControl).footer())
        // no promise of continuous looping (G-7)
        for phase in Self.phases {
            #expect(!status(phase).footer().contains("keeps looping"))
        }
        let stopped = status(.stopped(.resumeWindowPassed)).footer()
        #expect(stopped.contains(TrioOnWatchStatus.pumpFailSafe))
        #expect(stopped.contains(TrioOnWatchStatus.stopReason(.resumeWindowPassed)))
    }

    @Test("Start facts: what applies, then the two fixed lines") func startFacts() {
        let fixed = TrioOnWatchStatus.startFacts(WatchLoanStartFacts(), now: now)
        #expect(fixed.map(\.id) == ["alarms", "nightscout"])

        let unknown = TrioOnWatchStatus.startFacts(nil, now: now)
        #expect(unknown.first?.id == "unknown")
        #expect(unknown.first?.isWarning == true)

        let facts = WatchLoanStartFacts(
            override: .init(name: "Exercise", startedAt: ago(30), endsAt: nil),
            tempTarget: .init(name: "Eating soon", startedAt: ago(10), endsAt: now.addingTimeInterval(1800)),
            podEndsAt: now.addingTimeInterval(3 * 3600),
            sensorEndsAt: now.addingTimeInterval(7 * 3600)
        )
        let rows = TrioOnWatchStatus.startFacts(facts, now: now)
        #expect(rows.map(\.id) == ["pod", "sensor", "override", "tempTarget", "alarms", "nightscout"])
        #expect(rows.first { $0.id == "pod" }?.isWarning == true)
        #expect(rows.first { $0.id == "sensor" }?.isWarning == false)
        #expect(rows.first { $0.id == "override" }?.isWarning == true)
        // no "can't break through" device comparison (G-6b)
        #expect(!rows.contains { $0.text.contains("break through") })
    }

    @Test("Hand-off: progress, result, and refusals that stay") func handOff() {
        var watch = status(.phone)
        #expect(HandOffStage.stage(.start, status: watch).isWorking)
        watch.phase = .starting
        #expect(HandOffStage.stage(.start, status: watch).isWorking)
        watch.phase = .waitingForReading
        #expect(HandOffStage.stage(.start, status: watch).isWorking)
        // the check comes once the pump has moved, as on the phone, not with the first reading
        watch.pumpAdopted = true
        #expect(HandOffStage.stage(.start, status: watch) == .succeeded(
            "Your watch has your pod. It starts looping with its next sensor reading."
        ))
        watch.pumpIsPatch = true
        #expect(HandOffStage.stage(.start, status: watch) == .succeeded(
            "Your watch has your patch. It starts looping with its next sensor reading."
        ))
        watch.pumpIsPatch = false
        watch.phase = .inControl
        #expect(HandOffStage.stage(.start, status: watch) == .succeeded("Your watch is in control."))
        watch.phase = .stopped(.foreignSession)
        #expect(HandOffStage.stage(.start, status: watch) == .failed(TrioOnWatchStatus.stopReason(.foreignSession)))

        var refused = status(.phone)
        refused.lastAlert = .startRefused(.indefiniteOverride)
        #expect(HandOffStage.stage(.start, status: refused) == .failed(TrioOnWatchStatus.refusalText(.indefiniteOverride)))
        refused.lastAlert = .phoneDidNotAnswer
        if case let .failed(text) = HandOffStage.stage(.start, status: refused) {
            // the phone may already have released the pump (G-1)
            #expect(!text.contains("Nothing changed"))
        } else {
            Issue.record("no answer must be a failure")
        }

        // End is tried: a silent phone is a refusal that stays (G-15)
        #expect(HandOffStage.stage(.end, status: status(.inControl), phoneSilent: true).isFailed)
        #expect(status(.waitingForReading).footer().contains(TrioOnWatchStatus.notGivingInsulinYet))

        var ending = status(.ending)
        #expect(HandOffStage.stage(.end, status: ending).isWorking)
        ending.phase = .phone
        #expect(HandOffStage.stage(.end, status: ending) == .succeeded("Your iPhone is in control."))
        var endRefused = status(.inControl)
        endRefused.lastAlert = .endRefused(.unconfirmedCommand)
        #expect(HandOffStage.stage(.end, status: endRefused) == .failed(TrioOnWatchStatus.refusalText(.unconfirmedCommand)))
    }

    @Test("Every refusal has plain words, no reason code") func refusals() {
        let all: [LoanRefusal] = [
            .featureOff, .bolusRunning, .unconfirmedCommand, .deliveryUncertain, .pumpStatusStale, .versionMismatch,
            .watchBatteryLow, .notificationsOff, .unsupportedWatch, .phoneUnreachable, .unsupportedDevice, .pumpScreenOpen,
            .indefiniteOverride, .notClosedLoop, .busy, .releaseRefused, .unknownRequest, .staleEpoch, .grantExpired,
            .snapshotIncomplete,
            .clockOffset, .timeZoneMismatch
        ]
        for refusal in all {
            let text = TrioOnWatchStatus.refusalText(refusal)
            #expect(!text.isEmpty)
            #expect(!text.contains("(\(refusal.rawValue))"))
            #expect(!text.contains("hand"))
            #expect(WatchLoanAlerts.text(for: refusal) == text)
        }
    }

    @Test("Bolus states: accepted is not delivered, failures stay, uncertain offers no retry") func bolus() {
        let states: [WatchLoanHost.BolusProgress] = [
            .idle, .requested, .accepted, .delivering, .done, .cancelled, .failed("Refused."), .uncertain
        ]
        for state in states {
            var watch = status(.inControl)
            watch.bolus = state
            let view = watch.bolusView(units: 1, carbsSaved: false)
            #expect(!view.title.isEmpty)
            #expect(!view.detail.isEmpty)
            switch state {
            case .accepted,
                 .delivering:
                #expect(view.showsCancel)
                #expect(!view.isFinished)
                #expect(!view.title.contains("finished"))
            case .cancelled,
                 .failed:
                #expect(view.needsAcknowledgement)
            case .uncertain:
                #expect(view.needsAcknowledgement)
                #expect(view.showsRecentDoses)
                #expect(!view.showsCancel)
                #expect(!view.detail.lowercased().contains("try again"))
            case .done:
                #expect(view.isFinished)
                #expect(!view.needsAcknowledgement)
            case .idle,
                 .requested:
                #expect(!view.isFinished)
            }
        }
        var uncertain = status(.inControl)
        uncertain.bolus = .uncertain
        uncertain.phoneReachable = false
        let away = uncertain.bolusView(units: 1, carbsSaved: true).detail
        uncertain.phoneReachable = true
        #expect(away != uncertain.bolusView(units: 1, carbsSaved: true).detail)
    }

    @MainActor @Test("Bolus amounts round down to the pump increment") func units() {
        #expect(LoanTreatments.units(0.35, increment: 0.05) == Decimal(string: "0.35"))
        #expect(LoanTreatments.units(0.37, increment: 0.05) == Decimal(string: "0.35"))
        #expect(LoanTreatments.units(1.0, increment: 0.1) == 1)
        #expect(LoanTreatments.units(1, increment: 0) == 0)
    }

    @MainActor @Test("Every screenshot fixture resolves") func fixtures() {
        let names = [
            "main-phone", "main-starting", "main-in-control", "main-no-loop-yet", "main-loop-late", "main-ending", "main-stopped",
            "status-phone", "status-starting", "status-waiting-reading", "status-in-control", "status-phone-away",
            "status-pod-unreachable", "status-suspended", "status-stopped", "start-facts", "start-indefinite-override",
            "start-no-answer", "handoff-starting", "handoff-waiting-reading", "handoff-started", "handoff-refused",
            "handoff-no-answer", "handoff-ending", "handoff-end-refused", "end-confirmation", "bolus-sending",
            "bolus-accepted", "bolus-delivering", "bolus-done", "bolus-cancelled", "bolus-failed", "bolus-uncertain",
            "recent-doses", "carbs-saved", "override-sheet", "main-phone-fresh", "main-pod-stopped", "main-suspended",
            "main-pod-unreachable", "main-bolus-paused", "handoff-not-closed-loop"
        ]
        for name in names {
            #expect(TrioOnWatchFixture.named(name, now: now) != nil, "\(name)")
        }
    }
}

private extension HandOffStage {
    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
