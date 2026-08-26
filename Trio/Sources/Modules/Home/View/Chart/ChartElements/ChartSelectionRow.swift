import Foundation
import SwiftUI

/// Color of the selection marker/readout for a glucose value. Shared by the readout row
/// and the shell's selection overlay dot.
func selectionMarkColor(
    for glucose: GlucoseStored,
    highGlucose: Decimal,
    lowGlucose: Decimal,
    currentGlucoseTarget: Decimal,
    glucoseColorScheme: GlucoseColorScheme
) -> Color {
    let hardCodedLow = Decimal(55)
    let hardCodedHigh = Decimal(220)
    let isDynamicColorScheme = glucoseColorScheme == .dynamicColor

    return Trio.getDynamicGlucoseColor(
        glucoseValue: Decimal(glucose.glucose),
        highGlucoseColorValue: isDynamicColorScheme ? hardCodedHigh : highGlucose,
        lowGlucoseColorValue: isDynamicColorScheme ? hardCodedLow : lowGlucose,
        targetGlucose: currentGlucoseTarget,
        glucoseColorScheme: glucoseColorScheme
    )
}

/// Resolves a scrub timestamp to the records it points at. Shared by the chart shell (which
/// draws the marks) and the Home meal slot (which draws the readout), so both always speak
/// about the same reading.
enum ChartSelectionLookup {
    /// Half-width of the lookup window. Pairs with the 300 s scrub snap in
    /// `MainChartView.updateSelection`, so a snapped selection lands on exactly one reading.
    static let window: TimeInterval = 150

    /// How long the readout stays up after the scrub stops resolving to anything — a gap in
    /// the CGM data, or the finger lifting. Long enough to bridge a missing reading or two,
    /// short enough that the slot doesn't feel stuck after the finger is gone.
    static let decay: TimeInterval = 0.6

    /// How far a held determination may sit from the current selection before it is dropped
    /// instead of held. Two determination cadences: bridging a hole is fine, carrying values
    /// across a jump to a different part of the chart is not.
    static let determinationHold: TimeInterval = 600

    static func glucose(at date: Date, in readings: [GlucoseStored]) -> GlucoseStored? {
        let range = date.addingTimeInterval(-window) ... date.addingTimeInterval(window)
        return readings.first { $0.date.map(range.contains) ?? false }
    }

    static func determination(at date: Date, in determinations: [OrefDetermination]) -> OrefDetermination? {
        let range = date.addingTimeInterval(-window) ... date.addingTimeInterval(window)
        let now = Date.now
        return determinations.first {
            $0.deliverAt ?? now >= range.lowerBound && $0.deliverAt ?? now <= range.upperBound
        }
    }
}

/// The selection readout, rendered in the Home meal slot in place of IOB / COB / delivery
/// rate for as long as a scrub is live.
///
/// It used to be a card floating over the glucose pane, which covered the very data it
/// described — worst exactly where the finger already is. The meal row is a fixed 44 pt slot
/// that is always on screen and whose live values the readout supersedes anyway, so taking
/// it over costs nothing and reflows nothing.
struct ChartSelectionRow: View {
    let selectedGlucose: GlucoseStored
    /// COB / IOB / ISF all come from the one determination nearest the selection.
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

    /// `raw | smoothed` while smoothing is on, the raw SGV alone otherwise. Only the raw
    /// value takes the glucose state color — it is the one the chart's dot and the ranges
    /// refer to; separator and smoothed value stay neutral so they can't be misread as a
    /// second state.
    private var glucoseText: Text {
        let raw = Text(glucoseToDisplay.description).foregroundStyle(pointMarkColor)
        guard isSmoothingEnabled, let smoothed = selectedGlucose.smoothedGlucose else { return raw }
        let smoothedToDisplay = units == .mgdL ? smoothed.decimalValue : smoothed.decimalValue.asMmolL
        // verbatim: a bare separator has nothing to translate, and Xcode would otherwise
        // extract it into the string catalog
        return raw + Text(verbatim: " | ").fontWeight(.regular).foregroundStyle(.primary)
            + Text(smoothedToDisplay.description).foregroundStyle(.primary)
    }

    private var timeString: String {
        selectedGlucose.date?.formatted(.dateTime.hour().minute(.twoDigits)) ?? ""
    }

    var body: some View {
        // Five groups on one row: nothing may truncate, so instead of letting SwiftUI squeeze
        // one child to an ellipsis (which it did to the glucose value), every group is
        // `fixedSize` and the whole row steps down a type size until it fits.
        ViewThatFits(in: .horizontal) {
            row(font: .callout)
            row(font: .subheadline)
            row(font: .footnote)
        }
        // Scrubbing changes these values several times a second; animating them would smear
        // digits across the row.
        .animation(nil, value: selectedGlucose.date)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        // Plain chrome, same as the stats banner and the untinted bottom panels: the row
        // borrows a slot the rest of Home owns, so it should read as that chrome rather than
        // as a panel of its own. The glucose state stays where it is legible — on the value.
        .glassPanel()
    }

    @ViewBuilder private func row(font: Font) -> some View {
        HStack(spacing: 0) {
            // the row is only ever shown for a scrub, so the time needs no clock glyph to
            // say what it is
            Text(timeString)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 6)

            // The glucose value carries its own state color, and the unit is the app-wide one
            // the bobble omits too — so it needs neither icon nor suffix to be read. With
            // smoothing on it reads `raw | smoothed`, both values in one group rather than a
            // second one across the row.
            glucoseText
                .fixedSize(horizontal: true, vertical: false)

            if let iob = determination?.iob {
                Spacer(minLength: 6)
                item(icon: "syringe.fill", tint: Color.insulin) {
                    Text(Formatter.decimalFormatterWithTwoFractionDigits.string(from: iob) ?? "")
                        + Text(String(localized: " U", comment: "Insulin unit")).fontWeight(.regular)
                }
            }

            if let determination {
                Spacer(minLength: 6)
                item(icon: "fork.knife", tint: .loopYellow) {
                    Text(Formatter.integerFormatter.string(from: determination.cob as NSNumber) ?? "")
                        + Text(String(localized: " g", comment: "gram of carbs")).fontWeight(.regular)
                }
            }

            if let isf = determination?.insulinSensitivity {
                Spacer(minLength: 6)
                item(icon: "arrow.up.arrow.down", tint: .secondary) {
                    Text(Formatter.integerFormatter.string(from: isf) ?? "")
                        + Text(String(localized: " ISF", comment: "Insulin Sensitivity Factor")).fontWeight(.regular)
                }
            }
        }
        .font(font).fontWeight(.bold).fontDesign(.rounded)
        .lineLimit(1)
    }

    /// One icon + value pair, laid out like the meal row's own groups.
    @ViewBuilder private func item(
        icon: String,
        tint: Color,
        @ViewBuilder value: () -> some View
    ) -> some View {
        HStack(spacing: 4) {
            // scales with whichever step `ViewThatFits` settled on, instead of pinning a size
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(tint)
            value()
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
