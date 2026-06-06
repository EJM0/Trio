import SwiftUI

struct GlucoseTrendView: View {
    let state: WatchState
    let rotationDegrees: Double
    let isWatchStateDated: Bool

    /// Determines the status color based on the time elapsed since the last loop
    /// - Parameter timeString: The time string representing minutes since last loop (format: "X min")
    /// - Returns: A color indicating the status:
    ///   - Green: <= 5 minutes
    ///   - Yellow: 5-10 minutes
    ///   - Red: > 10 minutes or invalid time
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

                VStack(alignment: .center) {
                    Text(isWatchStateDated ? "--" : state.currentGlucose)
                        .fontWeight(.semibold)
                        .font(state.deviceType.currentGlucoseFontSize)
                        .foregroundStyle(isWatchStateDated ? Color.secondary : state.currentGlucoseColorString.toColor())

                    if let delta = state.delta {
                        Text(isWatchStateDated ? "--" : delta)
                            .fontWeight(.semibold)
                            .font(.system(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text(
                isWatchStateDated ?
                    String(localized: "STALE DATA", comment: "Information displayed when watch app data outdated or stale.") :
                    state
                    .lastLoopTime ?? "--"
            )
            .font(.system(size: state.deviceType.minutesAgoFontSize))
            .fontWidth(isWatchStateDated ? .expanded : .standard)

            Spacer()

        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
