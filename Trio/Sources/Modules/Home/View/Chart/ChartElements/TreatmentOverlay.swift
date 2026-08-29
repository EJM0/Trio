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
/// (through `xPosition`, which already applies it) and nothing else, so a marker holds its
/// own shape for the whole gesture and there is nothing to snap back from.
///
/// One `Canvas` rather than a view per marker. This layer has no `Equatable` shortcut — it
/// redraws on every pan and pinch frame — so what it draws has to be cheap and bounded: it
/// culls to the visible window, which at any zoom is a few hundred markers rather than the
/// several thousand the canvas's own render window spans.
struct TreatmentOverlay: View {
    /// Ascending, and covering at least the visible window. Boluses and carbs hang off the
    /// curve, so this is also the series their y anchor is looked up in.
    let glucose: [GlucoseStored]
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
    let visibleStart: Date
    let visibleSeconds: TimeInterval

    /// The shell's own mappings, passed in rather than re-derived, so the markers and the
    /// selection overlay can never disagree about where a reading is. `xPosition` carries
    /// the live-pinch transform; `yPosition` takes a value in display units.
    let xPosition: (Date) -> CGFloat
    let yPosition: (Decimal) -> CGFloat

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

    private var secondsPerPoint: TimeInterval {
        visibleSeconds / Double(max(viewportWidth, 1))
    }

    private var cullRange: ClosedRange<Date> {
        let margin = Double(Self.cullMarginPoints) * secondsPerPoint
        return visibleStart.addingTimeInterval(-margin)
            ... visibleStart.addingTimeInterval(visibleSeconds + margin)
    }

    private func displayValue(_ mgdl: Decimal) -> Decimal {
        units == .mgdL ? mgdl : mgdl.asMmolL
    }

    /// The y value a treatment hangs off: the curve at its own time, offset clear of it.
    /// `pointsUp` marks a carb entry, which hangs below the curve.
    private func curveAnchor(at date: Date, pointsUp: Bool) -> CGFloat? {
        guard let nearest = MainChartHelper.timeToNearestGlucose(
            glucoseValues: glucose,
            time: date.timeIntervalSince1970
        )?.glucose else { return nil }
        let offset = MainChartHelper.bolusOffset(units: units)
        let value = displayValue(Decimal(nearest)) + (pointsUp ? -offset : offset)
        return yPosition(value)
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
            let rect = CGRect(x: xPosition(date) - size / 2, y: y - size / 2, width: size, height: size)

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
        let entries = MainChartHelper.windowSlice(
            carbs, from: range.lowerBound, through: range.upperBound,
            ascendingInput: true, date: \.date
        )
        for entry in entries {
            guard let date = entry.date, let y = curveAnchor(at: date, pointsUp: true) else { continue }

            let size = min(
                MainChartHelper.Config.carbsSize + CGFloat(entry.carbs) * MainChartHelper.Config.carbsScale,
                MainChartHelper.Config.maxCarbSize
            )
            let rect = CGRect(x: xPosition(date) - size / 2, y: y - size / 2, width: size, height: size)

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
            ascendingInput: true, date: \.date
        )
        let y = yPosition(fpuBaseline)
        for entry in entries {
            guard let date = entry.date else { continue }
            let area = (MainChartHelper.Config.fpuSize + CGFloat(entry.carbs) * MainChartHelper.Config.carbsScale) * 1.8
            let diameter = 2 * sqrt(max(area, 0) / .pi)
            let rect = CGRect(
                x: xPosition(date) - diameter / 2,
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
