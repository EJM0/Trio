import Foundation
import Testing
@testable import Trio

@Suite("OrefRun stages") struct OrefRunStageTests {
    let now = Date(timeIntervalSince1970: 1_781_699_400)

    private func hoursAgo(_ hours: Double) -> Date {
        now.addingTimeInterval(-hours * 3600)
    }

    @Test("TDD insulin sums boluses, temp basals and inferred scheduled basal") func tddInsulin() {
        let history = [
            PumpHistoryEvent(id: "smb", type: .bolus, timestamp: hoursAgo(1), amount: 0.5, duration: 0, isSMB: true),
            PumpHistoryEvent(id: "resume", type: .pumpResume, timestamp: hoursAgo(1.5)),
            PumpHistoryEvent(id: "suspend", type: .pumpSuspend, timestamp: hoursAgo(2)),
            PumpHistoryEvent(id: "bolus", type: .bolus, timestamp: hoursAgo(3), amount: 2, duration: 0),
            PumpHistoryEvent(id: "temp", type: .tempBasal, timestamp: hoursAgo(4), amount: 2, duration: 60),
            // a schedule report covers nothing; it only anchors the window
            PumpHistoryEvent(
                id: "schedule",
                type: .tempBasal,
                timestamp: hoursAgo(6),
                amount: 4,
                duration: 1440,
                isScheduledBasal: true
            )
        ]

        let insulin = OrefInputs.tddInsulin(
            pumpHistory: history,
            basalProfile: [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1)],
            now: now,
            timeZone: TimeZone.current,
            roundToSupportedBasalRate: { $0 }
        )

        #expect(insulin.bolus == 2.5)
        #expect(insulin.tempBasal == 2, "1 h at 2 U/h")
        // gaps -6…-4 h, -3…-2 h and -1.5 h…now at 1 U/h; the suspension delivers nothing
        #expect(insulin.scheduledBasal == 4.5)
    }

    @Test("TDD scheduled basal is looked up in the given time zone, never the process zone") func tddTimeZone() throws {
        let profile = [
            BasalProfileEntry(start: "00:00", minutes: 0, rate: 0.5),
            BasalProfileEntry(start: "06:00", minutes: 360, rate: 1),
            BasalProfileEntry(start: "12:00", minutes: 720, rate: 1.5),
            BasalProfileEntry(start: "18:00", minutes: 1080, rate: 0.8)
        ]
        func scheduledBasal(now: Date, timeZone: String) throws -> Decimal {
            let history = [
                PumpHistoryEvent(id: "temp", type: .tempBasal, timestamp: now - 4 * 3600, amount: 2, duration: 60),
                PumpHistoryEvent(
                    id: "schedule",
                    type: .tempBasal,
                    timestamp: now - 20 * 3600,
                    amount: 1,
                    duration: 1440,
                    isScheduledBasal: true
                )
            ]
            return OrefInputs.tddInsulin(
                pumpHistory: history,
                basalProfile: profile,
                now: now,
                timeZone: try #require(TimeZone(identifier: timeZone)),
                roundToSupportedBasalRate: { $0 }
            ).scheduledBasal
        }

        // 14:30 CEST and 14:30 JST: the same wall-clock day in both zones
        let berlin = try scheduledBasal(now: now, timeZone: "Europe/Berlin")
        let tokyo = try scheduledBasal(now: now - 7 * 3600, timeZone: "Asia/Tokyo")
        #expect(berlin == tokyo)
        #expect(berlin != (try scheduledBasal(now: now, timeZone: "Asia/Tokyo")))
    }

    @Test("Autosens is reused for under 30 minutes") func autosensFreshness() {
        func autosens(minutesAgo: Double?) -> Autosens {
            var autosens = Autosens(ratio: 1, newisf: nil)
            autosens.timestamp = minutesAgo.map { now.addingTimeInterval(-$0 * 60) }
            return autosens
        }

        #expect(!OrefRun.isAutosensFresh(nil, now: now))
        #expect(!OrefRun.isAutosensFresh(autosens(minutesAgo: nil), now: now))
        #expect(OrefRun.isAutosensFresh(autosens(minutesAgo: 30 - 1.0 / 60), now: now))
        #expect(!OrefRun.isAutosensFresh(autosens(minutesAgo: 30), now: now))
    }
}
