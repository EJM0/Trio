import Charts
import CoreData
import Foundation
import SwiftUI

/// Shared triangle for the treatment markers: boluses point down at the glucose curve from
/// above, carb entries point up at it from below. A `ChartSymbolShape` is rasterized as a
/// path, unlike `.symbol { Image(...) }`, which instantiates a SwiftUI view per data point —
/// the dominant cost of these series when SMBs land every few minutes.
struct TreatmentTriangleSymbol: ChartSymbolShape {
    let pointsDown: Bool

    /// Corner radius as a fraction of the symbol's smaller dimension. Small enough that the
    /// apex still reads as a point at the sizes these markers are drawn at.
    private var cornerFraction: CGFloat { 0.11 }

    func path(in rect: CGRect) -> Path {
        let corners: [CGPoint] = pointsDown
            ? [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.midX, y: rect.maxY)
            ]
            : [
                CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.midX, y: rect.minY)
            ]

        let radius = min(rect.width, rect.height) * cornerFraction
        var path = Path()
        // Begin midway along the closing edge so the first arc has a straight run-up into
        // the first corner, the same as every other corner gets.
        let last = corners[corners.count - 1]
        path.move(to: CGPoint(x: (last.x + corners[0].x) / 2, y: (last.y + corners[0].y) / 2))
        for index in corners.indices {
            path.addArc(
                tangent1End: corners[index],
                tangent2End: corners[(index + 1) % corners.count],
                radius: radius
            )
        }
        path.closeSubpath()
        return path
    }

    var perceptualUnitRect: CGRect { CGRect(x: 0, y: 0, width: 1, height: 1) }
}

enum MainChartHelper {
    // Calculates the glucose value thats the nearest to parameter 'time'
    /// -Returns: A NSManagedObject of GlucoseStored
    /// it is thread safe as everything is executed on the main thread
    ///
    /// The parentheses around the nil-coalescing in the "update if necessary" test are
    /// load-bearing. `-` binds tighter than `??`, so `... ?? 0 - time` reads as
    /// `... ?? (0 - time)`: with a non-nil date that compares a distance against an absolute
    /// unix timestamp, the test is always true, and the search returns its last probe rather
    /// than the nearest reading. That offset the bolus and carb markers, which pin their y
    /// position to the reading this returns.
    static func timeToNearestGlucose(glucoseValues: [GlucoseStored], time: TimeInterval) -> GlucoseStored? {
        guard !glucoseValues.isEmpty else {
            return nil
        }

        var low = 0
        var high = glucoseValues.count - 1
        var closestGlucose: GlucoseStored?

        // binary search to find next glucose
        while low <= high {
            let mid = low + (high - low) / 2
            let midTime = glucoseValues[mid].date?.timeIntervalSince1970 ?? 0

            if midTime == time {
                return glucoseValues[mid]
            } else if midTime < time {
                low = mid + 1
            } else {
                high = mid - 1
            }

            // update if necessary
            if closestGlucose == nil || abs(midTime - time) < abs((closestGlucose!.date?.timeIntervalSince1970 ?? 0) - time) {
                closestGlucose = glucoseValues[mid]
            }
        }

        return closestGlucose
    }

    /// The slice of a date-sorted array covering `start ... end`, found by binary search
    /// rather than a full scan. These run on every canvas layout, over arrays holding the
    /// whole 72 h history, so the scan is the one part of the cost that grows with how much
    /// data is loaded rather than with how much is on screen.
    ///
    /// `ascendingInput` describes how the array itself is ordered — glucose and pump history
    /// are fetched ascending, carbs, FPUs and determinations descending (see the fetch
    /// requests in `Home.StateModel`). `ascendingOutput` says how the caller wants it back;
    /// the default normalises to ascending, so anything that walks a slice in time order
    /// need not care which way the fetch ran. Determinations are the exception and pass
    /// `false`: `drawCOBIOBChart` de-duplicates by keeping the first of two entries sharing
    /// a `deliverAt`, which is only the right one in the fetch's own order.
    ///
    /// An entry with no date cannot be placed in the ordering at all. Core Data groups those
    /// at one end, so they fall outside the searched range; the filter on the way out is
    /// belt and braces for the case where one is not where the sort implies.
    static func windowSlice<T>(
        _ sorted: [T],
        from start: Date,
        through end: Date,
        ascendingInput: Bool,
        ascendingOutput: Bool = true,
        date: (T) -> Date?
    ) -> [T] {
        guard !sorted.isEmpty, start <= end else { return [] }
        let key: (T) -> Date = ascendingInput
            ? { date($0) ?? .distantPast }
            : { date($0) ?? .distantFuture }

        // First index whose key satisfies `predicate`. Valid because each predicate below is
        // monotone over the array's own direction: false for a prefix, true for the rest.
        func firstIndex(where predicate: (Date) -> Bool) -> Int {
            var low = 0, high = sorted.count
            while low < high {
                let mid = low + (high - low) / 2
                if predicate(key(sorted[mid])) { high = mid } else { low = mid + 1 }
            }
            return low
        }

        let low: Int, high: Int
        if ascendingInput {
            low = firstIndex { $0 >= start }
            high = firstIndex { $0 > end }
        } else {
            low = firstIndex { $0 <= end }
            high = firstIndex { $0 < start }
        }
        guard low < high else { return [] }

        let kept = sorted[low ..< high].filter { date($0) != nil }
        return ascendingInput == ascendingOutput ? kept : kept.reversed()
    }

    enum Config {
        /// How far back the chart's `startMarker` is anchored — the fixed 24 h
        /// history window loaded on every open. Independent of the currently
        /// visible viewport, which the user can pinch-zoom within this range.
        static let chartHistorySeconds: TimeInterval = 72 * 3600
        /// Backfill triggers when the visible leading edge gets this close
        /// Visible x-axis window seeded on first launch of the chart (matches the old 6 h default).
        static let defaultVisibleSeconds: TimeInterval = 6 * 3600
        /// Tightest pinch-in zoom.
        static let minVisibleSeconds: TimeInterval = 1 * 3600
        /// Widest pinch-out zoom.
        static let maxVisibleSeconds: TimeInterval = 24 * 3600
        /// Double-tap cycles the visible window through these presets.
        static let zoomPresets: [TimeInterval] = [6 * 3600, 12 * 3600, 24 * 3600]
        /// When auto-follow re-anchors to `now` at tight zoom, the current reading sits this
        /// fraction from the trailing edge (0.55 makes the crossover land at ~6 h, so the
        /// forecast-anchored framing at 6 h and wider is unchanged; below it, `now` stays on-screen).
        static let followForecastPeekFraction: CGFloat = 0.55
        /// Render window extends this many visible-windows beyond each visible edge.
        /// With `renderWindowMarginFactor` at 0.5, this is what sets how far you can pan
        /// before the window re-anchors and the whole canvas re-lays: 3.0 buys ~2.5
        /// visible-windows of panning per re-layout (1.5 bought exactly one).
        static let renderWindowPadFactor = 3.0
        /// Re-anchor when the visible edge gets within this fraction of a
        /// visible-window of the render window's edge.
        static let renderWindowMarginFactor = 0.5
        /// Geometric grid for pinch commits (~4 % per step). Every committed zoom step
        /// re-lays the full-width canvas, so this bounds a halving of the visible window
        /// to roughly 18 re-layouts instead of hundreds.
        static let zoomStepRatio: Double = 1.04
        /// Live pinch previews as a transform; once the stretch drifts past
        /// this ratio a crisp re-layout is committed mid-gesture, so the
        /// distortion stays bounded.
        static let pinchCommitScaleDrift: Double = 1.25
        /// How far (pt) a one-finger touch may travel and still count as a stationary
        /// press-to-inspect; beyond this the touch becomes a pan.
        static let inspectMovementTolerance: CGFloat = 10
        /// Width (pt) of the strips at the viewport edges where a scrubbing finger makes
        /// the chart auto-pan to reveal more data; pan speed scales with edge depth.
        static let edgePanZoneWidth: CGFloat = 44
        /// How long (s) a one-finger touch must rest before the inspect readout appears.
        /// Without this, every drag briefly triggered inspect on touch-down — and each
        /// selection change re-lays the canvas, stalling the pan as it starts.
        static let inspectHoldDelay: TimeInterval = 0.25

        // MARK: Forecast offset (how far past `now` the chart's domain extends)

        /// Spacing between consecutive forecast points, as oref emits them.
        static let forecastPointInterval: TimeInterval = 5 * 60
        /// Floor on how far ahead the domain reaches, used when there is no forecast to
        /// measure — a fresh install, a failed loop, or the gap before the first determination
        /// lands. Without it the domain would end at `now` and the current-time rule would sit
        /// on the edge.
        static let minForecastHorizon: TimeInterval = 1 * 3600
        /// Ceiling on how far ahead the domain reaches. oref's horizon can run well past the
        /// point where the prediction says anything useful; beyond this the curve is clipped
        /// rather than stretching the domain (and squeezing history) to accommodate it.
        static let maxForecastHorizon: TimeInterval = 3 * 3600
        /// Gap between the pinned y-axis labels and the screen edge.
        static let yAxisLabelInset: CGFloat = 4
        /// Fallback gutter, as a fraction of the viewport, used only for the frame or two
        /// before `YAxisLabelGutterKey` reports the labels' real width. The measured value
        /// replaces it immediately; this just keeps the first layout from starting flush
        /// against the labels and visibly settling.
        ///
        /// The clearance itself is a *pixel* width, not a duration — the labels are the same
        /// size at every zoom, so a fixed duration would swallow a big slice of the screen
        /// pinched in to 1 h and shrink to nothing at 24 h. It is also the only padding past
        /// the last forecast point, which is what makes that point sit flush to the labels.
        static let labelGutterFraction: CGFloat = 0.05

        // MARK: Glucose excursion markers (`GlucoseEpisode`)

        /// Consecutive in-range readings needed to close an excursion. At the 5-minute CGM
        /// cadence this is ~25 min: the 3-5 readings a brief dip back into range produces
        /// never end the episode, so a marker spans the whole event.
        static let episodeRecoveryReadings = 4
        /// Alternative close condition for sparse data — an in-range run this long counts as
        /// recovered even if it holds fewer readings than the count above.
        static let episodeRecoveryDuration: TimeInterval = 30 * 60
        /// Longest data gap an episode is carried across. Shorter gaps are bridged (the scan
        /// just continues with the next reading); a longer one ends the episode at the last
        /// reading before it, because nothing is known about the glucose in between.
        static let episodeMaxGap: TimeInterval = 90 * 60
        /// Excursions shorter than this are not worth marking — the chart already shows them.
        static let episodeMinimumDuration: TimeInterval = 60 * 60
        /// The duration label is dropped once the marker covers less than this fraction of
        /// the visible window, where the text would be wider than the bar it labels.
        static let episodeLabelMinimumWindowFraction: Double = 0.06
        /// How far behind the settled mark `GlucoseEpisodeStore` re-scans on each update.
        /// Covers the routine CGM backfill (a transmitter reconnecting hands over the last
        /// couple of hours at once), so those readings still reshape the episode they belong
        /// to; anything older is caught by the store's full-rescan fallback.
        static let episodeRescanOverlap: TimeInterval = 6 * 3600

        static let bolusSize: CGFloat = 5
        static let bolusScale: CGFloat = 1.8
        static let carbsSize: CGFloat = 5
        static let maxCarbSize: CGFloat = 30
        static let carbsScale: CGFloat = 0.3
        static let fpuSize: CGFloat = 10
        static let maxGlucose = 270
        static let minGlucose = 45

        /// Gap between the bottom of the COB/IOB plot and the top of the x-axis time
        /// labels below it.
        static let xAxisLabelTopGap: CGFloat = 4

        /// First-frame stand-in for the height of an x-axis time label, until the strip
        /// has laid out once and reported its real height (`MainChartView.axisStripHeight`).
        /// Font metrics rather than a fixed number, so even the very first frame is close
        /// at any Dynamic Type size; it is not accurate enough to rely on beyond that,
        /// since a script with taller glyphs than Latin exceeds the font's own line height.
        static var estimatedXAxisLabelHeight: CGFloat {
            UIFont.preferredFont(forTextStyle: .footnote).lineHeight
        }
    }

    /// Whether a bolus carries its dose label. Pure comparison — no scanning, no Core Data
    /// access beyond the mark's own amount.
    ///
    /// Shared, because `PeakLabelsOverlay` has to reserve exactly the footprint `TreatmentOverlay`
    /// draws: a labelled bolus is taller than an unlabelled one, and a peak label that
    /// assumes the wrong one either overlaps the dose or is shoved away from nothing.
    static func showsBolusLabel(
        amount: Decimal,
        threshold: BolusDisplayThreshold,
        smbCutoff: Decimal?
    ) -> Bool {
        switch threshold {
        case .aboveAverageSMBFactor:
            guard let smbCutoff else { return true }
            return amount > smbCutoff
        default:
            return amount >= threshold.rawValue
        }
    }

    static func bolusOffset(units: GlucoseUnits) -> Decimal {
        units == .mgdL ? 20 : (20 / 18)
    }

    static func calculateDuration(
        objectID: NSManagedObjectID,
        attribute: String,
        context: NSManagedObjectContext
    ) -> TimeInterval? {
        do {
            let object = try context.existingObject(with: objectID)
            if let attributeValue = object.value(forKey: attribute) as? NSDecimalNumber {
                let doubleValue = attributeValue.doubleValue
                if doubleValue != 0 {
                    return TimeInterval(doubleValue * 60) // return seconds
                }
            } else {
                debugPrint("Attribute \(attribute) not found or not of type NSDecimalNumber")
            }
        } catch {
            debugPrint(
                "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to calculate duration for object with error: \(error)"
            )
        }

        return nil
    }

    static func calculateTarget(objectID: NSManagedObjectID, attribute: String, context: NSManagedObjectContext) -> Decimal? {
        do {
            let object = try context.existingObject(with: objectID)
            if let attributeValue = object.value(forKey: attribute) as? NSDecimalNumber, attributeValue != 0 {
                return attributeValue.decimalValue
            }
        } catch {
            debugPrint(
                "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to calculate target for object with error: \(error)"
            )
        }
        return nil
    }
}

// MARK: - Rule Marks and Charts configurations

extension MainChartCanvas {
    func drawCurrentTimeMarker() -> some ChartContent {
        RuleMark(
            x: .value(
                "",
                Date(timeIntervalSince1970: TimeInterval(NSDate().timeIntervalSince1970)),
                unit: .second
            )
        ).lineStyle(.init(lineWidth: 2, dash: [3])).foregroundStyle(Color(.systemGray2))
    }

    /// High and low threshold lines. Horizontal rules span the whole x-domain, so they stay
    /// visually static while the chart scrolls. (Moved here from the deleted static-axis
    /// overlay chart.)
    @ChartContentBuilder func drawThresholdLines() -> some ChartContent {
        if thresholdLines {
            // TODO: workaround for now: set low value to 55, to have dynamic color shades between 55 and user-set low (approx. 70); same for high glucose
            let hardCodedLow = Decimal(55)
            let hardCodedHigh = Decimal(220)
            let isDynamicColorScheme = glucoseColorScheme == .dynamicColor

            let highColor = Trio.getDynamicGlucoseColor(
                glucoseValue: highGlucose,
                highGlucoseColorValue: isDynamicColorScheme ? hardCodedHigh : highGlucose,
                lowGlucoseColorValue: isDynamicColorScheme ? hardCodedLow : lowGlucose,
                targetGlucose: currentGlucoseTarget,
                glucoseColorScheme: glucoseColorScheme
            )
            let lowColor = Trio.getDynamicGlucoseColor(
                glucoseValue: lowGlucose,
                highGlucoseColorValue: isDynamicColorScheme ? hardCodedHigh : highGlucose,
                lowGlucoseColorValue: isDynamicColorScheme ? hardCodedLow : lowGlucose,
                targetGlucose: currentGlucoseTarget,
                glucoseColorScheme: glucoseColorScheme
            )

            RuleMark(y: .value("High", units == .mgdL ? highGlucose : highGlucose.asMmolL))
                .foregroundStyle(highColor)
                .lineStyle(.init(lineWidth: 1, dash: [5]))
            RuleMark(y: .value("Low", units == .mgdL ? lowGlucose : lowGlucose.asMmolL))
                .foregroundStyle(lowColor)
                .lineStyle(.init(lineWidth: 1, dash: [5]))
        }
    }

    /// Mark dates for the rendered window, at the current zoom's hour stride.
    var hourAxisMarks: [Date] {
        MainChartHelper.hourAxisMarks(
            over: windowStart ... windowEnd,
            calendar: calendar,
            visibleSeconds: visibleSeconds
        )
    }

    /// Grid lines only — for every pane. The hour labels are no longer an axis component
    /// at all: they are drawn by the shell (`MainChartView.xAxisOverlay`), which can swap
    /// them for the scrub's own time label without re-laying the canvas out.
    var mainChartXAxis: some AxisContent {
        AxisMarks(values: hourAxisMarks) { _ in
            if displayXgridLines {
                AxisGridLine(stroke: .init(lineWidth: 0.5, dash: [2, 3]))
            } else {
                AxisGridLine(stroke: .init(lineWidth: 0, dash: [2, 3]))
            }
        }
    }

    var cobIobChartYAxis: some AxisContent {
        // Only two y-grid lines — at the top and bottom of the pane — instead of
        // automatic marks: the values are exactly the bounds of the same combined
        // COB/IOB domain the chart is scaled to.
        let domain = combinedYDomain()
        return AxisMarks(position: .trailing, values: [domain.lowerBound, domain.upperBound]) { _ in
            if displayYgridLines {
                AxisGridLine(stroke: .init(lineWidth: 0.5, dash: [2, 3]))
            } else {
                AxisGridLine(stroke: .init(lineWidth: 0, dash: [2, 3]))
            }
        }
    }
}
