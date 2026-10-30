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
            .startRefused(requestID: UUID(), reason: "Busy")
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

    @Test("A dose's identity goes back to the raw bytes it came from") func identity() {
        let raw = Data([0x0A, 0x1B, 0x2C])
        #expect(WatchLoopIdentity.hexEncoded(raw) == "0a1b2c")
        #expect(WatchLoopIdentity.raw("0a1b2c") == raw)
        #expect(WatchLoopIdentity.hexDecoded("0a1") == nil)
        #expect(WatchLoopIdentity.raw("not-hex") == Data("not-hex".utf8))
    }

    @Test("A saved phone state missing a field keeps the rest") func phoneStateDecodesLeniently() throws {
        let data = try JSONSerialization.data(withJSONObject: ["role": "lending", "session": 4])
        let state = try JSONDecoder().decode(WatchLoopPhoneState.self, from: data)
        #expect(state.role == .lending)
        #expect(state.session == 4)
        #expect(state.storedRecordIDs.isEmpty)
    }
}
