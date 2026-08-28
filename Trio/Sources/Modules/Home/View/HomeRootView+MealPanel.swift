import Foundation
import SwiftUI

// MARK: - Zone C: meal panel (IOB / COB / delivery rate)

extension Home.RootView {
    /// The meal slot has two states: the live IOB / COB / alarms row, and — while the main
    /// chart is being scrubbed — the readout for the selected point. The scrub readout wins:
    /// it answers the same questions for a different instant, and showing it here keeps the
    /// chart itself unobstructed, instead of covering the very data the finger is pointing at.
    ///
    /// It renders from `chartReadoutDate`, not from `chartSelection` directly, so a hole in
    /// the data can't flicker the slot (see `updateChartReadout`).
    @ViewBuilder func mealPanel() -> some View {
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
            .transition(.opacity)
        } else {
            liveMealPanel
        }
    }

    /// Decays the readout instead of dropping it.
    ///
    /// Glucose readings and determinations both have holes, and they are not the same holes:
    /// scrubbing across one would otherwise hand the slot straight back to the live meal row
    /// (or blank out IOB / COB) for a step or two and flicker. So each half of the readout
    /// remembers the last selection that actually resolved it, and only once nothing has
    /// resolved for `ChartSelectionLookup.decay` — a real gap, or the finger lifting — does
    /// the slot let go.
    ///
    /// Run as `.task(id: chartSelection)`: the next scrub step cancels the pending decay, so
    /// crossing a hole never reaches the timeout in the first place.
    func updateChartReadout() async {
        if let selection = chartSelection {
            var resolvedAnything = false

            if ChartSelectionLookup.glucose(at: selection, in: state.glucoseFromPersistence) != nil {
                // Only the first step of a scrub swaps the slot, and only that step is worth
                // animating: every step after it merely moves the values inside the readout,
                // and fading those would smear digits several times a second.
                if chartReadoutDate == nil {
                    withAnimation(ChartSelectionLookup.readoutFade) { chartReadoutDate = selection }
                } else {
                    chartReadoutDate = selection
                }
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

            if resolvedAnything { return }
        }

        guard chartReadoutDate != nil || chartReadoutDeterminationDate != nil else { return }
        try? await Task.sleep(for: .seconds(ChartSelectionLookup.decay))
        guard !Task.isCancelled else { return }
        withAnimation(ChartSelectionLookup.readoutFade) {
            chartReadoutDate = nil
            chartReadoutDeterminationDate = nil
        }
    }

    @ViewBuilder private var liveMealPanel: some View {
        ZStack {
            // the carb value itself sits on the panel's midline; the icon hangs off it
            Text(
                (
                    Formatter.decimalFormatterWithTwoFractionDigits.string(
                        from: NSNumber(value: state.enactedAndNonEnactedDeterminations.first?.cob ?? 0)
                    ) ?? "0"
                ) +
                    String(localized: " g", comment: "gram of carbs")
            )
            .font(.callout).fontWeight(.bold).fontDesign(.rounded)
            .overlay(alignment: .leading) {
                Image(systemName: "fork.knife")
                    .font(.callout)
                    .foregroundColor(.loopYellow)
                    .alignmentGuide(.leading) { $0.width + 5 }
            }

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

                alarmsPill
            }
        }.padding(.horizontal)
    }

    func refreshAlarmsSnooze() {
        alarmsSnoozeUntil = UserDefaults.standard
            .object(forKey: "UserNotificationsManager.snoozeUntilDate") as? Date ?? .distantPast
    }

    /// Bell pill matching the header pills; countdown replaces the label while snoozed.
    @ViewBuilder var alarmsPill: some View {
        // timerDate keeps the countdown ticking
        // measure from now, so calculation is not based off stale tick date
        // cf. https://github.com/nightscout/Trio/issues/1381
        let isSnoozed = alarmsSnoozeUntil > state.timerDate
        let remainingMinutes = max(Int(ceil(alarmsSnoozeUntil.timeIntervalSince(max(state.timerDate, Date())) / 60)), 0)

        Button {
            showSnoozeSheet = true
        } label: {
            Group {
                if isSnoozed {
                    HStack(spacing: 5) {
                        Image(systemName: "bell.slash.fill")
                            .font(.callout)
                        Text("\(remainingMinutes) m")
                            .font(.callout).fontWeight(.bold).fontDesign(.rounded)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .foregroundStyle(.secondary)
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(0.4), lineWidth: 2)
                    )
                } else {
                    Image(systemName: "bell.fill")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(0.4), lineWidth: 2)
                        )
                }
            }
        }
        .buttonStyle(.plain)
    }
}
