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

    /// The fade the readout swaps in and out with, in both orientations. Driven from the
    /// mutation site (`withAnimation`), not from an `.animation(_:value:)` on the container:
    /// the container form animated the arrival but dropped the departure — by the time the
    /// slot is emptied the view that carried the modifier is already on its way out — and it
    /// animated anything else that happened to change in the same frame, the chart's pan
    /// offset included. A transaction animates only what this function itself changes.
    static let readoutFade: Animation = .easeOut(duration: 0.12)

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
/// No time: the scrub's time is written on the chart's own x axis, under the selection
/// indicator, where it travels with the finger (`MainChartView.xAxisOverlay`). Repeating it
/// here would only ask the eye to leave the point it is reading to find out "when".
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

    /// Stand-in for a value the selection resolves to nothing: the item keeps its place and
    /// its width, and says so rather than vanishing. Centered in the box it holds, since it
    /// stands for the whole of it rather than starting it.
    private static let missingValue = Text(verbatim: "–").foregroundStyle(.secondary)

    /// Widest reading the unit can produce: three digits in mg/dL, `88.8` in mmol/L.
    private var glucoseTemplate: String { units == .mgdL ? "888" : "88.8" }

    var body: some View {
        // Nothing may truncate, so instead of letting SwiftUI squeeze one child to an
        // ellipsis (which it did to the glucose value), every group is `fixedSize` and the
        // whole row steps down a type size until it fits.
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
        .glassPanel(tint: pointMarkColor, tintOpacity: 0.10, strokeOpacity: 0.25)
    }

    /// Fixed spacing rather than `Spacer`s, so the row hugs its content: with no
    /// determination to read, the panel is just the reading and shrinks to fit it, instead
    /// of stretching the slot's full width around one value.
    @ViewBuilder private func row(font: Font) -> some View {
        HStack(spacing: 12) {
            glucoseGroup

            // All three stay in the row when the scrub lands where oref produced no
            // determination — a gap in the data, or a loop that never ran — and show a dash
            // instead. Letting them come and go would resize the row under the finger, which
            // is the one thing the reserved boxes exist to prevent.
            let iobUnit = Text(String(localized: " U", comment: "Insulin unit")).fontWeight(.regular)
            let iobString = determination?.iob
                .flatMap { Formatter.decimalFormatterWithTwoFractionDigits.string(from: $0) }
            item(
                icon: "syringe.fill",
                tint: Color.insulin,
                value: iobString.map { Text($0) + iobUnit } ?? Self.missingValue,
                template: Text(verbatim: "88.88") + iobUnit,
                alignment: iobString == nil ? .center : .leading
            )

            let cobUnit = Text(String(localized: " g", comment: "gram of carbs")).fontWeight(.regular)
            let cobString = determination
                .flatMap { Formatter.integerFormatter.string(from: $0.cob as NSNumber) }
            item(
                icon: "fork.knife",
                tint: .loopYellow,
                value: cobString.map { Text($0) + cobUnit } ?? Self.missingValue,
                template: Text(verbatim: "888") + cobUnit,
                alignment: cobString == nil ? .center : .leading
            )

            let isfUnit = Text(String(localized: " ISF", comment: "Insulin Sensitivity Factor")).fontWeight(.regular)
            let isfString = determination?.insulinSensitivity
                .flatMap { Formatter.integerFormatter.string(from: $0) }
            item(
                icon: "arrow.up.arrow.down",
                tint: .secondary,
                value: isfString.map { Text($0) + isfUnit } ?? Self.missingValue,
                template: Text(verbatim: "888") + isfUnit,
                alignment: isfString == nil ? .center : .leading
            )
        }
        .font(font).fontWeight(.bold).fontDesign(.rounded)
        // equal-width digits: with the reserved boxes below, this is what keeps a value from
        // wobbling inside its own box as the scrub runs
        .monospacedDigit()
        .lineLimit(1)
    }

    /// The reading under the drop and, with smoothing on, the smoothed value in brackets
    /// behind it. The brackets are the whole label — a glyph there would read as another item
    /// — and only the drop and the raw value take the glucose color, so the bracketed value
    /// can't be misread as a second state. Each gets its own reserved box with the slack
    /// pushed outwards, so the pair stays welded together at every reading width.
    @ViewBuilder private var glucoseGroup: some View {
        // verbatim: brackets have nothing to translate, and Xcode would otherwise extract
        // them into the string catalog
        let open = Text(verbatim: "(")
        let close = Text(verbatim: ")")
        let reading = Text(glucoseToDisplay.description).foregroundStyle(pointMarkColor)
        let smoothed = smoothedToDisplay.map { (open + Text($0.description) + close).foregroundStyle(.secondary) }

        item(
            icon: "drop.fill",
            tint: pointMarkColor,
            value: smoothed.map { reading + $0 } ?? reading,
            // One box for the pair, not one each: separate boxes would park the reading's
            // spare digits between it and its bracket. The setting decides the width, not
            // the individual reading — with smoothing on the bracket's room is held even for
            // a reading that has no smoothed value, so the row never reflows mid-scrub; with
            // it off the box is just the reading and the row is that much tighter.
            template: isSmoothingEnabled
                ? Text(glucoseTemplate) + open + Text(glucoseTemplate) + close
                : Text(glucoseTemplate)
        )
    }

    /// The smoothed reading in display units, or nil when smoothing is off or the reading
    /// has no smoothed value of its own.
    private var smoothedToDisplay: Decimal? {
        guard isSmoothingEnabled, let smoothed = selectedGlucose.smoothedGlucose else { return nil }
        return units == .mgdL ? smoothed.decimalValue : smoothed.decimalValue.asMmolL
    }

    /// One value, with the glyph that labels it, laid out in the width `template` needs —
    /// so a reading that gains or loses a digit mid-scrub cannot resize its own group and
    /// shove everything after it sideways. Every element in the row therefore keeps its
    /// position for as long as the same fields are on screen.
    ///
    /// The template is laid out and hidden, the real value drawn over it. Hidden views are
    /// excluded from accessibility, so VoiceOver reads only the value. `Text` rather than
    /// `String`, so a unit travels inside the box with its own weight — and is measured in
    /// the template too, since a bold `88.88` and a regular ` U` are not the same width.
    /// Left outside the box, a unit would be pushed off its number by exactly the slack this
    /// is meant to absorb.
    ///
    /// Leading-aligned by default, so the slack collects at the group's trailing edge rather
    /// than anywhere inside it: value and unit stay tucked against their glyph, and every bit
    /// of spare room reads as the gap before the next icon. A box whose content is labelled
    /// from the right — the reading, with the smoothed pair behind it — passes `.trailing`
    /// instead, for the same reason read the other way round.
    @ViewBuilder private func item(
        icon: String? = nil,
        tint: Color = .secondary,
        value: Text,
        template: Text,
        alignment: Alignment = .leading
    ) -> some View {
        HStack(spacing: 4) {
            if let icon {
                // scales with whichever step `ViewThatFits` settled on, instead of pinning a size
                Image(systemName: icon)
                    .imageScale(.small)
                    .foregroundStyle(tint)
            }
            template
                .hidden()
                .overlay(alignment: alignment) {
                    value.fixedSize(horizontal: true, vertical: false)
                }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
