import Foundation
import SwiftUI

/// Brackets over sustained glucose excursions: a capped bar spanning the episode, carrying how
/// long it ran in `hh:mm`.
///
/// Both highs and lows are marked in the same empty band above the data — the padding
/// `MainChartView.paddedGlucoseYDomain` adds beyond the upper axis bound — so the markers never
/// sit on top of the glucose curve and every episode reads off one shared baseline. The two kinds
/// never overlap in time, so a single lane is unambiguous; color carries which is which. Only
/// episodes past `Config.episodeMinimumDuration` are drawn; shorter excursions are already
/// legible from the curve itself.
///
/// Drawn by the shell, like every other marker layer: inside the canvas the live-pinch
/// `scaleEffect` — an x-only transform — stretched the bar's round caps and the duration text
/// for the length of a gesture and snapped them back at every commit, and the marks re-laid
/// with the canvas on every committed zoom step. Out here the pinch reaches only their
/// *coordinates*, through the same `ChartViewport` the dots and treatment markers use.
///
/// One `Canvas`, exactly like `GlucoseDotsOverlay` and `TreatmentOverlay`, and for a reason
/// this layer learned the hard way. Its first version drew each bar as a laid-out view —
/// `Capsule().frame(width: endX - startX).position(x: midpoint)` — and the brackets tracked the
/// chart for a while and then stuck. At tight zoom that frame is several screens wide, and a
/// `.position` view claims the space it is offered and centres its child at the given point: an
/// oversized child whose centre has left the container is no longer placed truthfully, and a
/// wide enough one exceeds the max texture size on top of that. Here the span is a `Path` in
/// the canvas's own coordinate space, so nothing about it passes through layout, and the
/// `Canvas` clips to its bounds the way the `Chart`'s plot used to — which is why the bar can
/// be handed its real geometry however far past the viewport it runs.
struct GlucoseEpisodesOverlay: View {
    @Environment(\.colorScheme) private var colorScheme

    let episodes: [GlucoseEpisode]
    let units: GlucoseUnits
    let highGlucose: Decimal
    let lowGlucose: Decimal
    let currentGlucoseTarget: Decimal
    let glucoseColorScheme: GlucoseColorScheme
    /// Upper axis bound in mg/dL. The lane hangs in the padding beyond it.
    let maxYAxisValue: Decimal
    /// Leading edge of the chart's history. Stored episodes keep the start they were measured
    /// at, which can predate it, so the bar is drawn from here instead.
    let historyStart: Date

    /// Time-to-x mapping for this frame, handed down by `ChartOverlayLayer` — already
    /// interpolated, and already carrying the live-pinch stretch.
    let viewport: ChartViewport

    /// Value-to-pixel mapping for the glucose pane, so the lane sits exactly where the padded
    /// y-domain puts it.
    let yPosition: (Decimal) -> CGFloat

    /// Thickness of the span bar — the `lineWidth` its `RuleMark` carried.
    private static let barThickness: CGFloat = 4

    /// Padding around the duration label's badge.
    private static let labelPadding = CGSize(width: 4, height: 1)

    /// How far past the viewport an episode is still drawn: enough that a bar whose end has
    /// just left the screen still reaches the edge, and that its label can travel off rather
    /// than wink out.
    private static let cullMarginPoints: CGFloat = 60

    var body: some View {
        // Fixed for the pass, like the canvas's own current-time rule: an ongoing episode is
        // drawn up to here, and its length is measured to here.
        let now = Date()

        let isDark = colorScheme == .dark

        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            for bracket in brackets(asOf: now) {
                context.fill(bracket.bar, with: .color(bracket.tint.opacity(0.75)))

                // Resolved here rather than up front: measuring it is what sizes the badge
                // behind it, and only a context can measure.
                let resolved = context.resolve(bracket.label)
                let textSize = resolved.measure(in: size)
                let center = bracket.labelCenter
                let badge = Path(
                    roundedRect: CGRect(
                        x: center.x - textSize.width / 2 - Self.labelPadding.width,
                        y: center.y - textSize.height / 2 - Self.labelPadding.height,
                        width: textSize.width + Self.labelPadding.width * 2,
                        height: textSize.height + Self.labelPadding.height * 2
                    ),
                    cornerRadius: isDark ? 3 : 2
                )

                context.fill(badge, with: .color(bracket.tint.opacity(isDark ? 0.65 : 0.75)))
                if !isDark {
                    context.stroke(badge, with: .color(Color.primary.opacity(0.7)), lineWidth: 0.4)
                }
                context.draw(resolved, at: center, anchor: .center)
            }
        }
    }

    // MARK: - Bracket geometry

    private struct Bracket {
        let bar: Path
        /// The episode's own color, at full strength: the bar and the badge each take it down
        /// by their own amount.
        let tint: Color
        let label: Text
        let labelCenter: CGPoint
    }

    private func brackets(asOf now: Date) -> [Bracket] {
        let lane = yPosition(laneValue)
        let thickness = Self.barThickness
        // Two kinds, so the color is resolved twice per pass rather than once per bracket.
        let highColor = color(for: .high)
        let lowColor = color(for: .low)

        return visibleEpisodes(asOf: now).map { episode in
            let tint = episode.type == .high ? highColor : lowColor
            // An excursion that began before the chart's history is drawn from that edge: the
            // readings behind it are gone, and the label — which reports the whole length
            // either way — then centres between the edge and the end.
            let startX = viewport.x(for: max(episode.start, historyStart))
            let endX = viewport.x(for: episode.displayEnd(asOf: now))

            // Round caps extend a `RuleMark` by half its line width at each end, so the rect is
            // that much wider than the span it covers. It is handed the episode's real extent,
            // however far off screen that runs: the `Canvas` clips it.
            let rect = CGRect(
                x: startX - thickness / 2,
                y: lane - thickness / 2,
                width: max(endX - startX, 0) + thickness,
                height: thickness
            )

            return Bracket(
                bar: Path(roundedRect: rect, cornerRadius: thickness / 2),
                tint: tint,
                label: durationLabel(for: episode, asOf: now),
                // The middle of the bar, and nothing else — the label is the mark's own
                // caption, so it stays put on it however the bar moves. Every bracket carries
                // one at every zoom: it is never dropped for being wider than the bar it
                // labels, so a shrinking excursion keeps reporting its length.
                //
                // For an excursion that began before the chart's history this is the middle of
                // the bar *as drawn*, between the clipped edge and the end — so the label
                // travels with the shrinking remnant rather than sitting where the readings no
                // longer exist.
                labelCenter: CGPoint(x: (startX + endX) / 2, y: lane)
            )
        }
    }

    // MARK: - Culling

    /// Excursions long enough to be worth a marker, that reach the screen.
    ///
    /// An ongoing episode qualifies as soon as it has run past the minimum, so the marker
    /// appears while the event is still happening. The test is an *overlap*, not containment:
    /// unlike a point series these are spans, and one that starts before the viewport — or runs
    /// past its trailing edge — still crosses it.
    private func visibleEpisodes(asOf now: Date) -> [GlucoseEpisode] {
        let range = viewport.cullRange(marginPoints: Self.cullMarginPoints)
        return episodes.filter { episode in
            episode.elapsed(asOf: now) >= MainChartHelper.Config.episodeMinimumDuration
                && episode.start <= range.upperBound
                && episode.displayEnd(asOf: now) >= range.lowerBound
        }
    }

    // MARK: - Label

    /// White in both themes, on a badge tinted the way `PeakLabelBadge` tints a peak's: the
    /// mark's own color is already carrying high-or-low, so the digits are free to be the one
    /// thing on the chart that always reads the same way.
    ///
    /// The fill is kept mostly solid — a faint one is what a *colored* label sits on, and white
    /// on it would wash out over a light chart — but not fully, so the grid still shows through
    /// and the badge reads as part of the chart rather than a sticker on top of it.
    ///
    /// Monospaced, unlike a peak badge, because a duration ticks upward while an episode runs
    /// and proportional digits make it breathe.
    private func durationLabel(for episode: GlucoseEpisode, asOf now: Date) -> Text {
        Text(episode.formattedDuration(asOf: now))
            .font(.caption2)
            .fontWeight(.semibold)
            .monospacedDigit()
            .foregroundStyle(Color.white)
    }

    // MARK: - Geometry

    /// Centre of the marker lane, in the chart's display units. 12 mg/dL past the upper axis
    /// bound keeps the bar inside the 25 mg/dL padding of the plotted domain. Lows share the
    /// lane with highs so all episode markers line up at the top of the chart.
    private var laneValue: Decimal {
        let mgdl = maxYAxisValue + 12
        return units == .mgdL ? mgdl : mgdl.asMmolL
    }

    /// The same colors the threshold lines use, so a marker reads as "this is the high line's
    /// territory" without a legend.
    private func color(for type: GlucoseEpisode.EpisodeType) -> Color {
        // TODO: same workaround as the glucose dots and threshold lines — the dynamic scheme
        // needs headroom beyond the user's limits to have shades to interpolate through.
        let hardCodedLow = Decimal(55)
        let hardCodedHigh = Decimal(220)
        let isDynamicColorScheme = glucoseColorScheme == .dynamicColor

        return getDynamicGlucoseColor(
            glucoseValue: type == .high ? highGlucose : lowGlucose,
            highGlucoseColorValue: isDynamicColorScheme ? hardCodedHigh : highGlucose,
            lowGlucoseColorValue: isDynamicColorScheme ? hardCodedLow : lowGlucose,
            targetGlucose: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }
}
