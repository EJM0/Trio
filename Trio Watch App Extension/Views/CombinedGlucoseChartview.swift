import Charts
import Foundation
import SwiftUI

struct CombinedGlucoseChartView: View {
    let state: WatchState
    let rotationDegrees: Double
    let isWatchStateDated: Bool

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            // Top row: full-width complications (IOB left, time center, COB right)
            HStack {
                // Left complication (e.g. IOB)
                if let iob = state.iob {
                    VStack(spacing: 0) {
                        Image(systemName: "syringe.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(iob)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }

                Spacer()

                // Center: current time
                Text(state.currentTime ?? "--")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer()

                // Right complication (e.g. COB)
                if let cob = state.cob {
                    VStack(spacing: 0) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(cob)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(.horizontal, 6)

            // Middle row: Glucose pill left + Chart right
            HStack(alignment: .center, spacing: 4) {
                // Left: Glucose circle + loop time + delta
                VStack(alignment: .center, spacing: 2) {
                    MinimizedGlucoseTrendView(
                        state: state,
                        rotationDegrees: rotationDegrees,
                        isWatchStateDated: isWatchStateDated
                    )
                    .scaleEffect(0.55, anchor: .center)
                    .frame(width: 55, height: 55)

                    VStack(alignment: .center, spacing: -2) {
                        Text(state.lastLoopTime ?? "--")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        if let delta = state.delta {
                            Text(isWatchStateDated ? "--" : delta)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 2)
                .padding(.trailing, 2)

                // Right: Chart fills remaining width
                MinimizedGlucoseChartView(
                    glucoseValues: state.glucoseValues,
                    minYAxisValue: state.minYAxisValue,
                    maxYAxisValue: state.maxYAxisValue
                )
            }
        }
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

    var circleSize: CGFloat {
        switch state.deviceType {
        case .watch40mm: return 82
        case .watch41mm, .watch42mm: return 86
        case .watch44mm: return 96
        case .unknown, .watch45mm: return 103
        case .watch49mm: return 105
        }
    }

    var lineWidth: CGFloat {
        switch state.deviceType {
        case .watch40mm, .watch41mm, .watch42mm, .watch44mm: return 1
        case .unknown, .watch45mm, .watch49mm: return 1.5
        }
    }

    var shadowRadius: CGFloat {
        switch state.deviceType {
        case .watch40mm, .watch41mm, .watch42mm: return 8
        case .watch44mm: return 9
        case .unknown, .watch45mm, .watch49mm: return 12
        }
    }

    var currentGlucoseFontSize: Font {
        switch state.deviceType {
        case .watch40mm, .watch41mm, .watch42mm, .watch44mm: return .title2
        case .unknown, .watch45mm, .watch49mm: return .title
        }
    }

    var body: some View {
        VStack {
            ZStack {
                Circle()
                    .stroke(statusColor(for: state.lastLoopTime), lineWidth: lineWidth)
                    .frame(width: circleSize, height: circleSize)
                    .background(Circle().fill(Color.bgDarkBlue))
                    .shadow(color: statusColor(for: state.lastLoopTime), radius: shadowRadius)

                TrendShape(
                    isWatchStateDated: isWatchStateDated,
                    rotationDegrees: rotationDegrees,
                    deviceType: state.deviceType
                )
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: rotationDegrees)
                .shadow(color: Color.black.opacity(0.5), radius: 5)

                VStack(alignment: .center, spacing: 0) {
                    Text(isWatchStateDated ? "--" : state.currentGlucose)
                        .fontWeight(.semibold)
                        .font(currentGlucoseFontSize)
                        .foregroundStyle(isWatchStateDated ? Color.secondary : state.currentGlucoseColorString.toColor())
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MinimizedGlucoseChartView: View {
    let glucoseValues: [(date: Date, glucose: Double, color: Color)]
    let minYAxisValue: Decimal
    let maxYAxisValue: Decimal
    @State private var timeWindow: TimeWindow = .threeHours

    enum TimeWindow: Int {
        case threeHours = 3
        case sixHours = 6

        var next: TimeWindow {
            switch self {
            case .threeHours: return .sixHours
            case .sixHours: return .threeHours
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
        }
    }

    var body: some View {
        VStack(spacing: 8) {
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
                }
                .chartXAxis(.hidden)
                .chartYAxisLabel("\(timeWindow.rawValue) h", alignment: .topLeading)
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine(stroke: .init(lineWidth: 0.65, dash: [2, 3]))
                            .foregroundStyle(Color.white.opacity(0.25))

                        AxisValueLabel {
                            if let glucose = value.as(Double.self) {
                                Text("\(Int(glucose))")
                            }
                        }
                    }
                }
                .chartYScale(domain: minYAxisValue ... maxYAxisValue)
                .chartPlotStyle { plotContent in
                    plotContent
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.clear)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.bottom)
            }
        }
        .scenePadding()
        .onTapGesture {
            withAnimation {
                timeWindow = timeWindow.next
            }
        }
    }
}
