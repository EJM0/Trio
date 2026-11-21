import SwiftUI

struct GlucoseTrendView: View {
    let state: WatchState
    let rotationDegrees: Double
    let isWatchStateDated: Bool
    /// Trio on Watch; nil keeps the tethered remote as it is.
    var loan: TrioOnWatchStatus?
    var now = Date()
    var onControlLineTap: () -> Void = {}

    /// While a loan runs, the watch's own values replace the phone's snapshot.
    private var loanValues: TrioOnWatchStatus.MainValues? {
        guard let loan, loan.isLoanActive else { return nil }
        return loan.mainValues(now: now)
    }

    private var loanTrend: String? {
        guard loanValues != nil else { return nil }
        return loan?.trend(now: now)
    }

    private var arrowDegrees: Double {
        loanValues != nil ? Self.degrees(for: loanTrend) : rotationDegrees
    }

    /// The arrow's angle for a trend: up is -90, flat 0, down 90.
    static func degrees(for trend: String?) -> Double {
        switch trend {
        case "DoubleUp",
             "SingleUp":
            return -90
        case "FortyFiveUp":
            return -45
        case "FortyFiveDown":
            return 45
        case "DoubleDown",
             "SingleDown":
            return 90
        default:
            return 0
        }
    }

    private var controlLine: TrioOnWatchStatus.ControlLine? {
        guard let loan, loan.isLoanActive || !isWatchStateDated else { return nil }
        return loan.controlLine(now: now, phoneLoopText: state.lastLoopTime)
    }

    private var ringColor: Color {
        if let loan, loan.isLoanActive { return loan.controlLine(now: now, phoneLoopText: nil).tier.color }
        return statusColor(for: state.lastLoopTime)
    }

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

    var circleSize: CGFloat {
        switch state.deviceType {
        case .watch40mm:
            return 82
        case .watch41mm,
             .watch42mm:
            return 86
        case .watch44mm:
            return 96
        case .unknown,
             .watch45mm:
            return 103
        case .watch49mm:
            return 105
        }
    }

    var lineWidth: CGFloat {
        switch state.deviceType {
        case .watch40mm,
             .watch41mm,
             .watch42mm,
             .watch44mm:
            return 1
        case .unknown,
             .watch45mm:
            return 1.5
        case .watch49mm:
            return 1.5
        }
    }

    var shadowRadius: CGFloat {
        switch state.deviceType {
        case .watch40mm,
             .watch41mm,
             .watch42mm:
            return 8
        case .watch44mm:
            return 9
        case .unknown,
             .watch45mm:
            return 12
        case .watch49mm:
            return 12
        }
    }

    var currentGlucoseFontSize: Font {
        switch state.deviceType {
        case .watch40mm,
             .watch41mm,
             .watch42mm,
             .watch44mm:
            return .title2
        case .unknown,
             .watch45mm:
            return .title
        case .watch49mm:
            return .title
        }
    }

    var minutesAgoFontSize: CGFloat {
        switch state.deviceType {
        case .watch40mm,
             .watch41mm:
            return 9
        case .unknown,
             .watch42mm,
             .watch44mm:
            return 10
        case .watch45mm:
            return 11
        case .watch49mm:
            return 10
        }
    }

    var body: some View {
        VStack {
            ZStack {
                Circle()
                    .stroke(ringColor, lineWidth: lineWidth)
                    .frame(width: circleSize, height: circleSize)
                    .background(Circle().fill(Color.bgDarkBlue))
                    .shadow(color: ringColor, radius: shadowRadius)

                TrendShape(
                    // in watch mode, the trend of the watch's own reading, not the phone's
                    isWatchStateDated: loanValues != nil ? loanTrend == nil : isWatchStateDated,
                    rotationDegrees: arrowDegrees,
                    deviceType: state.deviceType
                )
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: arrowDegrees)
                .shadow(color: Color.black.opacity(0.5), radius: 5)

                if let loanValues {
                    VStack(alignment: .center) {
                        Text(loanValues.glucose)
                            .fontWeight(.semibold)
                            .font(currentGlucoseFontSize)
                            .foregroundStyle(loanValues.isStale ? Color.secondary : Color.primary)
                        Text(loanValues.detail)
                            .fontWeight(.semibold)
                            .font(.system(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: circleSize * 0.75)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(loanValues.accessibilityLabel))
                } else {
                    VStack(alignment: .center) {
                        Text(isWatchStateDated ? "--" : state.currentGlucose)
                            .fontWeight(.semibold)
                            .font(currentGlucoseFontSize)
                            .foregroundStyle(isWatchStateDated ? Color.secondary : state.currentGlucoseColorString.toColor())

                        if let delta = state.delta {
                            Text(isWatchStateDated ? "--" : delta)
                                .fontWeight(.semibold)
                                .font(.system(.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer()

            if let controlLine {
                ControlLineView(line: controlLine, action: onControlLineTap)
            } else {
                Text(
                    isWatchStateDated ?
                        String(localized: "STALE DATA", comment: "Information displayed when watch app data outdated or stale.") :
                        state
                        .lastLoopTime ?? "--"
                )
                .font(.system(size: minutesAgoFontSize))
                .fontWidth(isWatchStateDated ? .expanded : .standard)
            }

            Spacer()

        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
