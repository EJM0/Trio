import Charts
import Foundation
import SwiftUI

struct CombinedGlucoseChartview: View {
    let state: WatchState
    let rotationDegrees: Double
    let isWatchStateDated: Bool

    var body: some View {
        VStack(alignment: .center, spacing: -16) {
            // Top row: circle perfectly centered, texts sit directly beside it
            ZStack {
                MinimizedGlucoseTrendView(
                    state: state,
                    rotationDegrees: rotationDegrees,
                    isWatchStateDated: isWatchStateDated
                )
                .scaleEffect(state.deviceType.minimizedScale, anchor: .center)
                .frame(width: 45, height: 45)

                HStack(spacing: 0) {
                    Text(isWatchStateDated ? "--" : (state.lastLoopTime ?? "--"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 50, alignment: .trailing)

                    Spacer().frame(width: state.deviceType.minimizedCircleSpacerWidth + 2)

                    Text(isWatchStateDated ? "--" : (state.delta ?? "--"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 50, alignment: .leading)
                }
            }
            .frame(height: 45)

            MinimizedGlucoseChartView(
                state: state,
                glucoseValues: state.glucoseValues
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -15)
    }
}

struct MinimizedGlucoseTrendView: View {
    let state: WatchState
    let rotationDegrees: Double
    let isWatchStateDated: Bool

    private func statusColor(for timeString: String?) -> Color {
        guard let timeString = timeString,
              timeString != "--",
              let minutes = timeString.split(separator: " ").first.flatMap({ Int($0) })
        else {
            return Color.secondary
        }
        guard !isWatchStateDated else {
            return Color.secondary
        }
        switch minutes {
        case ...5:
            return Color.loopGreen
        case 5 ... 10:
            return Color.loopYellow
        case 11...:
            return Color.loopRed
        default:
            return Color.secondary
        }
    }

    var body: some View {
        VStack {
            ZStack {
                Circle()
                    .stroke(statusColor(for: state.lastLoopTime), lineWidth: state.deviceType.lineWidth)
                    .frame(width: state.deviceType.circleSize, height: state.deviceType.circleSize)
                    .background(Circle().fill(Color.bgDarkBlue))
                    .shadow(color: statusColor(for: state.lastLoopTime), radius: state.deviceType.shadowRadius)

                TrendShape(
                    isWatchStateDated: isWatchStateDated,
                    rotationDegrees: rotationDegrees,
                    deviceType: state.deviceType
                )
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: rotationDegrees)
                .shadow(color: Color.black.opacity(0.5), radius: 5)

                VStack(alignment: .center, spacing: 0) {
                    Text(isWatchStateDated ? "--" : state.currentGlucose)
                        .fontWeight(.bold)
                        .font(state.deviceType.currentGlucoseFontSize)
                        .foregroundStyle(
                            isWatchStateDated
                                ? Color.secondary
                                : state.currentGlucoseColorString.toColor()
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MinimizedGlucoseChartView: View {
    let state: WatchState
    let glucoseValues: [(date: Date, glucose: Double, color: Color)]
    @State private var timeWindow: TimeWindow = .threeHours

    @AppStorage("showForecast") private var showForecast: Bool = true

    private var forecastConeMode: Bool { state.forecast?.showCone ?? true }

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

    // 1. Berechnet die X-Achsen-Grenzen: (Gesamtstunden - 2h Vergangenheit) bis (+2h Zukunft)
    private var xAxisDomain: ClosedRange<Date> {
        let now = Date()
        let pastOffset = -Double(timeWindow.rawValue - 2) * 3600
        let futureOffset = 2.0 * 3600
        return now.addingTimeInterval(pastOffset) ... now.addingTimeInterval(futureOffset)
    }

    // 2. Filtert historische Werte passend zum dynamischen Vergangenheits-Fenster
    private var filteredValues: [(date: Date, glucose: Double, color: Color)] {
        let pastHours = Double(timeWindow.rawValue - 2)
        let cutoffDate = Date().addingTimeInterval(-pastHours * 3600)
        return glucoseValues.filter { $0.date > cutoffDate }
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

    // 3. Begrenzt den Forecast-Kegel strikt auf maximal 2 Stunden (120 Minuten)
    private var forecastConePoints: [ForecastConePoint] {
        guard let forecast = state.forecast, showForecast, forecastConeMode else { return [] }
        guard let minPoly = forecast.coneMin, let maxPoly = forecast.coneMax else { return [] }
        var pts: [ForecastConePoint] = []
        let endMinutes = min(minPoly.endMinutes, 120.0)
        let end = Int(endMinutes / 5.0)
        for i in 0 ... end {
            let t = Double(i) * 5.0
            let date = minPoly.startDate.addingTimeInterval(t * 60)
            pts.append(ForecastConePoint(date: date, min: minPoly.evaluate(at: t), max: maxPoly.evaluate(at: t)))
        }
        return pts
    }

    // 4. Begrenzt die Forecast-Linien ebenfalls strikt auf maximal 2 Stunden (120 Minuten)
    private var forecastLinePoints: [ForecastLinePoint] {
        guard let forecast = state.forecast, showForecast, !forecastConeMode else { return [] }
        var pts: [ForecastLinePoint] = []
        for line in forecast.forecastLines {
            let endMinutes = min(line.endMinutes, 120.0)
            let end = Int(endMinutes / 5.0)
            for i in 0 ... end {
                let t = Double(i) * 5.0
                let date = line.startDate.addingTimeInterval(t * 60)
                pts.append(ForecastLinePoint(type: line.type, date: date, value: line.evaluate(at: t)))
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
        if filteredValues.isEmpty {
            VStack {
                Text("No glucose readings.").font(.headline)
                Text("Check phone and CGM connectivity.").font(.caption)
            }
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

                if showForecast {
                    if forecastConeMode {
                        ForEach(forecastConePoints) { pt in
                            AreaMark(
                                x: .value("Time", pt.date),
                                yStart: .value("Min", pt.min),
                                yEnd: .value("Max", pt.max)
                            )
                            .foregroundStyle(Color.insulin.opacity(0.3))
                        }
                        ForEach(forecastConePoints) { pt in
                            LineMark(
                                x: .value("Time", pt.date),
                                y: .value("Min", pt.min),
                                series: .value("Type", "min")
                            )
                            .foregroundStyle(Color.insulin)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))

                            LineMark(
                                x: .value("Time", pt.date),
                                y: .value("Max", pt.max),
                                series: .value("Type", "max")
                            )
                            .foregroundStyle(Color.insulin)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                        }
                    } else {
                        // Nutzt die sauber gecappten Forecast-Linien-Punkte im Chart
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
            .chartXScale(domain: xAxisDomain) // 5. Erzwingt die exakte Gesamtbreite auf der X-Achse
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
            .onTapGesture {
                withAnimation {
                    timeWindow = timeWindow.next
                }
            }
            .contextMenu {
                Toggle("Show Forecast", isOn: $showForecast)
            }
        }
    }
}

#Preview("CombinedGlucoseChartview") {
    let mockState = WatchState()
    // ... setup mockState ...
    return CombinedGlucoseChartview(
        state: mockState,
        rotationDegrees: 0,
        isWatchStateDated: false
    )
    .frame(width: 176, height: 215)
    .background(
        LinearGradient(
            gradient: Gradient(colors: [Color.bgDarkBlue, Color.black]),
            startPoint: .top,
            endPoint: .bottom
        )
    )
    .clipShape(RoundedRectangle(cornerRadius: 44))
}
