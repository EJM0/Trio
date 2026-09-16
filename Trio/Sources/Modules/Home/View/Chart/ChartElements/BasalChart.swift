import Charts
import Foundation
import SwiftUI

struct BasalProfile: Hashable {
    let amount: Double
    var isOverwritten: Bool
    let startDate: Date
    let endDate: Date?
    init(amount: Double, isOverwritten: Bool, startDate: Date, endDate: Date? = nil) {
        self.amount = amount
        self.isOverwritten = isOverwritten
        self.startDate = startDate
        self.endDate = endDate
    }
}

extension MainChartCanvas {
    var basalChart: some View {
        VStack {
            Chart {
                drawCurrentTimeMarker()
                drawTempBasals()
                drawBasalProfile()
                drawSuspensions()
            }.onChange(of: state.tempBasals) {
                calculateBasals()
                calculateTempBasals()
            }
            .onChange(of: state.maxBasal) {
                calculateBasals()
            }
            .onChange(of: state.basalProfile) {
                calculateBasals()
            }
            .frame(width: canvasWidth, height: basalHeight)
            .chartXScale(domain: windowStart ... windowEnd)
            .chartXAxis { mainChartXAxis } // grid lines only; hour labels render once, on the bottom pane
            .chartYAxis(.hidden)
            .chartYScale(domain: 0 ... basalDomainMax)
        }
    }

    /// Upper bound of the basal chart's y-domain. The bars hang from the top of the plot
    /// (drawn at `basalDomainMax - rate`), so the tallest rate spans the full strip height —
    /// matching the old rendering, which achieved the same look by rotating and mirroring
    /// the plot content.
    var basalDomainMax: Double {
        let tempMax = preparedTempBasals.map(\.rate).max() ?? 0
        let profileMax = basalProfiles.map(\.amount).max() ?? 0
        return max(tempMax, profileMax, 0.1)
    }
}

// MARK: - Draw functions

extension MainChartCanvas {
    func drawTempBasals() -> some ChartContent {
        // only bars overlapping the render window; the rest clip invisibly but still cost layout
        let visible = preparedTempBasals.filter { $0.end >= windowStart && $0.start <= windowEnd }
        // Hoisted, like the windowed series in `mainChart`: `basalDomainMax` scans both rate
        // arrays and allocates two of them per call, and the loop below asked for it four
        // times per bar — once directly and three times through the `invertedY` helper this
        // replaces. Top-anchored y is `domainMax - rate`; the bars hang from the plot's top.
        let domainMax = basalDomainMax
        // One stroked outline per contiguous run, rather than one for the whole strip. Left as a
        // single series, the line also spans the gaps *between* bars — a stretch nothing covered,
        // such as a suspension — and Swift Charts joins the two ends across it with a diagonal
        // ramp, as though the rate had slid from one level to the other. Bars that do abut stay
        // in the same run, so their join remains the vertical step it has always been.
        // A gap only breaks the outline when it is wide enough to see. Measured in points rather
        // than in seconds: bars can sit seconds apart and still land on the same pixel column, and
        // splitting those left each side closing on the baseline — a stroke up and straight back
        // down, reading as a seam between two bars that belong together.
        let secondsPerPoint = windowEnd.timeIntervalSince(windowStart) / Double(max(canvasWidth, 1))
        return ForEach(contiguousBasalRuns(visible, minimumGap: secondsPerPoint * Self.visibleGapPoints)) { run in
            ForEach(run.bars, id: \.start) { basal in
                let y = domainMax - basal.rate
                RectangleMark(
                    xStart: .value("start", basal.start),
                    xEnd: .value("end", basal.end),
                    yStart: .value("rate-start", domainMax),
                    yEnd: .value("rate-end", y)
                ).foregroundStyle(
                    .linearGradient(
                        colors: [
                            Color.insulin.opacity(0.6),
                            Color.insulin.opacity(0.1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                ).alignsMarkStylesWithPlotArea()
                    .opacity(basal.isScheduled ? 0.5 : 1)
            }

            // The run's outline, walked as one line: down from the zero baseline at the leading
            // edge, across each bar's top, and back up to the baseline at the trailing edge.
            // The two baseline points are what draw the side strokes on the first and last bar;
            // without them a run begins and ends in mid-air and only its top shows.
            ForEach(run.outlinePoints(baseline: domainMax)) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Amount", point.y),
                    series: .value("basal run", run.id)
                )
                .lineStyle(.init(lineWidth: 1)).foregroundStyle(Color.insulin)
                .opacity(point.opacity)
            }
        }
    }

    /// How wide a gap has to be, in points, before it breaks the outline. Below one point there
    /// is no column left to draw the break in, and the bars either side are touching on screen.
    static var visibleGapPoints: Double { 1 }

    /// One point of a run's stroked outline.
    struct BasalOutlinePoint: Identifiable {
        let id: String
        let date: Date
        let y: Double
        /// Taken from the bar the point belongs to, so an inferred scheduled stretch keeps the
        /// dimmed stroke it has always had.
        let opacity: Double
    }

    /// A stretch of basal bars that abut one another end-to-start, and so belong to one outline.
    struct BasalRun: Identifiable {
        let id: String
        let bars: [(start: Date, end: Date, rate: Double, isScheduled: Bool)]

        /// The outline as the points one stroked line walks, in x order.
        ///
        /// `baseline` is the y of a zero rate — the top of the strip, since the bars hang from
        /// it. Closing on it at both ends is what gives the outer bars their vertical sides; the
        /// ones in between get theirs from the step between two neighbours.
        func outlinePoints(baseline: Double) -> [BasalOutlinePoint] {
            guard let first = bars.first, let last = bars.last else { return [] }

            var points: [BasalOutlinePoint] = []
            points.reserveCapacity(bars.count * 2 + 2)

            func append(_ date: Date, _ y: Double, _ opacity: Double) {
                points.append(BasalOutlinePoint(id: "\(id)-\(points.count)", date: date, y: y, opacity: opacity))
            }

            append(first.start, baseline, first.isScheduled ? 0.5 : 1)
            for bar in bars {
                let y = baseline - bar.rate
                let opacity = bar.isScheduled ? 0.5 : 1
                append(bar.start, y, opacity)
                append(bar.end, y, opacity)
            }
            append(last.end, baseline, last.isScheduled ? 0.5 : 1)

            return points
        }
    }

    /// Splits the sorted bars into runs, breaking wherever one bar's end does not meet the next
    /// one's start.
    ///
    /// `calculateTempBasals` already sweeps the pump's schedule into every gap it can infer, so a
    /// break here means a stretch nothing covered at all — a suspension, or a window the pump
    /// reported nothing for. Those are exactly the places the outline must not be drawn across.
    ///
    /// `minimumGap` is what counts as a break, in seconds — derived from the current zoom, so a
    /// gap too narrow to render keeps its bars in one run rather than closing both sides on the
    /// baseline. Overlapping bars give a negative interval and stay in the same run either way.
    func contiguousBasalRuns(
        _ bars: [(start: Date, end: Date, rate: Double, isScheduled: Bool)],
        minimumGap: TimeInterval
    ) -> [BasalRun] {
        var runs: [BasalRun] = []
        var current: [(start: Date, end: Date, rate: Double, isScheduled: Bool)] = []

        func closeRun() {
            guard let first = current.first else { return }
            runs.append(BasalRun(id: "basal-\(first.start.timeIntervalSince1970)", bars: current))
            current = []
        }

        for bar in bars {
            if let last = current.last, bar.start.timeIntervalSince(last.end) > minimumGap { closeRun() }
            current.append(bar)
        }
        closeRun()
        return runs
    }

    func drawBasalProfile() -> some ChartContent {
        /// dashed profile line
        let visible = basalProfiles.filter { ($0.endDate ?? state.endMarker) >= windowStart && $0.startDate <= windowEnd }
        let domainMax = basalDomainMax
        return ForEach(visible, id: \.self) { profile in
            let y = domainMax - profile.amount
            LineMark(
                x: .value("Start Date", profile.startDate),
                y: .value("Amount", y),
                series: .value("profile", "profile")
            ).lineStyle(.init(lineWidth: 2, dash: [2, 4])).foregroundStyle(Color.insulin)
            LineMark(
                x: .value("End Date", profile.endDate ?? state.endMarker),
                y: .value("Amount", y),
                series: .value("profile", "profile")
            ).lineStyle(.init(lineWidth: 2.5, dash: [2, 4])).foregroundStyle(Color.insulin)
        }
    }

    /// Suspend→resume intervals resolved once, so the mark loop does no per-mark lookups.
    private func suspensionIntervals() -> [(start: Date, end: Date, height: Double)] {
        let suspensions = state.suspendAndResumeEvents
        let now = Date()
        var intervals = [(start: Date, end: Date, height: Double)]()

        for suspension in suspensions {
            guard suspension.type == EventType.pumpSuspend.rawValue, let suspensionStart = suspension.timestamp else {
                continue
            }
            let suspensionEnd = min(
                suspensions.first(where: {
                    $0.timestamp ?? now > suspensionStart && $0.type == EventType.pumpResume.rawValue
                })?.timestamp ?? now,
                now
            )
            let basalProfileDuringSuspension = basalProfiles.first(where: { $0.startDate <= suspensionStart })
            // Clamp to the explicit y-domain: the fallback height of 1 U/hr can exceed
            // `basalDomainMax` when no profile data is available, and unlike the old
            // auto-scaled (flipped) plot, an explicit domain would clip the mark.
            let height = min(basalProfileDuringSuspension?.amount ?? 1, basalDomainMax)
            intervals.append((suspensionStart, suspensionEnd, height))
        }
        return intervals
    }

    func drawSuspensions() -> some ChartContent {
        let visible = suspensionIntervals().filter { $0.end >= windowStart && $0.start <= windowEnd }
        let domainMax = basalDomainMax
        return ForEach(visible, id: \.start) { interval in
            RectangleMark(
                xStart: .value("start", interval.start),
                xEnd: .value("end", interval.end),
                yStart: .value("suspend-start", domainMax),
                yEnd: .value("suspend-end", domainMax - interval.height)
            )
            .foregroundStyle(Color.loopGray.opacity(colorScheme == .dark ? 0.3 : 0.8))
        }
    }
}

// MARK: - Calculation

extension MainChartCanvas {
    @MainActor func calculateTempBasals() {
        let now = Date()
        let suspensionTimes = state.suspendAndResumeEvents.compactMap(\.timestamp)

        // Snapshot the managed-object fields once; plain values from here on.
        let events = state.tempBasals.map {
            (
                timestamp: $0.timestamp,
                duration: $0.tempBasal?.duration ?? 0,
                rate: $0.tempBasal?.rate,
                isScheduled: $0.tempBasal?.isScheduledBasal ?? false
            )
        }

        // A scheduled-basal row marks a schedule change, not a delivery change: the pump logs one
        // whenever its schedule is reprogrammed, which Trio itself triggers on saving a basal
        // profile — even mid temp basal. Such a row must neither draw a bar nor clip the temp basal
        // that is actually delivering, so only real delivery events lay out bars. The sweep below
        // paints what no temp basal covered.
        let deliveryEvents = events.filter { !$0.isScheduled }

        var prepared = [(start: Date, end: Date, rate: Double, isScheduled: Bool)]()
        prepared.reserveCapacity(deliveryEvents.count)

        for (index, event) in deliveryEvents.enumerated() {
            let timestamp = event.timestamp ?? now
            let end = timestamp + event.duration.minutes

            // Start of the next later-starting temp basal, which supersedes this one.
            var next = index + 1
            while next < deliveryEvents.count {
                if let nextStart = deliveryEvents[next].timestamp, nextStart > timestamp { break }
                next += 1
            }
            let nextStart = next < deliveryEvents.count ? deliveryEvents[next].timestamp : nil

            // A temp basal ends at its own scheduled end, or earlier where a later one superseded
            // it. Stretching it to the next event would paint the temp rate over a span the pump
            // ran its schedule; that span is swept below instead.
            let barEnd = nextStart.map { min(end, $0) } ?? end

            let isInsulinSuspended = suspensionTimes.contains { $0 >= timestamp && $0 <= barEnd }
            let rate = Double(truncating: event.rate ?? 0) * (isInsulinSuspended ? 0 : 1)

            prepared.append((timestamp, barEnd, rate, false))
        }

        // gaps no event covers ran the pump's schedule; inferred in memory, drawn dimmed
        var timeline = prepared.map {
            ScheduledBasalInference.TimelineEvent(start: $0.start, end: $0.end, kind: .tempBasal)
        }
        // A schedule change covers nothing, but it does tell us the pump was reporting: without it
        // an open-loop window holding only scheduled rows would have no anchor and sweep to nothing.
        timeline += events.filter(\.isScheduled).compactMap { event in
            event.timestamp.map { ScheduledBasalInference.TimelineEvent(start: $0, kind: .tempBasal) }
        }
        timeline += state.suspendAndResumeEvents.compactMap { event -> ScheduledBasalInference.TimelineEvent? in
            guard let timestamp = event.timestamp else { return nil }
            let isSuspend = event.type == PumpEventStored.EventType.pumpSuspend.rawValue
            return ScheduledBasalInference.TimelineEvent(start: timestamp, kind: isSuspend ? .suspend : .resume)
        }
        for segment in ScheduledBasalInference.segments(events: timeline, profile: state.basalProfile, now: now) {
            prepared.append((segment.start, segment.end, Double(truncating: segment.rate as NSNumber), true))
        }

        // One line series strokes the whole outline: out-of-order bars backtrack across it,
        // and a zero-length bar leaves a stray point it then connects diagonally.
        preparedTempBasals = prepared
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
    }

    func findRegularBasalPoints(
        timeBegin: TimeInterval,
        timeEnd: TimeInterval
    ) async -> [BasalProfile] {
        guard timeBegin < timeEnd else { return [] }

        let beginDate = Date(timeIntervalSince1970: timeBegin)
        let endDate = Date(timeIntervalSince1970: timeEnd)
        let calendar = Calendar.current
        let profile = state.basalProfile
        var basalPoints: [BasalProfile] = []
        var lastEntryBeforeRange: (amount: Double, date: Date)?

        // Repeat the daily schedule over every calendar day the range touches. A fixed day
        // count would run out before the end of the chart's domain, which reaches back
        // `chartHistorySeconds` and forward to the end of the forecast, and the profile line
        // would then stop short of the chart's edge. Stepping by calendar day (rather than by
        // 86400 s) keeps the schedule anchored to local midnight across DST changes.
        var dayStart = calendar.startOfDay(for: beginDate)
        while dayStart <= endDate {
            defer { dayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? endDate.addingTimeInterval(1) }

            for entry in profile {
                let basalTime = dayStart.addingTimeInterval(entry.minutes.minutes.timeInterval)
                let basalTimeInterval = basalTime.timeIntervalSince1970

                if basalTimeInterval < timeBegin {
                    // Track the last profile entry before the visible range
                    if lastEntryBeforeRange == nil || basalTime > lastEntryBeforeRange!.date {
                        lastEntryBeforeRange = (amount: Double(entry.rate), date: basalTime)
                    }
                } else if basalTimeInterval < timeEnd {
                    basalPoints.append(BasalProfile(
                        amount: Double(entry.rate),
                        isOverwritten: false,
                        startDate: basalTime
                    ))
                }
            }
        }

        // Include the active profile entry at timeBegin so the line starts at the chart's left edge
        if let lastBefore = lastEntryBeforeRange {
            basalPoints.append(BasalProfile(
                amount: lastBefore.amount,
                isOverwritten: false,
                startDate: beginDate
            ))
        }

        return basalPoints
    }

    func calculateBasals() {
        Task {
            // Span the chart's whole domain, not just the last 24 h: the domain reaches back
            // `chartHistorySeconds`, and anything shorter leaves the profile line missing over
            // the older part of the chart once it is scrolled into view.
            async let getRegularBasalPoints = findRegularBasalPoints(
                timeBegin: state.startMarker.timeIntervalSince1970,
                timeEnd: state.endMarker.timeIntervalSince1970
            )

            var regularPoints = await getRegularBasalPoints
            regularPoints.sort { $0.startDate < $1.startDate }

            var basals: [BasalProfile] = []

            // No basal data? Then there's nothing to draw
            if regularPoints.isEmpty {
                // basals stays empty; do nothing
            }
            // Exactly one data point?
            else if regularPoints.count == 1 {
                let single = regularPoints[0]
                // Make one BasalProfile that stretches entire marker area
                basals.append(
                    BasalProfile(
                        amount: single.amount,
                        isOverwritten: single.isOverwritten,
                        startDate: state.startMarker,
                        endDate: state.endMarker
                    )
                )
            }
            // Multiple data points: chain them so each point ends where the next begins
            else {
                for i in 0 ..< (regularPoints.count - 1) {
                    basals.append(
                        BasalProfile(
                            amount: regularPoints[i].amount,
                            isOverwritten: regularPoints[i].isOverwritten,
                            startDate: regularPoints[i].startDate,
                            endDate: regularPoints[i + 1].startDate
                        )
                    )
                }
                // The last item goes from its start to endMarker
                if let lastItem = regularPoints.last {
                    basals.append(
                        BasalProfile(
                            amount: lastItem.amount,
                            isOverwritten: lastItem.isOverwritten,
                            startDate: lastItem.startDate,
                            endDate: state.endMarker
                        )
                    )
                }
            }

            await MainActor.run {
                basalProfiles = basals
            }
        }
    }
}
