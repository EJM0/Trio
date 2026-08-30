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
/// momentum), two-finger magnify zooms continuously, and a stationary press inspects.
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

    @Environment(\.colorScheme) var colorScheme

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
            MainChartCanvas(
                state: state,
                units: units,
                highGlucose: highGlucose,
                lowGlucose: lowGlucose,
                currentGlucoseTarget: currentGlucoseTarget,
                glucoseColorScheme: glucoseColorScheme,
                displayXgridLines: displayXgridLines,
                displayYgridLines: displayYgridLines,
                showGlucoseEpisodes: showGlucoseEpisodes,
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

            treatmentOverlay
                .allowsHitTesting(false)

            peakLabelsOverlay
                .allowsHitTesting(false)

            nowOffscreenGradient

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

            selectionOverlay
                .allowsHitTesting(false)
        }
        // The full zone: the canvas fills all of it but the bottom strip, which carries
        // the x-axis labels.
        .frame(width: viewportWidth, height: chartHeight, alignment: .topLeading)
        .clipped()
        .onPreferenceChange(CobIobPlotFrameKey.self) { cobIobPlotFrame = $0 }
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
        let pad = MainChartHelper.Config.renderWindowPadFactor * visibleSeconds
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

    /// Viewport x of a date, as it is actually on screen — including the live-pinch
    /// stretch. The overlays sit outside the canvas and so are not carried by its
    /// `scaleEffect`; without applying the same transform here, every pinned label and
    /// selection mark would drift off the marks it belongs to for the length of a pinch.
    private func xPosition(for date: Date) -> CGFloat {
        let x = CGFloat(date.timeIntervalSince(scrollPosition) / visibleSeconds) * viewportWidth
        guard let pinch = pinchAnchor, pinchScale != 1 else { return x }
        let anchorX = pinch.anchorFraction * viewportWidth
        return anchorX + (x - anchorX) * pinchScale
    }

    /// Top of the x-axis label strip — which is simply the bottom of the canvas, since
    /// the strip is taken off the zone before the panes split what is left. Nothing
    /// reserves height inside the COB/IOB pane any more, so its plot ends here too.
    var axisStripTop: CGFloat { stackHeight }

    private func glucoseYPosition(for glucose: GlucoseStored) -> CGFloat {
        glucoseYPosition(forDisplayValue: units == .mgdL ? Decimal(glucose.glucose) : Decimal(glucose.glucose).asMmolL)
    }

    /// Where a value in the chart's display units sits in the glucose pane. Shared with the
    /// treatment overlay, which anchors its markers to the curve the same way the marks did.
    func glucoseYPosition(forDisplayValue value: Decimal) -> CGFloat {
        let domain = paddedGlucoseYDomain
        let span = domain.upperBound - domain.lowerBound
        let fraction = span == 0 ? 0.5 :
            Double(truncating: ((value - domain.lowerBound) / span) as NSDecimalNumber)
        return basalHeight + mainHeight * CGFloat(1 - min(max(fraction, 0), 1))
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

    /// Dark fade pinned to the trailing edge whenever "now" is scrolled off-screen.
    /// Without it, yesterday's 2 am and today's 2 am are visually indistinguishable; the
    /// fade signals "you are looking at the past — newer data lies this way". Opacity
    /// ramps in over the first 30 min of scroll-back so it doesn't pop at the boundary.
    @ViewBuilder private var nowOffscreenGradient: some View {
        let trailingEdge = scrollPosition.addingTimeInterval(visibleSeconds)
        let secondsBehindNow = Date.now.timeIntervalSince(trailingEdge)
        let color: Color = (colorScheme == .dark ? Color.bgDarkerDarkBlue : Color.black.opacity(0.25))
        if isScrolledBack {
            let strength = min(1.0, secondsBehindNow / 1800)
            LinearGradient(
                colors: [color.opacity(0), color.opacity(0.8 * strength)],
                startPoint: .leading,
                endPoint: .trailing
            )
            // the whole zone, label strip included: stopping at the canvas would leave
            // a seam across the fade
            .frame(width: 120, height: chartHeight)
            .frame(width: viewportWidth, alignment: .trailing)
            .allowsHitTesting(false)
        }
    }

    /// Vertical indicator + point highlights for the current selection. Positions are
    /// computed with the same linear maps the canvas charts use. The readout itself is
    /// drawn by Home in the meal slot (`ChartSelectionRow`), never over the chart.
    @ViewBuilder private var selectionOverlay: some View {
        if let selectedGlucose, let selectionDate = selectedGlucose.date {
            let x = xPosition(for: selectionDate)
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

// MARK: - Treatment overlay (markers drawn outside the pinch transform)

extension MainChartView {
    /// Bolus, carb and FPU markers with their labels. Rendered here rather than as marks in
    /// the canvas so the live-pinch `scaleEffect` cannot stretch them — see `TreatmentOverlay`.
    ///
    /// Sliced against the render window rather than the visible one: the overlay culls to
    /// what is on screen itself, and the nearest-glucose lookup a marker's y anchor needs has
    /// to be able to reach a reading just outside the visible edge.
    @ViewBuilder var treatmentOverlay: some View {
        TreatmentOverlay(
            glucose: MainChartHelper.windowSlice(
                state.glucoseFromPersistence, from: renderWindowStart, through: renderWindowEnd,
                ascendingInput: true, date: \.date
            ),
            insulin: MainChartHelper.windowSlice(
                state.insulinFromPersistence, from: renderWindowStart, through: renderWindowEnd,
                ascendingInput: true, date: \.timestamp
            ),
            carbs: MainChartHelper.windowSlice(
                state.carbsFromPersistence, from: renderWindowStart, through: renderWindowEnd,
                ascendingInput: false, date: \.date
            ),
            fpus: MainChartHelper.windowSlice(
                state.fpusFromPersistence, from: renderWindowStart, through: renderWindowEnd,
                ascendingInput: false, date: \.date
            ),
            units: units,
            bolusDisplayThreshold: state.bolusDisplayThreshold,
            smbBolusDisplayCutoff: state.smbBolusDisplayCutoff,
            fpuBaseline: units == .mgdL ? state.minYAxisValue : state.minYAxisValue.asMmolL,
            viewportWidth: viewportWidth,
            stackHeight: stackHeight,
            visibleStart: scrollPosition,
            visibleSeconds: visibleSeconds,
            pinchScale: pinchScale,
            pinchAnchorFraction: pinchAnchor?.anchorFraction,
            yPosition: { glucoseYPosition(forDisplayValue: $0) }
        )
    }
}

// MARK: - Peak / nadir badges (drawn outside the pinch transform)

extension MainChartView {
    /// Peak and nadir badges. In the shell rather than a `.chartOverlay` so the live-pinch
    /// `scaleEffect` cannot stretch them, and so they can be culled to what is on screen —
    /// see `PeakLabelsOverlay`.
    @ViewBuilder var peakLabelsOverlay: some View {
        if state.showGlucosePeaks {
            PeakLabelsOverlay(
                peaks: state.glucosePeaks,
                glucoseData: MainChartHelper.windowSlice(
                    state.glucoseFromPersistence, from: renderWindowStart, through: renderWindowEnd,
                    ascendingInput: true, date: \.date
                ),
                insulinData: MainChartHelper.windowSlice(
                    state.insulinFromPersistence, from: renderWindowStart, through: renderWindowEnd,
                    ascendingInput: true, date: \.timestamp
                ),
                carbData: MainChartHelper.windowSlice(
                    state.carbsFromPersistence, from: renderWindowStart, through: renderWindowEnd,
                    ascendingInput: false, date: \.date
                ),
                units: units,
                highGlucose: highGlucose,
                lowGlucose: lowGlucose,
                glucoseColorScheme: glucoseColorScheme,
                currentGlucoseTarget: currentGlucoseTarget,
                viewportWidth: viewportWidth,
                stackHeight: stackHeight,
                visibleStart: scrollPosition,
                visibleSeconds: visibleSeconds,
                xPosition: { xPosition(for: $0) },
                yPosition: { glucoseYPosition(forDisplayValue: $0) },
                bolusDisplayThreshold: state.bolusDisplayThreshold,
                smbBolusDisplayCutoff: state.smbBolusDisplayCutoff
            )
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

            ForEach(visibleHourMarks, id: \.self) { date in
                hourLabel(for: date)
                    .position(x: xPosition(for: date), y: labelY)
            }
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
            hourLabel(for: Self.labelTemplateDate)
            hourLabel(for: Self.dayLabelTemplateDate)
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

    /// A non-midnight and a midnight date, for the two forms `hourLabel` can take.
    private static let labelTemplateDate = Calendar.current
        .date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 22)) ?? .distantPast
    private static let dayLabelTemplateDate = Calendar.current
        .date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 0)) ?? .distantPast

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
    private var hourMarkOverscanPoints: CGFloat {
        (axisLabelWidth > 0 ? axisLabelWidth : 56) / 2 + 1
    }

    /// Hour marks for the visible window plus that overscan — not the whole render window,
    /// which is ~9x wider and whose off-screen labels would be pure layout cost. The frame
    /// clips, so the overscanned ones simply slide out of view.
    private var visibleHourMarks: [Date] {
        let overscan = TimeInterval(hourMarkOverscanPoints / viewportWidth) * visibleSeconds
        return MainChartHelper.hourAxisMarks(
            over: scrollPosition.addingTimeInterval(-overscan)
                ... scrollPosition.addingTimeInterval(visibleSeconds + overscan),
            calendar: calendar,
            visibleSeconds: visibleSeconds
        )
    }

    /// Midnight ticks carry the day ("TUE 07") so panned-back history stays unambiguous;
    /// all other ticks show the hour.
    @ViewBuilder private func hourLabel(for date: Date) -> some View {
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

    /// The selection's time: the same axis label the hours use, just showing the scrub's
    /// own time and moving with the indicator. No container — it belongs to the axis, not
    /// to the readout, and a chip here would read as a second floating card.
    ///
    /// Bold is the only difference from an hour label, so it is legible as the live value
    /// while it has the strip to itself. Near a viewport edge it slides just far enough to
    /// stay whole: the label is the one part of the readout that must never be half-cut.
    @ViewBuilder private func selectionTimeLabel(y: CGFloat) -> some View {
        if let selectedGlucose, let selectionDate = selectedGlucose.date {
            let x = xPosition(for: selectionDate)
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

// MARK: - Zoom / pan / inspect gesture handling

extension MainChartView {
    private var isPinching: Bool { pinchAnchor != nil }

    /// Converts a horizontal translation (pt) into a time delta within the visible window.
    private func timeDelta(forTranslation dx: CGFloat) -> TimeInterval {
        TimeInterval(dx / viewportWidth) * visibleSeconds
    }

    /// The date under a given x position (in the viewport's coordinate space).
    private func date(atViewportX x: CGFloat) -> Date {
        let fraction = min(max(x / viewportWidth, 0), 1)
        return scrollPosition.addingTimeInterval(visibleSeconds * TimeInterval(fraction))
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
                    scheduleInspectHold()
                }

                // A touch that has been part of a pinch is spent. Lifting one finger ends the
                // magnify gesture but leaves this drag alive on the other, still carrying
                // everything that finger did *during* the pinch: its travel would be read as
                // a pan the moment the pinch ends, and its speed at lift-off as a fling. The
                // zoom is the gesture; panning starts from a fresh touch — which the reset
                // above recognises, since that touch brings a new `startLocation`.
                guard !touchWasPinching else { return }
                lastTouchLocation = value.location

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
                isInspectLatched = false
                lastTouchLocation = nil
                let wasPanning = panBaseline != nil
                let wasPinching = touchWasPinching
                panBaseline = nil
                touchWasPinching = false
                touchStartLocation = nil
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
        let raw = date(atViewportX: x)
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

    /// Deceleration after a flick. Mutates only `scrollPosition` (a transform), so each
    /// frame costs a GPU translation — the same cost profile as live panning.
    private func startMomentum(velocitySecondsPerSecond initialVelocity: TimeInterval) {
        // Ignore tiny flicks.
        guard abs(initialVelocity) > visibleSeconds * 0.05 else { return }
        momentumTask?.cancel()
        momentumTask = Task { @MainActor in
            var velocity = initialVelocity
            let frameDuration: TimeInterval = 1.0 / 60.0
            let decayPerFrame = 0.97
            while !Task.isCancelled, abs(velocity) > visibleSeconds * 0.02 {
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
                if pinchAnchor == nil {
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

                let drift = MainChartHelper.Config.pinchCommitScaleDrift
                if pinchScale > drift || pinchScale < 1 / drift {
                    commitPinchZoom(proposed)
                }
            }
            .onEnded { _ in
                guard pinchAnchor != nil else { return }
                commitPinchZoom(visibleSeconds / TimeInterval(pinchScale))
                // The commit no-ops when the zoom quantizes back to the
                // current value; the preview must still un-stretch.
                pinchScale = 1
                pinchAnchor = nil
            }
    }

    /// Quantizes to the geometric zoom grid and re-lays the canvas exactly
    /// once: window re-anchor happens in the same transaction, else the
    /// commit first lays out the OLD window at the new zoom (a canvas up to
    /// 12x the viewport) before re-laying at the right size.
    private func commitPinchZoom(_ proposed: TimeInterval) {
        guard let pinch = pinchAnchor else { return }
        let ratio = MainChartHelper.Config.zoomStepRatio
        let step = (log(proposed / MainChartHelper.Config.defaultVisibleSeconds) / log(ratio)).rounded()
        var quantized = MainChartHelper.Config.defaultVisibleSeconds * pow(ratio, step)
        quantized = min(
            max(quantized, MainChartHelper.Config.minVisibleSeconds),
            MainChartHelper.Config.maxVisibleSeconds
        )
        // A no-op commit would just snap the preview back to 1 with no fresh
        // layout to justify it.
        guard quantized != visibleSeconds else { return }

        visibleSeconds = quantized
        scrollPosition = clampedLeadingEdge(
            pinch.anchorDate.addingTimeInterval(-quantized * pinch.anchorFraction)
        )
        updateRenderWindow(force: true)
        pinchScale = 1
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
    var showGlucoseEpisodes: Bool
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

    // The point series sliced to the render window: marks outside the window
    // clip invisibly but still cost layout, so with 72h loaded an unfiltered
    // re-layout (every pinch step) does 3x the work for nothing.
    var windowedGlucose: [GlucoseStored] {
        MainChartHelper.windowSlice(
            state.glucoseFromPersistence,
            from: windowStart, through: windowEnd,
            ascendingInput: true, date: \.date
        )
    }

    /// Excursion markers overlapping the render window. Unlike the point series these are
    /// spans, so an episode that starts before the window — or is still running past its
    /// trailing edge — has to be kept.
    var windowedEpisodes: [GlucoseEpisode] {
        let now = Date()
        return state.glucoseEpisodes.filter { episode in
            episode.start <= windowEnd && episode.displayEnd(asOf: now) >= windowStart
        }
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

// MARK: - Main (glucose) chart pane

extension MainChartCanvas {
    var mainChart: some View {
        // slice each series once per layout; these were computed properties
        // re-evaluated on every reference (glucose alone was scanned 3x)
        let glucose = windowedGlucose

        return Chart {
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

            GlucoseChartView(
                glucoseData: glucose,
                units: state.units,
                highGlucose: state.highGlucose,
                lowGlucose: state.lowGlucose,
                currentGlucoseTarget: state.currentGlucoseTarget,
                isSmoothingEnabled: state.isSmoothingEnabled,
                glucoseColorScheme: state.glucoseColorScheme
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

            if showGlucoseEpisodes {
                GlucoseEpisodeView(
                    episodes: windowedEpisodes,
                    units: state.units,
                    highGlucose: state.highGlucose,
                    lowGlucose: state.lowGlucose,
                    currentGlucoseTarget: state.currentGlucoseTarget,
                    glucoseColorScheme: state.glucoseColorScheme,
                    maxYAxisValue: state.maxYAxisValue,
                    historyStart: state.startMarker,
                    visibleSeconds: visibleSeconds
                )
            }
        }
        .frame(width: canvasWidth, height: mainHeight)
        .chartXScale(domain: windowStart ... windowEnd)
        .chartXAxis { mainChartXAxis }
        .chartYAxis(.hidden)
        .chartYScale(domain: glucoseYDomain)
        .chartLegend(.hidden)
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
            lhs.showGlucoseEpisodes == rhs.showGlucoseEpisodes &&
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
