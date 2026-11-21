import SwiftUI

/// What the Trio on Watch screens show. Built from the loan host (`WatchLoanHost.uiStatus()`), or fixed for previews.
struct TrioOnWatchStatus: Equatable {
    enum Phase: Equatable {
        case phone
        case starting
        /// Holding the pump, before the watch's first own sensor reading (V3-8).
        case waitingForReading
        case inControl
        case ending
        case stopped(WatchStopReason)
    }

    struct Reading: Equatable {
        var date: Date
        var mgdl: Int
        /// The sensor's trend, as a `BloodGlucose.Direction` raw value.
        var direction: String? = nil
    }

    struct Preset: Equatable, Identifiable {
        var id: String
        var name: String
    }

    struct Adjustment: Equatable {
        var name: String?
        var endsAt: Date?
    }

    struct Dose: Equatable {
        var date: Date
        var units: Decimal
        var isAutomatic: Bool
        var isUnconfirmed = false
    }

    var phase: Phase = .phone
    var phoneReachable = true
    /// The last cycle that confirmed the pump's state.
    var lastLoopAt: Date?
    var lastCycleAt: Date?
    var readings: [Reading] = []
    var units: GlucoseUnits = .mgdL
    var iob: Decimal?
    var cob: Decimal?
    var tempBasalRate: Decimal?
    var tempBasalEndsAt: Date?
    var eventualGlucose: Int?
    /// The last determination's reasoning.
    var reason: String?
    var pumpLastContact: Date?
    var reservoir: Double?
    /// An Omnipod reports its reservoir only below 50 U; above that it is shown as 50+, as on the phone.
    var reservoirAboveReadingLimit = false
    var podEndsAt: Date?
    var podFaulted = false
    var podUnreachable = false
    var insulinSuspended = false
    /// A command the pump hasn't confirmed: boluses, SMBs and high temps wait, and End is refused.
    var insulinPaused = false
    var sensorEndsAt: Date?
    /// The watch has no key for the sensor yet and pairs at the next connection.
    var sensorNeedsPairing = false
    var battery: Float?
    var override: Adjustment?
    var tempTarget: Adjustment?
    /// The phone's presets the watch can start.
    var overridePresets: [Preset] = []
    var tempTargetPresets: [Preset] = []
    var recentDoses: [Dose] = []
    var bolus: WatchLoanHost.BolusProgress = .idle
    var lastAlert: LoanAlert?

    /// The trend of the watch's latest reading while it is fresh; nil hides the arrow.
    func trend(now: Date) -> String? {
        guard let latest = readings.first, now.timeIntervalSince(latest.date) <= TrioOnWatchRules.readingMaxAge else {
            return nil
        }
        return latest.direction
    }

    /// The watch gives insulin; the treatment buttons talk to the watch, not the phone.
    var isInControl: Bool { phase == .inControl }
    /// Anything but the tethered remote: the main page reads the watch's own values.
    var isLoanActive: Bool { phase != .phone }
}

// MARK: - Shared rules

enum TrioOnWatchRules {
    /// iOS `LoopView.ringColor` grace and thresholds.
    static let loopLag: TimeInterval = 30
    /// A reading older than this shows "--" (iOS `CurrentGlucoseView`).
    static let readingMaxAge: TimeInterval = 12 * 60
    /// Pod or sensor ending sooner than this is called out at Start (V2-26).
    static let endingSoon: TimeInterval = 6 * 60 * 60
    /// The battery row shows only below the Start threshold (G-16).
    static let batteryShownBelow: Float = 0.3

    enum Tier: Equatable {
        case unknown
        case fresh
        case aging
        case stale
        /// A pump condition, not a loop age.
        case warning

        var color: Color {
            switch self {
            case .unknown: return .secondary
            case .fresh: return .loopGreen
            case .aging: return .loopYellow
            case .stale: return .loopRed
            case .warning: return .orange
            }
        }
    }

    /// Reading age: green to 6 min, yellow to 12, red beyond.
    static func readingTier(lastReadingAt: Date?, now: Date) -> Tier {
        guard let lastReadingAt else { return .unknown }
        let age = now.timeIntervalSince(lastReadingAt)
        if age <= 6 * 60 { return .fresh }
        return age <= readingMaxAge ? .aging : .stale
    }

    /// Loop age as iOS colours its ring: green to 5 min, yellow to 10, red beyond, after a 30 s grace.
    static func loopTier(lastLoopAt: Date?, now: Date) -> Tier {
        guard let lastLoopAt else { return .unknown }
        let delta = now.timeIntervalSince(lastLoopAt) - loopLag
        if delta <= 5 * 60 { return .fresh }
        if delta <= 10 * 60 { return .aging }
        return .stale
    }

    static func insulin(_ units: Decimal) -> String {
        WatchLoanAlerts.insulin(units)
    }

    static func timeLeft(until date: Date, now: Date) -> String {
        Duration.seconds(max(0, date.timeIntervalSince(now))).formattedTimeSpan(.largestTwoUnits)
    }

    static func spokenTimeLeft(until date: Date, now: Date) -> String {
        Duration.seconds(max(0, date.timeIntervalSince(now))).formattedSpokenTimeSpan(.largestTwoUnits)
    }
}

// MARK: - Control line (W1)

extension TrioOnWatchStatus {
    struct ControlLine: Equatable {
        var symbol: String
        var text: String
        var tier: TrioOnWatchRules.Tier
        var accessibilityLabel: String
    }

    /// `phoneLoopText` is the phone's own "N min" from the tethered snapshot, shown while the phone is in control.
    func controlLine(now: Date, phoneLoopText: String?) -> ControlLine {
        switch phase {
        case .phone:
            // the tethered snapshot carries "N min"; shown in the "3m" style of every other age (G-R3)
            let loopAt = phoneLoopText?.split(separator: " ").first.flatMap { Int($0) }
                .map { now.addingTimeInterval(-Double($0) * 60) }
            let age = loopAt?.formattedTimeAgo() ?? "--"
            return ControlLine(
                symbol: "iphone",
                text: String(
                    localized: "iPhone · \(age)",
                    comment: "Watch control line: the phone is in control, then its loop age"
                ),
                tier: .unknown,
                accessibilityLabel: loopAt.map {
                    String(
                        localized: "iPhone is in control, last loop \($0.formattedSpokenTimeAgo())",
                        comment: "Watch accessibility: control line while the phone is in control"
                    )
                } ?? String(
                    localized: "iPhone is in control",
                    comment: "Watch accessibility: control line, phone loop age unknown"
                )
            )
        case .starting,
             .waitingForReading:
            return ControlLine(
                symbol: "applewatch",
                text: String(localized: "Starting…", comment: "Watch control line while Trio on Watch starts"),
                tier: .unknown,
                accessibilityLabel: String(
                    localized: "Trio on Watch is starting. Your watch is not giving insulin yet.",
                    comment: "Watch accessibility: control line while starting"
                )
            )
        case .inControl:
            // as on iOS, a pump condition wins over the loop age (G-M3)
            if let pump = pumpCondition {
                return ControlLine(
                    symbol: "exclamationmark.triangle.fill",
                    text: pump.text,
                    tier: pump.tier,
                    accessibilityLabel: String(
                        localized: "Watch is in control. \(pump.spoken)",
                        comment: "Watch accessibility: control line with a pump condition"
                    )
                )
            }
            let tier = TrioOnWatchRules.loopTier(lastLoopAt: lastLoopAt, now: now)
            let age = lastLoopAt?.formattedTimeAgo() ?? "--"
            let spoken = lastLoopAt.map {
                String(localized: "last loop \($0.formattedSpokenTimeAgo())", comment: "Watch accessibility: loop age")
            } ?? String(localized: "no loop yet", comment: "Watch accessibility: no loop on the watch yet")
            return ControlLine(
                symbol: "applewatch",
                text: String(
                    localized: "Watch · \(age)",
                    comment: "Watch control line: the watch is in control, then its loop age"
                ),
                tier: tier,
                accessibilityLabel: String(
                    localized: "Watch is in control, \(spoken)",
                    comment: "Watch accessibility: control line while the watch is in control"
                )
            )
        case .ending:
            return ControlLine(
                symbol: "applewatch",
                text: String(localized: "Ending…", comment: "Watch control line while Trio on Watch ends"),
                tier: .unknown,
                accessibilityLabel: String(
                    localized: "Trio on Watch is ending. Your watch is not giving insulin.",
                    comment: "Watch accessibility: control line while ending"
                )
            )
        case .stopped:
            return ControlLine(
                symbol: "exclamationmark.triangle.fill",
                text: String(localized: "Stopped", comment: "Watch control line when Trio on Watch stopped"),
                tier: .stale,
                accessibilityLabel: String(
                    localized: "Trio on Watch stopped. Your watch is not giving insulin.",
                    comment: "Watch accessibility: control line when stopped"
                )
            )
        }
    }
}

// MARK: - Pump condition on the main page

extension TrioOnWatchStatus {
    struct PumpCondition: Equatable {
        var text: String
        var spoken: String
        var tier: TrioOnWatchRules.Tier
    }

    /// The most serious pump condition, or nil when the pump delivers as the loop asks.
    var pumpCondition: PumpCondition? {
        if podFaulted {
            return PumpCondition(
                text: String(localized: "Pod stopped", comment: "Watch control line: pod fault"),
                spoken: String(localized: "Your pod has stopped. It is not giving insulin.", comment: "Watch status: pod fault"),
                tier: .stale
            )
        }
        if insulinSuspended {
            return PumpCondition(
                text: String(localized: "Insulin suspended", comment: "Watch status: pump suspended"),
                spoken: String(
                    localized: "Insulin is suspended. Trio isn't looping.",
                    comment: "Watch accessibility: insulin suspended"
                ),
                tier: .warning
            )
        }
        if podUnreachable {
            return PumpCondition(
                text: String(localized: "Can't reach pod", comment: "Watch control line: pod not answering"),
                spoken: String(
                    localized: "Can't reach your pod. Keep your watch close to it.",
                    comment: "Watch status: pod not answering (V3-4)"
                ),
                tier: .stale
            )
        }
        if insulinPaused {
            return PumpCondition(
                text: String(
                    localized: "Extra insulin paused",
                    comment: "Watch control line: unconfirmed command; boluses, SMBs and temps above the scheduled basal wait"
                ),
                spoken: String(
                    localized: "Trio can't confirm your last insulin. Boluses and extra automatic insulin are paused, and you can't end yet, until your pump answers.",
                    comment: "Watch status: unconfirmed pump command"
                ),
                tier: .warning
            )
        }
        return nil
    }
}

// MARK: - Main page values while the watch holds the pump

extension TrioOnWatchStatus {
    struct MainValues: Equatable {
        var glucose: String
        /// Delta and reading age on one line (G-14).
        var detail: String
        var isStale: Bool
        var iob: String
        var cob: String
        var accessibilityLabel: String
    }

    func mainValues(now: Date) -> MainValues {
        let latest = readings.first
        let isStale = latest.map { now.timeIntervalSince($0.date) > TrioOnWatchRules.readingMaxAge } ?? true
        // as the phone-controlled main screen: at most two decimals, no unit
        let iobText = iob.flatMap { Formatter.decimalFormatterWithTwoFractionDigits.string(from: $0 as NSNumber) } ?? "--"
        let cobText = cob
            .map { String(localized: "\(Int(truncating: $0 as NSNumber)) g", comment: "Carbs on board in grams") } ?? "--"
        guard let latest, !isStale else {
            return MainValues(
                glucose: "--",
                detail: "--",
                isStale: true,
                iob: iobText,
                cob: cobText,
                accessibilityLabel: String(localized: "Glucose unavailable", comment: "Watch accessibility: no recent reading")
            )
        }
        let glucose = Decimal(latest.mgdl).formatted(for: units)
        let delta = readings.count > 1 && latest.date.timeIntervalSince(readings[1].date) <= 15 * 60
            ? Decimal(latest.mgdl - readings[1].mgdl).formattedDelta(for: units)
            : nil
        let age = latest.date.formattedTimeAgo()
        return MainValues(
            glucose: glucose,
            // the delta alone, as the phone-controlled screen; "-0,3 · 1 min" doesn't fit in the ring
            detail: delta ?? age,
            isStale: false,
            iob: iobText,
            cob: cobText,
            accessibilityLabel: String(
                localized: "Glucose \(glucose) \(units.rawValue), \(delta.map { String(localized: "delta \($0), ", comment: "Watch accessibility: glucose delta") } ?? "")\(latest.date.formattedSpokenTimeAgo())",
                comment: "Watch accessibility: glucose, unit, optional delta, reading age"
            )
        )
    }
}

// MARK: - Status page (W2)

extension TrioOnWatchStatus {
    struct Row: Equatable, Identifiable {
        var id: String
        var symbol: String
        var title: String
        var lines: [String]
        var tint: Color = .secondary
        var accessibilityLabel: String
    }

    enum PrimaryAction: Equatable {
        case start
        case end
        case acknowledgeStop
    }

    var header: (symbol: String, title: String, tint: Color) {
        switch phase {
        case .phone:
            return ("iphone", String(localized: "Your iPhone is in control", comment: "Watch status header"), .primary)
        case .starting,
             .waitingForReading:
            return ("applewatch", String(localized: "Starting…", comment: "Watch status header while starting"), .primary)
        case .inControl:
            return ("applewatch", String(localized: "Your watch is in control", comment: "Watch status header"), .primary)
        case .ending:
            return ("applewatch", String(localized: "Ending…", comment: "Watch status header while ending"), .primary)
        case .stopped:
            return (
                "exclamationmark.triangle.fill",
                String(localized: "Trio on Watch stopped", comment: "Watch status header when stopped"),
                .loopRed
            )
        }
    }

    var primaryAction: PrimaryAction? {
        switch phase {
        case .phone: return .start
        case .inControl,
             .waitingForReading: return .end
        case .stopped: return .acknowledgeStop
        case .ending,
             .starting: return nil
        }
    }

    /// What the pump does when no device gives insulin (F G1.4).
    static var pumpFailSafe: String {
        String(
            localized: "Your watch is not giving insulin. Your pump keeps the last temp basal until it ends, at most 2 hours, then runs your scheduled basal.",
            comment: "Watch: what the pump does while nothing loops"
        )
    }

    func footer() -> String {
        switch phase {
        case .phone:
            return String(
                localized: "Your watch takes over your pump and sensor. It may miss some loops; when it does, Trio alerts you and your pump falls back to your scheduled basal.",
                comment: "Watch status footer before Start"
            )
        case .ending,
             .starting:
            return String(localized: "Keep your iPhone close.", comment: "Watch status footer during a hand-off")
        case .waitingForReading:
            return Self.notGivingInsulinYet + " " + String(
                localized: "Keep Trio open until your watch gets its first sensor reading.",
                comment: "Watch status footer after Start, before the first reading"
            )
        case .inControl:
            return phoneReachable
                ? String(
                    localized: "Ending moves your pump and history back to your iPhone. To change your pod or sensor, end Trio on Watch first.",
                    comment: "Watch status footer in control, phone near"
                )
                : String(
                    localized: "Bring your iPhone close to end. Your watch stays in control until then.",
                    comment: "Watch status footer in control, phone away"
                )
        case let .stopped(reason):
            return [
                Self.stopReason(reason),
                Self.pumpFailSafe,
                String(localized: "Open Trio on your iPhone to take back your pump.", comment: "Watch stopped footer"),
                String(
                    localized: "Tap Done once your iPhone has your pump. Your watch then stops its glucose alarms.",
                    comment: "Watch stopped footer: what Done does"
                )
            ].joined(separator: " ")
        }
    }

    static var notGivingInsulinYet: String {
        String(localized: "Your watch isn't giving insulin yet.", comment: "Watch: after Start, before the first reading (G-M13)")
    }

    /// The Start refusal outside Closed Loop (G-M2).
    static var closedLoopRequiredText: String {
        String(
            localized: "Trio on Watch only runs in Closed Loop. Switch Dosing Mode to Closed Loop on your iPhone first.",
            comment: "Watch refusal reason"
        )
    }

    static func stopReason(_ reason: WatchStopReason) -> String {
        switch reason {
        case .superseded:
            return String(localized: "Your iPhone took back your pump.", comment: "Watch stop reason")
        case .foreignSession:
            return String(localized: "Another device used your pod.", comment: "Watch stop reason")
        case .resumeWindowPassed:
            return String(localized: "Your watch couldn't loop for over 6 hours.", comment: "Watch stop reason")
        case .unconfirmed:
            return String(localized: "Your iPhone didn't confirm the start.", comment: "Watch stop reason")
        }
    }

    func rows(now: Date) -> [Row] {
        guard phase != .phone, phase != .starting else { return [] }
        var rows: [Row] = []

        let tier = TrioOnWatchRules.loopTier(lastLoopAt: lastLoopAt, now: now)
        let loopLine = lastLoopAt.map {
            String(localized: "Last loop \($0.formattedTimeAgo()) ago", comment: "Watch status: loop age")
        } ?? String(localized: "No loop on this watch yet", comment: "Watch status: no loop yet")
        var loopLines = [loopLine]
        if let lastCycleAt, lastCycleAt > (lastLoopAt ?? .distantPast) {
            loopLines.append(String(
                localized: "Loop at \(lastCycleAt.formatted(date: .omitted, time: .shortened)) couldn't reach the pump.",
                comment: "Watch status: last cycle didn't confirm the pump"
            ))
        }
        rows.append(Row(
            id: "loop",
            symbol: "arrow.triangle.2.circlepath",
            title: String(localized: "Loop", comment: "Watch status row title"),
            lines: loopLines,
            tint: tier.color,
            accessibilityLabel: ([String(localized: "Loop", comment: "Watch status row title")] + loopLines)
                .joined(separator: ", ")
        ))

        var sensorLines = [readings.first.map {
            String(localized: "Last reading \($0.date.formattedTimeAgo()) ago", comment: "Watch status: sensor reading age")
        } ?? String(localized: "No reading on this watch yet", comment: "Watch status: no sensor reading yet")]
        var sensorTint = Color.secondary
        if sensorNeedsPairing {
            sensorLines.append(String(
                localized: "Keep Trio open on your watch to pair with the sensor.",
                comment: "Watch status: the watch pairs with the G7 at its next connection"
            ))
            sensorTint = .orange
        }
        if let sensorEndsAt {
            sensorLines.append(String(
                localized: "Sensor ends in \(TrioOnWatchRules.timeLeft(until: sensorEndsAt, now: now))",
                comment: "Watch status: sensor time left"
            ))
            if sensorEndsAt.timeIntervalSince(now) < TrioOnWatchRules.endingSoon { sensorTint = .orange }
        }
        rows.append(Row(
            id: "sensor",
            symbol: "sensor.tag.radiowaves.forward",
            title: String(localized: "Sensor", comment: "Watch status row title"),
            lines: sensorLines,
            tint: sensorTint,
            accessibilityLabel: ([String(localized: "Sensor", comment: "Watch status row title")] + sensorLines)
                .joined(separator: ", ")
        ))

        var pumpLines: [String] = []
        var pumpTint = Color.secondary
        if podFaulted {
            pumpLines
                .append(String(localized: "Your pod has stopped. It is not giving insulin.", comment: "Watch status: pod fault"))
            pumpTint = .loopRed
        }
        if podUnreachable {
            pumpLines.append(String(
                localized: "Can't reach your pod. Keep your watch close to it.",
                comment: "Watch status: pod not answering (V3-4)"
            ))
            pumpTint = .loopRed
        }
        if insulinPaused {
            pumpLines.append(String(
                localized: "Trio can't confirm your last insulin. Boluses and extra automatic insulin are paused, and you can't end yet, until your pump answers.",
                comment: "Watch status: unconfirmed pump command"
            ))
            if pumpTint == .secondary { pumpTint = .orange }
        }
        if insulinSuspended {
            pumpLines.append(String(localized: "Insulin suspended", comment: "Watch status: pump suspended"))
            if pumpTint == .secondary { pumpTint = .orange }
        }
        pumpLines.append(pumpLastContact.map {
            String(localized: "Last contact \($0.formattedTimeAgo()) ago", comment: "Watch status: pump contact age")
        } ?? String(localized: "No pump contact yet", comment: "Watch status: no pump contact yet"))
        if reservoirAboveReadingLimit {
            pumpLines.append(String(
                localized: "Reservoir 50+ \(String(localized: "U", comment: "Insulin unit"))",
                comment: "Watch status: Omnipod reservoir above the 50 U it reports exactly"
            ))
        } else if let reservoir {
            pumpLines.append(String(
                localized: "Reservoir \(TrioOnWatchRules.insulin(Decimal(reservoir)))",
                comment: "Watch status: reservoir with unit"
            ))
            if reservoir <= 10 { pumpTint = .loopRed } else if reservoir <= 30, pumpTint == .secondary { pumpTint = .orange }
        }
        if let podEndsAt {
            pumpLines.append(String(
                localized: "Pod ends in \(TrioOnWatchRules.timeLeft(until: podEndsAt, now: now))",
                comment: "Watch status: pod time left"
            ))
            if podEndsAt.timeIntervalSince(now) < TrioOnWatchRules.endingSoon, pumpTint == .secondary { pumpTint = .orange }
        }
        rows.append(Row(
            id: "pump",
            symbol: "cross.vial",
            title: String(localized: "Pump", comment: "Watch status row title"),
            lines: pumpLines,
            tint: pumpTint,
            accessibilityLabel: ([String(localized: "Pump", comment: "Watch status row title")] + pumpLines)
                .joined(separator: ", ")
        ))

        if let battery, battery < TrioOnWatchRules.batteryShownBelow {
            let line = String(
                localized: "Watch battery \(Int(battery * 100)) %",
                comment: "Watch status: battery percentage, shown when low"
            )
            rows.append(Row(
                id: "battery",
                symbol: "battery.25",
                title: String(localized: "Battery", comment: "Watch status row title"),
                lines: [line],
                tint: battery < 0.1 ? .loopRed : .orange,
                accessibilityLabel: line
            ))
        }
        return rows
    }
}

// MARK: - Start facts (W3)

extension TrioOnWatchStatus {
    struct Fact: Equatable, Identifiable {
        var id: String
        var text: String
        var isWarning: Bool
    }

    /// The facts that apply, then the two fixed lines (G-12). Nil facts: the phone didn't answer.
    static func startFacts(_ facts: WatchLoanStartFacts?, now: Date) -> [Fact] {
        var result: [Fact] = []
        if let facts {
            if let podEndsAt = facts.podEndsAt {
                result.append(Fact(
                    id: "pod",
                    text: String(
                        localized: "Pod ends in \(TrioOnWatchRules.timeLeft(until: podEndsAt, now: now)).",
                        comment: "Watch Start fact"
                    ),
                    isWarning: podEndsAt.timeIntervalSince(now) < TrioOnWatchRules.endingSoon
                ))
            }
            if let sensorEndsAt = facts.sensorEndsAt {
                result.append(Fact(
                    id: "sensor",
                    text: String(
                        localized: "Sensor ends in \(TrioOnWatchRules.timeLeft(until: sensorEndsAt, now: now)).",
                        comment: "Watch Start fact"
                    ),
                    isWarning: sensorEndsAt.timeIntervalSince(now) < TrioOnWatchRules.endingSoon
                ))
            }
            if let override = facts.override {
                let name = override.name ?? String(localized: "Override", comment: "Fallback override name")
                result.append(Fact(
                    id: "override",
                    text: override.endsAt.map {
                        String(
                            localized: "Override “\(name)” runs until \($0.formatted(date: .omitted, time: .shortened)).",
                            comment: "Watch Start fact: running override and its end"
                        )
                    } ?? String(
                        localized: "Override “\(name)” has no end time. Stop it on your iPhone, or give it an end time, first.",
                        comment: "Watch Start fact: an indefinite override refuses Start"
                    ),
                    isWarning: override.endsAt == nil
                ))
            }
            if let tempTarget = facts.tempTarget, let endsAt = tempTarget.endsAt {
                let name = tempTarget.name ?? String(localized: "Temp target", comment: "Fallback temp target name")
                result.append(Fact(
                    id: "tempTarget",
                    text: String(
                        localized: "Temp target “\(name)” runs until \(endsAt.formatted(date: .omitted, time: .shortened)).",
                        comment: "Watch Start fact: running temp target and its end"
                    ),
                    isWarning: false
                ))
            }
        } else {
            result.append(Fact(
                id: "unknown",
                text: String(
                    localized: "Pod, sensor and override details: unknown. Your iPhone didn't send them.",
                    comment: "Watch Start fact when the phone didn't answer the facts query"
                ),
                isWarning: true
            ))
        }
        result.append(Fact(
            id: "alarms",
            text: String(
                localized: "On your watch, Trio's alarms may only tap your wrist when Silent Mode or a Focus is on. Keep your watch on and notifications allowed.",
                comment: "Watch Start disclosure about alarms (G-6b)"
            ),
            isWarning: false
        ))
        result.append(Fact(
            id: "nightscout",
            text: String(
                localized: "Nightscout updates and remote commands pause until you end Trio on Watch.",
                comment: "Watch Start disclosure for caregivers (G-8, V2-26)"
            ),
            isWarning: false
        ))
        return result
    }
}

// MARK: - Hand-off outcomes (W4, W5)

extension TrioOnWatchStatus {
    /// The text for a refusal or failure the host reported; kept on screen until dismissed (G-4).
    static func outcomeText(_ alert: LoanAlert) -> String? {
        switch alert {
        case .phoneDidNotAnswer:
            return String(
                localized: "Your iPhone didn't answer. Open Trio on your iPhone to check which device controls your pump.",
                comment: "Watch Start outcome when the phone didn't answer (G-1)"
            )
        case let .endRefused(reason),
             let .startRefused(reason):
            return refusalText(reason)
        case .podUnreachable:
            return String(
                localized: "Your watch couldn't reach your pod. Keep it close to your pod.",
                comment: "Watch outcome when the first pod contact failed"
            )
        case let .stopped(reason):
            return stopReason(reason)
        default:
            return nil
        }
    }

    static func refusalText(_ reason: LoanRefusal) -> String {
        switch reason {
        case .featureOff:
            return String(localized: "Trio on your iPhone doesn't include Trio on Watch.", comment: "Watch refusal")
        case .bolusRunning:
            return String(localized: "A bolus is running. Try again when it's finished.", comment: "Watch refusal")
        case .deliveryUncertain,
             .releaseRefused,
             .unconfirmedCommand:
            return String(
                localized: "Your pump hasn't confirmed its last command. Try again once it has.",
                comment: "Watch refusal"
            )
        case .pumpStatusStale:
            return String(
                localized: "Your iPhone hasn't heard from your pump recently. Keep your iPhone close to your pump and try again.",
                comment: "Watch refusal"
            )
        case .versionMismatch:
            return String(localized: "Update Trio on your iPhone and watch to the same version.", comment: "Watch refusal")
        case .watchBatteryLow:
            return String(localized: "Charge your watch to at least 30 % to start.", comment: "Watch refusal")
        case .notificationsOff:
            return String(
                localized: "Allow notifications and time-sensitive notifications for Trio on your watch to start.",
                comment: "Watch refusal"
            )
        case .unsupportedWatch:
            return String(
                localized: "Trio on Watch needs Apple Watch Series 6 or later, or SE (2nd generation) or later.",
                comment: "Watch refusal"
            )
        case .phoneUnreachable:
            return String(localized: "Bring your iPhone close and try again.", comment: "Watch refusal")
        case .unsupportedDevice:
            return String(
                localized: "Trio on Watch works with an Omnipod DASH pod and a Dexcom G7 shared with your watch.",
                comment: "Watch refusal"
            )
        case .pumpScreenOpen:
            return String(localized: "Close the pump screen in Trio on your iPhone and try again.", comment: "Watch refusal")
        case .notClosedLoop:
            return closedLoopRequiredText
        case .indefiniteOverride:
            return String(
                localized: "Stop your override on your iPhone first, or give it an end time.",
                comment: "Watch refusal"
            )
        case .busy:
            return String(
                localized: "Your iPhone is busy starting or ending Trio on Watch. Check Trio on your iPhone.",
                comment: "Watch refusal"
            )
        case .grantExpired,
             .staleEpoch,
             .unknownRequest:
            return String(
                localized: "Starting took too long, so Trio on Watch didn't start. Check Trio on your iPhone.",
                comment: "Watch refusal"
            )
        case .snapshotIncomplete:
            return String(
                localized: "Your iPhone didn't send everything your watch needs. Check Trio on your iPhone.",
                comment: "Watch refusal"
            )
        case .clockOffset,
             .timeZoneMismatch:
            return String(
                localized: "Your watch and iPhone show different times. Check the time settings on both.",
                comment: "Watch refusal"
            )
        }
    }
}

// MARK: - Bolus (W7)

extension TrioOnWatchStatus {
    struct BolusView: Equatable {
        var symbol: String?
        var title: String
        var detail: String
        var tint: Color
        var isFinished: Bool
        var needsAcknowledgement: Bool
        var showsCancel: Bool
        var showsRecentDoses: Bool
    }

    /// Never says "delivered" before the pump says so (V2-24).
    func bolusView(units: Decimal, carbsSaved: Bool) -> BolusView {
        let amount = TrioOnWatchRules.insulin(units)
        let carbsLine = carbsSaved ? " " + String(localized: "Your carbs were saved.", comment: "Watch combo bolus note") : ""
        switch bolus {
        case .idle,
             .requested:
            return BolusView(
                symbol: nil,
                title: String(localized: "Sending to pump…", comment: "Watch bolus state"),
                detail: amount,
                tint: .primary,
                isFinished: false,
                needsAcknowledgement: false,
                showsCancel: false,
                showsRecentDoses: false
            )
        case .accepted:
            return BolusView(
                symbol: "cross.vial.fill",
                title: String(localized: "Bolus started", comment: "Watch bolus state: the pump accepted it"),
                detail: String(
                    localized: "Your pump accepted \(amount). It isn't delivered yet.",
                    comment: "Watch bolus state detail: accepted, not delivered"
                ),
                tint: .insulin,
                isFinished: false,
                needsAcknowledgement: false,
                showsCancel: true,
                showsRecentDoses: false
            )
        case .delivering:
            return BolusView(
                symbol: "cross.vial.fill",
                title: String(localized: "Bolusing", comment: "Watch bolus state"),
                detail: String(localized: "Your pump is delivering \(amount).", comment: "Watch bolus state detail"),
                tint: .insulin,
                isFinished: false,
                needsAcknowledgement: false,
                showsCancel: true,
                showsRecentDoses: false
            )
        case .done:
            return BolusView(
                symbol: "checkmark.circle",
                title: String(localized: "Bolus finished", comment: "Watch bolus state"),
                detail: String(
                    localized: "Your pump reports \(amount) finished.",
                    comment: "Watch bolus state detail when the pump reports the bolus done"
                ) + carbsLine,
                tint: .loopGreen,
                isFinished: true,
                needsAcknowledgement: false,
                showsCancel: false,
                showsRecentDoses: false
            )
        case .cancelled:
            return BolusView(
                symbol: "xmark",
                title: String(localized: "Bolus cancelled", comment: "Watch bolus state"),
                detail: String(
                    localized: "Part of it may have been given. Check recent doses.",
                    comment: "Watch bolus state detail after cancel"
                ) + carbsLine,
                tint: .primary,
                isFinished: true,
                needsAcknowledgement: true,
                showsCancel: false,
                showsRecentDoses: true
            )
        case let .failed(message):
            return BolusView(
                symbol: "xmark",
                title: String(localized: "Bolus not given", comment: "Watch bolus state"),
                detail: message + carbsLine,
                tint: .loopRed,
                isFinished: true,
                needsAcknowledgement: true,
                showsCancel: false,
                showsRecentDoses: false
            )
        case .uncertain:
            let next = phoneReachable
                ? String(
                    localized: "If this doesn't clear, take back your pump on your iPhone.",
                    comment: "Watch uncertain bolus: way out with the phone near (G-3)"
                )
                : String(localized: "Your pump keeps running its basal.", comment: "Watch uncertain bolus, phone away (G-3)")
            return BolusView(
                symbol: "exclamationmark.triangle.fill",
                title: String(localized: "Bolus not confirmed", comment: "Watch bolus state"),
                detail: String(
                    localized: "Trio can't tell if your last bolus was given. New boluses are paused until your pump answers.",
                    comment: "Watch uncertain bolus (G-3)"
                ) + " " + next + carbsLine,
                tint: .orange,
                isFinished: true,
                needsAcknowledgement: true,
                showsCancel: false,
                showsRecentDoses: true
            )
        }
    }
}
