import Foundation
import Testing

@testable import Trio

@Suite("Watch loan: delivered-total audit") struct WatchLoanAuditTests {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!
    /// 10:00 local in Berlin.
    static let start = Date(timeIntervalSince1970: 1_800_003_600)
    static let flatProfile = [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1)]

    static func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    static func bolus(_ minutes: Double, _ units: Decimal, id: String = UUID().uuidString) -> PumpHistoryEvent {
        PumpHistoryEvent(id: id, type: .bolus, timestamp: at(minutes), amount: units)
    }

    static func temp(_ minutes: Double, rate: Decimal, duration: Int, scheduled: Bool = false) -> PumpHistoryEvent {
        PumpHistoryEvent(
            id: UUID().uuidString,
            type: .tempBasal,
            timestamp: at(minutes),
            amount: rate,
            duration: duration,
            isScheduledBasal: scheduled
        )
    }

    static func input(
        hours: Double = 2,
        delivered: Double,
        remainder: Double = 0,
        profile: [BasalProfileEntry] = flatProfile,
        events: [PumpHistoryEvent] = []
    ) -> WatchLoanAudit.Input {
        WatchLoanAudit.Input(
            start: start,
            startUnits: 10,
            end: at(hours * 60),
            endUnits: 10 + delivered,
            bolusRemainder: remainder,
            basalProfile: profile,
            timeZone: berlin,
            pulse: 0.05,
            events: events
        )
    }

    @Test("Scheduled basal only: the schedule explains the pod, nothing is booked") func scheduledOnly() {
        let result = WatchLoanAudit.evaluate(Self.input(delivered: 2.0))
        #expect(abs(result.expected - 2.0) < 1E-9)
        #expect(result.unexplained == 0)
        #expect(!result.isShortfall)
    }

    @Test("Scheduled basal follows the profile across a change, in the grant's time zone") func scheduleChange() {
        // 10:00 to 12:00 Berlin, the rate changes at 11:00
        let profile = [
            BasalProfileEntry(start: "00:00", minutes: 0, rate: 1),
            BasalProfileEntry(start: "11:00", minutes: 660, rate: 2)
        ]
        let units = WatchLoanAudit.scheduledUnits(
            DateInterval(start: Self.start, end: Self.at(120)),
            profile: profile,
            timeZone: Self.berlin
        )
        #expect(abs(units - 3.0) < 1E-9)
        // the same instant in another zone sits elsewhere in the schedule
        let utc = WatchLoanAudit.scheduledUnits(
            DateInterval(start: Self.start, end: Self.at(120)),
            profile: profile,
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(abs(utc - 2.0) < 1E-9)
    }

    @Test("A suspended span delivers nothing") func suspend() {
        let events = [
            PumpHistoryEvent(id: "s", type: .pumpSuspend, timestamp: Self.at(30)),
            PumpHistoryEvent(id: "r", type: .pumpResume, timestamp: Self.at(90))
        ]
        let result = WatchLoanAudit.evaluate(Self.input(delivered: 1.0, events: events))
        #expect(abs(result.expected - 1.0) < 1E-9)
        #expect(result.unexplained == 0)
    }

    @Test("A suspend still running at the window's end, and one from before its start, count") func openSuspends() {
        let fromBefore = [
            PumpHistoryEvent(id: "s", type: .pumpSuspend, timestamp: Self.at(-30)),
            PumpHistoryEvent(id: "r", type: .pumpResume, timestamp: Self.at(60))
        ]
        #expect(abs(WatchLoanAudit.expectedDelivery(Self.input(delivered: 0, events: fromBefore)) - 1.0) < 1E-9)
        let untilEnd = [PumpHistoryEvent(id: "s", type: .pumpSuspend, timestamp: Self.at(90))]
        #expect(abs(WatchLoanAudit.expectedDelivery(Self.input(delivered: 0, events: untilEnd)) - 1.5) < 1E-9)
    }

    @Test("A temp replaces the schedule during its span, in whole pulses, and ends at the next temp") func temps() {
        // 0.0-30 min: temp 3 U/h (1.5 U); 30-45: temp 0 cut short at 45 by a 2 U/h temp for 30 min (1.0 U);
        // 75-120: scheduled 1 U/h (0.75 U)
        let events = [
            Self.temp(0, rate: 3, duration: 30),
            Self.temp(30, rate: 0, duration: 120),
            Self.temp(45, rate: 2, duration: 30),
            Self.temp(10, rate: 9, duration: 30, scheduled: true)
        ]
        let expected = WatchLoanAudit.expectedDelivery(Self.input(delivered: 0, events: events))
        #expect(abs(expected - 3.25) < 1E-9)
        // a temp that doesn't fill whole pulses counts only the whole ones: 1.33 U/h for 30 min = 0.665 → 0.65
        let partial = WatchLoanAudit.expectedDelivery(Self.input(hours: 0.5, delivered: 0, events: [
            Self.temp(0, rate: 1.33, duration: 30)
        ]))
        #expect(abs(partial - 0.65) < 1E-9)
    }

    @Test("A temp running into the window counts only its part inside") func tempFromBefore() {
        let expected = WatchLoanAudit.expectedDelivery(Self.input(delivered: 0, events: [Self.temp(-15, rate: 2, duration: 30)]))
        // 15 min at 2 U/h (0.5 U), then 105 min scheduled at 1 U/h (1.75 U)
        #expect(abs(expected - 2.25) < 1E-9)
    }

    @Test("Excess beyond one pulse plus 0.15 U is booked as whole pulses; within it nothing is") func tolerance() {
        #expect(WatchLoanAudit.evaluate(Self.input(delivered: 2.2)).unexplained == 0)
        let result = WatchLoanAudit.evaluate(Self.input(delivered: 3.0))
        #expect(abs(result.unexplained - 0.8) < 1E-9)
        #expect(WatchLoanAudit.evaluate(Self.input(delivered: 2.27)).unexplained == 0.05)
    }

    @Test("Booked boluses count; the tagged audit bolus never does") func boluses() {
        let events = [
            Self.bolus(20, 1.0),
            Self.bolus(40, 0.5),
            Self.bolus(60, 0.8, id: WatchLoanAudit.auditBolusIDPrefix + "3"),
            Self.bolus(130, 4.0)
        ]
        let result = WatchLoanAudit.evaluate(Self.input(delivered: 3.5, events: events))
        #expect(abs(result.expected - 3.5) < 1E-9)
        #expect(result.unexplained == 0)
    }

    @Test("A bolus under way counts its undelivered remainder as delivered") func bolusRemainder() {
        // the watch's 2 U bolus is booked in full, the pod has delivered 1.2 U of it so far
        let events = [Self.bolus(110, 2.0)]
        let withoutRemainder = WatchLoanAudit.evaluate(Self.input(delivered: 3.2, events: events))
        #expect(withoutRemainder.isShortfall)
        let withRemainder = WatchLoanAudit.evaluate(Self.input(delivered: 3.2, remainder: 0.8, events: events))
        #expect(!withRemainder.isShortfall)
        #expect(withRemainder.unexplained == 0)
        // nothing booked yet for it: the whole bolus, delivered part plus remainder, is unexplained
        let unbooked = WatchLoanAudit.evaluate(Self.input(delivered: 3.2, remainder: 0.8))
        #expect(abs(unbooked.unexplained - 1.8) < 1E-9)
    }

    @Test("Late records shrink the audit bolus: the amount is recomputed, never added") func recompute() {
        let before = WatchLoanAudit.evaluate(Self.input(delivered: 4.0))
        #expect(abs(before.unexplained - 1.8) < 1E-9)
        let partly = WatchLoanAudit.evaluate(Self.input(delivered: 4.0, events: [
            Self.bolus(30, 1.0),
            Self.bolus(60, 1.8, id: WatchLoanAudit.auditBolusIDPrefix + "3")
        ]))
        #expect(abs(partly.unexplained - 0.8) < 1E-9)
        let fully = WatchLoanAudit.evaluate(Self.input(delivered: 4.0, events: [Self.bolus(30, 1.0), Self.bolus(31, 1.0)]))
        #expect(fully.unexplained == 0)
        #expect(!fully.isShortfall)
    }

    @Test("A booked intent counts as booked, so the audit doesn't book it again") func bookedIntent() {
        // the watch couldn't confirm a 1 U bolus and booked it as delivered
        let result = WatchLoanAudit.evaluate(Self.input(delivered: 3.0, events: [Self.bolus(50, 1.0, id: "intent-1")]))
        #expect(result.unexplained == 0)
    }

    @Test("Shortfall beyond tolerance is reported, never booked") func shortfall() {
        let result = WatchLoanAudit.evaluate(Self.input(delivered: 1.0))
        #expect(result.isShortfall)
        #expect(result.unexplained == 0)
    }

    @Test("Pod lifetime: from activation at 0 U, all booked doses against the pod's total") func podLifetime() {
        var input = Self.input(hours: 24, delivered: 0, events: [Self.bolus(60, 5), Self.bolus(600, 3)])
        input.startUnits = 0
        input.endUnits = 24 + 8 + 2
        let result = WatchLoanAudit.evaluate(input)
        #expect(abs(result.expected - 32) < 1E-9)
        #expect(abs(result.unexplained - 1.8) < 1E-9)
    }
}
