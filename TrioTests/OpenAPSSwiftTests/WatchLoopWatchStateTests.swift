import Foundation
import Testing
@testable import Trio

@Suite("Watch Loop on the watch") struct WatchLoopWatchStateTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func bolus(_ id: String, _ units: Double, delivered: Double? = nil, mutable: Bool = false) -> WatchLoopDose {
        WatchLoopDose(
            kind: .bolus,
            syncIdentifier: id,
            startDate: t0,
            endDate: t0.addingTimeInterval(60),
            value: units,
            deliveredUnits: delivered,
            automatic: false,
            isMutable: mutable
        )
    }

    @Test("A bolus reported again replaces its earlier form, in the history and in the records") func doseReplaced() {
        var state = WatchLoopWatchState()
        state.session = 2
        state.noteDose(bolus("ab", 2, mutable: true), at: t0)
        state.noteDose(bolus("ab", 2, delivered: 1.5), at: t0.addingTimeInterval(60))
        #expect(state.history.count == 1)
        #expect(state.history.first?.amount == 1.5)
        #expect(state.pending.count == 1)
        #expect(state.pending.first?.seq == 2)
        #expect(state.pending.first?.session == 2)
    }

    @Test("The algorithm reads the phone's history and the watch's own, newest first, each once") func pumpHistoryMerged() {
        var state = WatchLoopWatchState()
        let phoneEvent = PumpHistoryEvent(id: "p1", type: .bolus, timestamp: t0.addingTimeInterval(-3600), amount: 1)
        let sameAsWatch = PumpHistoryEvent(id: "ab", type: .bolus, timestamp: t0, amount: 2)
        state.grant = nil
        state.history = bolus("ab", 3).historyEvents
        #expect(state.pumpHistory.map(\.id) == ["ab"])
        state.history = []
        state.noteDose(bolus("ab", 3), at: t0)
        let merged = WatchLoopWatchState.merged(phone: [phoneEvent, sameAsWatch], own: state.history)
        #expect(merged.map(\.id) == ["ab", "p1"])
        #expect(merged.first?.amount == 3)
    }

    @Test("Acknowledged records stop being sent") func acknowledge() {
        var state = WatchLoopWatchState()
        state.record(.carbsDeleted(id: "x"), at: t0)
        state.record(.carbsDeleted(id: "y"), at: t0)
        state.acknowledge([state.pending[0].id])
        #expect(state.pending.count == 1)
        #expect(state.nextSeq == 3)
    }

    @Test("The newest temp target decides, until it ends or is cancelled") func activeTempTarget() {
        var state = WatchLoopWatchState()
        let target = TempTarget(
            name: "Activity", createdAt: t0, targetTop: 140, targetBottom: 140, duration: 60,
            enteredBy: TempTarget.local, reason: nil, isPreset: false, enabled: true, halfBasalTarget: nil
        )
        state.tempTargets = [target]
        #expect(state.activeTempTarget(at: t0.addingTimeInterval(30 * 60))?.targetBottom == 140)
        #expect(state.activeTempTarget(at: t0.addingTimeInterval(61 * 60)) == nil)
        state.tempTargets.append(TempTarget.cancel(at: t0.addingTimeInterval(10 * 60)))
        #expect(state.activeTempTarget(at: t0.addingTimeInterval(30 * 60)) == nil)
    }

    @Test("Smoothing changes CGM readings only and keeps their order") func smoothing() {
        let readings = (0 ..< 12).reversed().map { step -> BloodGlucose in
            let date = t0.addingTimeInterval(Double(step) * 300)
            let value = 100 + (step % 2 == 0 ? 6 : -6)
            return BloodGlucose(
                id: "\(step)", sgv: value, direction: nil, date: Decimal(date.timeIntervalSince1970 * 1000),
                dateString: date, unfiltered: nil, filtered: nil, noise: nil, glucose: value
            )
        }
        let smoothed = WatchLoopWatchState.smoothed(readings)
        #expect(smoothed.map(\.id) == readings.map(\.id))
        #expect(smoothed.map(\.sgv) != readings.map(\.sgv))
        #expect(smoothed.allSatisfy { abs(($0.sgv ?? 0) - 100) <= 6 })
    }

    @Test("A saved watch state missing a field keeps the rest") func decodesLeniently() throws {
        let data = try JSONSerialization.data(withJSONObject: ["phase": "active", "session": 7, "closedLoop": false])
        let state = try JSONDecoder().decode(WatchLoopWatchState.self, from: data)
        #expect(state.phase == .active)
        #expect(state.session == 7)
        #expect(!state.closedLoop)
        #expect(state.pending.isEmpty)
        #expect(state.nextSeq == 1)
    }
}
