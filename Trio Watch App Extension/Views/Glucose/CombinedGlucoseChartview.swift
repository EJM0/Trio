import Charts
import Foundation
import SwiftUI

/// A compact glucose page: a small glucose bubble on top with the reading's age and delta beside it, and a chart
/// below. An alternative to the separate bubble/trend and full-screen chart pages; additive, so it is not wired
/// into the main view here (see the note at the bottom).
struct CombinedGlucoseChartview: View {
    let state: WatchState
    let rotationDegrees: Double
    let isWatchStateDated: Bool

    /// Like the phone's home screen: the last reading stays on screen with its age until it is 12 minutes old
    /// (one missed CGM transmission, the loop's own freshness gate), even while no new data arrives.
    private static let readingDisplayLimit: TimeInterval = 12 * 60

    private func readingAge(at now: Date) -> TimeInterval? {
        state.glucoseValues.last.map { now.timeIntervalSince($0.date) }
    }

    /// "6 m", or "< 1 m" for a reading younger than a minute, as on the phone.
    private func readingAgeText(_ age: TimeInterval) -> String {
        let minutes = Int(floor(age / 60))
        let unit = String(localized: "m", comment: "Abbreviation for Minutes")
        return minutes >= 1 ? "\(minutes)\u{00A0}\(unit)" : "<\u{00A0}1\u{00A0}\(unit)"
    }

    var body: some View {
        VStack(alignment: .center, spacing: -16) {
            // Top row: circle perfectly centered, texts sit directly beside it. Redrawn every 30 seconds, so the
            // reading's age keeps counting while no new data arrives.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let age = readingAge(at: context.date)
                let isReadingShown = age.map { $0 < Self.readingDisplayLimit } ?? false

                ZStack {
                    MinimizedGlucoseTrendView(
                        state: state,
                        rotationDegrees: rotationDegrees,
                        isWatchStateDated: isWatchStateDated,
                        isReadingShown: isReadingShown
                    )
                    .scaleEffect(state.deviceType.minimizedScale, anchor: .center)
                    .frame(width: 45, height: 45)

                    HStack(spacing: 0) {
                        // Age of the shown reading, like the "6 m" in the phone's glucose bubble.
                        Text(isReadingShown ? age.map(readingAgeText) ?? "--" : "--")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 50, alignment: .trailing)

                        Spacer().frame(width: state.deviceType.minimizedCircleSpacerWidth + 2)

                        Text(isReadingShown ? (state.delta ?? "--") : "--")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 50, alignment: .leading)
                    }
                }
                .frame(height: 45)
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
    /// Greys out the loop status ring.
    let isWatchStateDated: Bool
    /// The last reading is recent enough to show, with its trend arrow.
    let isReadingShown: Bool

    /// Minutes since the last loop, counted at `now`. Mirrors GlucoseTrendView's non-direct path: the phone sends
    /// a relative "N min" string and `lastLoopDate`; the date is aged here so the ring keeps counting between
    /// updates, with the sent string as the fallback when no date is known.
    private func loopMinutes(at now: Date) -> Int? {
        if let lastLoopDate = state.lastLoopDate {
            return max(0, Int((now.timeIntervalSince(lastLoopDate) - 30) / 60) + 1)
        }
        return state.lastLoopTime?.split(separator: " ").first.flatMap { Int($0) }
    }

    private func statusColor(at now: Date) -> Color {
        guard !isWatchStateDated, let minutes = loopMinutes(at: now) else { return Color.secondary }
        switch minutes {
        case ...5:
            return Color.loopGreen
        case 6 ... 10:
            return Color.loopYellow
        default:
            return Color.loopRed
        }
    }

    var body: some View {
        // the ring and its minutes count on from the last loop, minute by minute
        TimelineView(.everyMinute) { context in content(at: context.date) }
    }

    private func content(at now: Date) -> some View {
        let ringColor = statusColor(at: now)
        return VStack {
            ZStack {
                Circle()
                    .stroke(ringColor, lineWidth: state.deviceType.lineWidth)
                    .frame(width: state.deviceType.circleSize, height: state.deviceType.circleSize)
                    .background(Circle().fill(Color.bgDarkBlue))
                    .shadow(color: ringColor, radius: state.deviceType.shadowRadius)

                TrendShape(
                    isWatchStateDated: !isReadingShown,
                    rotationDegrees: rotationDegrees,
                    deviceType: state.deviceType
                )
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: rotationDegrees)
                .shadow(color: Color.black.opacity(0.5), radius: 5)

                VStack(alignment: .center, spacing: 0) {
                    if state.showSyncingAnimation {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                    } else {
                        Text(isReadingShown ? state.currentGlucose : "--")
                            .fontWeight(.bold)
                            .font(state.deviceType.currentGlucoseFontSize)
                            .foregroundStyle(
                                isReadingShown
                                    ? state.currentGlucoseColorString.toColor()
                                    : Color.secondary
                            )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MinimizedGlucoseChartView: View {
    let state: WatchState
    let glucoseValues: [(date: Date, glucose: Double, color: Color)]
    /// This chart's own zoom, kept across launches — see `WatchChartTimeWindow`.
    @AppStorage(WatchChartTimeWindow.combinedStorageKey) private var timeWindow: WatchChartTimeWindow = .threeHours

    typealias TimeWindow = WatchChartTimeWindow

    private var xAxisDomain: ClosedRange<Date> {
        let now = Date()
        let pastOffset = -Double(timeWindow.rawValue - 2) * 3600
        let startDate = now.addingTimeInterval(pastOffset)

        // By default, the chart ends at "now" if no forecast is active
        var endDate = now

        if state.showForecast {
            if state.isForecastCone {
                if let lastConePoint = forecastConePoints.last {
                    endDate = lastConePoint.date
                } else {
                    endDate = now.addingTimeInterval(2 * 3600) // Fallback if data is missing
                }
            } else {
                if let maxLineDate = forecastLinePoints.map(\.date).max() {
                    endDate = maxLineDate
                } else {
                    endDate = now.addingTimeInterval(2 * 3600) // Fallback if data is missing
                }
            }
        }

        // Prevents an invalid range interval if the calculated end date is in the past
        return startDate ... max(now, endDate)
    }

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
        // one hour is the full-screen chart's only; this one cycles from three hours
        case .oneHour,
             .threeHours: return 18
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

                // boluses, SMBs and carbs, the watch's own while it loops, as on the big chart
                TreatmentMarks(
                    markers: state.treatmentMarkers.isEmpty ? state.phoneTreatmentMarkers : state.treatmentMarkers,
                    glucose: filteredValues
                )

                if state.showForecast {
                    if state.isForecastCone {
                        // Only the fill area of the cone — no border lines for min/max.
                        ForEach(forecastConePoints) { pt in
                            AreaMark(
                                x: .value("Time", pt.date),
                                yStart: .value("Min", pt.min),
                                yEnd: .value("Max", pt.max)
                            )
                            .foregroundStyle(Color.insulin.opacity(0.3))
                        }
                    } else {
                        // Uses the cleanly capped forecast line points in the chart
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
            // `withAnimation` doesn't reach an `@AppStorage` write, so the chart animates itself —
            // on zoom and whenever new readings or a new forecast arrive.
            .animation(.easeInOut, value: timeWindow)
            .animation(.easeInOut, value: glucoseValues.last?.date)
            .animation(.easeInOut, value: state.forecastStartDate)
            .onTapGesture {
                timeWindow = timeWindow.next
            }
        }
    }
}

// MARK: - Wiring note

//
// CombinedGlucoseChartview is additive: it is intentionally NOT embedded in TrioMainWatchView, so the existing
// Trio-on-Watch loan/control UI stays exactly as it is. To use it as a page, add it to the main view's paging
// stack the same way the separate GlucoseTrendView + GlucoseChartView pages are added, passing `state`,
// the trend `rotationDegrees` the main view already computes, and its `isWatchStateDated` flag, e.g.:
//
//     CombinedGlucoseChartview(
//         state: state,
//         rotationDegrees: rotationDegrees,
//         isWatchStateDated: isWatchStateDated
//     )
