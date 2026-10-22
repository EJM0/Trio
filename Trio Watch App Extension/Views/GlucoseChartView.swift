import Charts
import Foundation
import SwiftUI
import WatchKit

struct WatchTreatmentMarker: Identifiable {
    enum Kind { case bolus, smb, carbs }
    let id: String
    let date: Date
    let kind: Kind
}

/// As on the phone's main chart: a blue triangle above the reading for insulin, an orange dot below it for carbs.
struct TreatmentMarks: ChartContent {
    let markers: [WatchTreatmentMarker]
    let glucose: [(date: Date, glucose: Double, color: Color)]

    private struct Placed: Identifiable {
        let marker: WatchTreatmentMarker
        let y: Double
        var id: String { marker.id }
    }

    var body: some ChartContent {
        ForEach(placed) { placed in
            PointMark(x: .value("Time", placed.marker.date), y: .value("Glucose", placed.y))
                .symbol {
                    switch placed.marker.kind {
                    case .bolus,
                         .smb:
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: placed.marker.kind == .smb ? 6 : 9))
                            .foregroundStyle(Color.insulin)
                            .offset(y: -8)
                    case .carbs:
                        Circle().fill(Color.orange).frame(width: 7, height: 7).offset(y: 8)
                    }
                }
        }
    }

    /// Each marker on the reading nearest to it; none without a reading within 15 minutes.
    private var placed: [Placed] {
        guard let start = glucose.first?.date else { return [] }
        return markers.filter { $0.date >= start }.compactMap { marker -> Placed? in
            func gap(_ reading: (date: Date, glucose: Double, color: Color)) -> TimeInterval {
                abs(reading.date.timeIntervalSince(marker.date))
            }
            guard let nearest = glucose.min(by: { gap($0) < gap($1) }), gap(nearest) <= 15 * 60 else { return nil }
            return Placed(marker: marker, y: nearest.glucose)
        }
    }
}

struct GlucoseChartView: View {
    let state: WatchState
    let glucoseValues: [(date: Date, glucose: Double, color: Color)]

    @State private var timeWindow: TimeWindow = .oneHour
    /// Scrubbing back in time with the Digital Crown, in five-minute steps; tap the chart to start and to stop.
    /// As LoopFollow's watch app does it (nightscout/LoopFollow PR 785, AGPL-3.0).
    /// Owned by the main view, which owns the crown: one crown binding that scrubs here and turns pages
    /// otherwise, so nothing has to hand the crown back after scrubbing.
    @Binding var isScrubbing: Bool
    @Binding var scrubSteps: Double
    /// The chart takes the crown by focus while scrubbing (the vertical pages take it otherwise, by themselves)
    /// and gives it back when scrubbing ends.
    @FocusState private var crownFocused: Bool

    private var scrubOffset: TimeInterval { isScrubbing ? max(0, scrubSteps) * 300 : 0 }

    /// Back to the oldest reading the phone sent (24 hours).
    static func maxScrubSteps(_ glucoseValues: [(date: Date, glucose: Double, color: Color)]) -> Double {
        guard let oldest = glucoseValues.first?.date else { return 1 }
        return max(1, (Date().timeIntervalSince(oldest) / 300).rounded(.down))
    }

    /// The time the scrub line points at: where "now" sits when not scrubbing.
    private var scrubDate: Date { Date().addingTimeInterval(-scrubOffset) }

    /// The phone's values in mg/dL, the chart's in the display units.
    private var displayFactor: Double { WatchG7Reader.shared.isMmol ? 0.0555 : 1 }
    private var lowLine: Double? { state.chartLowMgDL.map { $0 * displayFactor } }
    private var highLine: Double? { state.chartHighMgDL.map { $0 * displayFactor } }
    private var targetLine: Double? { state.chartTargetMgDL.map { $0 * displayFactor } }

    enum TimeWindow: Int {
        case oneHour = 1
        case threeHours = 3
        case sixHours = 6
        case twelveHours = 12
        case twentyFourHours = 24

        var next: TimeWindow {
            switch self {
            case .oneHour: return .threeHours
            case .threeHours: return .sixHours
            case .sixHours: return .twelveHours
            case .twelveHours: return .twentyFourHours
            case .twentyFourHours: return .oneHour
            }
        }
    }

    private var futureOffset: TimeInterval {
        guard state.showForecast else { return 0 }
        let now = Date()
        if state.isForecastCone {
            return forecastConePoints.last?.date.timeIntervalSince(now) ?? (2 * 3600)
        } else {
            let maxLineDate = forecastLinePoints.map(\.date).max()
            return maxLineDate?.timeIntervalSince(now) ?? (2 * 3600)
        }
    }

    private var pastOffset: TimeInterval {
        let totalWindowDuration = Double(timeWindow.rawValue) * 3600
        return -(totalWindowDuration - futureOffset)
    }

    private var xAxisDomain: ClosedRange<Date> {
        let now = Date().addingTimeInterval(-scrubOffset)
        let startDate = now.addingTimeInterval(pastOffset)
        let endDate = now.addingTimeInterval(futureOffset)
        return startDate ... max(now, endDate)
    }

    private var filteredValues: [(date: Date, glucose: Double, color: Color)] {
        let domain = xAxisDomain
        return glucoseValues.filter { domain.contains($0.date) }
    }

    /// The reading nearest the scrub line, within half a reading's spacing either way.
    private var scrubReading: (date: Date, glucose: Double, color: Color)? {
        let marker = scrubDate
        guard let nearest = glucoseValues.min(by: {
            abs($0.date.timeIntervalSince(marker)) < abs($1.date.timeIntervalSince(marker))
        }) else { return nil }
        return abs(nearest.date.timeIntervalSince(marker)) <= 150 ? nearest : nil
    }

    struct ForecastConePoint: Identifiable {
        var id: Date { date }
        var date: Date
        var min: Double
        var max: Double
    }

    struct ForecastLinePoint: Identifiable {
        var id: String { "\(type)-\(date.timeIntervalSince1970)" }
        var type: String
        var date: Date
        var value: Double
    }

    private var forecastConePoints: [ForecastConePoint] {
        guard state.showForecast, state.isForecastCone, let anchorDate = state.forecastStartDate else { return [] }

        let minForecast = state.forecastConeMin
        let maxForecast = state.forecastConeMax
        let count = min(minForecast.count, maxForecast.count)

        var pts: [ForecastConePoint] = []
        for i in 0 ..< count {
            let date = anchorDate.addingTimeInterval(TimeInterval(i * 300))
            let yMin = minForecast[i]
            let yMax = maxForecast[i]

            if yMin == yMax {
                pts.append(ForecastConePoint(date: date, min: yMin - 1, max: yMax + 1))
            } else {
                pts.append(ForecastConePoint(date: date, min: yMin, max: yMax))
            }
        }
        return pts
    }

    private var forecastLinePoints: [ForecastLinePoint] {
        guard state.showForecast, !state.isForecastCone, let anchorDate = state.forecastStartDate else { return [] }

        var pts: [ForecastLinePoint] = []
        for (type, values) in state.forecastLines {
            for i in 0 ..< values.count {
                let date = anchorDate.addingTimeInterval(TimeInterval(i * 300))
                pts.append(ForecastLinePoint(type: type, date: date, value: values[i]))
            }
        }
        return pts
    }

    var glucosePointSize: CGFloat {
        switch timeWindow {
        case .oneHour: return 24
        case .threeHours: return 18
        case .sixHours: return 14
        case .twelveHours: return 10
        case .twentyFourHours: return 6
        }
    }

    private var yAxisBounds: (min: Double, max: Double)? {
        let values = filteredValues.map(\.glucose) +
            forecastConePoints.flatMap { [$0.min, $0.max] } +
            forecastLinePoints.map(\.value) +
            [lowLine, highLine].compactMap { $0 }

        guard let minValue = values.min(),
              let maxValue = values.max()
        else {
            return nil
        }
        return (minValue, maxValue)
    }

    private var yAxisDomain: ClosedRange<Double> {
        guard let bounds = yAxisBounds else { return 0 ... 1 }
        // as on the watch face: 0.5 mmol/L or 10 mg/dL past the readings and lines; the fixed 10 was mg/dL
        // only, and in mmol/L left the readings squeezed into a band in the middle
        let padding = WatchG7Reader.shared.isMmol ? 0.5 : 10
        return (bounds.min - padding) ... (bounds.max + padding)
    }

    private var yAxisValues: [Double] {
        guard let bounds = yAxisBounds else { return [] }
        guard bounds.min != bounds.max else { return [bounds.min] }
        let middle = roundedUpMiddle(for: bounds)
        return [bounds.min, middle, bounds.max].reduce(into: [Double]()) { values, value in
            guard !values.contains(where: { abs($0 - value) < 0.0001 }) else { return }
            values.append(value)
        }
    }

    private func roundedUpMiddle(for bounds: (min: Double, max: Double)) -> Double {
        let step = bounds.max < 40 ? 0.1 : 1
        let middle = (bounds.min + bounds.max) / 2
        return ceil(middle / step) * step
    }

    private func formattedYAxisLabel(for glucose: Double) -> String {
        glucose < 40 ? String(format: "%.1f", glucose) : "\(Int(glucose))"
    }

    var body: some View {
        VStack(spacing: 0) {
            if filteredValues.isEmpty {
                Text("No glucose readings.").font(.headline)
                Text("Check phone and CGM connectivity.").font(.caption)
            } else {
                Chart {
                    // the low and high thresholds dashed, the target solid, as on the watch face
                    if let lowLine {
                        RuleMark(y: .value("Low", lowLine))
                            .foregroundStyle(Color.red.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    if let highLine {
                        RuleMark(y: .value("High", highLine))
                            .foregroundStyle(Color.yellow.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    if let targetLine {
                        RuleMark(y: .value("Target", targetLine))
                            .foregroundStyle(Color.loopGreen.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }

                    if isScrubbing {
                        RuleMark(x: .value("Scrub", scrubDate))
                            .foregroundStyle(Color.white.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }

                    ForEach(filteredValues, id: \.date) { reading in
                        PointMark(
                            x: .value("Time", reading.date),
                            y: .value("Glucose", reading.glucose)
                        )
                        .foregroundStyle(reading.color)
                        .symbolSize(glucosePointSize)
                    }

                    // untethered mode's own history while it runs, else the phone's
                    TreatmentMarks(
                        markers: state.treatmentMarkers.isEmpty ? state.phoneTreatmentMarkers : state.treatmentMarkers,
                        glucose: filteredValues
                    )

                    if state.showForecast {
                        if state.isForecastCone {
                            ForEach(forecastConePoints) { pt in
                                AreaMark(
                                    x: .value("Time", pt.date),
                                    yStart: .value("Min", pt.min),
                                    yEnd: .value("Max", pt.max)
                                )
                                .foregroundStyle(Color.insulin.opacity(0.3))
                            }
                        } else {
                            ForEach(forecastLinePoints) { pt in
                                LineMark(
                                    x: .value("Time", pt.date),
                                    y: .value("Value", pt.value),
                                    series: .value("Type", pt.type)
                                )
                                .foregroundStyle(by: .value("Type", pt.type))
                                .lineStyle(StrokeStyle(lineWidth: 1.5))
                            }
                        }
                    }
                }
                .chartForegroundStyleScale([
                    "iob": Color.insulin,
                    "zt": Color.ZT,
                    "cob": Color.loopYellow,
                    "uam": Color.UAM
                ])
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartXScale(domain: xAxisDomain)
                .chartYAxisLabel(isScrubbing ? "" : "\(timeWindow.rawValue) h", alignment: .topLeading)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: yAxisValues) { value in
                        AxisGridLine(stroke: .init(lineWidth: 0.65, dash: [2, 3]))
                            .foregroundStyle(Color.white.opacity(0.25))

                        AxisValueLabel {
                            if let glucose = value.as(Double.self) {
                                Text(formattedYAxisLabel(for: glucose))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartYScale(domain: yAxisDomain)
                .chartPlotStyle { plotContent in
                    plotContent
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.clear)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if isScrubbing { scrubHeader }
                }

                timeInRangeBar
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        // tap: scrub with the crown, tap again: back to now; a long press changes the time span
        .onLongPressGesture {
            withAnimation {
                timeWindow = timeWindow.next
            }
        }
        .onTapGesture {
            scrubSteps = 0
            isScrubbing.toggle()
        }
        .focusable(isScrubbing)
        .focused($crownFocused)
        .digitalCrownRotation(
            $scrubSteps,
            // one step below now ends scrubbing
            from: -1,
            through: Self.maxScrubSteps(glucoseValues),
            by: 1,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        // focus follows scrubbing both ways, also when the main view ends it (timeout, past now, page change)
        .onChange(of: isScrubbing) { _, scrubbing in
            if scrubbing {
                // once the chart is focusable, on the next pass
                DispatchQueue.main.async { crownFocused = true }
                WKInterfaceDevice.current().play(.click)
            } else {
                crownFocused = false
            }
        }
    }

    /// Below, in range and above the low and high lines over the last 24 hours, in percent of the readings.
    private var timeInRange: (low: Double, inRange: Double, high: Double)? {
        guard let low = lowLine, let high = highLine else { return nil }
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        let values = glucoseValues.filter { $0.date >= dayAgo }.map(\.glucose)
        guard !values.isEmpty else { return nil }
        let count = Double(values.count)
        let below = Double(values.filter { $0 < low }.count) / count * 100
        let above = Double(values.filter { $0 > high }.count) / count * 100
        return (below, 100 - below - above, above)
    }

    /// The time-in-range bar: low red, in range green, high yellow, with the percentages under it.
    @ViewBuilder private var timeInRangeBar: some View {
        if let tir = timeInRange {
            VStack(spacing: 1) {
                Text("Last 24 h", comment: "Watch chart: span of the time-in-range bar")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { geometry in
                    HStack(spacing: 1) {
                        ForEach(
                            [
                                RangeShare(id: "low", share: tir.low, color: .loopRed),
                                RangeShare(id: "inRange", share: tir.inRange, color: .loopGreen),
                                RangeShare(id: "high", share: tir.high, color: .loopYellow)
                            ].filter { $0.share > 0 }
                        ) { part in
                            Rectangle()
                                .fill(part.color)
                                .frame(width: max(2, (geometry.size.width - 2) * part.share / 100))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 5)
                HStack {
                    Text(percent(tir.low)).foregroundStyle(Color.loopRed)
                    Spacer()
                    Text("\(percent(tir.inRange)) in range").foregroundStyle(Color.loopGreen)
                    Spacer()
                    Text(percent(tir.high)).foregroundStyle(Color.loopYellow)
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Last 24 hours: \(percent(tir.inRange)) in range, \(percent(tir.low)) low, \(percent(tir.high)) high")
        }
    }

    private struct RangeShare: Identifiable {
        let id: String
        let share: Double
        let color: Color
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded())) %"
    }

    /// Time and glucose at the scrub line.
    private var scrubHeader: some View {
        HStack {
            Text(scrubDate, style: .time)
                .foregroundStyle(.secondary)
            Spacer()
            if let reading = scrubReading {
                Text(formattedGlucose(reading.glucose))
                    .foregroundStyle(reading.color)
            } else {
                Text("–").foregroundStyle(.secondary)
            }
        }
        .font(.system(.headline, design: .rounded))
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.6)))
    }

    private func formattedGlucose(_ glucose: Double) -> String {
        WatchG7Reader.shared.isMmol ? String(format: "%.1f", glucose) : "\(Int(glucose.rounded()))"
    }
}
