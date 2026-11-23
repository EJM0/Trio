import Charts
import Foundation
import SwiftUI

struct GlucoseChartView: View {
    let state: WatchState
    let glucoseValues: [(date: Date, glucose: Double, color: Color)]
    /// Nil shows the phone's forecast.
    var forecast: Forecast? = nil

    struct Forecast: Equatable {
        var start: Date?
        var coneMin: [Double] = []
        var coneMax: [Double] = []
        var lines: [String: [Double]] = [:]
    }

    private var shownForecast: Forecast {
        forecast ?? Forecast(
            start: state.forecastStartDate,
            coneMin: state.forecastConeMin,
            coneMax: state.forecastConeMax,
            lines: state.forecastLines
        )
    }

    @State private var timeWindow: TimeWindow = .threeHours

    enum TimeWindow: Int {
        case threeHours = 3
        case sixHours = 6
        case twelveHours = 12
        case twentyFourHours = 24

        var next: TimeWindow {
            switch self {
            case .threeHours: return .sixHours
            case .sixHours: return .twelveHours
            case .twelveHours: return .twentyFourHours
            case .twentyFourHours: return .threeHours
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
        let now = Date()
        let startDate = now.addingTimeInterval(pastOffset)
        let endDate = now.addingTimeInterval(futureOffset)
        return startDate ... max(now, endDate)
    }

    private var filteredValues: [(date: Date, glucose: Double, color: Color)] {
        let cutoffDate = Date().addingTimeInterval(pastOffset)
        return glucoseValues.filter { $0.date >= cutoffDate }
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
        let forecast = shownForecast
        guard state.showForecast, state.isForecastCone, let anchorDate = forecast.start else { return [] }

        let minForecast = forecast.coneMin
        let maxForecast = forecast.coneMax
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
        let forecast = shownForecast
        guard state.showForecast, !state.isForecastCone, let anchorDate = forecast.start else { return [] }

        var pts: [ForecastLinePoint] = []
        for (type, values) in forecast.lines {
            for i in 0 ..< values.count {
                let date = anchorDate.addingTimeInterval(TimeInterval(i * 300))
                pts.append(ForecastLinePoint(type: type, date: date, value: values[i]))
            }
        }
        return pts
    }

    var glucosePointSize: CGFloat {
        switch timeWindow {
        case .threeHours: return 18
        case .sixHours: return 14
        case .twelveHours: return 10
        case .twentyFourHours: return 6
        }
    }

    private var yAxisBounds: (min: Double, max: Double)? {
        let values = filteredValues.map(\.glucose) +
            forecastConePoints.flatMap { [$0.min, $0.max] } +
            forecastLinePoints.map(\.value)

        guard let minValue = values.min(),
              let maxValue = values.max()
        else {
            return nil
        }
        return (minValue, maxValue)
    }

    private var yAxisDomain: ClosedRange<Double> {
        guard let bounds = yAxisBounds else { return 0 ... 1 }
        let padding = max((bounds.max - bounds.min) * 0.20, 10)
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
                    ForEach(filteredValues, id: \.date) { reading in
                        PointMark(
                            x: .value("Time", reading.date),
                            y: .value("Glucose", reading.glucose)
                        )
                        .foregroundStyle(reading.color)
                        .symbolSize(glucosePointSize)
                    }

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
                .chartYAxisLabel("\(timeWindow.rawValue) h", alignment: .topLeading)
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
            }
        }
        .padding(.horizontal, 6)
        .onTapGesture {
            withAnimation {
                timeWindow = timeWindow.next
            }
        }
    }
}

extension TrioOnWatchStatus {
    /// The graph's readings in watch mode: the phone's from before the grant's first reading, then the watch's. Each
    /// watch reading takes the phone's colour for it, or else the colour of the phone reading closest in value, as
    /// the grant doesn't carry the colour settings. Outside the phone's range nothing tells low from in range, so
    /// such a reading is drawn neutral.
    func chartValues(phone: [(date: Date, glucose: Double, color: Color)]) -> [(date: Date, glucose: Double, color: Color)] {
        guard let first = chartReadings.first?.date else { return phone }
        let colorByDate = Dictionary(phone.map { ($0.date, $0.color) }, uniquingKeysWith: { first, _ in first })
        let values = phone.map(\.glucose)
        let range = (values.min() ?? 0) ... (values.max() ?? 0)
        return phone.filter { $0.date < first } + chartReadings.map { reading in
            let value = display(reading.mgdl)
            let closest = range.contains(value) ? phone.min { abs($0.glucose - value) < abs($1.glucose - value) }?.color : nil
            return (reading.date, value, colorByDate[reading.date] ?? closest ?? .primary)
        }
    }

    /// The watch's forecast as the graph draws it; empty before the watch's first loop, not the phone's old one.
    func chartForecast(cone: Bool) -> GlucoseChartView.Forecast {
        guard let forecast else { return .init() }
        let series = forecast.lines.values.filter { !$0.isEmpty }
        guard cone else {
            return .init(start: forecast.start, lines: forecast.lines.mapValues { $0.map(display) })
        }
        let count = series.map(\.count).min() ?? 0
        let columns = (0 ..< count).map { index in series.map { $0[index] } }
        return .init(
            start: forecast.start,
            coneMin: columns.compactMap { $0.min().map(display) },
            coneMax: columns.compactMap { $0.max().map(display) }
        )
    }

    private func display(_ mgdl: Int) -> Double {
        units == .mmolL ? Double(truncating: Decimal(mgdl).asMmolL as NSNumber) : Double(mgdl)
    }
}
