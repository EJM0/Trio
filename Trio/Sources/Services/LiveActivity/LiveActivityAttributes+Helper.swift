import Foundation

extension UserDefaults {
    private enum Keys {
        static let liveActivityOrder = "liveActivityOrder"
    }

    func loadLiveActivityOrderFromUserDefaults() -> [LiveActivityAttributes.LiveActivityItem]? {
        if let itemStrings = stringArray(forKey: Keys.liveActivityOrder) {
            return itemStrings.map { string in
                if string == "" {
                    return .empty
                } else {
                    return LiveActivityAttributes.LiveActivityItem(rawValue: string) ?? .empty
                }
            }
        }
        return nil
    }
}

extension LiveActivityAttributes.SimpleViewStyle {
    init(settings: TrioSettings) {
        self.init(fontSize: settings.liveActivitySimpleFontSize)
    }
}

extension LiveActivityAttributes.ContentState {
    static func calculateChange(chart: [GlucoseData], units: GlucoseUnits) -> String {
        guard chart.count >= 2 else { return "" }

        let lastGlucose = Decimal(chart.first?.glucose ?? 0)
        let secondLastGlucose = Decimal(chart.dropFirst().first?.glucose ?? 0)
        return (lastGlucose - secondLastGlucose).formattedDelta(for: units)
    }

    /// Chart spacings to try, closest first, until an update fits in Apple's 4 KB.
    static let chartSpacings: [TimeInterval] = [4 * 60, 9 * 60, 14 * 60, 29 * 60]

    /// The readings, newest first, at least `spacing` apart: one per CGM interval, without the doubles a sensor read by
    /// two devices or a backfill can leave.
    static func thinned(_ chart: [GlucoseData], spacing: TimeInterval) -> [GlucoseData] {
        var kept: [GlucoseData] = []
        for reading in chart.sorted(by: { $0.date > $1.date }) {
            if let last = kept.last, last.date.timeIntervalSince(reading.date) < spacing { continue }
            kept.append(reading)
        }
        return kept
    }

    init(
        new bg: GlucoseData,
        prev _: GlucoseData?,
        units: GlucoseUnits,
        chart: [GlucoseData],
        settings: TrioSettings,
        determination: DeterminationData?,
        iob: Decimal?,
        override: OverrideData?,
        tempTarget: TempTargetData?,
        widgetItems: [LiveActivityAttributes.LiveActivityItem]?,
        chartSpacing: TimeInterval = Self.chartSpacings[0]
    ) {
        let glucose = bg.glucose
        let formattedBG = glucose.formatted(for: units)
        var rotationDegrees = 0.0

        switch bg.direction {
        case .doubleUp,
             .singleUp,
             .tripleUp:
            rotationDegrees = -90
        case .fortyFiveUp:
            rotationDegrees = -45
        case .flat:
            rotationDegrees = 0
        case .fortyFiveDown:
            rotationDegrees = 45
        case .doubleDown,
             .singleDown,
             .tripleDown:
            rotationDegrees = 90
        case nil,
             .notComputable,
             .rateOutOfRange:
            rotationDegrees = 0
        default:
            rotationDegrees = 0
        }

        let trendString = bg.direction?.symbol as? String
        let change = Self.calculateChange(chart: chart, units: units)

        let detailedState = LiveActivityAttributes.ContentAdditionalState(
            chart: Self.thinned(chart, spacing: chartSpacing).map {
                // whole seconds: the fractions only take up room in the 4 KB an update may have
                LiveActivityAttributes.ChartItem(
                    value: Decimal($0.glucose),
                    date: Date(timeIntervalSinceReferenceDate: $0.date.timeIntervalSinceReferenceDate.rounded())
                )
            },
            rotationDegrees: rotationDegrees,
            cob: Decimal(determination?.cob ?? 0),
            iob: iob ?? 0 as Decimal,
            tdd: determination?.tdd ?? 0 as Decimal,
            isOverrideActive: override?.isActive ?? false,
            overrideName: override?.overrideName ?? "Override",
            overrideDate: override?.date ?? Date(),
            overrideDuration: override?.duration ?? 0,
            overrideTarget: override?.target ?? 0,
            isTempTargetActive: tempTarget?.isActive ?? false,
            tempTargetName: tempTarget?.tempTargetName ?? "Temp Target",
            tempTargetDate: tempTarget?.date ?? Date(),
            tempTargetDuration: tempTarget?.duration ?? 0,
            tempTargetTarget: tempTarget?.target ?? 0,
            widgetItems: widgetItems ?? [], // set empty array here to silence compiler; this can never be nil
            minForecast: settings.displayGlucoseForecasts && settings.forecastDisplayType == .cone
                ? (determination?.minForecast ?? []) : [],
            maxForecast: settings.displayGlucoseForecasts && settings.forecastDisplayType == .cone
                ? (determination?.maxForecast ?? []) : [],
            forecastLines: settings.displayGlucoseForecasts && settings.forecastDisplayType == .lines
                ? (determination?.forecastLines ?? [])
                .map { LiveActivityAttributes.ForecastLine(type: $0.type, values: $0.values) }
                : [],
            forecastDisplayType: settings.forecastDisplayType.rawValue
        )

        self.init(
            unit: settings.units.rawValue,
            bg: formattedBG,
            glucose: Decimal(glucose),
            direction: trendString,
            change: change,
            date: determination?.date ?? nil,
            highGlucose: settings.high,
            lowGlucose: settings.low,
            target: determination?.target ?? 100 as Decimal,
            glucoseColorScheme: settings.glucoseColorScheme.rawValue,
            useDetailedViewIOS: settings.lockScreenView == .detailed,
            useDetailedViewWatchOS: settings.smartStackView == .detailed,
            simpleViewStyle: LiveActivityAttributes.SimpleViewStyle(settings: settings),
            detailedViewState: detailedState,
            isInitialState: false
        )
    }
}

extension LiveActivityAttributes.ContentState {
    /// iOS drops an update whose data is over 4 KB without an error, and the activity keeps its first state ("Live
    /// Activity Expired"). The margin is for what iOS adds.
    static let updateLimit = 3800

    var encodedSize: Int { (try? JSONEncoder().encode(self).count) ?? .max }
    var fitsUpdateLimit: Bool { encodedSize <= Self.updateLimit }

    /// The first state that fits, trying the chart spacings closest first; the sparsest one if none does.
    static func fitting(_ make: (TimeInterval) -> Self) -> Self {
        var content = make(chartSpacings[0])
        for spacing in chartSpacings.dropFirst() where !content.fitsUpdateLimit {
            content = make(spacing)
        }
        return content
    }
}
