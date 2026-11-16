import Foundation

/// Which configured glucose alarms fire or retract for a reading or a determination, given the
/// alarms already firing. `GlucoseAlertCoordinator` issues and retracts the alerts it returns.
enum GlucoseAlarmEvaluation {
    enum Action: Equatable {
        case fire(GlucoseAlert, valueMgDL: Decimal)
        case retract(GlucoseAlert)
    }

    /// 5 mg/dL recovery margin before we retract a fired alert. Prevents flap
    /// at the threshold boundary.
    static let recoveryMarginMgDL: Decimal = 5

    /// Readings older than this are considered stale and won't drive new
    /// alarms — matches `APSManager`'s loop-input freshness gate (12 min,
    /// allowing for one missed CGM transmission on a 5-min schedule).
    /// Without this gate, force-quitting the app and reopening it after a
    /// CGM blackout could fire an alarm based on a 19-min-old reading.
    static let readingFreshnessWindow: TimeInterval = 12 * 60

    /// Pure breach predicate. Low family (low/urgentLow/forecastedLow) breaches
    /// when the value is at or below threshold; high breaches at or above.
    /// `carbsRequired` is determination-driven and evaluated separately.
    static func breached(type: GlucoseAlertType, latestMgDL: Decimal, thresholdMgDL: Decimal) -> Bool {
        switch type {
        case .forecastedLow,
             .low,
             .urgentLow:
            return latestMgDL <= thresholdMgDL
        case .high:
            return latestMgDL >= thresholdMgDL
        case .carbsRequired:
            return false
        }
    }

    /// Pure retract predicate. A fired low-family alert retracts once the value
    /// recovers to threshold + margin; a high alert once it falls to
    /// threshold - margin.
    static func shouldRetract(
        type: GlucoseAlertType,
        latestMgDL: Decimal,
        thresholdMgDL: Decimal,
        recoveryMarginMgDL: Decimal = recoveryMarginMgDL
    ) -> Bool {
        switch type {
        case .forecastedLow,
             .low,
             .urgentLow:
            return latestMgDL >= thresholdMgDL + recoveryMarginMgDL
        case .high:
            return latestMgDL <= thresholdMgDL - recoveryMarginMgDL
        case .carbsRequired:
            return false
        }
    }

    /// Urgent low, low and high alarms for the latest reading. Updates `firing`.
    static func evaluateReading(
        latestMgDL: Decimal,
        alarms: [GlucoseAlert],
        configuration: GlucoseAlertConfiguration,
        firing: inout Set<UUID>,
        now: Date,
        calendar: Calendar = .current
    ) -> [Action] {
        var actions: [Action] = []
        // Iterate in type priority order so we can suppress lesser low-family
        // alarms when a more severe one is firing (urgent low > low). Without
        // this, glucose=60 with both urgent-low (54) AND low (70) configured
        // would surface two in-app alerts for the same low event.
        let sorted = alarms.sorted { $0.type.priority < $1.type.priority }
        var urgentLowFiring = false
        for alarm in sorted where alarm.type.isReadingDriven {
            if alarm.type == .low, urgentLowFiring {
                retractIfFiring(alarm, firing: &firing, actions: &actions)
                continue
            }
            if isEligible(alarm, at: now, configuration: configuration, calendar: calendar) {
                if breached(type: alarm.type, latestMgDL: latestMgDL, thresholdMgDL: alarm.thresholdMgDL) {
                    fireIfNeeded(alarm, valueMgDL: latestMgDL, firing: &firing, actions: &actions)
                } else if shouldRetract(type: alarm.type, latestMgDL: latestMgDL, thresholdMgDL: alarm.thresholdMgDL) {
                    retractIfFiring(alarm, firing: &firing, actions: &actions)
                }
            } else {
                retractIfFiring(alarm, firing: &firing, actions: &actions)
            }
            if alarm.type == .urgentLow, firing.contains(alarm.id) {
                urgentLowFiring = true
            }
        }
        return actions
    }

    /// Forecasted-low alarms for a determination's forecast. Updates `firing`.
    static func evaluateForecast(
        _ determination: Determination,
        alarms: [GlucoseAlert],
        configuration: GlucoseAlertConfiguration,
        firing: inout Set<UUID>,
        now: Date,
        calendar: Calendar = .current
    ) -> [Action] {
        var actions: [Action] = []
        // Suppress forecasted-low if any urgent-low or low alarm is already
        // firing — the forecast came true (or worse), no point preempting
        // it with a second alert.
        let lowFamilyFiring = alarms.contains { alarm in
            (alarm.type == .urgentLow || alarm.type == .low) && firing.contains(alarm.id)
        }
        let forecast = ForecastedGlucoseEvaluator.evaluate(determination: determination)

        for alarm in alarms where alarm.type == .forecastedLow {
            guard !lowFamilyFiring,
                  isEligible(alarm, at: now, configuration: configuration, calendar: calendar),
                  let forecast
            else {
                retractIfFiring(alarm, firing: &firing, actions: &actions)
                continue
            }
            if forecast.predictedGlucose <= alarm.thresholdMgDL {
                fireIfNeeded(alarm, valueMgDL: forecast.predictedGlucose, firing: &firing, actions: &actions)
            } else if shouldRetract(type: alarm.type, latestMgDL: forecast.predictedGlucose, thresholdMgDL: alarm.thresholdMgDL) {
                retractIfFiring(alarm, firing: &firing, actions: &actions)
            }
        }
        return actions
    }

    /// Carbs-required alarms for a determination's `carbsReq` (grams; the threshold is stored in
    /// `thresholdMgDL`). Updates `firing`.
    static func evaluateCarbsRequired(
        _ carbsRequired: Decimal?,
        alarms: [GlucoseAlert],
        configuration: GlucoseAlertConfiguration,
        firing: inout Set<UUID>,
        now: Date,
        calendar: Calendar = .current
    ) -> [Action] {
        var actions: [Action] = []
        for alarm in alarms where alarm.type == .carbsRequired {
            guard isEligible(alarm, at: now, configuration: configuration, calendar: calendar),
                  let carbsRequired, carbsRequired >= alarm.thresholdMgDL
            else {
                retractIfFiring(alarm, firing: &firing, actions: &actions)
                continue
            }
            fireIfNeeded(alarm, valueMgDL: carbsRequired, firing: &firing, actions: &actions)
        }
        return actions
    }

    /// Enabled (urgent low always is), not snoozed, and inside its day or night window.
    static func isEligible(
        _ alarm: GlucoseAlert,
        at date: Date,
        configuration: GlucoseAlertConfiguration,
        calendar: Calendar
    ) -> Bool {
        guard alarm.shouldEvaluate else { return false }
        if let until = alarm.snoozedUntil, until > date { return false }
        switch alarm.activeOption {
        case .always: return true
        case .day: return !configuration.isNight(at: date, calendar: calendar)
        case .night: return configuration.isNight(at: date, calendar: calendar)
        }
    }

    private static func fireIfNeeded(
        _ alarm: GlucoseAlert,
        valueMgDL: Decimal,
        firing: inout Set<UUID>,
        actions: inout [Action]
    ) {
        guard firing.insert(alarm.id).inserted else { return }
        actions.append(.fire(alarm, valueMgDL: valueMgDL))
    }

    private static func retractIfFiring(_ alarm: GlucoseAlert, firing: inout Set<UUID>, actions: inout [Action]) {
        guard firing.remove(alarm.id) != nil else { return }
        actions.append(.retract(alarm))
    }
}
