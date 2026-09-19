import SwiftUI

/// One bar per day in the selected window, measured against a time-in-range goal.
///
/// The per-day figures already exist: `GlucoseDailyDistributionStats.inRangePct` is computed
/// once for the whole 90-day history and cached on the state model, so this view only picks
/// the days in the current window and draws them.
///
/// Hand-drawn rather than a `Chart`: the layout is three aligned columns with a dashed line
/// running across all of them, which is a stack of rectangles — and Swift Charts would fight
/// us over annotation placement to land in the same place.
struct GlucoseGoalChart: View {
    let dailyStats: [GlucoseDailyDistributionStats]
    let window: (start: Date, end: Date)
    let interval: Stat.StateModel.StatsTimeIntervalWithCustom

    /// The goal lives in app storage rather than in `TrioSettings`: it steers nothing outside
    /// this screen, so it needs neither a place in the settings model nor a migration.
    @AppStorage("statsTimeInRangeGoal") private var goal: Int = 70

    @State private var isPickingGoal = false

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    /// The goals worth offering, a percentage point apart. Below 50 % the bar stops saying
    /// anything useful, and 100 % is a goal no day can clear.
    private static let selectableGoals = 50 ... 95

    private enum Layout {
        static let rowHeight: CGFloat = 26
        static let rowSpacing: CGFloat = 6
        static let labelWidth: CGFloat = 44
        static let valueWidth: CGFloat = 50
        /// Gap between the bar column and the percentages, on top of the row spacing. The
        /// bars run right up to their track's edge, so without it the figures touch them.
        static let valueGap: CGFloat = 10
        /// Room above the bars for the goal line's own caption.
        static let captionHeight: CGFloat = 18
    }

    var body: some View {
        // Bound once: every column below reads it, and each read filters and sorts anew.
        let days = daysInWindow

        VStack(alignment: .leading, spacing: 12) {
            header(for: days)

            if days.isEmpty {
                Text("No days with glucose data in this range.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                bars(for: days)
            }
        }
        .sheet(isPresented: $isPickingGoal) { goalPicker }
    }

    // MARK: - Data

    /// Only days the window covers, newest first. Days without readings are simply absent
    /// from the stats, so they leave no row rather than an empty one.
    ///
    /// Newest at the top because that is where a 90-day range is read from: the most recent
    /// days are the ones being judged, and the older ones are context below them. Oldest-first
    /// put today at the bottom of a list far taller than the screen, so the day that matters
    /// most took the longest scroll to reach.
    private var daysInWindow: [GlucoseDailyDistributionStats] {
        let calendar = Calendar.current

        // A picked range's upper bound is exclusive — the midnight *after* its last day — so
        // step back a moment before asking which day it falls in. Taking it as inclusive gave
        // a one-day range two rows.
        let last = calendar.startOfDay(for: window.end.addingTimeInterval(-1))

        // The rolling 24 h window straddles midnight, but these bars are whole calendar days.
        // Reporting yesterday in full would count hours the window never covered, so that
        // interval reports on today alone.
        let first = interval == .day ? last : calendar.startOfDay(for: window.start)

        return dailyStats
            .filter { stat in
                let day = calendar.startOfDay(for: stat.date)
                return day >= first && day <= last
            }
            .sorted { $0.date > $1.date }
    }

    /// The figure a row actually shows, rounded once. The bar, the percentage and the
    /// goal check all read from this, so a day printed as 100 % cannot draw a bar that
    /// stops short of the track — and a row printed as 92 % cannot count as missing a 92 %
    /// goal. The alternative, comparing the unrounded value, makes the number on screen
    /// disagree with the colour beside it.
    private func displayedPct(_ stat: GlucoseDailyDistributionStats) -> Double {
        stat.inRangePct.rounded()
    }

    private func reached(_ stat: GlucoseDailyDistributionStats) -> Bool {
        displayedPct(stat) >= Double(goal)
    }

    // MARK: - Header

    @ViewBuilder private func header(for days: [GlucoseDailyDistributionStats]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(
                    String(
                        format: String(
                            localized: "%d days",
                            comment: "Stats range picker footer: how many whole days the range covers"
                        ),
                        days.count
                    )
                )
                .font(.headline)

                Spacer()

                goalButton
            }

            Text(
                String(
                    format: String(
                        localized: "Goal reached on %1$d of %2$d days.",
                        comment: "Stats goal chart: how many days met the time-in-range goal (1: days met, 2: days total)"
                    ),
                    days.filter(reached).count,
                    days.count
                )
            )
            .font(.subheadline)
            .foregroundStyle(Color.secondary)

            // Read off the dates themselves rather than the ends of the array: the rows run
            // newest-first, so `first` is the later date, and a caption that quietly inverts
            // itself when the sort changes is not worth the two characters it saves.
            let dates = days.map(\.date)
            if let earliest = dates.min(), let latest = dates.max() {
                Text("\(shortDate(earliest)) – \(shortDate(latest))")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    /// Opens the wheel rather than carrying a menu of its own: a percentage point apart,
    /// the choices are far too many for a menu to list.
    private var goalButton: some View {
        Button {
            isPickingGoal = true
        } label: {
            HStack(spacing: 4) {
                Text(
                    String(
                        format: String(
                            localized: "Goal: %@",
                            comment: "Stats goal chart: the button showing the current goal (1: the goal percentage)"
                        ),
                        percentText(Double(goal))
                    )
                )
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.subheadline)
            .foregroundColor(.tabBar)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Time in range goal"))
        .accessibilityValue(Text(percentText(Double(goal))))
    }

    /// A wheel, in a sheet: inline it would swallow the stats screen's own scrolling.
    /// Writes straight through to app storage, so the bars redraw as the wheel turns.
    private var goalPicker: some View {
        NavigationStack {
            Picker("Goal", selection: $goal) {
                ForEach(Self.selectableGoals, id: \.self) { value in
                    Text(percentText(Double(value))).tag(value)
                }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Trio's own background rather than the system sheet grey, matching the day
            // picker sheet on the same screen.
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(Text("Time in Range Goal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPickingGoal = false }
                }
            }
        }
        .presentationDetents([.height(300)])
    }

    // MARK: - Bars

    @ViewBuilder private func bars(for days: [GlucoseDailyDistributionStats]) -> some View {
        let height = CGFloat(days.count) * Layout.rowHeight
            + CGFloat(max(0, days.count - 1)) * Layout.rowSpacing

        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: Layout.rowSpacing) {
                ForEach(days) { day in
                    Text(dayLabel(for: day.date, total: days.count))
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .frame(width: Layout.labelWidth, height: Layout.rowHeight, alignment: .leading)
                }
            }

            // One reader for the whole column: every bar width and the goal line's position
            // come off the same measurement.
            GeometryReader { geo in
                let goalX = geo.size.width * CGFloat(goal) / 100

                VStack(spacing: Layout.rowSpacing) {
                    ForEach(days) { day in
                        bar(for: day, in: geo.size.width)
                    }
                }
                // The line and its caption go in overlays, not in a ZStack beside the bars.
                // The caption centres itself by shifting its own leading guide, and a shifted
                // guide grows the stack that holds it — the tracks, being flexible, grew with
                // it while the bars kept dividing `geo.size.width`, so every bar fell short by
                // half the caption's width. An overlay never resizes what it sits on.
                .overlay(alignment: .topLeading) {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: -Layout.captionHeight / 2))
                        path.addLine(to: CGPoint(x: 0, y: height))
                    }
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .offset(x: goalX)
                }
                .overlay(alignment: .topLeading) {
                    Text(percentText(Double(goal)))
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                        .fixedSize()
                        // Centre the caption on the line rather than starting it there.
                        .alignmentGuide(.leading) { $0.width / 2 }
                        .offset(x: goalX, y: -Layout.captionHeight)
                }
            }
            .frame(height: height)

            VStack(spacing: Layout.rowSpacing) {
                ForEach(days) { day in
                    Text(percentText(displayedPct(day)))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(Color.primary)
                        .frame(width: Layout.valueWidth, height: Layout.rowHeight, alignment: .trailing)
                }
            }
            .padding(.leading, Layout.valueGap)
        }
        .padding(.top, Layout.captionHeight)
    }

    private func bar(for day: GlucoseDailyDistributionStats, in width: CGFloat) -> some View {
        let met = reached(day)
        // A day that met the goal gets the full colour; the rest stay washed out, so the
        // good days are picked out at a glance rather than read off the numbers.
        return ZStack(alignment: .leading) {
            // Pinned to the same number the bar below divides, so the two cannot disagree
            // however the surrounding layout is proposed.
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: width)

            RoundedRectangle(cornerRadius: 4)
                .fill(met ? Color.dynamicGreen : Color.dynamicGreen.opacity(0.35))
                .frame(width: displayedPct(day) > 0 ? max(2, width * CGFloat(displayedPct(day)) / 100) : 0)
        }
        .frame(height: Layout.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(day.date.formatted(.dateTime.weekday(.wide).day().month())))
        .accessibilityValue(
            Text(
                met
                    ? String(
                        format: String(
                            localized: "%@ time in range, goal reached",
                            comment: "Stats goal chart accessibility value for a day that met the goal (1: the percentage)"
                        ),
                        percentText(displayedPct(day))
                    )
                    : String(
                        format: String(
                            localized: "%@ time in range",
                            comment: "Stats goal chart accessibility value for a day that missed the goal (1: the percentage)"
                        ),
                        percentText(displayedPct(day))
                    )
            )
        )
    }

    // MARK: - Formatting

    /// Weekday initials read well for a week; past that they repeat without saying which
    /// week, so longer windows get the date instead.
    private func dayLabel(for date: Date, total: Int) -> String {
        total <= 7
            ? date.formatted(.dateTime.weekday(.abbreviated))
            : date.formatted(.dateTime.day(.twoDigits).month(.twoDigits))
    }

    private func percentText(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
