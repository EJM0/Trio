import Foundation
import SwiftUI

// MARK: - Zone C: meal panel (IOB / COB / delivery rate)

extension Home.RootView {
    /// Rate pill: what the pump delivers, and whether the temp is the user's own.
    var currentBasalReadout: (label: String, accessibilityLabel: String, isManual: Bool)? {
        switch state.activeBasalDelivery {
        case .none:
            return nil
        case .suspended:
            let label = String(localized: "Suspended", comment: "Basal delivery suspended on the pump")
            return (label, label, false)
        case let .temp(rate):
            let manual = state.manualTempBasal
            let label = basalRateLabel(rate)
            let spoken = manual
                ? String(
                    localized: "Manual basal \(basalRateAccessibilityLabel(rate))",
                    comment: "Accessibility: manual temp basal rate the user set on the pump"
                )
                : basalRateAccessibilityLabel(rate)
            return (label, spoken, manual)
        case let .scheduled(rate):
            return (basalRateLabel(rate), basalRateAccessibilityLabel(rate), false)
        }
    }

    func basalRateLabel(_ rate: Decimal) -> String {
        let value = Formatter.decimalFormatterWithTwoFractionDigits
            .string(from: NSDecimalNumber(decimal: rate)) ?? "\(rate)"
        return value + String(localized: " U/hr", comment: "Unit per hour with space")
    }

    func basalRateAccessibilityLabel(_ rate: Decimal) -> String {
        let value = Formatter.decimalFormatterWithTwoFractionDigits
            .string(from: NSDecimalNumber(decimal: rate)) ?? "\(rate)"
        return value + " " + UnitSpelling.spoken("U/hr")
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
                // Only when the flag actually flips. A resolving scrub step leaves it alone,
                // and opening a transaction per step would put the fade's curve over whatever
                // else changed in that frame — the chart's pan offset included.
                if !isChartReadoutVisible {
                    withAnimation(ChartSelectionLookup.readoutFade) { isChartReadoutVisible = true }
                }
                return
            }
        }

        guard isChartReadoutVisible else { return }
        try? await Task.sleep(for: .seconds(ChartSelectionLookup.decay))
        guard !Task.isCancelled else { return }
        withAnimation(ChartSelectionLookup.readoutFade) { isChartReadoutVisible = false }
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Insulin on board"))
            .accessibilityValue(Text(
                (
                    Formatter.decimalFormatterWithTwoFractionDigits
                        .string(from: state.currentIOB as NSNumber) ?? "0"
                )
                    + String(localized: " U", comment: "Insulin unit")
            ))

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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Carbs on board"))
            .accessibilityValue(Text(
                (Formatter.decimalFormatterWithTwoFractionDigits.string(
                    from: NSNumber(value: state.enactedAndNonEnactedDeterminations.first?.cob ?? 0)
                ) ?? "0") + String(localized: " g", comment: "gram of carbs")
            ))

            Spacer()

            alarmsPill
        }.padding(.horizontal)
    }

    /// Bell pill matching the header pills; countdown replaces the label while snoozed.
    @ViewBuilder var alarmsPill: some View {
        // timerDate keeps the countdown ticking
        // measure from now, so calculation is not based off stale tick date
        // cf. https://github.com/nightscout/Trio/issues/1381
        let isSnoozed = state.alarmsSnoozeUntil > state.timerDate
        let remainingMinutes = max(Int(ceil(state.alarmsSnoozeUntil.timeIntervalSince(max(state.timerDate, Date())) / 60)), 0)

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Alarms"))
        .accessibilityValue(Text(
            isSnoozed
                ? String(
                    format: String(localized: "snoozed, %d minutes remaining", comment: "Accessibility: alarm snooze"),
                    remainingMinutes
                )
                : String(localized: "active", comment: "Accessibility: alarms active")
        ))
        .accessibilityHint(Text(String(localized: "Opens snooze options", comment: "Accessibility hint")))
        .accessibilityAddTraits(.isButton)
    }
}
