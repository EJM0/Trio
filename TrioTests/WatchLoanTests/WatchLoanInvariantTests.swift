import Foundation
import Testing

@testable import Trio

/// Exhaustive search over every interleaving of user taps, timers, message delivery, loss and reordering, pump results
/// (success and failure), either kit talking to the pod at any time, and a crash after any effect, up to epoch 2
/// (one loan and its take-back). The default run allows one Start; `TRIO_STRESS=1` allows a second one (about 4 min).
/// Kits follow `LoanWorld.Kit`: a take absorbs the other controller's session silently, so a device counts as
/// commanding unless its kit provably refuses.
@Suite("Watch loan: never two commanders, never a silent stop") struct WatchLoanInvariantTests {
    private struct Pair: Hashable {
        let phone: LoanWorld.PhoneKind
        let watch: LoanWorld.WatchKind
    }

    private func successors(of world: LoanWorld, requests: Int) -> [LoanWorld] {
        var next: [LoanWorld] = []
        func add(_ action: (inout LoanWorld) -> Void) {
            var copy = world
            action(&copy)
            next.append(copy)
        }
        /// The event as is, then a crash after each of its effects.
        func event(_ action: (inout LoanWorld, Int?) -> Void) {
            var copy = world
            action(&copy, nil)
            next.append(copy)
            guard copy.lastEffectCount > 0 else { return }
            for crash in 0 ..< copy.lastEffectCount {
                add { action(&$0, crash) }
            }
        }

        event { $0.onPhone(.takeBackTapped(watchAnswer: nil), crashAfter: $1) }
        event { let answer = $0.watch
            $0.onPhone(.takeBackTapped(watchAnswer: answer), crashAfter: $1) }
        if world.phoneKit.refuses, world.phoneOnDisk.mayCommandPump || world.phoneOnDisk.isTakingBack {
            event { $0.onPhone(.usePodOnThisPhoneConfirmed, crashAfter: $1) }
        }
        if world.requestCount < requests { event { $0.onWatch(.startTapped, crashAfter: $1) } }
        event { $0.onWatch(.requestTimedOut, crashAfter: $1) }
        event { $0.onWatch(.endTapped, crashAfter: $1) }
        event { $0.onWatch(.handBackUnacknowledged, crashAfter: $1) }
        event { $0.onWatch(.stopAcknowledged, crashAfter: $1) }
        for index in world.toPhone.indices { event { $0.deliverToPhone(index, crashAfter: $1) } }
        for index in world.toWatch.indices { event { $0.deliverToWatch(index, crashAfter: $1) } }
        for index in world.stopsToPhone.indices { event { $0.deliverStopToPhone(index, crashAfter: $1) } }
        for index in world.stopsToWatch.indices { event { $0.deliverStopToWatch(index, crashAfter: $1) } }
        for index in world.phonePending.indices {
            for succeeded in [true, false] { event { $0.completePhone(index, succeeded: succeeded, crashAfter: $1) } }
        }
        for index in world.watchPending.indices {
            for succeeded in [true, false] { event { $0.completeWatch(index, succeeded: succeeded, crashAfter: $1) } }
        }
        for index in world.toPhone.indices { add { $0.toPhone.remove(at: index) } }
        for index in world.toWatch.indices { add { $0.toWatch.remove(at: index) } }
        for index in world.stopsToPhone.indices { add { $0.stopsToPhone.remove(at: index) } }
        for index in world.stopsToWatch.indices { add { $0.stopsToWatch.remove(at: index) } }
        add { $0.session(.phone) }
        add { $0.session(.watch) }
        add { $0.crash(.phone) }
        add { $0.crash(.watch, phoneAnswers: true) }
        add { $0.crash(.watch, phoneAnswers: false) }
        return next
    }

    private func isBounded(_ world: LoanWorld) -> Bool {
        (world.phone.epoch ?? 0) <= 2 && world.watch.epoch <= 2
            && world.toPhone.count <= 2 && world.toWatch.count <= 2
            && world.stopsToPhone.count <= 2 && world.stopsToWatch.count <= 2
            && world.phonePending.count <= 2 && world.watchPending.count <= 2
    }

    @Test("Every reachable state: at most one commander, and an alarm whenever nobody doses") func noTwoCommandersNoSilentStop() {
        search(requests: 1)
    }

    @Test(
        "Same search with a second Start",
        .enabled(if: ProcessInfo.processInfo.environment["TRIO_STRESS"] == "1")
    ) func noTwoCommandersNoSilentStopTwoRequests() {
        search(requests: 2)
    }

    private func search(requests: Int) {
        var seen: Set<LoanWorld> = [LoanWorld()]
        var queue = [LoanWorld()]
        var violations: [String] = []
        var noDoserPairs = Set<Pair>()

        while let world = queue.popLast() {
            for var candidate in successors(of: world, requests: requests) {
                candidate.lastEffectCount = 0
                candidate.canonicalize()
                if !candidate.violations.isEmpty {
                    if violations.count < 20 { violations += candidate.violations }
                    candidate.violations = []
                }
                guard isBounded(candidate), seen.insert(candidate).inserted else { continue }
                if candidate.nobodyMayDose {
                    noDoserPairs.insert(Pair(phone: candidate.phoneKind, watch: candidate.watchKind))
                }
                queue.append(candidate)
            }
        }

        #expect(violations.isEmpty, "\(violations)")
        #expect(seen.count > 1000, "searched \(seen.count) states")
        // The safety review's named no-dosing pairs must be reached
        #expect(noDoserPairs.contains(Pair(phone: .lent, watch: .returning)))
        #expect(noDoserPairs.contains(Pair(phone: .lending, watch: .idle)))
        #expect(noDoserPairs.contains(Pair(phone: .lent, watch: .stopped)))
        #expect(noDoserPairs.contains(Pair(phone: .takingBack, watch: .idle)))
    }

    @Test(
        "The kit model catches a plain take over a newer session (the relaunch take this machine no longer emits)"
    ) func kitModelCatchesPlainTake() {
        var world = LoanWorld.lent()
        world.onPhone(.takeBackTapped(watchAnswer: nil))
        world.stopsToWatch.removeAll()
        world.completePhone()
        #expect(world.violations.isEmpty)
        // What a relaunch take would do: the watch's take absorbs the phone's session
        world.watchPending.append(.take(epoch: 1, until: nil))
        world.completeWatch()
        #expect(world.violations.contains { $0.contains("two commanders") })
    }
}

private extension LoanWorld {
    /// Any queued item can be delivered next, so queue order carries no information. Sorting merges equal worlds;
    /// hash order is stable within one run, which is all the search needs.
    mutating func canonicalize() {
        toPhone.sort { $0.hashValue < $1.hashValue }
        toWatch.sort { $0.hashValue < $1.hashValue }
        stopsToPhone.sort { $0.hashValue < $1.hashValue }
        stopsToWatch.sort { $0.hashValue < $1.hashValue }
        phonePending.sort { $0.hashValue < $1.hashValue }
        watchPending.sort { $0.hashValue < $1.hashValue }
    }
}
