import Charts
import Foundation
import SwiftUI

/// Treatment markers — boluses, carb entries and FPUs — with their dose and gram labels.
///
/// These used to be `PointMark`s inside the chart canvas. They are drawn by the shell now
/// for one reason: a live pinch previews the zoom by applying `.scaleEffect(x:y:)` to the
/// whole canvas, an x-only transform. That is right for the glucose line and the basal bars,
/// where the gap between two timestamps genuinely does stretch, and wrong for anything with
/// a fixed point size — the triangles came out skewed, the dose text came out stretched, and
/// both snapped back at every zoom commit. Out here the pinch reaches their *coordinates*
/// (through `x(for:)`, which applies the same transform) and nothing else, so a marker holds its
/// own shape for the whole gesture and there is nothing to snap back from.
///
/// One `Canvas` rather than a view per marker. This layer has no `Equatable` shortcut — it
/// redraws on every pan and pinch frame — so what it draws has to be cheap and bounded: it
/// culls to the visible window, which at any zoom is a few hundred markers rather than the
/// several thousand the canvas's own render window spans.
struct TreatmentOverlay: View, Animatable {
    /// Ascending, and covering at least the visible window. Boluses and carbs hang off the
    /// curve, so this is also the series their y anchor is looked up in. Pre-resolved points
    /// (`GlucoseDot`), so the per-frame lookups below touch no Core Data.
    let glucose: [GlucoseDot]
    let insulin: [PumpEventStored]
    let carbs: [CarbEntryStored]
    let fpus: [CarbEntryStored]

    let units: GlucoseUnits
    let bolusDisplayThreshold: BolusDisplayThreshold
    /// Average SMB × multiplier, pre-computed by the state model. `nil` means no cutoff
    /// applies, so every label shows.
    let smbBolusDisplayCutoff: Decimal?
    /// Baseline the FPU dots sit on, in display units — the bottom of the plotted range.
    let fpuBaseline: Decimal

    let viewportWidth: CGFloat
    let stackHeight: CGFloat
    /// Leading edge of the visible window, and its length: everything outside is culled.
    /// `var`, because `animatableData` below interpolates it.
    var visibleStart: Date
    let visibleSeconds: TimeInterval

    /// The live-pinch transform, applied to marker coordinates only — which is the whole
    /// point of drawing them out here.
    let pinchScale: CGFloat
    let pinchAnchorFraction: CGFloat?

    /// Value-to-pixel mapping for the glucose pane, passed in so the markers and the
    /// selection overlay can never disagree about where a reading sits. Only y: x has to be
    /// computed here so it can be animated — see `x(for:)`.
    let yPosition: (Decimal) -> CGFloat

    /// The leading edge as a scalar SwiftUI can interpolate.
    ///
    /// Without it the markers snapped to the end of an animated scroll — the "jump to now"
    /// button wraps `scrollToTrailingEdge()` in `withAnimation` — while the canvas glided
    /// there, because the canvas moves under an animatable `.offset` and a `Date` handed to
    /// this view is not animatable at all. Interpolating it re-runs the draw closure each
    /// frame, so the markers travel with the chart they are pinned to.
    var animatableData: Double {
        get { visibleStart.timeIntervalSinceReferenceDate }
        set { visibleStart = Date(timeIntervalSinceReferenceDate: newValue) }
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            for marker in markers {
                context.fill(marker.path, with: .color(marker.color))
                if let label = marker.label {
                    context.draw(label, at: marker.labelPoint, anchor: marker.labelAnchor)
                }
            }
        }
        .frame(width: viewportWidth, height: stackHeight)
        .allowsHitTesting(false)
    }

    // MARK: - Marker geometry

    private struct Marker {
        let path: Path
        let color: Color
        let label: Text?
        let labelPoint: CGPoint
        let labelAnchor: UnitPoint
    }

    /// Gap between a marker and its label, standing in for the spacing Swift Charts put
    /// between a mark and its `.annotation`.
    private static let labelSpacing: CGFloat = 2

    /// How far beyond the visible window a marker is still drawn: enough that one whose
    /// centre has just left the screen still contributes its label at the edge.
    private static let cullMarginPoints: CGFloat = 60

    /// Everything on screen, plus the margin above.
    ///
    /// Measured off the viewport's own edges through `date(atViewportX:)` rather than derived
    /// from `visibleSeconds`: a live pinch stretches the canvas, so a zoom-out puts a wider
    /// span of time on screen than the committed window, and culling to the committed one
    /// would leave the newly exposed edges bare until the zoom commits.
    private var cullRange: ClosedRange<Date> {
        let margin = Self.cullMarginPoints
        return date(atViewportX: -margin) ... date(atViewportX: viewportWidth + margin)
    }

    /// Mirrors the shell's `xPosition(for:)`. Deliberately a copy rather than the closure it
    /// used to be: the closure captured the shell's `scrollPosition`, which is already at its
    /// final value when an animated scroll begins, so interpolating `visibleStart` here would
    /// have moved nothing.
    private func x(for date: Date) -> CGFloat {
        let x = CGFloat(date.timeIntervalSince(visibleStart) / visibleSeconds) * viewportWidth
        guard let anchorFraction = pinchAnchorFraction, pinchScale != 1 else { return x }
        let anchorX = anchorFraction * viewportWidth
        return anchorX + (x - anchorX) * pinchScale
    }

    /// Inverse of `x(for:)`: the date currently under a viewport x, live pinch included.
    private func date(atViewportX x: CGFloat) -> Date {
        var untransformed = x
        if let anchorFraction = pinchAnchorFraction, pinchScale != 1, pinchScale > 0 {
            let anchorX = anchorFraction * viewportWidth
            untransformed = anchorX + (x - anchorX) / pinchScale
        }
        return visibleStart.addingTimeInterval(
            TimeInterval(untransformed / max(viewportWidth, 1)) * visibleSeconds
        )
    }

    /// The y value a treatment hangs off: the curve at its own time, offset clear of it.
    /// `pointsUp` marks a carb entry, which hangs below the curve.
    private func curveAnchor(at date: Date, pointsUp: Bool) -> CGFloat? {
        guard let nearest = MainChartHelper.timeToNearestGlucose(
            glucoseValues: glucose,
            time: date.timeIntervalSince1970
        ) else { return nil }
        let offset = MainChartHelper.bolusOffset(units: units)
        // `GlucoseDot.value` is already in display units, as is the offset.
        return yPosition(nearest.value + (pointsUp ? -offset : offset))
    }

    private var markers: [Marker] {
        var markers: [Marker] = []
        appendBoluses(to: &markers)
        appendCarbs(to: &markers)
        appendFPUs(to: &markers)
        return markers
    }

    private func appendBoluses(to markers: inout [Marker]) {
        let range = cullRange
        let events = MainChartHelper.windowSlice(
            insulin, from: range.lowerBound, through: range.upperBound,
            ascendingInput: true, date: \.timestamp
        )
        for event in events {
            guard let bolus = event.bolus, let date = event.timestamp else { continue }
            let amount = (bolus.amount ?? 0 as NSDecimalNumber).decimalValue
            guard amount != 0, let y = curveAnchor(at: date, pointsUp: false) else { continue }

            // `size` was an SF Symbol point size; as a bounding box it keeps the same
            // amount-driven growth the Image had.
            let size = MainChartHelper.Config.bolusSize
                + CGFloat(truncating: amount as NSNumber) * MainChartHelper.Config.bolusScale
            let rect = CGRect(x: x(for: date) - size / 2, y: y - size / 2, width: size, height: size)

            let labelled = MainChartHelper.showsBolusLabel(
                amount: amount,
                threshold: bolusDisplayThreshold,
                smbCutoff: smbBolusDisplayCutoff
            )
            markers.append(Marker(
                path: TreatmentTriangleSymbol(pointsDown: true).path(in: rect),
                color: .insulin,
                label: labelled
                    ? Text(Formatter.bolusFormatter.string(from: amount as NSDecimalNumber) ?? "")
                    .font(.caption2).foregroundStyle(Color.primary)
                    : nil,
                labelPoint: CGPoint(x: rect.midX, y: rect.minY - Self.labelSpacing),
                labelAnchor: .bottom
            ))
        }
    }

    private func appendCarbs(to markers: inout [Marker]) {
        let range = cullRange
        // Carbs (and FPUs below) are fetched newest-first; `windowSlice` hands them back
        // ascending either way.
        let entries = MainChartHelper.windowSlice(
            carbs, from: range.lowerBound, through: range.upperBound,
            ascendingInput: false, date: \.date
        )
        for entry in entries {
            guard let date = entry.date, let y = curveAnchor(at: date, pointsUp: true) else { continue }

            let size = min(
                MainChartHelper.Config.carbsSize + CGFloat(entry.carbs) * MainChartHelper.Config.carbsScale,
                MainChartHelper.Config.maxCarbSize
            )
            let rect = CGRect(x: x(for: date) - size / 2, y: y - size / 2, width: size, height: size)

            markers.append(Marker(
                path: TreatmentTriangleSymbol(pointsDown: false).path(in: rect),
                color: .orange,
                label: Text(Formatter.integerFormatter.string(from: entry.carbs as NSNumber) ?? "")
                    .font(.caption2).foregroundStyle(Color.primary),
                labelPoint: CGPoint(x: rect.midX, y: rect.maxY + Self.labelSpacing),
                labelAnchor: .top
            ))
        }
    }

    /// FPUs sit on the baseline rather than on the curve, and carry no label.
    ///
    /// They kept Swift Charts' default circle symbol, whose `symbolSize` is an *area* in
    /// square points — not the bounding box the treatment triangles use — so the diameter is
    /// recovered from it rather than used directly.
    private func appendFPUs(to markers: inout [Marker]) {
        let range = cullRange
        let entries = MainChartHelper.windowSlice(
            fpus, from: range.lowerBound, through: range.upperBound,
            ascendingInput: false, date: \.date
        )
        let y = yPosition(fpuBaseline)
        for entry in entries {
            guard let date = entry.date else { continue }
            let area = (MainChartHelper.Config.fpuSize + CGFloat(entry.carbs) * MainChartHelper.Config.carbsScale) * 1.8
            let diameter = 2 * sqrt(max(area, 0) / .pi)
            let rect = CGRect(
                x: x(for: date) - diameter / 2,
                y: y - diameter / 2,
                width: diameter,
                height: diameter
            )
            markers.append(Marker(
                path: Path(ellipseIn: rect),
                color: .brown,
                label: nil,
                labelPoint: .zero,
                labelAnchor: .center
            ))
        }
    }
}
