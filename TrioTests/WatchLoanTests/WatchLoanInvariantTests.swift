import Foundation
import Testing

@testable import Trio

/// V2-12 by exhaustive search: every interleaving of user taps, timers, message delivery, loss and reordering,
/// pump results (success and failure) and a crash after any effect, up to epoch 3 (a loan, its take-back and a second lend) and two requests.
@Suite("Watch loan: no-dosing states always have an alarm") struct WatchLoanInvariantTests {
    private struct Pair: Hashable {
        let phone: LoanWorld.PhoneKind
        let watch: LoanWorld.WatchKind
    }

    private func successors(of world: LoanWorld) -> [LoanWorld] {
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
        if world.requestCount < 2 { event { $0.onWatch(.startTapped, crashAfter: $1) } }
        event { $0.onWatch(.requestTimedOut, crashAfter: $1) }
        event { $0.onWatch(.endTapped, crashAfter: $1) }
        event { $0.onWatch(.handBackUnacknowledged, crashAfter: $1) }
        event { $0.onWatch(.foreignPodSession, crashAfter: $1) }
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
        add { $0.crash(.phone) }
        add { $0.crash(.watch, phoneAnswers: true) }
        add { $0.crash(.watch, phoneAnswers: false) }
        return next
    }

    private func isBounded(_ world: LoanWorld) -> Bool {
        (world.phone.epoch ?? 0) <= 3 && world.watch.epoch <= 3
            && world.toPhone.count <= 2 && world.toWatch.count <= 2
            && world.stopsToPhone.count <= 2 && world.stopsToWatch.count <= 2
            && world.phonePending.count <= 2 && world.watchPending.count <= 2
    }

    @Test(
        "V2-12: in every reachable state pair where no device may dose, an alarm is armed; never two commanders"
    ) func noSilentStop() {
        var seen: Set<LoanWorld> = [LoanWorld()]
        var queue = [LoanWorld()]
        var violations: [String] = []
        var noDoserPairs = Set<Pair>()

        while let world = queue.popLast() {
            for var candidate in successors(of: world) {
                candidate.lastEffectCount = 0
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
        // SM-5's named cases must be among the reached no-dosing pairs
        #expect(noDoserPairs.contains(Pair(phone: .lent, watch: .returning)))
        #expect(noDoserPairs.contains(Pair(phone: .lending, watch: .idle)))
        #expect(noDoserPairs.contains(Pair(phone: .lent, watch: .stopped)))
        #expect(noDoserPairs.contains(Pair(phone: .takingBack, watch: .idle)))
    }
}
