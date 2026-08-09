import Charts
import Foundation
import SwiftUI

/// The COB/IOB pane's plot rect within its own frame. This pane carries the stack's hour
/// labels, so its plot is shorter than the pane — the shell's selection overlay needs the
/// real rect to place its dots on the lines instead of below them.
struct CobIobPlotFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension MainChartCanvas {
    var cobIobChart: some View {
        Chart {
            drawCurrentTimeMarker()
            drawCOBIOBChart()
        }
        .chartLegend(.hidden)
        .frame(width: canvasWidth, height: cobIobHeight)
        .chartXScale(domain: windowStart ... windowEnd)
        .chartXAxis { basalChartXAxis }
        .chartYAxis { cobIobChartYAxis }
        .chartYScale(domain: combinedYDomain())
        .chartOverlay { proxy in
            GeometryReader { geo in
                Color.clear.preference(
                    key: CobIobPlotFrameKey.self,
                    value: proxy.plotFrame.map { geo[$0] } ?? .zero
                )
            }
        }
    }

    func combinedYDomain() -> ClosedRange<Double> {
        MainChartHelper.cobIobYDomain(
            minCob: state.minValueCobChart,
            maxCob: state.maxValueCobChart,
            minIob: state.minValueIobChart,
            maxIob: state.maxValueIobChart,
            minIsf: state.minValueIsfChart,
            maxIsf: state.maxValueIsfChart
        )
    }

    func drawCOBIOBChart() -> some ChartContent {
        // Filter out duplicate entries by `deliverAt`,
        // We sometimes get two determinations when editing carbs, one without the entry-to-be-edited and then another one after editing the entry.
        // We are fetching determinations in descending order, so the first one is the latter determination (with correct amounts), so keeping the first one encountered.
        var seenDates = Set<Date>()
        let filteredDeterminations = windowedDeterminations.filter { item in
            if let date = item.deliverAt {
                if seenDates.contains(date) {
                    // Already seen this date – filter it out.
                    return false
                } else {
                    seenDates.insert(date)
                    return true
                }
            }
            return true
        }

        return ForEach(filteredDeterminations) { item in

            // MARK: - COB line and area mark

            let amountCOB = Int(item.cob)
            let date: Date = item.deliverAt ?? Date()

            // Fixed styles + explicit series identity replace foregroundStyle(by:)/
            // position(by:), which dragged every mark through scale resolution.
            // `.unstacked` is required: dropping position(by:) let the default stacking
            // pile the IOB area on top of the COB area instead of on the baseline.
            LineMark(x: .value("Time", date), y: .value("Value", amountCOB), series: .value("Series", "COB"))
                .foregroundStyle(Color.orange)
            AreaMark(
                x: .value("Time", date),
                y: .value("Value", amountCOB),
                series: .value("Series", "COB"),
                stacking: .unstacked
            )
            .foregroundStyle(Color.orange)
            .opacity(0.2)

            // MARK: - IOB line and area mark

            let rawAmount = item.iob?.doubleValue ?? 0
            let amountIOB: Double = MainChartHelper.scaledIobAmount(rawAmount)

            AreaMark(
                x: .value("Time", date),
                y: .value("Amount", amountIOB),
                series: .value("Series", "IOB"),
                stacking: .unstacked
            )
            .foregroundStyle(Color.darkerBlue)
            .opacity(0.2)
            LineMark(x: .value("Time", date), y: .value("Amount", amountIOB), series: .value("Series", "IOB"))
                .foregroundStyle(Color.darkerBlue)

            // MARK: - ISF line (no fill)

            let isfValue = item.insulinSensitivity?.doubleValue ?? 0

            LineMark(x: .value("Time", date), y: .value("ISF", isfValue), series: .value("Series", "ISF"))
                .foregroundStyle(Color.white)
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }
}
