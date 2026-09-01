import Charts
import CoreData
import SwiftUI

let calendar = Calendar.current

/// Shared generator for the light tick emitted when a scrub lands on a glucose reading.
/// File-scoped so it isn't a stored view property (which would be re-created per body
/// evaluation) and stays prepared across ticks.
private let scrubPointHaptic = UISelectionFeedbackGenerator()

/// The Home screen chart stack (basal / glucose / COB-IOB).
///
/// Rendering strategy: the three charts are laid out ONCE per (data, zoom) change onto a
/// wide fixed canvas spanning the full chart domain — the same render economics as the
/// original ScrollView implementation, which is the only approach that stays smooth at
/// real-world data volumes. Panning translates that canvas with a pure `.offset` transform
/// (zero re-layout), driven by this shell's gesture layer: one-finger drag pans (with
/// momentum), two-finger magnify zooms continuously, a double tap followed by a vertical
/// drag zooms one-handed through that same path, and a stationary press inspects.
/// Gestures work identically over all three strips, which also makes desync between the
/// strips structurally impossible.
///
/// `MainChartCanvas` is deliberately a separate child view whose stored properties do NOT
/// include the pan position; SwiftUI therefore skips its body while panning, so the chart
/// content is never re-evaluated mid-gesture.
struct MainChartView: View {
    var geo: GeometryProxy
    /// Height allocated to the chart stack by the Home layout (the flexible
    /// remainder after the fixed zones).
    var chartHeight: CGFloat
    var units: GlucoseUnits
    var highGlucose: Decimal
    var lowGlucose: Decimal
    var currentGlucoseTarget: Decimal
    var glucoseColorScheme: GlucoseColorScheme
    var displayXgridLines: Bool
    var displayYgridLines: Bool
    var showGlucoseEpisodes: Bool
    var thresholdLines: Bool
    /// Width of the display cutout the viewport's leading edge runs under, in points.
    /// Landscape draws the chart under the sensor housing; this is what lets the user pan
    /// the domain's first reading back out from behind it. Zero everywhere else.
    var leadingInset: CGFloat = 0
    /// The same, for the trailing edge. Everything pinned there — the y-axis labels, the
    /// return-to-now button, the domain's last reading — is pushed clear of the cutout by
    /// this much. Zero unless the phone is turned so the pill lands on that side.
    var trailingInset: CGFloat = 0
    var state: Home.StateModel

    /// Date under the user's finger while inspecting, else nil. Owned by Home so the
    /// readout can take over the meal slot; the chart only writes it.
    @Binding var selection: Date?

    @State var mainChartHasInitialized = false

    // MARK: - Continuous zoom / pan state

    /// Length of the visible x-axis window in seconds. Driven exclusively by the pinch gesture.
    @State var visibleSeconds: TimeInterval = MainChartHelper.Config.defaultVisibleSeconds

    /// Date at the leading (left) edge of the visible window. Owned by the gesture layer;
    /// panning only changes this value, which translates the pre-laid-out canvas.
    @State var scrollPosition = Date.now
        .addingTimeInterval(-MainChartHelper.Config.defaultVisibleSeconds)

    /// Rendered slice of the domain. The canvas covers only this window (visible
    /// ± `Config.renderWindowPadFactor` viewports), bounding canvas width and
    /// per-layout cost no matter how long the data domain grows.
    @State private var renderWindowStart = Date.now
        .addingTimeInterval(-MainChartHelper.Config.defaultVisibleSeconds * 2.5)
    @State private var renderWindowEnd = Date.now
        .addingTimeInterval(MainChartHelper.Config.defaultVisibleSeconds * 1.5)

    /// Horizontal stretch applied while a pinch is live. The zoom itself is
    /// committed once, on release; between touch-down and release the canvas
    /// is only transformed, never re-laid.
    @State private var pinchScale: CGFloat = 1

    /// When the last mid-gesture zoom commit re-laid the canvas, so the next one cannot
    /// follow it sooner than `Config.pinchCommitMinInterval`.
    @State private var lastZoomCommit: Date?

    /// True from the moment a zoom gesture takes a touch until its closing commit. It is what
    /// puts the render window on the narrow gesture-time pad — see `updateRenderWindow`.
    @State private var isZoomGestureLive = false

    /// Captured at pinch start so the zoom stays anchored under the pinch centroid.
    @State private var pinchAnchor: (
        visibleAtStart: TimeInterval,
        anchorDate: Date,
        anchorFraction: CGFloat
    )?

    /// Leading edge captured when a one-finger drag transitions from inspecting to panning.
    @State private var panBaseline: Date?

    /// True once a held press has engaged inspect; from then on finger movement scrubs
    /// the selection instead of panning, until the finger lifts.
    @State private var isInspectLatched = false

    /// Whether the touch currently down has been part of a pinch. A pinch consumes the
    /// whole touch: see the guard in `panAndInspectGesture`.
    @State private var touchWasPinching = false

    /// When and where the last clean tap lifted (no pan, no pinch, no inspect). A touch
    /// landing soon after and close by is the second tap of a double tap, which is what
    /// arms the drag zoom — `DragGesture` is the only recognizer that sees touch-down, so
    /// the double tap has to be reconstructed from its events.
    @State private var lastTapEnd: (time: Date, location: CGPoint)?

    /// The touch currently down is the second tap of a double tap: it neither pans nor
    /// inspects, it either lifts (the tap recognizer cycles the presets) or travels (the
    /// drag zoom engages).
    @State private var doubleTapCandidate = false

    /// True while a double-tap-and-drag zoom owns the touch. The zoom drives the very
    /// state a pinch does — `pinchAnchor`, `pinchScale`, `commitPinchZoom` — so this only
    /// marks who is holding it.
    @State private var isDoubleTapZooming = false

    /// When the last drag zoom engaged or ended, so the double tap that started it cannot
    /// also fire a preset jump. Expires by itself, so a later real double tap still works.
    @State private var doubleTapZoomEndTime: Date?

    /// Where the touch currently being tracked began. `DragGesture` holds `startLocation`
    /// fixed for the life of one drag, so a change of it is the one reliable signal that a
    /// *new* touch has started — which is what the per-touch state has to be reset on.
    @State private var touchStartLocation: CGPoint?

    /// Most recent finger location, so the hold timer can place the selection even if the
    /// finger produced no further events after touch-down.
    @State private var lastTouchLocation: CGPoint?

    /// Armed at touch-down; fires after `Config.inspectHoldDelay` and latches inspect if
    /// the touch is still down and stationary. A timer is required because `DragGesture`
    /// only reports *changes* — a perfectly still finger generates no events after
    /// touch-down, so the hold can never be detected from inside `onChanged` alone.
    @State private var inspectHoldTask: Task<Void, Never>?

    /// Timestamp of the current touch-down; inspect only engages after
    /// `Config.inspectHoldDelay` of resting, so starting a drag never triggers it.
    @State private var touchDownTime: Date?

    /// Drives post-flick deceleration; cancelled by any new touch or data-driven scroll.
    @State private var momentumTask: Task<Void, Never>?

    /// Auto-pans the chart while a scrubbing finger rests in the viewport's edge zones.
    @State private var edgePanTask: Task<Void, Never>?

    /// Measured plot rect of the COB/IOB pane (canvas y-coords) for overlay alignment.
    @State private var cobIobPlotFrame: CGRect = .zero

    /// The same for the glucose pane. Every shell layer that hangs off the curve — the dots,
    /// the treatment markers, the peak badges, the excursion lane, the scrub highlight — maps
    /// values through `glucoseYPosition(forDisplayValue:)`, and until this arrives that map
    /// assumes the pane's plot fills the pane. Swift Charts used to guarantee agreement by
    /// drawing the readings itself; now that they are drawn out here, the plot rect is measured
    /// so the two cannot drift apart if the chart's own insets ever change.
    @State private var glucosePlotFrame: CGRect = .zero

    /// Measured width of the pinned y-axis label column, published by `StaticYAxisChart`.
    /// Drives `trailingOverscan`, so the domain edge clears the labels exactly.
    @State private var labelGutterWidth: CGFloat = 0

    /// Measured width of the scrub's time label, so it can be kept inside the viewport
    /// when the selection is near an edge.
    @State private var selectionTimeLabelWidth: CGFloat = 0

    /// Measured width of the widest x-axis time label. Zero until the strip has laid out
    /// once. Sets how far past the viewport edge marks are still laid out, so a label can
    /// travel fully off screen instead of vanishing mid-stride.
    @State private var axisLabelWidth: CGFloat = 0

    /// Measured height of an x-axis time label. Zero until the strip has laid out once.
    /// Measured rather than assumed: the labels are ordinary `.footnote` text, so their
    /// height follows Dynamic Type and the script the app is localized into, and a fixed
    /// number would clip them at accessibility sizes.
    @State private var axisLabelHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                MainChartCanvas(
                    state: state,
                    units: units,
                    highGlucose: highGlucose,
                    lowGlucose: lowGlucose,
                    currentGlucoseTarget: currentGlucoseTarget,
                    glucoseColorScheme: glucoseColorScheme,
                    displayXgridLines: displayXgridLines,
                    displayYgridLines: displayYgridLines,
                    thresholdLines: thresholdLines,
                    visibleSeconds: visibleSeconds,
                    windowStart: renderWindowStart,
                    windowEnd: renderWindowEnd,
                    canvasWidth: canvasWidth,
                    basalHeight: basalHeight,
                    mainHeight: mainHeight,
                    cobIobHeight: cobIobHeight,
                    glucoseYDomain: paddedGlucoseYDomain
                )
                .equatable()
                .offset(x: -canvasOffsetX)
                .scaleEffect(x: pinchScale, y: 1, anchor: pinchScaleAnchor)

                glucoseDotsOverlay

                glucoseEpisodesOverlay

                treatmentOverlay
            }
            // Everything that scrolls fades out at the trailing edge once "now" is off screen
            // — see `scrolledBackMask`. Grouped and masked rather than covered with a dark
            // gradient: a scrim only dims what is under it, and the point is that the past
            // *ends* here. The pinned axis labels, the peak badges and the scrub marks are
            // outside this group and so stay at full strength, as they were when the fade was
            // painted under them.
            .frame(width: viewportWidth, height: chartHeight, alignment: .topLeading)
            .mask(alignment: .topLeading) { scrolledBackMask }

            // Pinned y-axis labels over the glucose pane, ABOVE the scrolled-back gradient
            // so the labels are never dimmed by it. Pure overlay; never re-lays the canvas.
            // CRITICAL: the explicit viewport-width frame below is load-bearing. `.offset`
            // does not shrink the canvas's *layout* bounds, so this ZStack is canvas-width
            // (~9x the screen); an unconstrained sibling inherits that width and its
            // trailing-aligned content renders thousands of points off-screen — which is
            // exactly how three axis-overlay attempts rendered "nothing".
            VStack(spacing: 0) {
                Color.clear.frame(height: basalHeight)
                StaticYAxisChart(
                    yDomain: paddedGlucoseYDomain,
                    units: units,
                    displayYgridLines: displayYgridLines
                )
                .equatable()
                .frame(height: mainHeight)
                // Keep the axis labels off the screen edge — and off the cutout, when the
                // phone is turned so that the pill sits on this side.
                .padding(.trailing, MainChartHelper.Config.yAxisLabelInset + trailingInset)
                Color.clear.frame(height: cobIobHeight)
            }
            .frame(width: viewportWidth, height: stackHeight, alignment: .topLeading)
            .allowsHitTesting(false)

            xAxisOverlay
                .allowsHitTesting(false)

            // Last of the static content, so a badge is never dimmed by the scrolled-back
            // gradient nor covered by the pinned axis labels — it is the one label that
            // marks a specific reading, so it wins every overlap. Only the scrub's own
            // marks, which are transient, sit above it.
            peakLabelsOverlay

            selectionOverlay
                .allowsHitTesting(false)
        }
        // The full zone: the canvas fills all of it but the bottom strip, which carries
        // the x-axis labels.
        .frame(width: viewportWidth, height: chartHeight, alignment: .topLeading)
        .clipped()
        .onPreferenceChange(CobIobPlotFrameKey.self) { cobIobPlotFrame = $0 }
        .onPreferenceChange(GlucosePlotFrameKey.self) { glucosePlotFrame = $0 }
        .onPreferenceChange(YAxisLabelGutterKey.self) { width in
            let isFirstMeasurement = labelGutterWidth == 0
            guard width > 0, abs(width - labelGutterWidth) > 0.5 else { return }
            labelGutterWidth = width
            // `onAppear` has already anchored using the fallback by the time this lands.
            // Re-anchor once so the forecast sits flush immediately instead of after the
            // next glucose tick; later changes just take effect on the next re-anchor, so
            // a mid-session measurement can never yank a chart the user has panned.
            if isFirstMeasurement {
                scrollToTrailingEdge()
                updateRenderWindow()
            }
        }
        // Only ever grows into a real measurement: the pill is gone between scrubs, and
        // letting the preference fall back to zero then would pop the next one into place
        // uncentered for a frame.
        .onPreferenceChange(SelectionTimeLabelWidthKey.self) { if $0 > 0 { selectionTimeLabelWidth = $0 } }
        .onPreferenceChange(AxisLabelHeightKey.self) { if $0 > 0 { axisLabelHeight = $0 } }
        .onPreferenceChange(AxisLabelWidthKey.self) { if $0 > 0 { axisLabelWidth = $0 } }
        .contentShape(Rectangle())
        .simultaneousGesture(panAndInspectGesture)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(
            SpatialTapGesture(count: 2).onEnded { value in cycleZoomPreset(atViewportX: value.location.x) }
        )
        // Overlaid after the gestures so its tap wins over the pan/inspect recognizer.
        .overlay(alignment: .bottomTrailing) { scrollToNowButton }
        .onDisappear {
            momentumTask?.cancel()
            inspectHoldTask?.cancel()
            edgePanTask?.cancel()
            if isDoubleTapZooming { endDoubleTapZoom() }
        }
        .onChange(of: scrollPosition) {
            updateRenderWindow()
        }
        .onChange(of: visibleSeconds) {
            updateRenderWindow(force: true)
            // Feed the committed zoom back so the peak-picker granularity follows it.
            state.chartVisibleHours = visibleSeconds / 3600
            state.updateGlucosePeaks()
        }
        .onChange(of: state.glucoseFromPersistence.last?.glucose) {
            state.updateStartEndMarkers()
            scrollToTrailingEdge()
            updateRenderWindow()
        }
        .onChange(of: state.enactedAndNonEnactedDeterminations.first?.deliverAt) {
            // The forward offset is anchored to this determination, so a new loop moves the
            // domain's trailing edge even when the forecast is the same length as before.
            state.updateStartEndMarkers()
            scrollToTrailingEdge()
            updateRenderWindow()
        }
        .onChange(of: state.forecastDisplayType) {
            // Cone and lines have different horizons — the band stops at the shortest curve,
            // the lines run to the longest — so switching resizes the domain.
            state.updateStartEndMarkers()
            scrollToTrailingEdge()
            updateRenderWindow(force: true)
        }
        .onChange(of: units) {
            // TODO: - Refactor this to only update the Y Axis Scale
            state.setupGlucoseArray()
        }
        .onAppear {
            if !mainChartHasInitialized {
                state.updateStartEndMarkers()
                scrollToTrailingEdge()
                updateRenderWindow(force: true)
                mainChartHasInitialized = true
            }
        }
    }
}

// MARK: - Layout metrics

extension MainChartView {
    private var viewportWidth: CGFloat { max(geo.size.width, 1) }

    /// Height of the x-axis label strip below the canvas: one label, plus the gap that
    /// keeps it off the plot. Derived from the label's own measured height, so it grows
    /// with Dynamic Type instead of clipping.
    ///
    /// Capped, because a strip is only ever the footer of a chart: at the largest
    /// accessibility sizes an uncapped label would eat the pane it belongs to. Past the
    /// cap the labels clip rather than the chart collapsing — the lesser of the two.
    var axisStripHeight: CGFloat {
        let label = axisLabelHeight > 0 ? axisLabelHeight : MainChartHelper.Config.estimatedXAxisLabelHeight
        return min(label + MainChartHelper.Config.xAxisLabelTopGap, chartHeight * 0.25)
    }

    /// What the three panes have to share: the zone, less the label strip.
    var chartStackHeight: CGFloat { max(chartHeight - axisStripHeight, 1) }

    // Pane splits of the chart's own allocation, preserving the proportions
    // of the previous screen-height fractions (0.05 / 0.33 / 0.12 = 10% /
    // 66% / 24% of the 50% chart block).
    var basalHeight: CGFloat { chartStackHeight * 0.10 }
    var mainHeight: CGFloat { chartStackHeight * 0.66 }
    var cobIobHeight: CGFloat { chartStackHeight * 0.24 }

    private var windowSeconds: TimeInterval {
        max(renderWindowEnd.timeIntervalSince(renderWindowStart), 1)
    }

    /// Width of the pre-laid-out canvas covering the render window.
    private var canvasWidth: CGFloat {
        viewportWidth * CGFloat(windowSeconds / visibleSeconds)
    }

    /// Pixel offset of the canvas for the current leading-edge date. Derived,
    /// not stored: re-anchoring the window recomputes it consistently.
    private var canvasOffsetX: CGFloat {
        CGFloat(scrollPosition.timeIntervalSince(renderWindowStart) / windowSeconds) * canvasWidth
    }

    /// Re-anchors the render window when the visible window nears its edge.
    /// Between re-anchors, panning stays a pure offset transform.
    func updateRenderWindow(force: Bool = false) {
        // A zoom in flight re-lays the canvas at every commit, so it holds the window to what
        // the gesture can actually expose; the closing commit restores the full pad.
        let padFactor = isZoomGestureLive
            ? MainChartHelper.Config.renderWindowPadFactorDuringZoom
            : MainChartHelper.Config.renderWindowPadFactor
        let pad = padFactor * visibleSeconds
        let margin = MainChartHelper.Config.renderWindowMarginFactor * visibleSeconds
        let domainStart = state.startMarker
        let domainEnd = max(state.endMarker, domainStart.addingTimeInterval(1))
        // Trailing overscan can push the visible window past the domain; the
        // window itself never exceeds the domain, so compare clamped edges.
        let visibleStart = max(scrollPosition, domainStart)
        let visibleEnd = min(scrollPosition.addingTimeInterval(visibleSeconds), domainEnd)

        let nearLeft = visibleStart.timeIntervalSince(renderWindowStart) < margin
            && renderWindowStart > domainStart
        let nearRight = renderWindowEnd.timeIntervalSince(visibleEnd) < margin
            && renderWindowEnd < domainEnd
        let uncovered = visibleStart < renderWindowStart || visibleEnd > renderWindowEnd
        guard force || nearLeft || nearRight || uncovered else { return }

        let newStart = max(visibleStart.addingTimeInterval(-pad), domainStart)
        let newEnd = min(visibleEnd.addingTimeInterval(pad), domainEnd)
        guard newStart != renderWindowStart || newEnd != renderWindowEnd else { return }
        renderWindowStart = newStart
        renderWindowEnd = newEnd
    }

    /// The time-to-x mapping every shell overlay draws with — one value, built once per body
    /// pass, so no two layers can disagree about where a date sits. `ChartOverlayLayer`
    /// interpolates its `visibleStart` for animated scrolls.
    var viewport: ChartViewport {
        ChartViewport(
            visibleStart: scrollPosition,
            visibleSeconds: visibleSeconds,
            viewportWidth: viewportWidth,
            pinchScale: pinchScale,
            pinchAnchorFraction: pinchAnchor?.anchorFraction
        )
    }

    /// Glucose y-domain padded above and below so values at the data extremes (and the carb
    /// markers `TreatmentOverlay` pins to the old baseline) render fully instead of straddling the
    /// plot edge. Also gives the plot visual breathing room at top and bottom.
    var paddedGlucoseYDomain: ClosedRange<Decimal> {
        let padding: Decimal = 25 // mg/dL
        let lower = state.minYAxisValue - padding
        let upper = state.maxYAxisValue + padding
        return units == .mgdL ? lower ... upper : lower.asMmolL ... upper.asMmolL
    }
}

// MARK: - Selection lookup (shell-owned; the canvas knows nothing about selection)

extension MainChartView {
    var selectedGlucose: GlucoseStored? {
        guard let selection = selection else { return nil }
        return ChartSelectionLookup.glucose(at: selection, in: state.glucoseFromPersistence)
    }

    /// COB, IOB and ISF all read off the one determination nearest the selection.
    var selectedDetermination: OrefDetermination? {
        guard let selection = selection else { return nil }
        return ChartSelectionLookup.determination(at: selection, in: state.enactedAndNonEnactedDeterminations)
    }
}

// MARK: - Selection overlay (rendered in the shell, never re-lays the canvas)

extension MainChartView {
    private var stackHeight: CGFloat { basalHeight + mainHeight + cobIobHeight }

    /// Top of the x-axis label strip — which is simply the bottom of the canvas, since
    /// the strip is taken off the zone before the panes split what is left. Nothing
    /// reserves height inside the COB/IOB pane any more, so its plot ends here too.
    var axisStripTop: CGFloat { stackHeight }

    private func glucoseYPosition(for glucose: GlucoseStored) -> CGFloat {
        glucoseYPosition(forDisplayValue: units == .mgdL ? Decimal(glucose.glucose) : Decimal(glucose.glucose).asMmolL)
    }

    /// Where a value in the chart's display units sits in the glucose pane. Shared by every
    /// layer that hangs off the curve, so none of them can disagree with another about where a
    /// reading is.
    ///
    /// Mapped through the pane's *measured* plot rect, exactly as `cobIobYPosition` does: the
    /// glucose readings are no longer marks inside that chart, so nothing but this makes them
    /// land on its grid lines and its forecast. The pane's own top and height stand in until
    /// the canvas publishes the rect, which is right to a point or two — the pane's axes are
    /// hidden and grid-only, so its plot does fill it today. This is what keeps that from
    /// being an assumption.
    func glucoseYPosition(forDisplayValue value: Decimal) -> CGFloat {
        let domain = paddedGlucoseYDomain
        let span = domain.upperBound - domain.lowerBound
        let fraction = span == 0 ? 0.5 :
            Double(truncating: ((value - domain.lowerBound) / span) as NSDecimalNumber)
        let plotTop = glucosePlotFrame == .zero ? basalHeight : glucosePlotFrame.minY
        let plotHeight = glucosePlotFrame == .zero ? mainHeight : glucosePlotFrame.height
        return plotTop + plotHeight * CGFloat(1 - min(max(fraction, 0), 1))
    }

    private func cobIobYPosition(forChartValue value: Double) -> CGFloat {
        let domain = MainChartHelper.cobIobYDomain(
            minCob: state.minValueCobChart,
            maxCob: state.maxValueCobChart,
            minIob: state.minValueIobChart,
            maxIob: state.maxValueIobChart,
            minIsf: state.minValueIsfChart,
            maxIsf: state.maxValueIsfChart
        )
        let span = domain.upperBound - domain.lowerBound
        let fraction = span == 0 ? 0.5 : (value - domain.lowerBound) / span
        // This pane's chart reserves room for the stack's hour labels, so its plot is
        // shorter than the pane; mapping over the full height drops the dots below the
        // lines. The published rect is already in canvas coordinates; fall back to the
        // pane's own top until the canvas publishes it.
        let plotTop = cobIobPlotFrame == .zero ? basalHeight + mainHeight : cobIobPlotFrame.minY
        let plotHeight = cobIobPlotFrame == .zero ? cobIobHeight : cobIobPlotFrame.height
        return plotTop + plotHeight * CGFloat(1 - min(max(fraction, 0), 1))
    }

    /// True while the visible window sits entirely in the past, i.e. "now" is off to the
    /// right. Drives both the trailing fade and the return-to-now button.
    private var isScrolledBack: Bool {
        Date.now.timeIntervalSince(scrollPosition.addingTimeInterval(visibleSeconds)) > 0
    }

    /// Jumps back to the trailing edge. Only offered while scrolled into the past, so it
    /// never covers the chart during normal use.
    @ViewBuilder private var scrollToNowButton: some View {
        if isScrolledBack {
            ChartOverlayButton(systemImage: "arrow.right") {
                // `onChange(of: scrollPosition)` re-anchors the render window for us.
                withAnimation(.easeOut(duration: 0.25)) {
                    scrollToTrailingEdge()
                }
            }
            // Stacked directly above the chart's info button, which `HomeRootView` overlays
            // on this same box: 32pt tall, sitting 16pt off the bottom (6pt padding + 10pt
            // offset) at a 16pt trailing inset. Keep these in sync with `chartInfoButton`.
            .padding(.trailing, 16 + trailingInset)
            .padding(.bottom, 56)
            .accessibilityLabel("Jump to now")
            .transition(.opacity)
        }
    }

    /// Fades the chart out at its trailing edge whenever "now" is scrolled off-screen.
    ///
    /// Without it, yesterday's 2 am and today's 2 am are visually indistinguishable; the fade
    /// signals "you are looking at the past — newer data lies this way". It ramps in over the
    /// first 30 min of scroll-back so it doesn't pop at the boundary, and stops short of
    /// erasing the edge outright: enough alpha is left that the curve is still followable into
    /// it, so this reads as the data thinning out rather than as a hole in the chart.
    ///
    /// A mask, not the dark scrim it used to be. A scrim tints whatever is under it — which
    /// looks like a shadow *on* the chart, and gets worse the busier the chart is — where a
    /// mask takes the content's own alpha down, so the marks genuinely fade away. It spans the
    /// whole zone, x-axis strip included: stopping at the canvas would leave a seam across the
    /// fade.
    private var scrolledBackMask: some View {
        let trailingEdge = scrollPosition.addingTimeInterval(visibleSeconds)
        let secondsBehindNow = Date.now.timeIntervalSince(trailingEdge)
        let strength = isScrolledBack ? min(1.0, secondsBehindNow / 1800) : 0
        // Opaque everywhere but the last `fadeWidth`, so the gradient is expressed in stops on
        // one full-width layer: two stacked layers cannot work, since a translucent white over
        // an opaque one still masks nothing.
        let fadeStart = max(0, viewportWidth - Self.fadeWidth) / max(viewportWidth, 1)

        return LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: fadeStart),
                .init(color: .white.opacity(1 - 0.8 * strength), location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: viewportWidth, height: chartHeight)
    }

    /// Width of the trailing fade.
    private static let fadeWidth: CGFloat = 120

    /// Vertical indicator + point highlights for the current selection. Positions are
    /// computed with the same linear maps the canvas charts use. The readout itself is
    /// drawn by Home in the meal slot (`ChartSelectionRow`), never over the chart.
    @ViewBuilder private var selectionOverlay: some View {
        if let selectedGlucose, let selectionDate = selectedGlucose.date {
            let x = viewport.x(for: selectionDate)
            if x >= 0, x <= viewportWidth {
                let markColor = selectionMarkColor(
                    for: selectedGlucose,
                    highGlucose: highGlucose,
                    lowGlucose: lowGlucose,
                    currentGlucoseTarget: currentGlucoseTarget,
                    glucoseColorScheme: glucoseColorScheme
                )
                let glucoseY = glucoseYPosition(for: selectedGlucose)
                // Every access rescans the determinations. Resolve it once per frame.
                let determination = selectedDetermination

                // Vertical indicator through all three panes. It stops at the bottom of
                // the COB/IOB plot rather than running the full stack height: below that
                // line is the x-axis strip, which during a scrub carries the selection's
                // own time label — the rule would otherwise strike straight through it.
                let ruleHeight = max(axisStripTop, 1)
                Rectangle()
                    .fill(Color.tabBar)
                    .frame(width: 2, height: ruleHeight)
                    .position(x: x, y: ruleHeight / 2)

                // Selected glucose highlight.
                Circle().fill(markColor)
                    .frame(width: 15, height: 15)
                    .position(x: x, y: glucoseY)
                Circle().fill(Color.primary)
                    .frame(width: 6, height: 6)
                    .position(x: x, y: glucoseY)

                // Bottom-pane dots stay on the rule, at the same x as the glucose dot.
                //
                // Upstream draws them at the determination's own `deliverAt` instead, to keep
                // them on a stepped line. This fork's COB/IOB/ISF marks are plain `LineMark`s
                // with the default linear interpolation (`drawCOBIOBChart`), so that buys
                // nothing here and costs alignment: the rule sits at the *glucose* reading's
                // timestamp while the determination lookup accepts anything within ±150 s, so the
                // two anchors disagree by up to 150 s and the dots visibly float off the rule
                // — worst at tight zoom, where 150 s is a large fraction of the viewport.
                // Between determinations ~5 min apart these values move little, so pinning to
                // the rule leaves the dots on the line segment anyway.

                // Selected COB / (scaled) IOB dots on the bottom pane.
                if let determination {
                    let y = cobIobYPosition(forChartValue: Double(determination.cob))
                    Circle().fill(Color.orange.opacity(0.8))
                        .frame(width: 15, height: 15)
                        .position(x: x, y: y)
                    Circle().fill(Color.primary)
                        .frame(width: 6, height: 6)
                        .position(x: x, y: y)
                }
                if let determination {
                    let scaled = MainChartHelper.scaledIobAmount(determination.iob?.doubleValue ?? 0)
                    let y = cobIobYPosition(forChartValue: scaled)
                    Circle().fill(Color.darkerBlue.opacity(0.8))
                        .frame(width: 15, height: 15)
                        .position(x: x, y: y)
                    Circle().fill(Color.primary)
                        .frame(width: 6, height: 6)
                        .position(x: x, y: y)
                }

                // Selected ISF dot, drawn on the shared COB/IOB axis.
                if let isf = determination?.insulinSensitivity?.doubleValue {
                    let y = cobIobYPosition(forChartValue: isf)
                    Circle().fill(Color.white.opacity(0.8))
                        .frame(width: 15, height: 15)
                        .position(x: x, y: y)
                    Circle().fill(Color.primary)
                        .frame(width: 6, height: 6)
                        .position(x: x, y: y)
                }
            }
        }
    }
}

// MARK: - Glucose points (drawn outside the pinch transform)

extension MainChartView {
    /// The glucose readings. In the shell rather than as marks in the canvas so that a
    /// committed zoom does not have to re-lay ~900 `PointMark`s, and so the live-pinch
    /// `scaleEffect` cannot squash the dots into ellipses — see `GlucoseDotsOverlay`.
    ///
    /// Handed the whole pre-resolved series: it culls to the visible window itself, and the
    /// slice is a few hundred plain structs either way.
    @ViewBuilder var glucoseDotsOverlay: some View {
        ChartOverlayLayer(viewport: viewport, height: stackHeight) { viewport in
            GlucoseDotsOverlay(
                points: state.glucoseDots,
                isSmoothingEnabled: state.isSmoothingEnabled,
                viewport: viewport,
                yPosition: { glucoseYPosition(forDisplayValue: $0) }
            )
        }
    }
}

// MARK: - Excursion markers (drawn outside the pinch transform)

extension MainChartView {
    /// Sustained high/low brackets in the lane above the data. In the shell for the reasons
    /// `GlucoseEpisodesOverlay` documents: inside the canvas the pinch stretched the bar and
    /// its duration label, and the marks re-laid on every committed zoom step.
    @ViewBuilder var glucoseEpisodesOverlay: some View {
        if showGlucoseEpisodes {
            ChartOverlayLayer(viewport: viewport, height: stackHeight) { viewport in
                GlucoseEpisodesOverlay(
                    episodes: state.glucoseEpisodes,
                    units: units,
                    highGlucose: highGlucose,
                    lowGlucose: lowGlucose,
                    currentGlucoseTarget: currentGlucoseTarget,
                    glucoseColorScheme: glucoseColorScheme,
                    maxYAxisValue: state.maxYAxisValue,
                    historyStart: state.startMarker,
                    viewport: viewport,
                    yPosition: { glucoseYPosition(forDisplayValue: $0) }
                )
            }
        }
    }
}

// MARK: - Treatment overlay (markers drawn outside the pinch transform)

extension MainChartView {
    /// Bolus, carb and FPU markers with their labels. Rendered here rather than as marks in
    /// the canvas so the live-pinch `scaleEffect` cannot stretch them — see `TreatmentOverlay`.
    ///
    /// Handed the series whole. They used to be pre-sliced to the render window here, which
    /// cost four `windowSlice` passes — allocating, and touching a Core Data date per element,
    /// over arrays spanning up to the whole 72 h — on *every* pan, pinch and scrub frame,
    /// because this body re-runs on each of them (`MainChartCanvas` has `.equatable()` to sit
    /// those out; an overlay taking closures cannot). The overlay culls to the visible window
    /// by binary search itself, and every lookup it does on these arrays is a binary search
    /// too, so the outer slice bought nothing it does not already do per frame.
    @ViewBuilder var treatmentOverlay: some View {
        ChartOverlayLayer(viewport: viewport, height: stackHeight) { viewport in
            TreatmentOverlay(
                glucose: state.glucoseDots,
                insulin: state.insulinFromPersistence,
                carbs: state.carbsFromPersistence,
                fpus: state.fpusFromPersistence,
                units: units,
                bolusDisplayThreshold: state.bolusDisplayThreshold,
                smbBolusDisplayCutoff: state.smbBolusDisplayCutoff,
                fpuBaseline: units == .mgdL ? state.minYAxisValue : state.minYAxisValue.asMmolL,
                viewport: viewport,
                yPosition: { glucoseYPosition(forDisplayValue: $0) }
            )
        }
    }
}

// MARK: - Peak / nadir badges (drawn outside the pinch transform)

extension MainChartView {
    /// Peak and nadir badges. In the shell rather than a `.chartOverlay` so the live-pinch
    /// `scaleEffect` cannot stretch them, and so they can be culled to what is on screen —
    /// see `PeakLabelsOverlay`.
    ///
    /// Handed the series whole, for the reason `treatmentOverlay` above spells out: the
    /// obstacle scan already reaches into them by binary search, per peak neighbourhood.
    @ViewBuilder var peakLabelsOverlay: some View {
        if state.showGlucosePeaks {
            ChartOverlayLayer(viewport: viewport, height: stackHeight) { viewport in
                PeakLabelsOverlay(
                    peaks: state.glucosePeaks,
                    glucoseData: state.glucoseDots,
                    insulinData: state.insulinFromPersistence,
                    carbData: state.carbsFromPersistence,
                    fpuData: state.fpusFromPersistence,
                    fpuBaseline: units == .mgdL ? state.minYAxisValue : state.minYAxisValue.asMmolL,
                    units: units,
                    highGlucose: highGlucose,
                    lowGlucose: lowGlucose,
                    glucoseColorScheme: glucoseColorScheme,
                    currentGlucoseTarget: currentGlucoseTarget,
                    viewport: viewport,
                    yPosition: { glucoseYPosition(forDisplayValue: $0) },
                    bolusDisplayThreshold: state.bolusDisplayThreshold,
                    smbBolusDisplayCutoff: state.smbBolusDisplayCutoff
                )
            }
        }
    }
}

// MARK: - X-axis overlay (hour labels / scrub time, pinned to the viewport)

/// Width of the scrub's time label, reported up to the shell so it can be clamped inside
/// the viewport. Zero (no label on screen) never overwrites a real measurement.
private struct SelectionTimeLabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next != 0 { value = next }
    }
}

/// Height of an x-axis time label at the current type size, reported up to the shell,
/// which sizes the strip — and with it the panes above — from it.
private struct AxisLabelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Width of the widest x-axis time label, from the same template — a `ZStack` takes the
/// size of its largest child, so measuring it measures the widest form.
private struct AxisLabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension MainChartView {
    /// The time strip under the COB/IOB plot.
    ///
    /// It has two states, and only ever one of them: the hour labels of the visible
    /// window, or — for as long as a scrub is live — the selected reading's own time,
    /// travelling with the indicator. The x axis is where time is read on this chart, so a
    /// scrub answers "when?" in that same place instead of on a card elsewhere; and with
    /// the hour labels gone for the duration, the moving label has the strip to itself and
    /// cannot collide with them.
    ///
    /// Drawn by the shell rather than by the pane's axis (which is now grid lines only):
    /// the canvas is deliberately not re-evaluated during a gesture, so an axis component
    /// could not swap its labels mid-scrub without giving that up.
    @ViewBuilder var xAxisOverlay: some View {
        let isScrubbing = selection != nil
        let labelHeight = axisStripHeight - MainChartHelper.Config.xAxisLabelTopGap
        let labelY = axisStripTop + MainChartHelper.Config.xAxisLabelTopGap + labelHeight / 2

        ZStack(alignment: .topLeading) {
            axisLabelTemplate

            HourAxisLabels(
                viewport: viewport,
                labelY: labelY,
                labelWidth: axisLabelWidth
            )
            .opacity(isScrubbing ? 0 : 1)
            .animation(.easeInOut(duration: 0.2), value: isScrubbing)

            selectionTimeLabel(y: labelY)
        }
        // Load-bearing, exactly as for the pinned y-axis above: an unconstrained sibling
        // in this ZStack inherits the canvas's (~9x screen) layout width.
        .frame(width: viewportWidth, height: chartHeight, alignment: .topLeading)
    }

    /// Laid out but never drawn: this is what the strip's height is measured from. A
    /// template rather than one of the real labels, so the measurement holds even at a
    /// zoom or scroll position that puts no hour mark on screen, and doesn't change as
    /// labels come and go. Both label forms are stacked, so the taller one wins in any
    /// locale.
    @ViewBuilder private var axisLabelTemplate: some View {
        ZStack {
            HourAxisLabel(date: Self.labelTemplateDate)
            HourAxisLabel(date: Self.dayLabelTemplateDate)
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(key: AxisLabelHeightKey.self, value: geo.size.height)
                    .preference(key: AxisLabelWidthKey.self, value: geo.size.width)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// A non-midnight and a midnight date, for the two forms `HourAxisLabel` can take.
    private static let labelTemplateDate = Calendar.current
        .date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 22)) ?? .distantPast
    private static let dayLabelTemplateDate = Calendar.current
        .date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 0)) ?? .distantPast

    /// The selection's time: the same axis label the hours use, just showing the scrub's
    /// own time and moving with the indicator. No container — it belongs to the axis, not
    /// to the readout, and a chip here would read as a second floating card.
    ///
    /// Bold is the only difference from an hour label, so it is legible as the live value
    /// while it has the strip to itself. Near a viewport edge it slides just far enough to
    /// stay whole: the label is the one part of the readout that must never be half-cut.
    @ViewBuilder private func selectionTimeLabel(y: CGFloat) -> some View {
        if let selectedGlucose, let selectionDate = selectedGlucose.date {
            let x = viewport.x(for: selectionDate)
            if x >= 0, x <= viewportWidth {
                let halfWidth = selectionTimeLabelWidth / 2
                Text(selectionDate.formatted(.dateTime.hour().minute(.twoDigits)))
                    .font(.footnote).bold()
                    // equal-width digits: the label is re-centred on every scrub step, and
                    // proportional digits would make it breathe as the minutes run
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(Color.primary)
                    .fixedSize()
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(key: SelectionTimeLabelWidthKey.self, value: geo.size.width)
                        }
                    }
                    .position(x: min(max(x, halfWidth), viewportWidth - halfWidth), y: y)
            }
        }
    }
}

/// The hour labels of the x-axis strip, in their own view so that they can be `Animatable`.
///
/// Same reason `TreatmentOverlay` and `PeakLabelsOverlay` are: the "jump to now" button
/// wraps `scrollToTrailingEdge()` in `withAnimation`, and the canvas glides there because
/// it moves under an animatable `.offset`. A `Date` handed to a view is not animatable at
/// all, so labels positioned from the shell's `scrollPosition` — already at its final
/// value when the animation starts — snapped straight to the destination hours while the
/// grid lines they name slid under them. Interpolating the leading edge here re-runs this
/// body each frame, so the hours travel with the chart.
private struct HourAxisLabels: View, Animatable {
    /// The marks are laid out over the visible span plus the overscan below. `var`, because
    /// `animatableData` interpolates the leading edge inside it.
    var viewport: ChartViewport

    /// Centre line of the label strip, measured by the shell.
    let labelY: CGFloat

    /// Measured width of the widest label form, from the shell's template. Only the
    /// overscan uses it.
    let labelWidth: CGFloat

    /// The leading edge as a scalar SwiftUI can interpolate — see the note above.
    ///
    /// This is the one layer that keeps its own `Animatable` conformance rather than sitting
    /// inside a `ChartOverlayLayer`: it is a component *within* the x-axis strip, which has
    /// its own frame and stacks it against the scrub's time label, not a top-level overlay.
    var animatableData: Double {
        get { viewport.animatableTime }
        set { viewport.animatableTime = newValue }
    }

    var body: some View {
        ForEach(hourMarks, id: \.self) { date in
            HourAxisLabel(date: date)
                .position(x: viewport.x(for: date), y: labelY)
        }
    }

    /// How far past each viewport edge hour marks are still laid out: exactly far enough
    /// for a label to clear the edge completely, and no further.
    ///
    /// A label is centred on its mark, so it is fully off screen only once the mark itself
    /// is half a label past the edge. Anything less and the label winks out of existence
    /// mid-stride instead of travelling off; anything more is laid out for nothing. Half
    /// the *measured* widest label — the midnight form, "TUE 07" — plus a point of slack
    /// for the rounding SwiftUI does when it positions it.
    ///
    /// The fallback only covers the frame or two before the template has been measured.
    private var overscanPoints: CGFloat {
        (labelWidth > 0 ? labelWidth : 56) / 2 + 1
    }

    /// Hour marks for the visible window plus that overscan — not the whole render window,
    /// which is ~9x wider and whose off-screen labels would be pure layout cost. The
    /// shell's frame clips, so the overscanned ones simply slide out of view.
    private var hourMarks: [Date] {
        let range = viewport.cullRange(marginPoints: overscanPoints)
        return MainChartHelper.hourAxisMarks(
            over: range,
            calendar: calendar,
            visibleSeconds: viewport.visibleSeconds
        )
    }
}

/// One x-axis time label. Midnight ticks carry the day ("TUE 07") so panned-back history
/// stays unambiguous; all other ticks show the hour.
///
/// Shared by the labels themselves and by the shell's hidden measuring template, so the
/// strip can never be sized from anything but the type actually drawn in it.
private struct HourAxisLabel: View {
    let date: Date

    var body: some View {
        if calendar.component(.hour, from: date) == 0 {
            Text(date.formatted(.dateTime.weekday(.abbreviated).day(.twoDigits)).uppercased())
                .font(.footnote).bold()
                .foregroundStyle(Color.primary)
                .fixedSize()
        } else {
            Text(date.formatted(.dateTime.hour(.defaultDigits(amPM: .narrow))))
                .font(.footnote)
                .foregroundStyle(Color.primary)
                .fixedSize()
        }
    }
}

// MARK: - Zoom / pan / inspect gesture handling

extension MainChartView {
    private var isPinching: Bool { pinchAnchor != nil }

    /// Converts a horizontal translation (pt) into a time delta within the visible window.
    private func timeDelta(forTranslation dx: CGFloat) -> TimeInterval {
        TimeInterval(dx / viewportWidth) * visibleSeconds
    }

    /// Keeps domain-edge content clear of the pinned y-axis labels.
    ///
    /// Converted from points to chart-time at the viewport's current scale, so the clearance
    /// is exactly as wide as the labels at every zoom level and on every device. Since
    /// `endMarker` now ends exactly at the forecast, this is the gap the last forecast point
    /// sits flush against. Falls back to the fraction until the first measurement arrives.
    private var trailingOverscan: TimeInterval {
        let measured = labelGutterWidth + MainChartHelper.Config.yAxisLabelInset + trailingInset
        let gutterPoints = labelGutterWidth > 0
            ? measured
            : viewportWidth * MainChartHelper.Config.labelGutterFraction + trailingInset
        return TimeInterval(gutterPoints / viewportWidth) * visibleSeconds
    }

    /// Double-tap cycles the zoom presets, anchored under the tap: the date the user
    /// tapped stays at the same screen position, exactly like a pinch centroid.
    private func cycleZoomPreset(atViewportX x: CGFloat) {
        // The drag zoom starts from this very double tap: the tap recognizer must not jump
        // a preset on top of it when the drag stayed short enough to still read as a tap.
        guard !isDoubleTapZooming else { return }
        if let ended = doubleTapZoomEndTime,
           Date.now.timeIntervalSince(ended) < MainChartHelper.Config.doubleTapMaxInterval { return }
        let presets = MainChartHelper.Config.zoomPresets
        let next = presets.first(where: { $0 > visibleSeconds + 1 }) ?? presets[0]
        let fraction = min(max(x / viewportWidth, 0), 1)
        let anchorDate = scrollPosition.addingTimeInterval(visibleSeconds * TimeInterval(fraction))
        momentumTask?.cancel()
        // Snap, like pinch commits: animating the zoom animates canvasWidth,
        // which re-lays the canvas every animation frame.
        visibleSeconds = next
        scrollPosition = clampedLeadingEdge(anchorDate.addingTimeInterval(-next * TimeInterval(fraction)))
        updateRenderWindow(force: true)
    }

    /// Mirror of `trailingOverscan` for the leading edge: keeps domain-start content clear of
    /// the display cutout the chart runs under in landscape, converted to chart-time at the
    /// viewport's current scale so the clearance is exactly as wide as the housing at every
    /// zoom level. Zero when there is no cutout, which is every other layout.
    private var leadingOverscan: TimeInterval {
        guard leadingInset > 0 else { return 0 }
        return TimeInterval(leadingInset / viewportWidth) * visibleSeconds
    }

    /// Clamps a proposed leading edge so the visible window never leaves the chart's domain.
    private func clampedLeadingEdge(_ proposed: Date) -> Date {
        let earliest = state.startMarker.addingTimeInterval(-leadingOverscan)
        let latest = state.endMarker.addingTimeInterval(trailingOverscan - visibleSeconds)
        return min(max(proposed, earliest), max(earliest, latest))
    }

    /// Anchors the visible window so the current reading stays on-screen at any zoom.
    private func scrollToTrailingEdge() {
        // Never yank the chart out from under an active gesture (pan, pinch, or an
        // in-progress inspect/scrub); the next data tick after the gesture ends will
        // re-anchor to trailing as before.
        guard !isPinching, panBaseline == nil, !isInspectLatched else { return }
        momentumTask?.cancel()
        // Wide zoom keeps the forecast-anchored framing; tighter zoom (where anchoring to
        // endMarker pushed `now` off the left) re-anchors to `now` plus a proportional peek.
        let forecastAnchoredTrailing = state.endMarker.addingTimeInterval(trailingOverscan)
        let nowAnchoredTrailing = Date.now
            .addingTimeInterval(visibleSeconds * MainChartHelper.Config.followForecastPeekFraction)
        let trailingEdge = min(forecastAnchoredTrailing, nowAnchoredTrailing)
        scrollPosition = clampedLeadingEdge(trailingEdge.addingTimeInterval(-visibleSeconds))
    }

    /// One-finger gesture: movement pans (with momentum on release); a press held in
    /// place for `Config.inspectHoldDelay` latches into inspect, after which dragging
    /// scrubs the selection until the finger lifts. Selection is rendered by a shell
    /// overlay and panning only mutates `scrollPosition` (a transform), so neither path
    /// ever re-lays the canvas.
    private var panAndInspectGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                momentumTask?.cancel()
                // A live drag zoom owns the whole touch. It has to be handled ahead of the
                // `isPinching` guard below, which would otherwise see the anchor the zoom
                // itself installed and write the touch off as spent.
                if isDoubleTapZooming {
                    updateDoubleTapZoom(translationY: value.translation.height)
                    return
                }
                guard !isPinching else {
                    inspectHoldTask?.cancel()
                    edgePanTask?.cancel()
                    if selection != nil { selection = nil }
                    panBaseline = nil
                    touchDownTime = nil
                    isInspectLatched = false
                    touchWasPinching = true
                    return
                }
                // First frame of a new touch: reset everything the last one left behind.
                //
                // This has to key off `startLocation` rather than `onEnded` having run,
                // because a drag that is *cancelled* never delivers `onEnded` — and that is
                // exactly what happens to this one when a second finger lands and the pinch
                // takes over. Its `panBaseline` then survives the gesture, and the next
                // touch, however still, fails the `panBaseline == nil` test below, takes the
                // pan branch, and snaps `scrollPosition` straight to that stale baseline.
                // That is the jump: tap once after a pinch and the chart teleports to
                // wherever the pan before the pinch had been heading.
                if touchStartLocation != value.startLocation {
                    touchStartLocation = value.startLocation
                    panBaseline = nil
                    touchWasPinching = false
                    isInspectLatched = false
                    touchDownTime = value.time
                    // Second tap of a double tap: this touch is reserved for the zoom, so
                    // it must neither pan nor latch inspect — lifting it still cycles the
                    // presets, travelling engages the drag zoom.
                    doubleTapCandidate = isSecondTap(value)
                    // No inspect on the second tap — and cancel any hold the first one
                    // left armed, so the drag zoom can never be preceded by inspect's
                    // haptic tick.
                    if doubleTapCandidate { inspectHoldTask?.cancel() } else { scheduleInspectHold() }
                }

                // A touch that has been part of a pinch is spent. Lifting one finger ends the
                // magnify gesture but leaves this drag alive on the other, still carrying
                // everything that finger did *during* the pinch: its travel would be read as
                // a pan the moment the pinch ends, and its speed at lift-off as a fling. The
                // zoom is the gesture; panning starts from a fresh touch — which the reset
                // above recognises, since that touch brings a new `startLocation`.
                guard !touchWasPinching else { return }
                lastTouchLocation = value.location

                // Second tap travelling: engage the drag zoom, anchored under the tap.
                // Vertical movement drives it; horizontal is ignored, since after a double
                // tap there is nothing else this touch could have meant.
                if doubleTapCandidate {
                    let travel = hypot(value.translation.width, value.translation.height)
                    guard travel > MainChartHelper.Config.inspectMovementTolerance else { return }
                    beginDoubleTapZoom(atViewportX: value.startLocation.x)
                    updateDoubleTapZoom(translationY: value.translation.height)
                    return
                }

                // Once inspect has engaged, the rest of this touch scrubs the selection —
                // selection is rendered by a shell overlay, so scrubbing never re-lays
                // the canvas and stays gesture-rate smooth.
                if isInspectLatched {
                    updateSelection(atViewportX: value.location.x)
                    manageEdgePan(atViewportX: value.location.x)
                    return
                }

                let distance = hypot(value.translation.width, value.translation.height)
                if panBaseline == nil, distance < MainChartHelper.Config.inspectMovementTolerance {
                    // Finger is stationary: nothing to do here — the hold timer armed at
                    // touch-down will latch inspect if it stays that way.
                } else {
                    // Finger is travelling: pan. The touch can no longer become an inspect.
                    inspectHoldTask?.cancel()
                    if selection != nil { selection = nil }
                    if panBaseline == nil {
                        // Compensate for the distance already travelled inside the
                        // tolerance so the pan engages without a positional jump.
                        panBaseline = scrollPosition
                            .addingTimeInterval(timeDelta(forTranslation: value.translation.width))
                    }
                    if let baseline = panBaseline {
                        scrollPosition = clampedLeadingEdge(
                            baseline.addingTimeInterval(-timeDelta(forTranslation: value.translation.width))
                        )
                    }
                }
            }
            .onEnded { value in
                inspectHoldTask?.cancel()
                edgePanTask?.cancel()
                if selection != nil { selection = nil }
                touchDownTime = nil
                let wasInspecting = isInspectLatched
                isInspectLatched = false
                lastTouchLocation = nil
                let wasPanning = panBaseline != nil
                let wasPinching = touchWasPinching
                let wasDoubleTapCandidate = doubleTapCandidate
                panBaseline = nil
                touchWasPinching = false
                touchStartLocation = nil
                doubleTapCandidate = false

                if isDoubleTapZooming {
                    endDoubleTapZoom()
                    return
                }

                // Remember a clean tap: a touch that neither panned, pinched nor inspected
                // is what arms the drag zoom for the touch after it. A tap that was itself
                // a second tap arms nothing, so a third tap starts the count over.
                let travel = hypot(value.translation.width, value.translation.height)
                let wasTap = !wasPanning && !wasPinching && !wasInspecting && !wasDoubleTapCandidate
                    && travel <= MainChartHelper.Config.inspectMovementTolerance
                lastTapEnd = wasTap ? (time: value.time, location: value.location) : nil

                guard wasPanning, !wasPinching, !isPinching else { return }
                // Momentum: initial velocity in seconds of chart time per second.
                let velocity = -timeDelta(forTranslation: value.velocity.width)
                startMomentum(velocitySecondsPerSecond: velocity)
            }
    }

    /// Arms the inspect hold: after `Config.inspectHoldDelay`, if the touch is still down
    /// and has neither become a pan nor a pinch, latch into inspect mode at the finger's
    /// last known position — with a haptic tick so the mode change is felt.
    private func scheduleInspectHold() {
        inspectHoldTask?.cancel()
        inspectHoldTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(MainChartHelper.Config.inspectHoldDelay * 1_000_000_000)
            )
            guard !Task.isCancelled,
                  touchDownTime != nil, // finger still down
                  panBaseline == nil, // touch has not become a pan
                  !isPinching,
                  !isInspectLatched
            else { return }

            isInspectLatched = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            scrubPointHaptic.prepare()
            if let location = lastTouchLocation {
                updateSelection(atViewportX: location.x, withPointHaptic: false)
            }
        }
    }

    /// Snaps a viewport x position to the 5-minute glucose cadence and updates the
    /// selection, skipping no-op writes. `ChartSelectionLookup.window` is +/-150 s, so the
    /// 300 s snap lands exactly on the nearest reading; it also means finger jitter or a
    /// scrub only produces a new value when actually crossing to another reading.
    private func updateSelection(atViewportX x: CGFloat, withPointHaptic: Bool = true) {
        // Clamped to the viewport: a scrub that runs off an edge keeps selecting the last
        // reading on screen rather than one beyond it.
        let raw = viewport.date(atViewportX: min(max(x, 0), viewportWidth))
        let quantum: TimeInterval = 300
        let snapped = Date(
            timeIntervalSince1970: (raw.timeIntervalSince1970 / quantum).rounded() * quantum
        )
        guard selection != snapped else { return }
        selection = snapped
        // A featherlight tick whenever the scrub lands on an actual glucose reading.
        if withPointHaptic, hasGlucoseReading(near: snapped) {
            scrubPointHaptic.selectionChanged()
            scrubPointHaptic.prepare()
        }
    }

    /// Whether a glucose reading exists within the selection matching window of `date`.
    private func hasGlucoseReading(near date: Date) -> Bool {
        ChartSelectionLookup.glucose(at: date, in: state.glucoseFromPersistence) != nil
    }

    /// While scrubbing, a finger resting in the viewport's edge zones auto-pans the chart
    /// so the scrub can continue into off-screen data. Speed scales with edge depth; only
    /// `scrollPosition` (a transform) and the overlay selection are mutated, so this runs
    /// at frame rate without touching the canvas.
    private func manageEdgePan(atViewportX x: CGFloat) {
        let zone = MainChartHelper.Config.edgePanZoneWidth
        let inZone = x < zone || x > viewportWidth - zone
        guard inZone else {
            edgePanTask?.cancel()
            edgePanTask = nil
            return
        }
        guard edgePanTask == nil else { return }
        edgePanTask = Task { @MainActor in
            let frameDuration: TimeInterval = 1.0 / 60.0
            while !Task.isCancelled, isInspectLatched {
                guard let fingerX = lastTouchLocation?.x else { break }
                let leftDepth = max(0, zone - fingerX) / zone
                let rightDepth = max(0, fingerX - (viewportWidth - zone)) / zone
                let depth = max(leftDepth, rightDepth)
                guard depth > 0 else { break }

                let direction: TimeInterval = rightDepth > 0 ? 1 : -1
                let speed = TimeInterval(depth) * visibleSeconds * 0.5 // chart-seconds per second
                let next = clampedLeadingEdge(
                    scrollPosition.addingTimeInterval(direction * speed * frameDuration)
                )
                guard next != scrollPosition else { break } // domain edge reached
                scrollPosition = next
                updateSelection(atViewportX: fingerX)

                try? await Task.sleep(nanoseconds: UInt64(frameDuration * 1_000_000_000))
            }
            edgePanTask = nil
        }
    }

    /// Where the visible window sits in the zoom range: 0 at the tightest, 1 at the widest.
    /// Log-scaled, so it moves with the geometric grid the zoom itself steps on.
    private var zoomOutFraction: Double {
        let span = log2(MainChartHelper.Config.maxVisibleSeconds / MainChartHelper.Config.minVisibleSeconds)
        guard span > 0 else { return 0 }
        let position = log2(visibleSeconds / MainChartHelper.Config.minVisibleSeconds) / span
        return min(max(position, 0), 1)
    }

    /// Deceleration after a flick. Mutates only `scrollPosition` (a transform), so each
    /// frame costs a GPU translation — the same cost profile as live panning.
    ///
    /// Friction scales with how far out the zoom is. Exponential decay has a long tail, and
    /// a tail that reads as a graceful coast at 1 h reads as the chart drifting on its own
    /// at 24 h — so the wide end both sheds speed faster and gives up on the last crawl
    /// sooner, which is what makes it stop rather than fade out.
    private func startMomentum(velocitySecondsPerSecond initialVelocity: TimeInterval) {
        // Ignore tiny flicks.
        guard abs(initialVelocity) > visibleSeconds * 0.05 else { return }
        let stickiness = zoomOutFraction
        let decayPerFrame = MainChartHelper.Config.momentumDecayTight
            + (MainChartHelper.Config.momentumDecayWide - MainChartHelper.Config.momentumDecayTight) * stickiness
        let stopFraction = MainChartHelper.Config.momentumStopFractionTight
            + (MainChartHelper.Config.momentumStopFractionWide - MainChartHelper.Config.momentumStopFractionTight)
            * stickiness
        let stopSpeed = visibleSeconds * stopFraction
        momentumTask?.cancel()
        momentumTask = Task { @MainActor in
            var velocity = initialVelocity
            let frameDuration: TimeInterval = 1.0 / 60.0
            while !Task.isCancelled, abs(velocity) > stopSpeed {
                try? await Task.sleep(nanoseconds: UInt64(frameDuration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                let next = clampedLeadingEdge(scrollPosition.addingTimeInterval(velocity * frameDuration))
                guard next != scrollPosition else { return } // hit a domain edge
                scrollPosition = next
                velocity *= decayPerFrame
            }
        }
    }

    /// Two-finger pinch drives the zoom level continuously, anchored under the pinch
    /// centroid. Zoom changes re-lay the canvas, so commits are quantized to a geometric
    /// grid (`Config.zoomStepRatio`) to bound the number of re-layouts per pinch.
    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                momentumTask?.cancel()
                // A second finger landing cancels the drag zoom's touch outright — no
                // `onEnded` ever arrives — so close it out here, or its anchor and stretch
                // would outlive the gesture and leave the canvas permanently distorted.
                if isDoubleTapZooming { endDoubleTapZoom() }
                if pinchAnchor == nil {
                    isZoomGestureLive = true
                    let fraction = min(max(value.startAnchor.x, 0), 1)
                    pinchAnchor = (
                        visibleAtStart: visibleSeconds,
                        anchorDate: scrollPosition.addingTimeInterval(visibleSeconds * fraction),
                        anchorFraction: fraction
                    )
                }
                guard let pinch = pinchAnchor, value.magnification > 0 else { return }

                // Live pinch previews as a transform: stretch the already-
                // laid-out canvas about the centroid. Pinch out
                // (magnification > 1) narrows the visible window, i.e. zooms
                // in. Once the stretch drifts past the commit threshold, a
                // crisp re-layout is committed mid-gesture and the transform
                // continues from that new baseline.
                let proposed = min(
                    max(pinch.visibleAtStart / TimeInterval(value.magnification), MainChartHelper.Config.minVisibleSeconds),
                    MainChartHelper.Config.maxVisibleSeconds
                )
                pinchScale = CGFloat(visibleSeconds / proposed)

                if shouldCommitMidGesture(stretch: pinchScale) {
                    commitPinchZoom(proposed)
                }
            }
            .onEnded { _ in
                guard pinchAnchor != nil else { return }
                finishZoomGesture()
            }
    }

    /// Quantizes to the geometric zoom grid and re-lays the canvas exactly
    /// once: window re-anchor happens in the same transaction, else the
    /// commit first lays out the OLD window at the new zoom (a canvas up to
    /// 12x the viewport) before re-laying at the right size.
    @discardableResult private func commitPinchZoom(_ proposed: TimeInterval) -> Bool {
        guard let pinch = pinchAnchor else { return false }
        let ratio = MainChartHelper.Config.zoomStepRatio
        let step = (log(proposed / MainChartHelper.Config.defaultVisibleSeconds) / log(ratio)).rounded()
        var quantized = MainChartHelper.Config.defaultVisibleSeconds * pow(ratio, step)
        quantized = min(
            max(quantized, MainChartHelper.Config.minVisibleSeconds),
            MainChartHelper.Config.maxVisibleSeconds
        )
        // A no-op commit would just snap the preview back to 1 with no fresh
        // layout to justify it.
        guard quantized != visibleSeconds else { return false }

        visibleSeconds = quantized
        scrollPosition = clampedLeadingEdge(
            pinch.anchorDate.addingTimeInterval(-quantized * pinch.anchorFraction)
        )
        updateRenderWindow(force: true)
        pinchScale = 1
        lastZoomCommit = Date.now
        return true
    }

    /// Ends a zoom gesture: commits whatever the stretch is still previewing, with the render
    /// window back on its full pad.
    ///
    /// The flag is cleared *before* the commit so that commit is the one that lays the wide
    /// window out — one re-layout at the end of the gesture rather than two. When it turns out
    /// to be a no-op (the zoom quantizes back to where it already was) the window still has to
    /// be widened, or the chart would be left on the gesture-time pad and re-anchor every half
    /// viewport of the next pan.
    private func finishZoomGesture() {
        isZoomGestureLive = false
        if !commitPinchZoom(visibleSeconds / TimeInterval(pinchScale)) {
            updateRenderWindow(force: true)
        }
        // The commit no-ops when the zoom quantizes back to the current value; the preview
        // must still un-stretch.
        pinchScale = 1
        pinchAnchor = nil
    }

    /// Whether a touch starting here is the second tap of a double tap: close enough in
    /// time and in place to the last clean tap.
    private func isSecondTap(_ value: DragGesture.Value) -> Bool {
        guard let last = lastTapEnd,
              value.time.timeIntervalSince(last.time) <= MainChartHelper.Config.doubleTapMaxInterval
        else { return false }
        let offset = hypot(
            value.startLocation.x - last.location.x,
            value.startLocation.y - last.location.y
        )
        return offset <= MainChartHelper.Config.doubleTapSlop
    }

    /// Takes over the touch and installs exactly the state a pinch installs, anchored under
    /// the double tap instead of under a centroid. From here the drag feeds
    /// `commitPinchZoom` like the pinch does, so the live stretch, the mid-gesture commits
    /// and every overlay that reads `pinchScale` behave identically.
    private func beginDoubleTapZoom(atViewportX x: CGFloat) {
        momentumTask?.cancel()
        inspectHoldTask?.cancel()
        edgePanTask?.cancel()
        if selection != nil { selection = nil }
        lastTapEnd = nil
        let fraction = min(max(x / viewportWidth, 0), 1)
        pinchAnchor = (
            visibleAtStart: visibleSeconds,
            anchorDate: scrollPosition.addingTimeInterval(visibleSeconds * TimeInterval(fraction)),
            anchorFraction: fraction
        )
        isDoubleTapZooming = true
        isZoomGestureLive = true
        doubleTapZoomEndTime = Date.now
    }

    /// Maps vertical travel onto the zoom: dragging up zooms in, down zooms out.
    private func updateDoubleTapZoom(translationY dy: CGFloat) {
        guard let pinch = pinchAnchor else { return }
        let proposed = min(
            max(
                zoomWindow(from: pinch.visibleAtStart, dragDown: dy),
                MainChartHelper.Config.minVisibleSeconds
            ),
            MainChartHelper.Config.maxVisibleSeconds
        )
        pinchScale = CGFloat(visibleSeconds / proposed)

        if shouldCommitMidGesture(stretch: pinchScale) {
            commitPinchZoom(proposed)
        }
    }

    /// Whether the live stretch has drifted far enough — and long enough since the last one —
    /// to be worth a crisp re-layout while the gesture is still running.
    ///
    /// `stretch` is `visibleSeconds / proposed`, so above 1 is zooming in (the canvas is
    /// magnified) and below 1 is zooming out. Both call sites, the pinch and the
    /// double-tap-drag, feed the same zoom state, so they share this. The gesture's *end*
    /// never asks: it commits unconditionally.
    private func shouldCommitMidGesture(stretch: CGFloat) -> Bool {
        let driftedIn = stretch > MainChartHelper.Config.pinchCommitScaleDriftIn
        let driftedOut = stretch < 1 / MainChartHelper.Config.pinchCommitScaleDriftOut
        guard driftedIn || driftedOut else { return false }
        // A stretch this far out has outrun the canvas; the rate limit yields to it.
        let ceiling = MainChartHelper.Config.pinchCommitDriftCeiling
        if stretch > ceiling || stretch < 1 / ceiling { return true }
        guard let last = lastZoomCommit else { return true }
        return Date.now.timeIntervalSince(last) >= MainChartHelper.Config.pinchCommitMinInterval
    }

    /// The visible window a drag of `dy` points (positive = down = out) reaches from a
    /// window of `start`.
    ///
    /// Accelerating-geometric: the points it takes to double the window shrinks linearly
    /// across the zoom range, from `Config.doubleTapZoomPointsPerDoubling` at the tightest
    /// window to that over `Config.doubleTapZoomAcceleration` at the widest. A flat rate
    /// spends the same travel on 1 h → 2 h as on 12 h → 24 h, which makes the wide end —
    /// where the useful jumps live — feel like wading.
    ///
    /// Working in doublings above the tightest window (`d`), that rate is
    /// `k(d) = k₀ / (1 + β·d/D)`, and integrating `ds = k(d)·dd` gives the travel to reach
    /// `d` in closed form — so the result stays a pure function of the drag's *total*
    /// translation. That is what keeps the gesture exactly reversible: drag back to where
    /// it started and the zoom lands back where it started, with no drift from summing
    /// per-frame deltas.
    private func zoomWindow(from start: TimeInterval, dragDown dy: CGFloat) -> TimeInterval {
        let tightest = MainChartHelper.Config.minVisibleSeconds
        let span = log2(MainChartHelper.Config.maxVisibleSeconds / tightest) // D: total doublings
        let beta = MainChartHelper.Config.doubleTapZoomAcceleration - 1
        let pointsPerDoubling = Double(MainChartHelper.Config.doubleTapZoomPointsPerDoubling)
        guard span > 0, beta > 0 else { // flat rate: the plain geometric mapping
            return start * pow(2, Double(dy) / pointsPerDoubling)
        }

        let scale = pointsPerDoubling * span / beta
        let startDoublings = min(max(log2(start / tightest), 0), span)
        // Travel that would have been needed to arrive at the window this drag started
        // from, so the drag continues along the same curve rather than restarting it.
        let startTravel = scale * log(1 + beta * startDoublings / span)
        let doublings = span / beta * (exp((startTravel + Double(dy)) / scale) - 1)
        return tightest * pow(2, min(max(doublings, 0), span))
    }

    /// Commits whatever the stretch is still previewing and hands the touch back.
    private func endDoubleTapZoom() {
        finishZoomGesture()
        isDoubleTapZooming = false
        doubleTapZoomEndTime = Date.now
        lastTapEnd = nil
    }

    /// Anchor for the live-pinch stretch: the centroid's layout position on
    /// the canvas, so the content under the fingers stays put on screen.
    private var pinchScaleAnchor: UnitPoint {
        guard let pinch = pinchAnchor, canvasWidth > 0 else { return .center }
        // The scale composes on top of the already-offset render, anchored in
        // the canvas's layout frame (origin at viewport 0) — so the centroid's
        // viewport position is the anchor and the content under the fingers
        // stays put on screen.
        return UnitPoint(x: pinch.anchorFraction * viewportWidth / canvasWidth, y: 0.5)
    }
}

// MARK: - Pinned y-axis overlay

/// Chart that renders only the glucose y-axis — the original `mainChartYAxis` content,
/// verbatim — at a fixed position over the scrolling canvas. This is the successor of the
/// old "dummy chart" overlay. It rendered "nothing" during this refactor only because its
/// container inherited the canvas's layout width and drew the trailing labels thousands of
/// points off-screen; with the container pinned to the viewport (see the load-bearing frame
/// at the call site), the pattern works as it always did.
/// Width the pinned y-axis labels occupy at the trailing edge of the glucose pane.
///
/// Measured rather than assumed: the labels are an overlay floating over a full-width plot,
/// so nothing in the layout reserves room for them, and their width moves with the glucose
/// unit ("300" vs "16,7"), the locale's decimal separator, and the user's Dynamic Type size.
/// Any hardcoded guess is wrong for someone.
struct YAxisLabelGutterKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

struct StaticYAxisChart: View {
    let yDomain: ClosedRange<Decimal>
    let units: GlucoseUnits
    let displayYgridLines: Bool

    var body: some View {
        Chart {
            // Invisible content at the domain corners so both scales are resolvable and
            // the plot (and with it the axis) materializes.
            PointMark(x: .value("Edge", 0.0), y: .value("Min", yDomain.lowerBound))
                .opacity(0)
            PointMark(x: .value("Edge", 1.0), y: .value("Max", yDomain.upperBound))
                .opacity(0)
        }
        .chartXScale(domain: 0.0 ... 1.0)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis { mainChartYAxis }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                // Everything to the right of the plot is label column.
                Color.clear.preference(
                    key: YAxisLabelGutterKey.self,
                    value: proxy.plotFrame.map { geo.size.width - geo[$0].maxX } ?? 0
                )
            }
        }
    }

    private var mainChartYAxis: some AxisContent {
        AxisMarks(position: .trailing) { value in
            if displayYgridLines {
                AxisGridLine(stroke: .init(lineWidth: 0.5, dash: [2, 3]))
            } else {
                AxisGridLine(stroke: .init(lineWidth: 0, dash: [2, 3]))
            }
            if let glucoseValue = value.as(Double.self), glucoseValue > 0 {
                /// fix offset between the two charts...
                if units == .mmolL {
                    AxisTick(length: 7, stroke: .init(lineWidth: 7)).foregroundStyle(Color.clear)
                }
                AxisValueLabel().font(.footnote).foregroundStyle(Color.primary)
            }
        }
    }
}

// MARK: - Canvas (laid out once per data / zoom change; translated while panning)

struct MainChartCanvas: View {
    var state: Home.StateModel
    var units: GlucoseUnits
    var highGlucose: Decimal
    var lowGlucose: Decimal
    var currentGlucoseTarget: Decimal
    var glucoseColorScheme: GlucoseColorScheme
    var displayXgridLines: Bool
    var displayYgridLines: Bool
    var thresholdLines: Bool
    var visibleSeconds: TimeInterval
    /// Rendered slice of the domain; all panes share this x-scale.
    var windowStart: Date
    var windowEnd: Date
    var canvasWidth: CGFloat
    var basalHeight: CGFloat
    var mainHeight: CGFloat
    var cobIobHeight: CGFloat
    var glucoseYDomain: ClosedRange<Decimal>

    @State var basalProfiles: [BasalProfile] = []
    @State var preparedTempBasals: [(start: Date, end: Date, rate: Double)] = []

    // Computed (not stored) on purpose: stored properties participate in SwiftUI's
    // change detection, and a stored reference initialized per-init could mark this view
    // as "changed" on every parent body evaluation — i.e. on every pan frame — defeating
    // the body skip this whole architecture depends on.
    var context: NSManagedObjectContext { CoreDataStack.shared.persistentContainer.viewContext }

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.calendar) var calendar

    var upperLimit: Decimal {
        units == .mgdL ? 400 : 22.2
    }

    /// Kept in the fetch's own descending order: `drawCOBIOBChart` de-duplicates entries
    /// sharing a `deliverAt` by keeping the first it meets, which is the correct one only
    /// in that order.
    var windowedDeterminations: [OrefDetermination] {
        MainChartHelper.windowSlice(
            state.enactedAndNonEnactedDeterminations,
            from: windowStart, through: windowEnd,
            ascendingInput: false, ascendingOutput: false, date: \.deliverAt
        )
    }

    /// Coordinate space for plot-frame preferences; pane-local plot rects let the
    /// shell's selection overlay match the charts' real plot areas.
    static let coordinateSpaceName = "mainChartCanvas"

    var body: some View {
        VStack(spacing: 0) {
            basalChart
            mainChart
            cobIobChart
        }
        .frame(width: canvasWidth)
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onAppear {
            calculateTempBasals()
            // The profile otherwise stays empty until the first temp basal or max basal
            // change comes in, leaving the scheduled basal line off the chart until then.
            calculateBasals()
        }
    }
}

/// Plot-area rect of the COB/IOB pane in canvas coordinates (y is offset-independent).
struct CobIobPlotFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The same for the glucose pane — what the shell's overlays map values through.
struct GlucosePlotFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Main (glucose) chart pane

extension MainChartCanvas {
    var mainChart: some View {
        Chart {
            drawCurrentTimeMarker()
            drawThresholdLines()

            GlucoseTargetsView(
                targetProfiles: state.targetProfiles
            )

            OverrideView(
                state: state,
                overrides: state.overrides,
                overrideRunStored: state.overrideRunStored,
                units: state.units,
                viewContext: context
            )

            TempTargetView(
                tempTargetStored: state.tempTargetStored,
                tempTargetRunStored: state.tempTargetRunStored,
                units: state.units,
                viewContext: context
            )

            ForecastView(
                preprocessedData: state.preprocessedData,
                minForecast: state.minForecast,
                maxForecast: state.maxForecast,
                units: state.units,
                maxValue: state.maxYAxisValue,
                forecastDisplayType: state.forecastDisplayType,
                lastDeterminationDate: state.determinationsFromPersistence.first?.deliverAt ?? .distantPast,
                chartEndDate: state.endMarker
            )
        }
        .frame(width: canvasWidth, height: mainHeight)
        .chartXScale(domain: windowStart ... windowEnd)
        .chartXAxis { mainChartXAxis }
        .chartYAxis(.hidden)
        .chartYScale(domain: glucoseYDomain)
        .chartLegend(.hidden)
        // Publish the plot rect for the shell's overlays, rebased into canvas coordinates —
        // the same measurement the COB/IOB pane makes, and for the same reason.
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let plotAnchor = proxy.plotFrame {
                    let chartFrame = geo.frame(in: .named(MainChartCanvas.coordinateSpaceName))
                    let plotLocal = geo[plotAnchor]
                    Color.clear.preference(
                        key: GlucosePlotFrameKey.self,
                        value: plotLocal.offsetBy(dx: chartFrame.minX, dy: chartFrame.minY)
                    )
                }
            }
        }
        .chartForegroundStyleScale([
            "iob": Color.insulin,
            "uam": Color.uam,
            "zt": Color.zt,
            "cob": Color.orange
        ])
    }
}

// MARK: - Change detection

/// Explicit equality so SwiftUI provably skips the canvas body during panning/momentum
/// (which only change the shell's offset). Data updates still propagate: they arrive via
/// Observation tracking of `state`, which invalidates the body independently of this check.
extension MainChartCanvas: Equatable {
    static func == (lhs: MainChartCanvas, rhs: MainChartCanvas) -> Bool {
        lhs.state === rhs.state &&
            lhs.units == rhs.units &&
            lhs.highGlucose == rhs.highGlucose &&
            lhs.lowGlucose == rhs.lowGlucose &&
            lhs.currentGlucoseTarget == rhs.currentGlucoseTarget &&
            lhs.glucoseColorScheme == rhs.glucoseColorScheme &&
            lhs.displayXgridLines == rhs.displayXgridLines &&
            lhs.displayYgridLines == rhs.displayYgridLines &&
            lhs.thresholdLines == rhs.thresholdLines &&
            lhs.visibleSeconds == rhs.visibleSeconds &&
            lhs.windowStart == rhs.windowStart &&
            lhs.windowEnd == rhs.windowEnd &&
            lhs.canvasWidth == rhs.canvasWidth &&
            lhs.basalHeight == rhs.basalHeight &&
            lhs.mainHeight == rhs.mainHeight &&
            lhs.cobIobHeight == rhs.cobIobHeight &&
            lhs.glucoseYDomain == rhs.glucoseYDomain
    }
}

extension StaticYAxisChart: Equatable {}
