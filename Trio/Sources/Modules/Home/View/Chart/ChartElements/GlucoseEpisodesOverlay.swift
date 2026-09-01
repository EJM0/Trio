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
/// The bar is filled with the colors of the readings underneath it, in place — a gradient
/// sampled from the same `GlucoseDot`s the curve is drawn from — so a bracket lifted into an
/// empty lane still carries the shape of the excursion it spans and not merely its extent, and
/// the duration badge takes the color of the episode's mean. See `barShading(for:...)` for how
/// that survives the static color scheme, which has only one color per band to sample.
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
    /// The resolved readings, ascending and covering the whole domain — the very array
    /// `GlucoseDotsOverlay` draws. Each bar is filled with a gradient sampled from the slice
    /// that falls inside its own episode, so a bracket reads as a smear of the curve it spans.
    /// Handed over whole, like the treatment series: this layer slices it by binary search.
    let glucoseDots: [GlucoseDot]
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

    /// Alpha the bar is drawn at — what the flat fill carried, now baked into every stop of the
    /// gradient that replaced it.
    private static let barOpacity: Double = 0.75

    /// Upper bound on gradient stops per bar. A 12 h excursion is ~145 readings and the bar is
    /// rebuilt on every pan, pinch and scrub frame; sampling evenly across the slice keeps the
    /// shape of the excursion while bounding that work, and at 4 pt thick the difference is not
    /// visible.
    private static let maximumGradientStops = 24

    // TODO: same workaround as the glucose dots and threshold lines — the dynamic scheme needs
    // headroom beyond the user's limits to have shades to interpolate through. The static
    // scheme's shading ramp reuses them as the far end of its own ramp, so a bar deepens over
    // the same span the dynamic one changes hue across.
    private static let hardCodedLow = Decimal(55)
    private static let hardCodedHigh = Decimal(220)

    /// Floor on how far the static scheme's shading ramp reaches past a threshold, in mg/dL, for
    /// thresholds already at or beyond the bounds above.
    private static let minimumShadingSpan = Decimal(30)

    var body: some View {
        // Fixed for the pass, like the canvas's own current-time rule: an ongoing episode is
        // drawn up to here, and its length is measured to here.
        let now = Date()

        let isDark = colorScheme == .dark

        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            for bracket in brackets(asOf: now) {
                context.fill(bracket.bar, with: bracket.fill)

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
        /// The bar's fill: the colors of the readings it spans, laid along its length.
        let fill: GraphicsContext.Shading
        /// The badge's color — the episode's mean glucose, at full strength; the badge takes it
        /// down by its own amount.
        let tint: Color
        let label: Text
        let labelCenter: CGPoint
    }

    private func brackets(asOf now: Date) -> [Bracket] {
        let lane = yPosition(laneValue)
        let thickness = Self.barThickness

        return visibleEpisodes(asOf: now).map { episode in
            // An excursion that began before the chart's history is drawn from that edge: the
            // readings behind it are gone, and the label — which reports the whole length
            // either way — then centres between the edge and the end.
            let start = max(episode.start, historyStart)
            let end = episode.displayEnd(asOf: now)
            let startX = viewport.x(for: start)
            let endX = viewport.x(for: end)
            let covered = readings(from: start, through: end)

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
                fill: barShading(
                    for: episode,
                    readings: covered,
                    over: start ... max(start, end),
                    from: startX,
                    to: endX,
                    lane: lane
                ),
                tint: badgeTint(for: episode, readings: covered),
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

    // MARK: - Bar color

    /// The readings inside one bracket's drawn extent — the ones whose colors the bar is made of.
    private func readings(from start: Date, through end: Date) -> [GlucoseDot] {
        MainChartHelper.windowSlice(
            glucoseDots,
            from: start,
            through: end,
            ascendingInput: true,
            date: { $0.date }
        )
    }

    /// The bar's fill: the color each reading under it was drawn in, laid along its length, so a
    /// bracket carries the shape of the excursion and not just its extent.
    ///
    /// `ChartViewport.x(for:)` is affine in time, so a reading's fraction along the bar is its
    /// fraction of the bar's own *duration* — the stops need no coordinate conversion, and they
    /// survive a pinch untouched because the two endpoints carry the stretch for them.
    ///
    /// The stops span the readings, not the bar: a bar reaching back to `historyStart`, or an
    /// ongoing one running to `now`, has stretches with no data at its ends, and SwiftUI holds
    /// the end stops' colors across those rather than fading out of them.
    ///
    /// Falls back to a flat fill when there is nothing to interpolate — an episode whose
    /// readings have aged out of the loaded series, or one covered by a single reading.
    private func barShading(
        for episode: GlucoseEpisode,
        readings: [GlucoseDot],
        over span: ClosedRange<Date>,
        from startX: CGFloat,
        to endX: CGFloat,
        lane: CGFloat
    ) -> GraphicsContext.Shading {
        func flat(_ color: Color) -> GraphicsContext.Shading { .color(color.opacity(Self.barOpacity)) }

        guard let first = readings.first else { return flat(color(for: episode.type)) }
        let seconds = span.upperBound.timeIntervalSince(span.lowerBound)
        guard readings.count > 1, seconds > 0, endX > startX else { return flat(barColor(for: first, in: episode)) }

        let stops = sampled(readings).map { dot in
            Gradient.Stop(
                color: barColor(for: dot, in: episode).opacity(Self.barOpacity),
                location: min(max(CGFloat(dot.date.timeIntervalSince(span.lowerBound) / seconds), 0), 1)
            )
        }

        return .linearGradient(
            Gradient(stops: stops),
            startPoint: CGPoint(x: startX, y: lane),
            endPoint: CGPoint(x: endX, y: lane)
        )
    }

    /// At most `maximumGradientStops` readings, spread evenly through the slice and always
    /// including both ends.
    private func sampled(_ readings: [GlucoseDot]) -> [GlucoseDot] {
        guard readings.count > Self.maximumGradientStops else { return readings }
        let step = Double(readings.count - 1) / Double(Self.maximumGradientStops - 1)
        return (0 ..< Self.maximumGradientStops).map { readings[Int((Double($0) * step).rounded())] }
    }

    /// The bar's color at one reading.
    ///
    /// Under the dynamic scheme this is the reading's own dot color, already resolved once per
    /// data change by `rebuildGlucoseDots`, so the bracket is literally a smear of the curve
    /// below it and costs nothing to sample.
    ///
    /// The static scheme has one color per band, which would leave every bar flat — so there the
    /// band's hue is held and its shade ramped by how far past the threshold the reading sits. A
    /// brief in-range dip inside an excursion (detection bridges those, see
    /// `GlucoseEpisode.detect`) lands at the pale end of that ramp, reading as a light patch in
    /// the bar rather than switching to the in-range green the dots use.
    private func barColor(for dot: GlucoseDot, in episode: GlucoseEpisode) -> Color {
        guard glucoseColorScheme != .dynamicColor else { return dot.color }
        return shadedStaticColor(forMgdl: mgdl(dot.value), type: episode.type)
    }

    /// The badge takes the color of the episode's *mean* glucose: one reading's worth of summary
    /// for a bar that spans many, and the one thing the duration beside it does not already say.
    ///
    /// Colored exactly as a reading of that value would be, under whichever scheme is in force,
    /// so the badge always sits somewhere inside the range of shades its own bar runs through.
    private func badgeTint(for episode: GlucoseEpisode, readings: [GlucoseDot]) -> Color {
        guard !readings.isEmpty else { return color(for: episode.type) }
        let mean = mgdl(readings.reduce(Decimal(0)) { $0 + $1.value } / Decimal(readings.count))
        return glucoseColorScheme == .dynamicColor
            ? dynamicColor(forMgdl: mean)
            : shadedStaticColor(forMgdl: mean, type: episode.type)
    }

    /// A value's color under the dynamic scheme — the same call `rebuildGlucoseDots` makes, with
    /// the same headroom, so a mean colors exactly like a dot of that value.
    private func dynamicColor(forMgdl value: Decimal) -> Color {
        calculateHueBasedGlucoseColor(
            glucoseValue: value,
            highGlucose: Self.hardCodedHigh,
            lowGlucose: Self.hardCodedLow,
            targetGlucose: currentGlucoseTarget
        )
    }

    /// A value's shade within its episode's static band: palest at the user's threshold, deepest
    /// at the headroom bound the dynamic ramp ends on, clamped past it.
    ///
    /// The far end is pushed out past the user's own threshold when their setting has already
    /// passed it, so the ramp always has a span to work across whatever the thresholds are set to
    /// — a high limit of 250 would otherwise sit on or beyond the 220 bound and flatten the bar
    /// back to a single shade.
    private func shadedStaticColor(forMgdl value: Decimal, type: GlucoseEpisode.EpisodeType) -> Color {
        let isHigh = type == .high
        return shadedStaticGlucoseColor(
            glucoseValue: value,
            threshold: isHigh ? highGlucose : lowGlucose,
            extreme: isHigh
                ? max(Self.hardCodedHigh, highGlucose + Self.minimumShadingSpan)
                : min(Self.hardCodedLow, lowGlucose - Self.minimumShadingSpan),
            hue: isHigh ? GlucoseHue.purple : GlucoseHue.red
        )
    }

    /// `GlucoseDot.value` is in the user's display units; every color function takes mg/dL.
    private func mgdl(_ displayValue: Decimal) -> Decimal {
        units == .mgdL ? displayValue : displayValue.asMgdL
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
    ///
    /// Only a fallback now: both the bar and its badge take their color from the readings the
    /// episode actually covers, and this stands in for an episode that has none left in the
    /// loaded series.
    private func color(for type: GlucoseEpisode.EpisodeType) -> Color {
        let isDynamicColorScheme = glucoseColorScheme == .dynamicColor

        return getDynamicGlucoseColor(
            glucoseValue: type == .high ? highGlucose : lowGlucose,
            highGlucoseColorValue: isDynamicColorScheme ? Self.hardCodedHigh : highGlucose,
            lowGlucoseColorValue: isDynamicColorScheme ? Self.hardCodedLow : lowGlucose,
            targetGlucose: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }
}
