import Charts
import Foundation
import SwiftUI

/// BG peak and nadir badges, with collision avoidance against the treatment markers and
/// the glucose curve (`LabelPlacement.placeLabelCenter`).
///
/// Drawn by the shell, for the same reason `TreatmentOverlay` is: inside the canvas these
/// badges rode the live-pinch `scaleEffect`, an x-only transform, so their text and their
/// rounded backgrounds stretched for the length of a gesture and snapped back at every
/// zoom commit. Out here the pinch reaches only their coordinates, through the same
/// `xPosition` the markers they avoid are placed with.
///
/// Cheap to redraw per frame, unlike the treatment markers: a window holds tens of peaks,
/// not hundreds of doses, and the obstacle search is already scoped to their neighbourhoods.
struct PeakLabelsOverlay: View, Animatable {
    @Environment(\.colorScheme) private var colorScheme

    let peaks: [(date: Date, glucose: Int16, type: ExtremumType)]
    let glucoseData: [GlucoseStored]
    let insulinData: [PumpEventStored]
    let carbData: [CarbEntryStored]
    let units: GlucoseUnits
    let highGlucose: Decimal
    let lowGlucose: Decimal
    let glucoseColorScheme: GlucoseColorScheme
    let currentGlucoseTarget: Decimal

    let viewportWidth: CGFloat
    let stackHeight: CGFloat
    /// Leading edge of the visible window, and its length. Together they convert the
    /// placement distances below into a span of chart time, which is what bounds the
    /// obstacle search. `var`, because `animatableData` interpolates it.
    var visibleStart: Date
    let visibleSeconds: TimeInterval

    /// The shell's mappings — `xPosition` carries the live-pinch transform, `yPosition`
    /// takes a value in display units — so a badge and the marker it avoids can never
    /// disagree about where either of them is.
    let xPosition: (Date) -> CGFloat
    let yPosition: (Decimal) -> CGFloat
    /// Mirrors what `TreatmentOverlay` uses to decide whether a bolus carries its dose label, so
    /// a marker's reserved footprint matches the one actually drawn.
    let bolusDisplayThreshold: BolusDisplayThreshold
    let smbBolusDisplayCutoff: Decimal?

    private static let labelMargin: CGFloat = 4
    private static let labelDesiredOffset: CGFloat = 18
    private static let maxPlacementDistance: CGFloat = 80
    private static let glucoseDotSize: CGFloat = 6
    private static let labelSize = CGSize(width: 30, height: 18)

    /// Height a dose/carb label adds above (bolus) or below (carb) its marker.
    private static let markerLabelHeight: CGFloat = 14

    /// Generous bound on half the width of the widest treatment marker — carbs are capped at
    /// `Config.maxCarbSize` (30) and a large bolus lands around 23 — used only to pad the
    /// search so a marker whose centre sits just outside it still can't reach a label.
    private static let maxMarkerHalfWidth: CGFloat = 20

    /// The leading edge as a scalar SwiftUI can interpolate, so the badges travel with the
    /// chart during an animated scroll instead of snapping to its destination. Same reason
    /// as `TreatmentOverlay.animatableData`.
    var animatableData: Double {
        get { visibleStart.timeIntervalSinceReferenceDate }
        set { visibleStart = Date(timeIntervalSinceReferenceDate: newValue) }
    }

    var body: some View {
        let placed = computePlacements(obstacles: computeObstacles())

        ZStack(alignment: .topLeading) {
            ForEach(placed.indices, id: \.self) { i in
                let p = placed[i]
                // Connector from peak point on the curve to the label edge.
                Path { path in
                    path.move(to: CGPoint(x: p.peakX, y: p.peakY))
                    path.addLine(to: connectorAnchor(rect: p.rect, peakY: p.peakY))
                }
                .stroke(Color.secondary, lineWidth: 0.75)
                .opacity(0.75)

                PeakLabelBadge(text: p.text, color: p.color)
                    .fixedSize()
                    .position(x: p.rect.midX, y: p.rect.midY)
            }
        }
        // Load-bearing, as for every other shell overlay: an unconstrained sibling in the
        // shell's ZStack inherits the canvas's (~9x screen) layout width.
        .frame(width: viewportWidth, height: stackHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Peaks that could put a badge on screen — its own position plus the furthest the
    /// placement may carry it. Everything else is culled before any work is done on it.
    private var visiblePeaks: [(date: Date, glucose: Int16, type: ExtremumType)] {
        let reach = Double(Self.maxPlacementDistance + Self.labelSize.width) * secondsPerPoint
        return MainChartHelper.windowSlice(
            peaks,
            from: visibleStart.addingTimeInterval(-reach),
            through: visibleStart.addingTimeInterval(visibleSeconds + reach),
            ascendingInput: true,
            date: { $0.date }
        )
    }

    private var secondsPerPoint: TimeInterval {
        visibleSeconds / Double(max(viewportWidth, 1))
    }

    // MARK: - Placement

    private struct PlacedPeak {
        let rect: CGRect
        let peakX: CGFloat
        let peakY: CGFloat
        let text: String
        let color: Color
    }

    /// Anchor on the label rect closest to the peak point — vertically above or below
    /// depending on which side of `peakY` the rect ended up on, clamped horizontally
    /// inside the rect to keep diagonal connectors short.
    private func connectorAnchor(rect: CGRect, peakY: CGFloat) -> CGPoint {
        let y = rect.midY <= peakY ? rect.maxY : rect.minY
        return CGPoint(x: rect.midX, y: y)
    }

    private func computePlacements(obstacles: [CGRect]) -> [PlacedPeak] {
        // Still sorted — `placeLabelCenter` binary-searches by `minX` — but over the tens of
        // rects the peak neighbourhoods produce rather than the whole render window.
        let sortedObstacles = obstacles.sorted { $0.minX < $1.minX }
        let labelSize = Self.labelSize

        return visiblePeaks.compactMap { peak -> PlacedPeak? in
            let glucoseDecimal = Decimal(peak.glucose)
            let cxRel = xPosition(peak.date)
            let cyRel = yPosition(displayValue(glucoseDecimal))

            let desiredCenterY: CGFloat
            let side: VerticalSide
            switch peak.type {
            case .max:
                desiredCenterY = cyRel - Self.labelDesiredOffset
                side = .above
            case .min:
                desiredCenterY = cyRel + Self.labelDesiredOffset
                side = .below
            case .none:
                desiredCenterY = cyRel
                side = .both
            }

            let desiredRect = CGRect(
                x: cxRel - labelSize.width / 2,
                y: desiredCenterY - labelSize.height / 2,
                width: labelSize.width,
                height: labelSize.height
            )

            let placedRect = sortedObstacles.placeLabelCenter(
                desiredRect: desiredRect,
                verticalSide: side,
                maxDistance: Self.maxPlacementDistance
            ) ?? desiredRect

            return PlacedPeak(
                rect: placedRect,
                peakX: cxRel,
                peakY: cyRel,
                text: formattedGlucose(Int(peak.glucose)),
                color: peakColor(glucose: glucoseDecimal)
            )
        }
    }

    // MARK: - Obstacles

    /// The rects a peak label has to avoid — built only where one could actually collide.
    ///
    /// `LabelPlacement.placeLabelCenter` throws away every obstacle further than
    /// `maxPlacementDistance` from the peak it is placing, so building one per glucose point,
    /// bolus and carb across the render window — which at wide zoom is the whole 72 h — was
    /// work discarded for all but a few tens of them. Peaks are few and arrive in time order,
    /// so their neighbourhoods are cheap to enumerate and the rest of the data is never
    /// touched: no scale lookup, no nearest-glucose search.
    private func computeObstacles() -> [CGRect] {
        let peaks = visiblePeaks
        guard !peaks.isEmpty, viewportWidth > 0 else { return [] }

        // Reach of a placement, in chart time: how far the label itself can travel, plus its
        // own width, plus the widest marker that could still overlap from beyond that.
        let pad = Double(
            Self.maxPlacementDistance + Self.labelSize.width + Self.maxMarkerHalfWidth
        ) * secondsPerPoint

        var rects: [CGRect] = []
        for neighbourhood in mergedNeighbourhoods(peaks, pad: pad) {
            appendGlucoseObstacles(in: neighbourhood, to: &rects)
            appendBolusObstacles(in: neighbourhood, to: &rects)
            appendCarbObstacles(in: neighbourhood, to: &rects)
        }
        return rects
    }

    /// Each peak's reach, with overlapping ones merged so a cluster of peaks builds its
    /// shared obstacles once. `PeakPicker` emits peaks in time order, so this is one pass.
    private func mergedNeighbourhoods(
        _ peaks: [(date: Date, glucose: Int16, type: ExtremumType)],
        pad: TimeInterval
    ) -> [ClosedRange<Date>] {
        var merged: [ClosedRange<Date>] = []
        for peak in peaks {
            let range = peak.date.addingTimeInterval(-pad) ... peak.date.addingTimeInterval(pad)
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound ... Swift.max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func displayValue(_ mgdl: Decimal) -> Decimal {
        units == .mgdL ? mgdl : mgdl.asMmolL
    }

    private func appendGlucoseObstacles(in range: ClosedRange<Date>, to rects: inout [CGRect]) {
        let readings = MainChartHelper.windowSlice(
            glucoseData, from: range.lowerBound, through: range.upperBound,
            ascendingInput: true, date: \.date
        )
        for reading in readings {
            guard let date = reading.date else { continue }
            let x = xPosition(date)
            let y = yPosition(displayValue(Decimal(reading.glucose)))
            rects.append(CGRect(
                x: x - Self.glucoseDotSize / 2,
                y: y - Self.glucoseDotSize / 2,
                width: Self.glucoseDotSize,
                height: Self.glucoseDotSize
            ))
        }
    }

    /// The bolus marker as `TreatmentOverlay` actually draws it: a triangle whose box grows with
    /// the dose, sitting `bolusOffset` above the curve, plus its label when it carries one.
    ///
    /// This used to model a bar up to 67 pt tall with a 14 pt minimum width — geometry from a
    /// bar-chart design that no longer exists — so peak labels were being shoved away from
    /// markers three to four times taller than the real ones.
    private func appendBolusObstacles(in range: ClosedRange<Date>, to rects: inout [CGRect]) {
        let events = MainChartHelper.windowSlice(
            insulinData, from: range.lowerBound, through: range.upperBound,
            ascendingInput: true, date: \.timestamp
        )
        for event in events {
            // No `isExternal` filter: `TreatmentOverlay` draws external boluses like any
            // other, so excluding them here reserved nothing and let a badge land on one.
            guard let bolus = event.bolus, let date = event.timestamp else { continue }
            let amount = (bolus.amount ?? 0 as NSDecimalNumber).decimalValue
            guard amount != 0 else { continue }
            guard let glucose = MainChartHelper.timeToNearestGlucose(
                glucoseValues: glucoseData,
                time: date.timeIntervalSince1970
            )?.glucose else { continue }

            let markValue = displayValue(Decimal(glucose)) + MainChartHelper.bolusOffset(units: units)
            let x = xPosition(date)
            let y = yPosition(markValue)

            let size = MainChartHelper.Config.bolusSize
                + CGFloat(truncating: amount as NSNumber) * MainChartHelper.Config.bolusScale
            let labelled = MainChartHelper.showsBolusLabel(
                amount: amount,
                threshold: bolusDisplayThreshold,
                smbCutoff: smbBolusDisplayCutoff
            )
            // the label sits above the marker
            let top = y - size / 2 - (labelled ? Self.markerLabelHeight : 0)
            rects.append(CGRect(
                x: x - size / 2,
                y: top,
                width: size,
                height: y + size / 2 - top
            ))
        }
    }

    /// The carb marker as `TreatmentOverlay` draws it: the mirrored triangle, capped at
    /// `Config.maxCarbSize`, below the curve — and its label, which carbs always carry.
    private func appendCarbObstacles(in range: ClosedRange<Date>, to rects: inout [CGRect]) {
        let entries = MainChartHelper.windowSlice(
            carbData, from: range.lowerBound, through: range.upperBound,
            ascendingInput: true, date: \.date
        )
        for entry in entries {
            guard let date = entry.date else { continue }
            guard let glucose = MainChartHelper.timeToNearestGlucose(
                glucoseValues: glucoseData,
                time: date.timeIntervalSince1970
            )?.glucose else { continue }

            let markValue = displayValue(Decimal(glucose)) - MainChartHelper.bolusOffset(units: units)
            let x = xPosition(date)
            let y = yPosition(markValue)

            let size = min(
                MainChartHelper.Config.carbsSize + CGFloat(entry.carbs) * MainChartHelper.Config.carbsScale,
                MainChartHelper.Config.maxCarbSize
            )
            rects.append(CGRect(
                x: x - size / 2,
                y: y - size / 2,
                width: size,
                height: size + Self.markerLabelHeight
            ))
        }
    }

    // MARK: - Helpers

    private func peakColor(glucose: Decimal) -> Color {
        let hardCodedLow = Decimal(55)
        let hardCodedHigh = Decimal(220)
        let isDynamic = glucoseColorScheme == .dynamicColor

        return Trio.getDynamicGlucoseColor(
            glucoseValue: glucose,
            highGlucoseColorValue: isDynamic ? hardCodedHigh : highGlucose,
            lowGlucoseColorValue: isDynamic ? hardCodedLow : lowGlucose,
            targetGlucose: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }

    private func formattedGlucose(_ glucose: Int) -> String {
        if units == .mgdL {
            return "\(glucose)"
        } else {
            return glucose.formattedAsMmolL
        }
    }
}

/// Shared peak-label badge used by `PeakLabelsOverlay` for both highs and lows.
///
/// Light mode keeps the current high-contrast design (`.primary` text on a
/// tinted fill with a faint primary stroke). Dark mode uses the original
/// pre-bars design (colored text on a faint colored fill, no stroke).
struct PeakLabelBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String
    let color: Color

    var body: some View {
        if colorScheme == .dark {
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.15))
                )
        } else {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.35))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.primary.opacity(0.7), lineWidth: 0.4)
                )
        }
    }
}
