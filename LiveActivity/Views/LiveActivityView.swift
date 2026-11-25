import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

struct LiveActivityView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.isWatchOS) var isWatchOS

    var context: ActivityViewContext<LiveActivityAttributes>

    private var hasStaticColorScheme: Bool {
        context.state.glucoseColorScheme == "staticColor"
    }

    private var glucoseColor: Color {
        context.state.glucoseColor
    }

    var body: some View {
        if context.state.watchMode != nil, !context.state.isInitialState {
            LiveActivityWatchModeView(context: context, glucoseColor: glucoseColor)
                .addLiveActivityModifiers(isWatchOS: isWatchOS)
        } else if isWatchOS, context.state.useDetailedViewWatchOS {
            VStack {
                HStack {
                    LiveActivityBGLabelWatchView(context: context, glucoseColor: glucoseColor)
                    LiveActivityIOBLabelWatchView(
                        context: context,
                        additionalState: context.state.detailedViewState,
                        glucoseColor: glucoseColor
                    )
                    Spacer()
                    LiveActivityUpdatedLabelView(context: context, isDetailedLayout: true)
                }
                LiveActivityChartView(context: context, additionalState: context.state.detailedViewState)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
            }
            .addLiveActivityModifiers(isWatchOS: true)

        } else if isWatchOS {
            HStack {
                LiveActivityBGLabelLargeView(
                    context: context,
                    glucoseColor: glucoseColor
                )
                Spacer()
                VStack {
                    LiveActivityGlucoseDeltaLabelView(
                        context: context,
                        glucoseColor: .primary
                    )
                    LiveActivityUpdatedLabelView(context: context, isDetailedLayout: false)
                }
            }
            .addLiveActivityModifiers(isWatchOS: true)

        } else if context.state.useDetailedViewIOS {
            VStack {
                LiveActivityChartView(context: context, additionalState: context.state.detailedViewState)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
                    .frame(height: 80)
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 4) {
                            if context.state.detailedViewState.isOverrideActive {
                                Text(context.state.detailedViewState.overrideName)
                                    .font(.footnote)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .padding(6)
                                    .background {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.purple.opacity(colorScheme == .dark ? 0.6 : 0.8))
                                    }
                            }
                            if context.state.detailedViewState.isTempTargetActive {
                                Text(context.state.detailedViewState.tempTargetName)
                                    .font(.footnote)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .padding(6)
                                    .background {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color("LoopGreen").opacity(colorScheme == .dark ? 0.6 : 0.8))
                                    }
                            }
                        }
                    }

                let widgetItems = context.state.detailedViewState.widgetItems.filter { $0 != .wideContinuation }

                HStack {
                    if widgetItems.contains(where: { $0 != .empty }) {
                        ForEach(
                            Array(widgetItems.enumerated()),
                            id: \.offset
                        ) { index, widgetItem in
                            switch widgetItem {
                            case .currentGlucose:
                                VStack {
                                    LiveActivityBGLabelView(
                                        context: context,
                                        additionalState: context.state.detailedViewState
                                    )

                                    HStack {
                                        LiveActivityGlucoseDeltaLabelView(
                                            context: context,
                                            glucoseColor: .primary
                                        )
                                        if !context.isStale, let direction = context.state.direction {
                                            Text(direction).font(.headline)
                                        }
                                    }
                                }
                            case .currentGlucoseLarge:
                                LiveActivityBGLabelLargeView(
                                    context: context,
                                    glucoseColor: glucoseColor
                                )
                            case .currentGlucoseLargeUncolored:
                                LiveActivityBGLabelLargeView(
                                    context: context,
                                    glucoseColor: .primary
                                )
                            case .currentGlucoseColored:
                                VStack {
                                    LiveActivityBGLabelView(
                                        context: context,
                                        additionalState: context.state.detailedViewState,
                                        glucoseColor: glucoseColor
                                    )

                                    HStack {
                                        LiveActivityGlucoseDeltaLabelView(
                                            context: context,
                                            glucoseColor: glucoseColor
                                        )
                                        if !context.isStale, let direction = context.state.direction {
                                            Text(direction).font(.headline).foregroundStyle(glucoseColor)
                                        }
                                    }
                                }
                            case .currentGlucoseWide,
                                 .currentGlucoseWideUncolored:
                                let wideColor: Color = widgetItem == .currentGlucoseWideUncolored ? .primary : glucoseColor
                                let wideFont: Font = isWatchOS ? .title : .largeTitle
                                let secondaryFont: Font = isWatchOS ? .title3 : .title2
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    LiveActivityBGLabelLargeView(
                                        context: context,
                                        glucoseColor: wideColor,
                                        glucoseFont: wideFont,
                                        arrowFont: secondaryFont
                                    )
                                    LiveActivityGlucoseDeltaLabelView(
                                        context: context,
                                        glucoseColor: .primary
                                    )
                                    .fontWeight(.bold)
                                    .font(secondaryFont)
                                }
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            case .iob:
                                LiveActivityIOBLabelView(context: context, additionalState: context.state.detailedViewState)
                            case .cob:
                                LiveActivityCOBLabelView(context: context, additionalState: context.state.detailedViewState)
                            case .updatedLabel:
                                LiveActivityUpdatedLabelView(context: context, isDetailedLayout: true)
                            case .totalDailyDose:
                                LiveActivityTotalDailyDoseView(
                                    context: context,
                                    additionalState: context.state.detailedViewState
                                )
                            case .empty:
                                Text("").frame(width: 50, height: 50)
                            case .wideContinuation:
                                EmptyView()
                            }

                            /// Check if the next item is also non-empty to determine if a divider should be shown
                            if index < widgetItems.count - 1 {
                                let currentItem = widgetItems[index]
                                let nextItem = widgetItems[index + 1]

                                if currentItem != .empty, nextItem != .empty {
                                    Divider()
                                        .foregroundStyle(.primary)
                                        .fontWeight(.bold)
                                        .frame(width: 10)
                                }
                            }
                        }
                    }
                }
            }
            .addLiveActivityModifiers(isWatchOS: false)
        } else {
            let simpleViewStyle = context.state.simpleViewStyle

            Group {
                if context.state.isInitialState {
                    Text("Live Activity Expired. Open Trio to Refresh").minimumScaleFactor(0.01)
                } else {
                    HStack(spacing: 3) {
                        LiveActivityBGAndTrendView(context: context, size: .expanded, glucoseColor: glucoseColor)
                            .font(simpleViewStyle.glucoseFont)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            LiveActivityGlucoseDeltaLabelView(
                                context: context,
                                glucoseColor: hasStaticColorScheme ? .primary : glucoseColor
                            ).font(.title3)
                            LiveActivityUpdatedLabelView(context: context, isDetailedLayout: false)
                                .font(.caption)
                                .foregroundStyle(.primary.opacity(0.7))
                        }
                    }
                }
            }
            .addLiveActivityModifiers(isWatchOS: false, verticalPadding: simpleViewStyle.fontSize.verticalPadding)
        }
    }
}

// Expanded, minimal, compact view components
struct LiveActivityExpandedLeadingView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color

    var body: some View {
        LiveActivityBGAndTrendView(context: context, size: .expanded, glucoseColor: glucoseColor).font(.title2)
            .padding(.leading, 5)
    }
}

struct LiveActivityExpandedTrailingView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color

    var body: some View {
        if context.state.watchMode != nil {
            Image(systemName: "applewatch").font(.title2).padding(.trailing, 5)
        } else {
            LiveActivityGlucoseDeltaLabelView(context: context, glucoseColor: glucoseColor).font(.title2)
                .padding(.trailing, 5)
        }
    }
}

struct LiveActivityExpandedBottomView: View {
    var context: ActivityViewContext<LiveActivityAttributes>

    var body: some View {
        if context.state.isInitialState {
            Text("Live Activity Expired. Open Trio to Refresh").minimumScaleFactor(0.01)
        } else if let watchMode = context.state.watchMode {
            LiveActivityWatchModeTimes(readingAt: context.state.date, watchMode: watchMode)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if context.state.useDetailedViewIOS {
            LiveActivityChartView(context: context, additionalState: context.state.detailedViewState)
                .addIsWatchOS()
        }
    }
}

struct LiveActivityExpandedCenterView: View {
    var context: ActivityViewContext<LiveActivityAttributes>

    var body: some View {
        if context.state.watchMode != nil {
            Text(String(localized: "Trio on Watch", comment: "Live Activity while Apple Watch controls the pump"))
                .font(.caption.weight(.semibold))
        } else {
            LiveActivityUpdatedLabelView(context: context, isDetailedLayout: false)
                .font(Font.caption)
                .foregroundStyle(Color.secondary)
                .addIsWatchOS()
        }
    }
}

struct LiveActivityCompactLeadingView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color

    var body: some View {
        LiveActivityBGAndTrendView(context: context, size: .compact, glucoseColor: glucoseColor)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

struct LiveActivityCompactTrailingView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color

    var body: some View {
        if context.state.watchMode != nil {
            Image(systemName: "applewatch").padding(.trailing, 4)
        } else {
            LiveActivityGlucoseDeltaLabelView(context: context, glucoseColor: glucoseColor).padding(.trailing, 4)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
}

struct LiveActivityMinimalView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color

    var body: some View {
        let (label, characterCount) = bgAndTrend(context: context, size: .minimal, glucoseColor: glucoseColor)
        let adjustedLabel = label.padding(.leading, 5).padding(.trailing, 2)

        if characterCount < 4 {
            adjustedLabel.fontWidth(.condensed)
        } else if characterCount < 5 {
            adjustedLabel.fontWidth(.compressed)
        } else {
            adjustedLabel.fontWidth(.compressed)
        }
    }
}

/// While Trio on Watch controls the pump the phone doesn't loop: its IOB, COB, forecast and loop time are old, so they
/// make way for the watch's state.
struct LiveActivityWatchModeView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            LiveActivityBGAndTrendView(context: context, size: .expanded, glucoseColor: glucoseColor)
                .font(.title)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Label(
                    String(localized: "Trio on Watch", comment: "Live Activity while Apple Watch controls the pump"),
                    systemImage: "applewatch"
                )
                .font(.headline)
                if let watchMode = context.state.watchMode {
                    LiveActivityWatchModeTimes(readingAt: context.state.date, watchMode: watchMode)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }
}

/// The reading's time and the watch's last loop, as times rather than ages, so they stay right between updates.
struct LiveActivityWatchModeTimes: View {
    let readingAt: Date?
    let watchMode: LiveActivityAttributes.WatchMode

    var body: some View {
        let reading = readingAt
            .map {
                Text(String(
                    localized: "Reading",
                    comment: "Live Activity in watch mode: label before the time of the latest reading"
                )) + Text(" ") +
                    Text($0, style: .time) }
        let loop = watchMode.lastLoop.map {
            Text(String(
                localized: "Watch loop",
                comment: "Live Activity in watch mode: label before the time of the watch's last loop"
            )) + Text(" ") +
                Text($0, style: .time)
        } ?? Text(String(localized: "Since", comment: "Live Activity in watch mode: label before the time watch mode started")) +
            Text(" ") + Text(watchMode.since, style: .time)
        if let reading {
            reading + Text(" · ") + loop
        } else {
            loop
        }
    }
}
