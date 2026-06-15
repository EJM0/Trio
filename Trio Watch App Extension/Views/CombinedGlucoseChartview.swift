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
    let glucoseValues: [(date: Date, glucose: Double, color: Color)]
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

    private var filteredValues: [(date: Date, glucose: Double, color: Color)] {
        let cutoffDate = Date().addingTimeInterval(-Double(timeWindow.rawValue) * 3600)
        return glucoseValues.filter { $0.date > cutoffDate }
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
        guard let minValue = filteredValues.map(\.glucose).min(),
              let maxValue = filteredValues.map(\.glucose).max()
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
            }
            .chartXAxis(.hidden)
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
            // No clipShape — prevents dots being cut at edges
            .onTapGesture {
                withAnimation {
                    timeWindow = timeWindow.next
                }
            }
        }
    }
}

#Preview("CombinedGlucoseChartview") {
    let mockState = WatchState()
    mockState.currentGlucose = "135"
    mockState.currentGlucoseColorString = "#4CD964"
    mockState.trend = "Flat"
    mockState.delta = "+4"
    mockState.lastLoopTime = "3 m"
    mockState.lastWatchStateUpdate = Date().timeIntervalSince1970
    mockState.glucoseValues = [
        (Date().addingTimeInterval(-7200), 110, Color.green),
        (Date().addingTimeInterval(-5400), 118, Color.green),
        (Date().addingTimeInterval(-3600), 124, Color.green),
        (Date().addingTimeInterval(-1800), 130, Color.green),
        (Date().addingTimeInterval(-900), 133, Color.green),
        (Date(), 135, Color.green)
    ]
    return CombinedGlucoseChartview(
        state: mockState,
        rotationDegrees: 0,
        isWatchStateDated: false
    )
    .frame(width: 176, height: 215)
    .background(
        LinearGradient(
            gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
            startPoint: .top,
            endPoint: .bottom
        )
    )
    .clipShape(RoundedRectangle(cornerRadius: 44))
}
