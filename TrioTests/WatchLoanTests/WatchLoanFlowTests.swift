import Foundation
import Testing

@testable import Trio

/// Start, End and Take Back step by step, with the message of each step lost and a crash after every effect
/// of each step. After the doc's recovery (timers, Take Back, both kits' next pod contact) the loan must settle
/// with one commander, and no state on the way may lack a not-looping alarm or have two commanders.
@Suite("Watch loan: hand-off steps with loss and crash") struct WatchLoanFlowTests {
    typealias F = LoanFixture

    enum Fault: CustomStringConvertible {
        case lose
        case crash(after: Int)

        var description: String {
            switch self {
            case .lose: return "message lost"
            case let .crash(after): return "crash after \(after) effects"
            }
        }

        static let crashes = (0 ... 6).map { Fault.crash(after: $0) }
    }

    enum StartStep: String, CaseIterable {
        case s1WatchRequests
        case s2PhoneLends
        case s3PhoneSendsGrant
        case s4WatchAdopts
        case s5WatchTakesControl
        case s6PhoneLent
    }

    enum EndStep: String, CaseIterable {
        case e1WatchReturns
        case e2WatchHandsBack
        case e3PhoneTakesBack
        case e4WatchIdle
        case e5PhoneHome
    }

    enum TakeBackStep: String, CaseIterable {
        case t1PhoneTakesBack
        case t2PhoneHome
        case t3WatchStops
        case t4WatchReleases
        case t5PhoneHearsStop
        case t6PhoneClearsWindow
    }

    /// Runs the happy path to `step`, applies `fault` there, finishes the path, then recovers.
    private func run<Step: CaseIterable & Equatable>(
        _ world: LoanWorld,
        steps: Step.AllCases,
        faultAt step: Step,
        _ fault: Fault,
        perform: (inout LoanWorld, Step, Int?) -> Bool
    ) -> LoanWorld {
        var world = world
        for current in steps {
            if current == step {
                switch fault {
                case .lose:
                    if !perform(&world, current, -1) { return world }
                case let .crash(after):
                    _ = perform(&world, current, after)
                }
            } else {
                _ = perform(&world, current, nil)
            }
        }
        world.recover()
        return world
    }

    private func expectSettled(_ world: LoanWorld, _ label: String) {
        #expect(world.violations.isEmpty, "\(label): \(world.violations)")
        #expect(world.isSettledAndConsistent, "\(label): \(world.phone), \(world.watch)")
    }

    // MARK: Start

    /// `crashAfter == -1` loses the step's message instead; returns false when the step has none.
    private func start(_ world: inout LoanWorld, _ step: StartStep, _ crashAfter: Int?) -> Bool {
        let lose = crashAfter == -1
        let crash = lose ? nil : crashAfter
        switch step {
        case .s1WatchRequests:
            guard !lose else { return false }
            world.onWatch(.startTapped, crashAfter: crash)
        case .s2PhoneLends:
            guard !world.toPhone.isEmpty else { return true }
            if lose { world.toPhone.removeFirst() } else { world.deliverToPhone(crashAfter: crash) }
        case .s3PhoneSendsGrant:
            guard !lose, !world.phonePending.isEmpty else { return !lose }
            world.completePhone(crashAfter: crash)
        case .s4WatchAdopts:
            guard !world.toWatch.isEmpty else { return true }
            if lose { world.toWatch.removeFirst() } else { world.deliverToWatch(crashAfter: crash) }
        case .s5WatchTakesControl:
            guard !lose, !world.watchPending.isEmpty else { return !lose }
            world.completeWatch(crashAfter: crash)
        case .s6PhoneLent:
            guard !world.toPhone.isEmpty else { return true }
            if lose { world.toPhone.removeFirst() } else { world.deliverToPhone(crashAfter: crash) }
        }
        return true
    }

    @Test("Start: clean run ends phone lent, watch holding") func startClean() {
        let world = LoanWorld.lent()
        #expect(world.phone == .lent(epoch: 1))
        #expect(world.watch == .holding(epoch: 1))
        expectSettled(world, "clean Start")
    }

    @Test("Start: message lost at each step", arguments: [
        StartStep.s2PhoneLends,
        .s4WatchAdopts,
        .s6PhoneLent
    ]) func startLoss(step: StartStep) {
        expectSettled(run(LoanWorld(), steps: StartStep.allCases, faultAt: step, .lose, perform: start), "\(step) lost")
    }

    @Test(
        "Start: crash of the acting device after each effect of each step",
        arguments: StartStep.allCases
    ) func startCrash(step: StartStep) {
        for fault in Fault.crashes {
            expectSettled(run(LoanWorld(), steps: StartStep.allCases, faultAt: step, fault, perform: start), "\(step), \(fault)")
        }
    }

    @Test(
        "Start: the other device crashes before each step",
        arguments: StartStep.allCases
    ) func startOtherCrash(step: StartStep) {
        let actingOnWatch: Set<StartStep> = [.s1WatchRequests, .s4WatchAdopts, .s5WatchTakesControl]
        var world = LoanWorld()
        for current in StartStep.allCases {
            if current == step { world.crash(actingOnWatch.contains(step) ? .phone : .watch) }
            _ = start(&world, current, nil)
        }
        world.recover()
        expectSettled(world, "\(step), other device crashed")
    }

    @Test("Start, doc rows: lost grant ends home; lost holding ends lent through the record batch") func startDocRows() {
        let grantLost = run(LoanWorld(), steps: StartStep.allCases, faultAt: .s4WatchAdopts, .lose, perform: start)
        #expect(grantLost.phone == .home(epoch: 2, lastLoan: F.superseding(1)))
        #expect(grantLost.watch == .idle(epoch: 2))

        let holdingLost = run(LoanWorld(), steps: StartStep.allCases, faultAt: .s6PhoneLent, .lose, perform: start)
        #expect(holdingLost.phone == .lent(epoch: 1))
        #expect(holdingLost.watch == .holding(epoch: 1))
    }

    @Test("Start: a grant arriving after the watch timed out is rejected, the phone retakes by itself") func startLateGrant() {
        var world = LoanWorld()
        world.onWatch(.startTapped)
        world.deliverToPhone()
        world.completePhone()
        world.onWatch(.requestTimedOut)
        world.deliverToWatch()
        #expect(world.watch == .idle(epoch: 0))
        world.settle()
        #expect(world.phone == .home(epoch: 2, lastLoan: LoanRecord(epoch: 1)))
        expectSettled(world, "late grant")
    }

    // MARK: End

    private func end(_ world: inout LoanWorld, _ step: EndStep, _ crashAfter: Int?) -> Bool {
        let lose = crashAfter == -1
        let crash = lose ? nil : crashAfter
        switch step {
        case .e1WatchReturns:
            guard !lose else { return false }
            world.onWatch(.endTapped, crashAfter: crash)
        case .e2WatchHandsBack:
            guard !lose, !world.watchPending.isEmpty else { return !lose }
            world.completeWatch(crashAfter: crash)
        case .e3PhoneTakesBack:
            guard !world.toPhone.isEmpty else { return true }
            if lose { world.toPhone.removeFirst() } else { world.deliverToPhone(crashAfter: crash) }
        case .e4WatchIdle:
            guard !world.toWatch.isEmpty else { return true }
            if lose { world.toWatch.removeFirst() } else { world.deliverToWatch(crashAfter: crash) }
        case .e5PhoneHome:
            guard !lose, !world.phonePending.isEmpty else { return !lose }
            world.completePhone(crashAfter: crash)
        }
        return true
    }

    @Test("End: clean run ends phone home(2), watch idle") func endClean() {
        var world = LoanWorld.lent()
        for step in EndStep.allCases { _ = end(&world, step, nil) }
        #expect(world.phone == .home(epoch: 2, lastLoan: LoanRecord(epoch: 1)))
        #expect(world.watch == .idle(epoch: 1))
        expectSettled(world, "clean End")
    }

    @Test("End: message lost at each step", arguments: [EndStep.e3PhoneTakesBack, .e4WatchIdle]) func endLoss(step: EndStep) {
        expectSettled(run(LoanWorld.lent(), steps: EndStep.allCases, faultAt: step, .lose, perform: end), "\(step) lost")
    }

    @Test(
        "End: crash of the acting device after each effect of each step",
        arguments: EndStep.allCases
    ) func endCrash(step: EndStep) {
        for fault in Fault.crashes {
            var world = run(LoanWorld.lent(), steps: EndStep.allCases, faultAt: step, fault, perform: end)
            if world.watchKind == .holding {
                // Crashed before persisting returning: the user taps End again
                world.onWatch(.endTapped)
                world.recover()
            }
            expectSettled(world, "\(step), \(fault)")
            #expect(world.phoneKind == .home, "\(step), \(fault)")
        }
    }

    @Test("End: the other device crashes before each step", arguments: EndStep.allCases) func endOtherCrash(step: EndStep) {
        let actingOnWatch: Set<EndStep> = [.e1WatchReturns, .e2WatchHandsBack, .e4WatchIdle]
        var world = LoanWorld.lent()
        for current in EndStep.allCases {
            if current == step { world.crash(actingOnWatch.contains(step) ? .phone : .watch) }
            _ = end(&world, current, nil)
        }
        world.recover()
        expectSettled(world, "\(step), other device crashed")
    }

    // MARK: Take Back

    private func takeBack(_ world: inout LoanWorld, _ step: TakeBackStep, _ crashAfter: Int?) -> Bool {
        let lose = crashAfter == -1
        let crash = lose ? nil : crashAfter
        switch step {
        case .t1PhoneTakesBack:
            guard !lose else { return false }
            world.onPhone(.takeBackTapped(watchAnswer: nil), crashAfter: crash)
        case .t2PhoneHome:
            guard !lose, !world.phonePending.isEmpty else { return !lose }
            world.completePhone(crashAfter: crash)
        case .t3WatchStops:
            guard !world.stopsToWatch.isEmpty else { return true }
            if lose { world.stopsToWatch.removeFirst() } else { world.deliverStopToWatch(crashAfter: crash) }
        case .t4WatchReleases:
            guard !lose, !world.watchPending.isEmpty else { return !lose }
            world.completeWatch(crashAfter: crash)
        case .t5PhoneHearsStop,
             .t6PhoneClearsWindow:
            guard !world.stopsToPhone.isEmpty else { return true }
            if lose { world.stopsToPhone.removeFirst() } else { world.deliverStopToPhone(crashAfter: crash) }
        }
        return true
    }

    @Test(
        "Take Back: clean run ends phone home(2), window cleared by the released stop, watch stopped and released"
    ) func takeBackClean() {
        var world = LoanWorld.lent()
        for step in TakeBackStep.allCases { _ = takeBack(&world, step, nil) }
        #expect(world.phone == .home(epoch: 2, lastLoan: LoanRecord(epoch: 1)))
        #expect(world.watch == .stopped(epoch: 1, reason: .superseded))
        #expect(!world.watchKit.hasControl)
        #expect(world.watchAlarms.isEmpty)
        world.recover()
        expectSettled(world, "clean Take Back")
    }

    @Test(
        "Take Back: message lost at each step",
        arguments: [TakeBackStep.t3WatchStops, .t5PhoneHearsStop, .t6PhoneClearsWindow]
    ) func takeBackLoss(step: TakeBackStep) {
        let world = run(LoanWorld.lent(), steps: TakeBackStep.allCases, faultAt: step, .lose, perform: takeBack)
        expectSettled(world, "\(step) lost")
        if step == .t6PhoneClearsWindow {
            // Without the release confirmation the window stays until it closes
            #expect(world.phone == .home(epoch: 2, lastLoan: F.superseding(1)))
        }
    }

    @Test(
        "Take Back: crash of the acting device after each effect of each step",
        arguments: TakeBackStep.allCases
    ) func takeBackCrash(step: TakeBackStep) {
        for fault in Fault.crashes {
            var world = run(LoanWorld.lent(), steps: TakeBackStep.allCases, faultAt: step, fault, perform: takeBack)
            if world.phoneKind == .lent {
                // Crashed before persisting takingBack: the user taps Take Back again
                world.onPhone(.takeBackTapped(watchAnswer: nil))
                world.recover()
            }
            expectSettled(world, "\(step), \(fault)")
            #expect(world.phoneKind == .home, "\(step), \(fault)")
        }
    }

    @Test(
        "Take Back: the watch crashes before it hears the revoke; on relaunch the phone's epoch stops it"
    ) func takeBackWatchCrash() {
        var world = LoanWorld.lent()
        _ = takeBack(&world, .t1PhoneTakesBack, nil)
        _ = takeBack(&world, .t2PhoneHome, nil)
        world.stopsToWatch.removeAll()
        world.crash(.watch, phoneAnswers: true)
        #expect(world.watch == .stopped(epoch: 1, reason: .superseded))
        world.recover()
        expectSettled(world, "watch crash before revoke")
    }

    @Test(
        "Take Back while the watch is off, watch relaunches with the phone unreachable: it never takes again"
    ) func takeBackWatchOffPhoneUnreachable() {
        var world = LoanWorld.lent()
        _ = takeBack(&world, .t1PhoneTakesBack, nil)
        _ = takeBack(&world, .t2PhoneHome, nil)
        world.stopsToWatch.removeAll()
        world.crash(.watch, phoneAnswers: false)
        #expect(world.watch == .holding(epoch: 1))
        #expect(world.watchPending.isEmpty)
        #expect(!world.commands(.watch))
        // Its next pod contact sees the phone's session and refuses
        world.session(.watch)
        #expect(world.watch == .stopped(epoch: 1, reason: .foreignSession))
        world.recover()
        expectSettled(world, "watch off during Take Back")
    }

    @Test(
        "Watch crashed before taking control, phone took back meanwhile and is unreachable: stop, never take"
    ) func adoptCrashThenTakeBack() {
        var world = LoanWorld()
        world.onWatch(.startTapped)
        world.deliverToPhone()
        world.completePhone()
        world.deliverToWatch()
        // Crashed after persisting holding, before the take ran and before holding reached the phone
        world.watchPending.removeAll()
        world.toPhone.removeAll()
        #expect(world.watchOnDisk == .holding(epoch: 1))
        world.onPhone(.takeBackTapped(watchAnswer: nil))
        world.stopsToWatch.removeAll()
        world.completePhone()
        #expect(world.phone.mayCommandPump)
        world.crash(.watch, phoneAnswers: false)
        #expect(world.watch == .stopped(epoch: 1, reason: .unconfirmed))
        #expect(!world.watchKit.hasControl)
        world.recover()
        expectSettled(world, "adopt crash then Take Back")
    }

    @Test(
        "Take Back while the watch's adopt is still in flight: the late adopt is refused, it never absorbs the take"
    ) func adoptRacesTakeBack() {
        var world = LoanWorld()
        world.onWatch(.startTapped)
        world.deliverToPhone()
        world.completePhone()
        world.deliverToWatch()
        world.toPhone.removeAll()
        world.onPhone(.takeBackTapped(watchAnswer: nil))
        world.stopsToWatch.removeAll()
        world.completePhone()
        #expect(world.phone.mayCommandPump)
        world.completeWatch()
        #expect(world.watch == .stopped(epoch: 1, reason: .foreignSession))
        #expect(!world.commands(.watch))
        world.recover()
        expectSettled(world, "adopt races Take Back")
    }
}
