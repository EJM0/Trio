import Foundation
import Testing
@testable import Trio

@Suite("Watch Loop models") struct WatchLoopModelTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func dose(_ kind: WatchLoopDose.Kind, value: Double, start: Date, minutes: Double = 0, delivered: Double? = nil)
        -> WatchLoopDose
    {
        WatchLoopDose(
            kind: kind,
            syncIdentifier: "0a1b2c",
            startDate: start,
            endDate: start.addingTimeInterval(minutes * 60),
            value: value,
            deliveredUnits: delivered,
            automatic: true,
            isMutable: false
        )
    }

    @Test("Every message survives the wire") func messagesRoundTrip() throws {
        let record = WatchLoopRecord(seq: 1, session: 3, loggedAt: t0, kind: .dose(dose(.bolus, value: 1.5, start: t0)))
        let messages: [WatchLoopMessage] = [
            .request(WatchLoopRequest(id: UUID(), sentAt: t0, highestSession: 2)),
            .checkpoint(WatchLoopCheckpoint(session: 3, sentAt: t0, startedAt: t0, records: [record], status: nil)),
            .checkpoint(WatchLoopCheckpoint(session: 3, sentAt: t0, startedAt: t0, records: [
                WatchLoopRecord(seq: 2, session: 3, loggedAt: t0, kind: .glucose(BloodGlucose(
                    id: "m", mbg: 120, date: 1_790_000_000_000, dateString: t0, glucose: 120, type: "mbg"
                ))),
                WatchLoopRecord(seq: 3, session: 3, loggedAt: t0, kind: .determination(
                    Determination(
                        id: UUID(), reason: "COB: 0", units: nil, insulinReq: nil, eventualBG: 110,
                        sensitivityRatio: nil, rate: 0.5, duration: 30, iob: 1.25, cob: 0, predictions: nil, deliverAt: t0,
                        carbsReq: nil, temp: .absolute, bg: 120, reservoir: nil, isf: nil, timestamp: t0, tdd: nil,
                        current_target: nil, minDelta: nil, expectedDelta: nil, minGuardBG: nil, minPredBG: nil,
                        threshold: nil, carbRatio: nil, received: nil
                    ),
                    enacted: true
                ))
            ], status: nil)),
            .ack(session: 3, recordIDs: [record.id]),
            .handBack(WatchLoopHandBack(session: 3, records: [record], odometer: WatchLoopOdometer(
                deliveredAtStart: 10,
                startReadAt: t0,
                deliveredLatest: 12,
                latestReadAt: t0.addingTimeInterval(3600)
            ))),
            .handBackAck(session: 3),
            .stop(session: 3),
            .statusQuery(id: UUID()),
            .statusReport(WatchLoopStatusReport(replyTo: nil, session: 3, holdsPump: true, startedAt: t0, pumpReachable: false)),
            .startRefused(requestID: UUID(), reason: "Busy"),
            .remoteTreatment(WatchLoopRemoteTreatment(
                id: UUID(), sentAt: t0, bolus: 1.5, carbs: 30, fat: nil, protein: nil, carbsDate: t0, mealID: "m"
            )),
            .remoteTreatmentResult(id: UUID(), delivered: true, message: "Bolus started")
        ]
        for message in messages {
            let wire = try WatchLoopTransport.encode(message)
            let envelope = try #require(try WatchLoopTransport.decode(wire))
            #expect(envelope.message == message)
            #expect(envelope.version == WatchLoopTransport.version)
        }
    }

    @Test("Other traffic on the channel is not ours, another version refuses") func foreignPayloads() throws {
        #expect(try WatchLoopTransport.decode(["watchState": [:]]) == nil)
        let other = try JSONSerialization.data(withJSONObject: ["version": 99])
        #expect(throws: WatchLoopTransport.TransportError.versionMismatch(seen: 99)) {
            try WatchLoopTransport.decode([WatchLoopTransport.key: other])
        }
    }

    @Test("Bookkeeping only queues; what a person waits through rides both channels") func channels() {
        #expect(WatchLoopTransport.ridesBothChannels(.stop(session: 1)))
        #expect(WatchLoopTransport.ridesBothChannels(.statusQuery(id: UUID())))
        #expect(!WatchLoopTransport.ridesBothChannels(.ack(session: 1, recordIDs: [])))
    }

    @Test("The copy that came by the other channel is dropped") func duplicates() {
        var seen = WatchLoopSeenEnvelopes()
        let id = UUID()
        let first = seen.firstSighting(of: id)
        let second = seen.firstSighting(of: id)
        #expect(first)
        #expect(!second)
    }

    @Test("The audit books what the records miss and warns of what they overstate") func audit() {
        #expect(WatchLoopAudit.compare(delivered: 5.1, recorded: 5.0) == .matches)
        #expect(WatchLoopAudit.compare(delivered: 6.0, recorded: 5.0) == .missing(units: 1.0))
        #expect(WatchLoopAudit.compare(delivered: 4.0, recorded: 5.0) == .overstated(units: 1.0))
    }

    @Test("A dose's insulin within a stretch") func insulin() {
        let end = t0.addingTimeInterval(3600)
        #expect(WatchLoopAudit.insulin(dose(.bolus, value: 2, start: t0, delivered: 1.5), from: t0, to: end) == 1.5)
        #expect(WatchLoopAudit.insulin(dose(.bolus, value: 2, start: t0.addingTimeInterval(-60)), from: t0, to: end) == 0)
        // a 1 U bolus over two minutes, read one minute in: half on each side of the reading
        let running = WatchLoopDose(
            kind: .bolus, syncIdentifier: "b", startDate: t0.addingTimeInterval(-60), endDate: t0.addingTimeInterval(60),
            value: 1, deliveredUnits: nil, automatic: false, isMutable: true
        )
        #expect(WatchLoopAudit.insulin(running, from: t0, to: end) == 0.5)
        #expect(WatchLoopAudit.insulin(running, from: t0.addingTimeInterval(-3600), to: t0) == 0.5)
        // a 1 U/h temp, half of it inside the stretch
        #expect(
            WatchLoopAudit
                .insulin(dose(.tempBasal, value: 1, start: t0.addingTimeInterval(-1800), minutes: 60), from: t0, to: end) == 0.5
        )
    }

    @Test("The records account for the scheduled basal where no temp ran") func recordedInsulin() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = calendar.startOfDay(for: t0)
        let profile = [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1)]
        // two hours: the first an hour of a 0 U/h temp, the second scheduled at 1 U/h, plus a 0.5 U bolus
        let temp = dose(.tempBasal, value: 0, start: midnight, minutes: 60)
        let bolus = dose(.bolus, value: 0.5, start: midnight.addingTimeInterval(90 * 60))
        let total = WatchLoopAudit.recordedInsulin(
            [temp, bolus],
            basalProfile: profile,
            from: midnight,
            to: midnight.addingTimeInterval(2 * 3600),
            calendar: calendar
        )
        #expect(abs(total - 1.5) < 0.0001)
    }

    @Test("A temp ends where the next begins and counts in whole pulses") func recordedTemps() {
        let profile = [BasalProfileEntry(start: "00:00", minutes: 0, rate: 0)]
        let end = t0.addingTimeInterval(3600)
        // a 1 U/h temp for 30 min, superseded after 10 by a 2 U/h one for 30 min, then the schedule (0 U/h)
        let first = dose(.tempBasal, value: 1, start: t0, minutes: 30)
        let second = dose(.tempBasal, value: 2, start: t0.addingTimeInterval(600), minutes: 30)
        let total = WatchLoopAudit.recordedInsulin([first, second], basalProfile: profile, from: t0, to: end)
        #expect(abs(total - (1.0 / 6 + 1.0)) < 0.0001)
        // in 0.05 U pulses: 10 min at 1 U/h is 3 whole pulses (0.15 U), 30 min at 2 U/h 20 (1.0 U)
        let pulsed = WatchLoopAudit.recordedInsulin([first, second], basalProfile: profile, from: t0, to: end, pulseUnits: 0.05)
        #expect(abs(pulsed - 1.15) < 0.0001)
    }

    @Test("A dose's identity goes back to the raw bytes it came from") func identity() {
        let raw = Data([0x0A, 0x1B, 0x2C])
        #expect(WatchLoopIdentity.hexEncoded(raw) == "0a1b2c")
        #expect(WatchLoopIdentity.raw("0a1b2c") == raw)
        #expect(WatchLoopIdentity.hexDecoded("0a1") == nil)
        #expect(WatchLoopIdentity.raw("not-hex") == Data("not-hex".utf8))
    }

    @Test("A span runs from the watch's session start until the phone has the pod back") func spans() {
        var state = WatchLoopPhoneState()
        state.role = .standingAside
        state.sessionStartedAt = t0
        state.noteSpan(at: t0.addingTimeInterval(600))
        state.role = .transferring
        state.noteSpan(at: t0.addingTimeInterval(1200))
        state.role = .holdsPump
        state.noteSpan(at: t0.addingTimeInterval(1800))
        #expect(state.spans == [WatchLoopSpan(start: t0, end: t0.addingTimeInterval(1800))])
        // uploaded and a day old: gone
        state.spans[0].uploaded = true
        state.noteSpan(at: t0.addingTimeInterval(1800 + 24 * 3600 + 1))
        #expect(state.spans.isEmpty)
    }

    @Test("A saved phone state missing a field keeps the rest") func phoneStateDecodesLeniently() throws {
        let data = try JSONSerialization.data(withJSONObject: ["role": "lending", "session": 4])
        let state = try JSONDecoder().decode(WatchLoopPhoneState.self, from: data)
        #expect(state.role == .lending)
        #expect(state.session == 4)
        #expect(state.storedRecordIDs.isEmpty)
    }

    @Test("The audit reads the pump's doses and leaves external insulin out") func dosesFromHistory() {
        let history = [
            PumpHistoryEvent(id: "b", type: .bolus, timestamp: t0, amount: 1),
            PumpHistoryEvent(id: "x", type: .bolus, timestamp: t0, amount: 2, isExternal: true),
            PumpHistoryEvent(id: "t", type: .tempBasal, timestamp: t0, rate: 1.2),
            PumpHistoryEvent(id: "_t", type: .tempBasalDuration, timestamp: t0, durationMin: 30)
        ]
        let doses = WatchLoopAudit.doses(history, now: t0.addingTimeInterval(3600))
        #expect(doses.map(\.syncIdentifier).sorted() == ["b", "t"])
        #expect(doses.first { $0.kind == .tempBasal }?.endDate == t0.addingTimeInterval(30 * 60))
    }

    @Test("A phone killed mid-transfer comes back lending, its report overdue") func transferringResolves() throws {
        let data = try JSONSerialization.data(withJSONObject: ["role": "transferring", "session": 4])
        let state = try JSONDecoder().decode(WatchLoopPhoneState.self, from: data)
        #expect(state.role == .lending)
        #expect(state.lastReportAt == .distantPast)
        #expect(state.session == 4)
    }
}
