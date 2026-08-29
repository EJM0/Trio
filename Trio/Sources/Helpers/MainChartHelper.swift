import Charts
import CoreData
import Foundation
import SwiftUI

enum MainChartHelper {
    // Calculates the glucose value thats the nearest to parameter 'time'
    /// -Returns: A NSManagedObject of GlucoseStored
    /// it is thread safe as everything is executed on the main thread
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
            if closestGlucose == nil || abs(midTime - time) < abs(closestGlucose!.date?.timeIntervalSince1970 ?? 0 - time) {
                closestGlucose = glucoseValues[mid]
            }
        }

        return closestGlucose
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
        static let renderWindowPadFactor = 1.5
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
        /// How long (s) a one-finger touch must rest before the inspect popover appears.
        /// Without this, every drag briefly triggered inspect on touch-down — and each
        /// selection change re-lays the canvas, stalling the pan as it starts.
        static let inspectHoldDelay: TimeInterval = 0.15
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

    /// Visual scaling applied to IOB values on the shared COB/IOB axis (COB is usually
    /// much larger than IOB). Single source of truth for the chart marks, the y-domain,
    /// and the shell's selection overlay.
    static func scaledIobAmount<T: Numeric & Comparable>(_ rawAmount: T) -> T
        where T: ExpressibleByIntegerLiteral
    {
        rawAmount > 0 ? rawAmount * 8 : rawAmount * 9
    }

    /// The combined y-domain of the COB/IOB chart. Used by both the canvas chart and the
    /// shell's selection overlay, which must agree exactly on the value-to-pixel mapping.
    static func cobIobYDomain(
        minCob: Decimal,
        maxCob: Decimal,
        minIob: Decimal,
        maxIob: Decimal
    ) -> ClosedRange<Double> {
        let iobMin = scaledIobAmount(minIob)
        let iobMax = scaledIobAmount(maxIob)
        let minValue = min(minCob, iobMin)
        let maxValue = max(maxCob, iobMax)
        return Double(minValue) ... Double(maxValue)
    }

    /// X-axis grid/label stride for the current continuous zoom level. Same ladder as the
    /// old presets: up to 6 h visible -> 1 h, up to 12 h -> 2 h, wider -> 4 h.
    static func xAxisStrideHours(visibleSeconds: TimeInterval) -> Int {
        let visibleHours = visibleSeconds / 3600
        if visibleHours <= 6 { return 1 }
        if visibleHours <= 12 { return 2 }
        return 4
    }

    /// Calendar-hour axis mark dates for the given range, anchored to absolute time
    /// (multiples of the stride counted from midnight, DST-safe via `Calendar`), unlike
    /// `.stride(by: .hour, count:)`, which anchors its sequence to the domain start.
    ///
    /// Shared by the canvas panes (which draw the grid lines) and the shell's x-axis
    /// overlay (which draws the labels), so labels always land on their own grid lines.
    static func hourAxisMarks(
        over range: ClosedRange<Date>,
        calendar: Calendar,
        visibleSeconds: TimeInterval
    ) -> [Date] {
        let strideHours = xAxisStrideHours(visibleSeconds: visibleSeconds)
        var components = calendar.dateComponents([.year, .month, .day, .hour], from: range.lowerBound)
        let hour = components.hour ?? 0
        components.hour = hour - hour % strideHours
        guard var mark = calendar.date(from: components) else { return [] }

        var marks: [Date] = []
        while mark <= range.upperBound {
            if mark >= range.lowerBound {
                marks.append(mark)
            }
            guard let next = calendar.date(byAdding: .hour, value: strideHours, to: mark) else { break }
            mark = next
        }
        return marks
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
