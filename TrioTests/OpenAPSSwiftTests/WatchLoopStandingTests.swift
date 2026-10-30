import Foundation
import Testing
@testable import Trio

@Suite("Watch Loop without the phone") struct WatchLoopStandingTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func inputs(_ readingsMinutesAgo: [Double]) -> WatchLoopFallback.Inputs {
        WatchLoopFallback.Inputs(
            ownReadings: readingsMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
            phoneNewestReading: now.addingTimeInterval(-20 * 60),
            phoneLastLoop: now.addingTimeInterval(-20 * 60),
            phoneAnswered: false,
            sensorProblemNow: false,
            lastSensorProblemAt: nil,
            copyUsable: true,
            now: now
        )
    }

    @Test("Two consecutive readings of the watch's own, phone silent: the fallback starts") func starts() {
        #expect(WatchLoopFallback.shouldStart(inputs([1, 6])))
    }

    @Test("One reading, or two not five minutes apart, start nothing") func needsCadence() {
        #expect(!WatchLoopFallback.shouldStart(inputs([1])))
        #expect(!WatchLoopFallback.shouldStart(inputs([1, 2])))
        #expect(!WatchLoopFallback.shouldStart(inputs([1, 11])))
        // too old
        #expect(!WatchLoopFallback.shouldStart(inputs([13, 18])))
    }

    @Test("A sensor problem now or in the last 15 minutes starts nothing") func sensorProblem() {
        var problem = inputs([1, 6])
        problem.sensorProblemNow = true
        #expect(!WatchLoopFallback.shouldStart(problem))
        var recent = inputs([1, 6])
        recent.lastSensorProblemAt = now.addingTimeInterval(-10 * 60)
        #expect(!WatchLoopFallback.shouldStart(recent))
        recent.lastSensorProblemAt = now.addingTimeInterval(-16 * 60)
        #expect(WatchLoopFallback.shouldStart(recent))
    }

    @Test("A phone that answers, loops or reads the sensor keeps the pod") func phoneThere() {
        var answered = inputs([1, 6])
        answered.phoneAnswered = true
        #expect(!WatchLoopFallback.shouldStart(answered))
        var looping = inputs([1, 6])
        looping.phoneLastLoop = now.addingTimeInterval(-4 * 60)
        #expect(!WatchLoopFallback.shouldStart(looping))
        var reading = inputs([1, 6])
        reading.phoneNewestReading = now.addingTimeInterval(-3 * 60)
        #expect(!WatchLoopFallback.shouldStart(reading))
        var noCopy = inputs([1, 6])
        noCopy.copyUsable = false
        #expect(!WatchLoopFallback.shouldStart(noCopy))
    }

    @Test("The phone's history as doses: a temp ends at the next one, a suspend at the resume") func doses() {
        let t0 = now.addingTimeInterval(-3600)
        let history = [
            PumpHistoryEvent(id: "t1", type: .tempBasal, timestamp: t0, amount: 2, duration: 30),
            PumpHistoryEvent(id: "t2", type: .tempBasal, timestamp: t0.addingTimeInterval(10 * 60), amount: 0, duration: 30),
            PumpHistoryEvent(id: "b", type: .bolus, timestamp: t0.addingTimeInterval(15 * 60), amount: 1),
            PumpHistoryEvent(id: "s", type: .pumpSuspend, timestamp: t0.addingTimeInterval(50 * 60)),
            PumpHistoryEvent(id: "r", type: .pumpResume, timestamp: t0.addingTimeInterval(55 * 60))
        ]
        let doses = WatchLoopStanding.doses(history, now: now)
        #expect(doses.map(\.syncIdentifier) == ["t1", "t2", "b", "s"])
        #expect(doses[0].endDate == t0.addingTimeInterval(10 * 60))
        #expect(doses[3].endDate == t0.addingTimeInterval(55 * 60))
        // 2 U/h for 10 min, then a 0 temp for 30, a 1 U bolus, the schedule at 1 U/h for the other 15 min
        let profile = [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1)]
        let total = WatchLoopAudit.recordedInsulin(doses, basalProfile: profile, from: t0, to: now)
        #expect(abs(total - (2.0 / 6 + 1 + 15.0 / 60)) < 0.0001)
    }

    @Test("A bolus from the phone's history lasts as long as the pump takes to give it") func bolusDuration() {
        let t0 = now.addingTimeInterval(-600)
        let history = [PumpHistoryEvent(id: "b", type: .bolus, timestamp: t0, amount: 2)]
        // 2 U at 1.5 U/min: 80 s; read 40 s in, half of it is still to come
        let doses = WatchLoopStanding.doses(history, now: now) { $0 / 1.5 * 60 }
        #expect(doses[0].endDate == t0.addingTimeInterval(80))
        #expect(abs(WatchLoopAudit.insulin(doses[0], from: t0.addingTimeInterval(40), to: now) - 1) < 0.0001)
    }
}
