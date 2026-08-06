import Charts
import Foundation
import SwiftUI

/// Brackets over sustained glucose excursions: a capped bar spanning the episode, carrying how
/// long it ran in `hh:mm`.
///
/// Highs are marked in the empty band above the data, lows in the band below it — the padding
/// `MainChartView.paddedGlucoseYDomain` adds beyond the axis bounds — so the markers never sit
/// on top of the glucose curve. Only episodes past `Config.episodeMinimumDuration` are drawn;
/// shorter excursions are already legible from the curve itself.
struct GlucoseEpisodeView: ChartContent {
    let episodes: [GlucoseEpisode]
    let units: GlucoseUnits
    let highGlucose: Decimal
    let lowGlucose: Decimal
    let currentGlucoseTarget: Decimal
    let glucoseColorScheme: GlucoseColorScheme
    /// Axis bounds in mg/dL. The lanes hang in the padding beyond them.
    let minYAxisValue: Decimal
    let maxYAxisValue: Decimal
    /// Length of the visible x-window, used to decide whether a marker is wide enough on
    /// screen to carry its label.
    let visibleSeconds: TimeInterval
    /// Right edge of an episode that is still running. Fixed per layout, like the chart's
    /// current-time rule.
    let now = Date()

    var body: some ChartContent {
        ForEach(displayedEpisodes) { episode in
            marks(for: episode)
        }
    }

    /// Excursions long enough to be worth a marker. An ongoing episode qualifies as soon as it
    /// has run past the minimum, so the marker appears while the event is still happening.
    private var displayedEpisodes: [GlucoseEpisode] {
        episodes.filter { $0.elapsed(asOf: now) >= MainChartHelper.Config.episodeMinimumDuration }
    }

    @ChartContentBuilder private func marks(for episode: GlucoseEpisode) -> some ChartContent {
        let lane = laneValue(for: episode.type)
        let capInset = capHalfHeight
        let color = color(for: episode.type)
        let end = episode.displayEnd(asOf: now)

        // The span itself.
        RuleMark(
            xStart: .value("Start", episode.start, unit: .second),
            xEnd: .value("End", end, unit: .second),
            y: .value("Episode", lane)
        )
        .foregroundStyle(color.opacity(0.75))
        .lineStyle(.init(lineWidth: 4, lineCap: .round))
        .annotation(
            position: .overlay,
            alignment: .center,
            spacing: 0,
            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
        ) {
            durationLabel(for: episode)
        }

        // Start cap. Both boundaries get one, so the moment the excursion began and the moment
        // it ended are readable even where two markers nearly touch.
        /*         RuleMark(
             x: .value("Start", episode.start, unit: .second),
             yStart: .value("Cap start", lane - capInset),
             yEnd: .value("Cap end", lane + capInset)
         )
         .foregroundStyle(color)
         .lineStyle(.init(lineWidth: 2, lineCap: .round)) */

        // End cap — only once the episode is closed; a running one is deliberately open-ended.
        /*         if !episode.isOngoing {
             RuleMark(
                 x: .value("End", end, unit: .second),
                 yStart: .value("Cap start", lane - capInset),
                 yEnd: .value("Cap end", lane + capInset)
             )
             .foregroundStyle(color)
             .lineStyle(.init(lineWidth: 2, lineCap: .round))
         } */
    }

    @ViewBuilder private func durationLabel(for episode: GlucoseEpisode) -> some View {
        let fraction = visibleSeconds > 0 ? episode.elapsed(asOf: now) / visibleSeconds : 0
        if fraction >= MainChartHelper.Config.episodeLabelMinimumWindowFraction {
            Text(episode.formattedDuration(asOf: now))
                .font(.caption2)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.ultraThinMaterial)
                )
        }
    }

    /// Centre of the marker lane, in the chart's display units. 12 mg/dL past the axis bound
    /// keeps the bar and both caps inside the 25 mg/dL padding of the plotted domain.
    private func laneValue(for type: GlucoseEpisode.EpisodeType) -> Decimal {
        let mgdl = type == .high ? maxYAxisValue + 12 : minYAxisValue - 12
        return units == .mgdL ? mgdl : mgdl.asMmolL
    }

    /// Half-height of the end caps, in display units.
    private var capHalfHeight: Decimal {
        units == .mgdL ? 8 : Decimal(8).asMmolL
    }

    /// The same colors the threshold lines use, so a marker reads as "this is the high line's
    /// territory" without a legend.
    private func color(for type: GlucoseEpisode.EpisodeType) -> Color {
        // TODO: same workaround as the glucose points and threshold lines — the dynamic scheme
        // needs headroom beyond the user's limits to have shades to interpolate through.
        let hardCodedLow = Decimal(55)
        let hardCodedHigh = Decimal(220)
        let isDynamicColorScheme = glucoseColorScheme == .dynamicColor

        return Trio.getDynamicGlucoseColor(
            glucoseValue: type == .high ? highGlucose : lowGlucose,
            highGlucoseColorValue: isDynamicColorScheme ? hardCodedHigh : highGlucose,
            lowGlucoseColorValue: isDynamicColorScheme ? hardCodedLow : lowGlucose,
            targetGlucose: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }
}
