import Foundation
import SwiftUI

// MARK: - Zone C: meal panel (IOB / COB / delivery rate)

extension Home.RootView {
    var basalString: String? {
        var rate: NSNumber = 0
        var manualBasalString = ""

        guard let apsManager = state.apsManager else {
            return nil
        }

        if apsManager.isScheduledBasal == true {
            guard let scheduledRate = scheduledBasalDeliveryRate(at: Date()) else {
                return nil
            }
            rate = scheduledRate
        } else {
            guard let lastTempBasal = state.tempBasals.last?.tempBasal, let tempRate = lastTempBasal.rate else {
                return nil
            }
            if apsManager.isManualTempBasal {
                manualBasalString = String(
                    localized: " - Manual Basal ⚠️",
                    comment: "Manual Temp basal"
                )
            }
            rate = tempRate
        }

        let rateString = Formatter.decimalFormatterWithThreeFractionDigits.string(from: rate) ?? "0"
        return rateString + String(localized: " U/hr", comment: "Unit per hour with space") +
            manualBasalString
    }

    func scheduledBasalDeliveryRate(at when: Date) -> NSNumber? {
        let calendar = Calendar(identifier: .gregorian)

        let hours = calendar.component(.hour, from: when)
        let minutes = calendar.component(.minute, from: when)
        let totalMinutes = hours * 60 + minutes

        if let rate = findBasalRateForOffset(for: totalMinutes, in: state.basalProfile) {
            return NSDecimalNumber(decimal: rate)
        }
        return nil
    }

    /// The meal slot has two states: the live IOB / COB / delivery-rate row, and — while the
    /// main chart is being scrubbed — the readout for the selected point. The scrub readout
    /// wins: it answers the same three questions for a different instant, and showing it here
    /// keeps the chart itself unobstructed.
    ///
    /// It renders from `chartReadoutDate`, not from `chartSelection` directly, so a hole in
    /// the data can't flicker the slot (see `updateChartReadout`).
    /// Both halves stay mounted and cross-fade on `opacity`. Swapping them with `if`/`else`
    /// left the exit to a removal transition, which never played: the row's root is a
    /// `ViewThatFits` and its background is a glass/material effect, and neither survives one
    /// — the readout blinked out while the arrival faded in normally. Opacity is a plain
    /// animatable value, so both directions animate.
    @ViewBuilder func mealPanel() -> some View {
        ZStack {
            liveMealPanel
                .opacity(isChartReadoutVisible ? 0 : 1)

            // Renders from the last resolved selection, which is deliberately not cleared on
            // decay: the row has to keep its values to fade out with, and it is invisible
            // (and untouchable) for as long as no readout is showing.
            if let readoutDate = chartReadoutDate,
               let selectedGlucose = ChartSelectionLookup.glucose(at: readoutDate, in: state.glucoseFromPersistence)
            {
                ChartSelectionRow(
                    selectedGlucose: selectedGlucose,
                    determination: chartReadoutDeterminationDate.flatMap {
                        ChartSelectionLookup.determination(at: $0, in: state.enactedAndNonEnactedDeterminations)
                    },
                    units: state.units,
                    highGlucose: state.highGlucose,
                    lowGlucose: state.lowGlucose,
                    currentGlucoseTarget: state.currentGlucoseTarget,
                    glucoseColorScheme: state.glucoseColorScheme,
                    isSmoothingEnabled: state.settingsManager.settings.smoothGlucose
                )
                .padding(.horizontal)
                .opacity(isChartReadoutVisible ? 1 : 0)
                .allowsHitTesting(isChartReadoutVisible)
            }
        }
    }

    /// Decays the readout instead of dropping it.
    ///
    /// Glucose readings and determinations both have holes, and they are not the same holes:
    /// scrubbing across one would otherwise hand the slot straight back to the live meal row
    /// (or blank out IOB / COB / ISF) for a step or two and flicker. So each half of the
    /// readout remembers the last selection that actually resolved it, and only once nothing
    /// has resolved for `ChartSelectionLookup.decay` — a real gap, or the finger lifting —
    /// does the slot let go.
    ///
    /// Run as `.task(id: chartSelection)`: the next scrub step cancels the pending decay, so
    /// crossing a hole never reaches the timeout in the first place.
    ///
    /// Only `isChartReadoutVisible` is cleared when it does let go; the dates it renders from
    /// stay, so the row keeps its values while fading out.
    ///
    /// `@MainActor` because the continuation after the decay sleep would otherwise resume off
    /// the main actor, writing view state from the wrong one.
    @MainActor func updateChartReadout() async {
        if let selection = chartSelection {
            var resolvedAnything = false

            if ChartSelectionLookup.glucose(at: selection, in: state.glucoseFromPersistence) != nil {
                chartReadoutDate = selection
                resolvedAnything = true
            }

            if ChartSelectionLookup.determination(
                at: selection,
                in: state.enactedAndNonEnactedDeterminations
            ) != nil {
                chartReadoutDeterminationDate = selection
                resolvedAnything = true
            } else if let held = chartReadoutDeterminationDate,
                      abs(held.timeIntervalSince(selection)) > ChartSelectionLookup.determinationHold
            {
                // a hop to a different part of the chart, not a hole: don't carry the values over
                chartReadoutDeterminationDate = nil
            }

            if resolvedAnything {
                isChartReadoutVisible = true
                return
            }
        }

        guard isChartReadoutVisible else { return }
        try? await Task.sleep(for: .seconds(ChartSelectionLookup.decay))
        guard !Task.isCancelled else { return }
        isChartReadoutVisible = false
    }

    @ViewBuilder private var liveMealPanel: some View {
        HStack {
            HStack {
                Image(systemName: "syringe.fill")
                    .font(.callout)
                    .foregroundColor(Color.insulin)
                Text(
                    (
                        Formatter.decimalFormatterWithTwoFractionDigits
                            .string(from: state.currentIOB as NSNumber) ?? "0"
                    ) +
                        String(localized: " U", comment: "Insulin unit")
                )
                .font(.callout).fontWeight(.bold).fontDesign(.rounded)
            }

            Spacer()

            HStack {
                Image(systemName: "fork.knife")
                    .font(.callout)
                    .foregroundColor(.loopYellow)
                Text(
                    (
                        Formatter.decimalFormatterWithTwoFractionDigits.string(
                            from: NSNumber(value: state.enactedAndNonEnactedDeterminations.first?.cob ?? 0)
                        ) ?? "0"
                    ) +
                        String(localized: " g", comment: "gram of carbs")
                )
                .font(.callout).fontWeight(.bold).fontDesign(.rounded)
            }

            Spacer()

            deliveryRate
        }.padding(.horizontal)
    }

    func refreshAlarmsSnooze() {
        alarmsSnoozeUntil = UserDefaults.standard
            .object(forKey: "UserNotificationsManager.snoozeUntilDate") as? Date ?? .distantPast
    }

    /// Insulin delivery rate, back in the meal row alongside IOB and COB.
    @ViewBuilder var deliveryRate: some View {
        if state.maxIOB == 0.0 {
            HStack {
                Image(systemName: "exclamationmark.circle.fill")
                Text("MaxIOB: 0 U")
            }.bold()
                .foregroundStyle(Color.red)
                .font(.callout)
        } else {
            HStack {
                /// Only display the insulin delivery rate info if the pump is not
                /// suspended and is available (e.g., pod is paired & not faulted).
                let pumpAvailable = state.apsManager.isScheduledBasal != nil
                if !state.apsManager.isSuspended && pumpAvailable {
                    Image(systemName: "drop.circle")
                        .font(.callout)
                        .foregroundColor(Color.insulin)
                    if let basalString = self.basalString {
                        /// Adjust opacity when displaying a scheduled basal rate
                        let opacity = state.apsManager?.isScheduledBasal == true ? 0.6 : 1.0
                        if basalString.count > 5 {
                            Text(basalString)
                                .font(.callout).fontWeight(.bold).fontDesign(.rounded)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .truncationMode(.tail)
                                .allowsTightening(true)
                                .opacity(opacity)
                        } else {
                            // Short strings can just display normally
                            Text(basalString)
                                .font(.callout).fontWeight(.bold).fontDesign(.rounded)
                                .opacity(opacity)
                        }
                    } else {
                        Text("No Data")
                            .font(.callout).fontWeight(.bold).fontDesign(.rounded)
                    }
                }
            }
        }
    }
}
