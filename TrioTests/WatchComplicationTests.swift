import Foundation
import SwiftUI
import Testing
@testable import Trio

@Suite("Watch Complication") struct WatchComplicationTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeModel(_ kind: ComplicationKind, _ state: ComplicationState, at date: Date) -> ComplicationModel {
        ComplicationModel(kind: kind, state: state, rendering: ComplicationRendering(referenceDate: date))
    }

    private func decodeSettings(_ json: String) throws -> TrioSettings {
        try JSONDecoder().decode(TrioSettings.self, from: Data(json.utf8))
    }

    @Test("Settings without complication keys use the defaults") func settingsDefaults() throws {
        let settings = try decodeSettings("{}")
        #expect(settings.watchComplicationCornerValue == WatchComplicationDefaults.cornerValue)
        #expect(settings.watchComplicationSecondaryValue == WatchComplicationDefaults.secondaryValue)
    }

    @Test("Stored complication settings decode") func settingsDecode() throws {
        let json = #"{"watchComplicationCornerValue": "cob", "watchComplicationSecondaryValue": "loopAge"}"#
        let settings = try decodeSettings(json)
        #expect(settings.watchComplicationCornerValue == .cob)
        #expect(settings.watchComplicationSecondaryValue == .loopAge)
    }

    @Test("Snapshot round-trips through the store encoding") func snapshotRoundTrips() throws {
        let sample = ComplicationState.sample(
            units: "mg/dL",
            settings: ComplicationSlotSettings(cornerValue: .cob, secondaryValue: .loopAge),
            date: now
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(ComplicationState.self, from: data)
        #expect(decoded == sample)
        #expect(!decoded.isMmol)
        #expect(decoded.history.count == 36)
        #expect(decoded.cornerValue == .cob)
    }

    @Test("Units decide the gauge range and clamp the value") func gaugeRange() {
        var state = ComplicationState.sample(units: "mmol/L", date: now)
        #expect(state.gaugeRange == 2.5 ... 16.0)
        state.glucoseValue = 25
        #expect(state.gaugeValue == 16.0)
        state.glucoseValue = 1
        #expect(state.gaugeValue == 2.5)

        state = ComplicationState.sample(units: "mg/dL", date: now)
        #expect(state.gaugeRange == 45 ... 290)
        #expect(state.gaugeValue == 115)
    }

    @Test("Aging flips after 5 minutes, staleness after 10") func stalenessThresholds() {
        let state = ComplicationState.sample(units: "mg/dL", date: now)
        #expect(!state.isAging(at: now.addingTimeInterval(5 * 60)))
        #expect(state.isAging(at: now.addingTimeInterval(5 * 60 + 1)))
        #expect(!state.isStale(at: now.addingTimeInterval(10 * 60)))
        #expect(state.isStale(at: now.addingTimeInterval(10 * 60 + 1)))
        #expect(state.minutesAgo(at: now.addingTimeInterval(11 * 60)) == 11)
    }

    @Test("An aging reading shows its time in place of the delta") func agingShowsReadingTime() {
        var state = ComplicationState.sample(
            units: "mg/dL",
            settings: ComplicationSlotSettings(secondaryValue: .delta),
            date: now
        )
        state.trend = "Flat"
        state.delta = "+3"
        let time = now.formatted(date: .omitted, time: .shortened)
        #expect(makeModel(.glucose, state, at: now.addingTimeInterval(5 * 60)).secondaryText == "→ +3")
        for minutes in [6.0, 11, 120] {
            let model = makeModel(.glucose, state, at: now.addingTimeInterval(minutes * 60))
            #expect(model.secondaryText == "→ \(time)")
            #expect(model.glucoseWithArrow == "115→")
        }
    }

    @Test("A stale reading is greyed") func staleReadingGreyed() {
        let state = ComplicationState.sample(units: "mg/dL", date: now)
        let fresh = makeModel(.glucose, state, at: now.addingTimeInterval(7 * 60))
        #expect(fresh.valueColor == .primary)
        #expect(fresh.dimColor == .secondary)
        let stale = makeModel(.glucose, state, at: now.addingTimeInterval(11 * 60))
        #expect(stale.glucoseColor == .gray)
        #expect(stale.valueColor == .gray)
        #expect(stale.dimColor == .gray)
    }

    @Test("Every kind keeps showing a stale glucose") func staleGlucoseByKind() {
        var state = ComplicationState.sample(units: "mg/dL", date: now)
        state.trend = "Flat"
        let staleDate = now.addingTimeInterval(60 * 60)
        #expect(makeModel(.glucose, state, at: staleDate).glucoseWithArrow == "115→")
        #expect(makeModel(.gauge, state, at: staleDate).cornerMainText == "115")
        #expect(makeModel(.chart, state, at: staleDate).glucoseText == "115")
    }

    @Test("Slot text follows the chosen value") func slotText() {
        var state = ComplicationState.sample(units: "mmol/L", date: now)
        state.trend = "FortyFiveUp"
        state.delta = "+0.3"
        #expect(state.trendArrow == "↗︎")
        #expect(state.labelledText(for: .nothing) == "")
        #expect(state.labelledText(for: .iob) == "IOB 1.25")
        #expect(state.plainText(for: .iob) == "1.25")
        #expect(state.labelledText(for: .cob) == "COB 12")
        #expect(state.labelledText(for: .delta) == "↗︎ +0.3")
        #expect(state.labelledText(for: .loopAge) == "Loop 2 min")
        state.trend = "Unknown"
        #expect(state.trendArrow == "")
        #expect(state.plainText(for: .delta) == "+0.3")
    }

    @Test("Loop staleness is separate from reading staleness") func loopStaleness() {
        var state = ComplicationState.sample(units: "mmol/L", date: now)
        state.loopDate = now.addingTimeInterval(-20 * 60)
        let model = makeModel(.iob, state, at: now)
        #expect(!model.isStale)
        #expect(model.isLoopStale)
        #expect(model.valueColor == .gray)
        #expect(model.statusLine == "loop 20 min")
        state.loopDate = nil
        #expect(!state.isLoopStale(at: now.addingTimeInterval(3600)))
    }

    @Test("Loop age counts up from the loop date") func loopAge() {
        var state = ComplicationState.sample(units: "mg/dL", date: now)
        state.loopDate = now
        state.lastLoopTime = "1 min"
        #expect(state.loopAgeText(at: now.addingTimeInterval(7 * 60)) == "7 min")
        #expect(state.loopAgeText(at: now.addingTimeInterval(-60)) == "0 min")
        #expect(state.loopAgeText(at: now.addingTimeInterval(1440 * 60)) == "1440 min")
        #expect(state.loopAgeText(at: now.addingTimeInterval(1441 * 60)) == "--")
        let model = makeModel(.glucose, state, at: now.addingTimeInterval(7 * 60))
        #expect(model.displayedState.labelledText(for: .loopAge) == "Loop 7 min")

        state.loopDate = nil
        #expect(state.loopAgeText(at: now.addingTimeInterval(7 * 60)) == "1 min")
    }

    @Test("A stale loop replaces IOB and COB with dashes") func loopStaleValues() {
        var state = ComplicationState.sample(units: "mg/dL", date: now)
        state.loopDate = now.addingTimeInterval(-10 * 60)
        var model = makeModel(.iob, state, at: now)
        #expect(model.displayedState.iob == "1.25")
        #expect(model.iobText == "1.25 U")
        #expect(model.cobText == "12 g")
        #expect(model.valueColor == .primary)

        state.loopDate = now.addingTimeInterval(-10 * 60 - 1)
        model = makeModel(.iob, state, at: now)
        #expect(model.displayedState.iob == "--")
        #expect(model.displayedState.cob == "--")
        #expect(model.iobText == "--")
        #expect(model.cobText == "--")
        #expect(model.displayedState.labelledText(for: .iob) == "IOB --")
        #expect(model.displayedState.plainText(for: .cob) == "--")
        #expect(model.valueColor == .gray)
    }

    @Test("A missing loop date greys IOB and COB but keeps their values") func loopUnknown() {
        var state = ComplicationState.sample(units: "mg/dL", date: now)
        state.loopDate = nil
        let model = makeModel(.iob, state, at: now)
        #expect(model.isLoopUnknown)
        #expect(!model.isLoopStale)
        #expect(model.displayedState.iob == "1.25")
        #expect(model.iobText == "1.25 U")
        #expect(model.valueColor == .gray)
        let rendering = ComplicationRendering(referenceDate: now, isPlaceholder: true)
        #expect(!ComplicationModel(kind: .iob, state: .placeholder, rendering: rendering).isLoopUnknown)
    }

    @Test("Ring and chart band follow the user's limits") func inRangeBand() {
        var state = ComplicationState.sample(units: "mg/dL", date: now)
        #expect(state.inRangeBand == 70 ... 180)
        state.limits = 80 ... 160
        #expect(state.inRangeBand == 80 ... 160)
        state.limits = nil
        #expect(state.inRangeBand == 70 ... 180)
        let model = makeModel(.gauge, state, at: state.date)
        #expect(model.gaugeGradient.stops.first?.color == .red)
        #expect(model.gaugeGradient.stops.count == 5)
    }

    @Test("Placeholder has no reading and a neutral colour") func placeholder() {
        let state = ComplicationState.placeholder
        #expect(state.gaugeValue == nil)
        let rendering = ComplicationRendering(referenceDate: now, isPlaceholder: true)
        let model = ComplicationModel(kind: .gauge, state: state, rendering: rendering)
        #expect(model.gaugeValue == (45.0 + 290.0) / 2)
        #expect(model.gaugeGradient == Gradient(colors: [.gray, .gray]))
        #expect(state.history.isEmpty)
        #expect(state.trendArrow == "")
        #expect(Color(complicationHex: "#4cd964") != nil)
        #expect(Color(complicationHex: "4cd964ff") == nil)
        #expect(Color(complicationHex: "zzz") == nil)
    }

    private func londonCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func londonDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        londonCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test("Transfers are spread over what is left of the day") func transferBudgetSpread() {
        let noon = londonDate(2026, 6, 1, 12)
        let spread: TimeInterval = 12 * 60 * 60 / 6
        func isDue(after elapsed: TimeInterval) -> Bool {
            ComplicationTransferBudget.isTransferDue(
                at: noon,
                lastTransfer: noon.addingTimeInterval(-elapsed),
                remainingTransfers: 6,
                calendar: londonCalendar()
            )
        }
        #expect(!isDue(after: spread - 1))
        #expect(isDue(after: spread))
    }

    @Test("A scarce budget is never spent faster than the spread") func transferBudgetScarce() {
        let noon = londonDate(2026, 6, 1, 12)
        let isDueAfterTwoHours = ComplicationTransferBudget.isTransferDue(
            at: noon,
            lastTransfer: noon.addingTimeInterval(-2 * 60 * 60),
            remainingTransfers: 1,
            calendar: londonCalendar()
        )
        #expect(!isDueAfterTwoHours)
    }

    @Test("Transfers keep a minimum gap late in the day") func transferBudgetMinimumGap() {
        let lateEvening = londonDate(2026, 6, 1, 23)
        func isDue(after elapsed: TimeInterval) -> Bool {
            ComplicationTransferBudget.isTransferDue(
                at: lateEvening,
                lastTransfer: lateEvening.addingTimeInterval(-elapsed),
                remainingTransfers: 50,
                calendar: londonCalendar()
            )
        }
        #expect(!isDue(after: 10 * 60 - 1))
        #expect(isDue(after: 10 * 60))
    }

    @Test("An empty budget never transfers") func transferBudgetExhausted() {
        #expect(!ComplicationTransferBudget.isTransferDue(at: now, lastTransfer: .distantPast, remainingTransfers: 0))
    }

    @Test("The day's end follows the clock on a 25 hour day") func transferBudgetClockChange() {
        let lateOnClockChange = londonDate(2026, 10, 25, 23).addingTimeInterval(30 * 60)
        let isDueAfterTwentyMinutes = ComplicationTransferBudget.isTransferDue(
            at: lateOnClockChange,
            lastTransfer: lateOnClockChange.addingTimeInterval(-20 * 60),
            remainingTransfers: 1,
            calendar: londonCalendar()
        )
        #expect(!isDueAfterTwentyMinutes)
    }

    @Test("The application context payload is a property list") func applicationContextIsPropertyList() throws {
        var state = WatchState(date: now)
        state.currentGlucose = "115"
        state.lastLoopDate = now
        state.lowGlucoseLimit = 70
        state.highGlucoseLimit = 180
        state.maxBolus = 2.5
        state.forecastLines = ["iob": [100, 110]]
        state.forecastStartDate = now
        let context = [WatchMessageKeys.watchState: BaseWatchManager.watchStateToDictionary(from: state)]
        let data = try PropertyListSerialization.data(fromPropertyList: context, format: .binary, options: 0)
        #expect(!data.isEmpty)
    }
}
