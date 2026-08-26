import Foundation
import SwiftUI

/// The selection readout as a floating card — time, glucose, IOB, COB and ISF stacked, at
/// the size the original popover had, which is the size that still reads at arm's length.
///
/// Portrait parks this readout in the meal slot as a single row (`ChartSelectionRow`):
/// there a card would cover the very data it describes, worst exactly where the finger
/// already is. Landscape has no meal slot and a wide, near-empty top-right corner, so the
/// card comes back — over the chart's least busy region, and in the same glass chrome as
/// every other Home panel instead of the flat `Color.chart` rectangle it used to wear. The
/// tint is the selected reading's own state color, so the card carries the low/in-range/high
/// verdict in its chrome before any digit is read.
///
/// Plain SwiftUI (not `ChartContent`): it is drawn by the shell that overlays the chart, so
/// it can neither be clipped by the viewport nor force a canvas re-layout while scrubbing.
struct SelectionPopoverView: View {
    let selectedGlucose: GlucoseStored
    /// COB, IOB and ISF all come from the one determination nearest the selection.
    let determination: OrefDetermination?
    let units: GlucoseUnits
    let highGlucose: Decimal
    let lowGlucose: Decimal
    let currentGlucoseTarget: Decimal
    let glucoseColorScheme: GlucoseColorScheme
    let isSmoothingEnabled: Bool

    private var glucoseToDisplay: Decimal {
        units == .mgdL ? Decimal(selectedGlucose.glucose) : Decimal(selectedGlucose.glucose).asMmolL
    }

    private var pointMarkColor: Color {
        selectionMarkColor(
            for: selectedGlucose,
            highGlucose: highGlucose,
            lowGlucose: lowGlucose,
            currentGlucoseTarget: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }

    private var timeString: String {
        selectedGlucose.date?.formatted(.dateTime.hour().minute(.twoDigits)) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "clock").imageScale(.small)
                Text(timeString)
            }
            .font(.subheadline).fontWeight(.semibold).fontDesign(.rounded)
            .foregroundStyle(.secondary)

            glucoseLine

            if let iob = determination?.iob {
                metric(
                    icon: "syringe.fill",
                    tint: Color.insulin,
                    value: Formatter.decimalFormatterWithTwoFractionDigits.string(from: iob) ?? "",
                    unit: String(localized: " U", comment: "Insulin unit")
                )
            }

            if let determination {
                metric(
                    icon: "fork.knife",
                    tint: .loopYellow,
                    value: Formatter.integerFormatter.string(from: determination.cob as NSNumber) ?? "",
                    unit: String(localized: " g", comment: "gram of carbs")
                )
            }

            if let isf = determination?.insulinSensitivity {
                metric(
                    icon: "arrow.up.arrow.down",
                    tint: .secondary,
                    value: Formatter.integerFormatter.string(from: isf) ?? "",
                    unit: String(localized: " ISF", comment: "Insulin Sensitivity Factor")
                )
            }
        }
        .lineLimit(1)
        // the card sizes to its widest line rather than stretching to the overlay it sits in
        .fixedSize(horizontal: true, vertical: true)
        // Scrubbing changes these values several times a second; animating them would smear
        // digits across the card.
        .animation(nil, value: selectedGlucose.date)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassPanel(tint: pointMarkColor, tintOpacity: 0.14, strokeOpacity: 0.30)
    }

    /// The headline number. With smoothing on it reads `raw | smoothed`; only the raw value
    /// takes the state color — it is the one the chart's dot and the ranges refer to, so the
    /// separator and the smoothed value stay neutral and can't be misread as a second state.
    private var glucoseLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(glucoseToDisplay.description)
                .font(.title2).fontWeight(.bold).fontDesign(.rounded)
                .foregroundStyle(pointMarkColor)

            if isSmoothingEnabled, let smoothedGlucose = selectedGlucose.smoothedGlucose {
                let smoothedToDisplay = units == .mgdL
                    ? smoothedGlucose.decimalValue
                    : smoothedGlucose.decimalValue.asMmolL
                // verbatim: a bare separator has nothing to translate, and Xcode would
                // otherwise extract it into the string catalog
                Text(verbatim: "|")
                    .font(.title3).fontDesign(.rounded)
                    .foregroundStyle(.tertiary)
                Text(smoothedToDisplay.description)
                    .font(.title3).fontWeight(.semibold).fontDesign(.rounded)
            }

            Text(units.rawValue)
                .font(.footnote).fontDesign(.rounded)
                .foregroundStyle(.secondary)
        }
    }

    /// One icon + value line. The icons share a fixed column so the numbers line up down the
    /// card no matter how wide each glyph draws.
    @ViewBuilder private func metric(icon: String, tint: Color, value: String, unit: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(tint)
                .frame(width: 16, alignment: .leading)
            Text(value).fontWeight(.bold) + Text(unit).fontWeight(.regular)
        }
        .font(.body).fontDesign(.rounded)
    }
}
