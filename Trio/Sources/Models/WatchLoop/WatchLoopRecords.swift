import Foundation

/// A dose as the watch's pump reported it, in the form that travels. `syncIdentifier` is the pump event's own
/// identity: the phone rebuilds the event with the same identity, so storing it twice updates one row.
struct WatchLoopDose: Codable, Equatable {
    enum Kind: String, Codable {
        case bolus
        case tempBasal
        case suspend
        case resume
    }

    let kind: Kind
    let syncIdentifier: String
    let startDate: Date
    let endDate: Date
    /// Bolus: units programmed; temp basal: U/h; suspend and resume: 0.
    let value: Double
    /// Bolus: units delivered so far, once known.
    let deliveredUnits: Double?
    /// Enacted by the loop rather than confirmed by the user.
    let automatic: Bool
    /// A bolus still being given: stored at once so IOB counts it, replaced by the finished record.
    let isMutable: Bool
}

/// One thing that happened during a session (after LoopKit/Loop#2545's LoanDoseRecord). Few kinds on purpose: the
/// phone recomputes TDD and autosens from its pump history, and fills glucose gaps from the sensor's backfill, so of
/// glucose only a meter's BG travels.
struct WatchLoopRecord: Codable, Equatable, Identifiable {
    enum Kind: Codable, Equatable {
        /// A bolus, a suspend or a resume when it happens; a temp basal once it has ended.
        case dose(WatchLoopDose)
        case carbs(CarbsEntry)
        /// A carb entry deleted on the watch, by its id.
        case carbsDeleted(id: String)
        /// A meter's BG deleted on the watch, by its time: the phone gives each its own id.
        case glucoseDeleted(at: Date)
        /// An override started on the watch; nil ends the running one.
        case override(Override?)
        /// A temp target set on the watch; nil ends the running one.
        case tempTarget(TempTarget?)
        /// A meter's BG entered on the watch: the phone files it as a manual reading.
        case glucose(BloodGlucose)
        /// A cycle of the watch's loop: what oref determined, and whether the watch enacted it. The phone's charts,
        /// loop status and Nightscout show the watch's loops from these.
        case determination(Determination, enacted: Bool)
    }

    /// For acknowledgement: the phone stores each id once.
    let id: UUID
    /// Orders the records within a session.
    let seq: Int
    let session: Int
    let loggedAt: Date
    let kind: Kind

    init(id: UUID = UUID(), seq: Int, session: Int, loggedAt: Date = Date(), kind: Kind) {
        self.id = id
        self.seq = seq
        self.session = session
        self.loggedAt = loggedAt
        self.kind = kind
    }
}

/// The pump's own running total of insulin delivered: the independent check on the records.
struct WatchLoopOdometer: Codable, Equatable {
    /// At the takeover, and when it was read.
    let deliveredAtStart: Double
    let startReadAt: Date
    /// At the last reading.
    let deliveredLatest: Double
    let latestReadAt: Date
}

/// What a pump reading says against the records (rule 1 of the control document: insulin is booked regardless).
enum WatchLoopAudit {
    /// Below this the pump's pulses and the records' rounding can differ without anything missing.
    static let band: Double = 0.2

    enum Result: Equatable {
        /// Within the band.
        case matches
        /// The pump delivered more than the records explain: book the difference.
        case missing(units: Double)
        /// The records claim more than the pump delivered: IOB may be overstated; the loop stays closed.
        case overstated(units: Double)
    }

    /// `delivered`: the pump's total since the takeover; `recorded`: the insulin the records account for over the
    /// same stretch, scheduled basal included.
    static func compare(delivered: Double, recorded: Double) -> Result {
        let difference = delivered - recorded
        if difference > band { return .missing(units: difference) }
        if difference < -band { return .overstated(units: -difference) }
        return .matches
    }

    /// The insulin a dose delivers between `start` and `end`. A bolus (delivered, else programmed) is spread over
    /// its delivery, `startDate` to `endDate`, as the pump gives it: a bolus still running at a pump reading is
    /// counted on both sides of it in the right shares. One without a duration counts whole at its start. A temp
    /// basal counts its rate over its overlap.
    static func insulin(_ dose: WatchLoopDose, from start: Date, to end: Date) -> Double {
        switch dose.kind {
        case .bolus:
            let units = dose.deliveredUnits ?? dose.value
            guard dose.endDate > dose.startDate else {
                return dose.startDate >= start && dose.startDate <= end ? units : 0
            }
            let from = max(start, dose.startDate), to = min(end, dose.endDate)
            guard to > from else { return 0 }
            return units * to.timeIntervalSince(from) / dose.endDate.timeIntervalSince(dose.startDate)
        case .tempBasal:
            let from = max(start, dose.startDate), to = min(end, dose.endDate)
            guard to > from else { return 0 }
            return dose.value * to.timeIntervalSince(from) / 3600
        case .resume,
             .suspend:
            return 0
        }
    }
}

extension WatchLoopAudit {
    /// The insulin the records account for between `start` and `end`: the doses, and the scheduled basal wherever no
    /// temp basal or suspend covered the time (the pump gives it then without a record), minute by minute.
    /// As LoopKit/Loop#2545's LoanReconciler: each temp or suspend ends where the next begins (the pump runs one rate
    /// at a time, whatever end a record still carries), and a temp counts in whole `pulseUnits`, since it starts its
    /// own pulse clock and rate × time over-counts it. The schedule stays rate × time: its pulse phase is unknown.
    static func recordedInsulin(
        _ doses: [WatchLoopDose],
        basalProfile: [BasalProfileEntry],
        from start: Date,
        to end: Date,
        pulseUnits: Double? = nil,
        calendar: Calendar = .current
    ) -> Double {
        guard end > start else { return 0 }
        let boluses = doses.filter { $0.kind == .bolus }.reduce(0) { $0 + insulin($1, from: start, to: end) }
        let rates = doses.filter { $0.kind == .tempBasal || $0.kind == .suspend }.sorted { $0.startDate < $1.startDate }
        let spans: [(Date, Date, Double)] = rates.indices.compactMap { index in
            let dose = rates[index]
            let until = index + 1 < rates.count ? min(dose.endDate, rates[index + 1].startDate) : dose.endDate
            let from = max(dose.startDate, start), to = min(until, end)
            return to > from ? (from, to, dose.kind == .tempBasal ? dose.value : 0) : nil
        }
        let temps = spans.reduce(0) { total, span in
            let hours = span.1.timeIntervalSince(span.0) / 3600
            guard let pulseUnits, pulseUnits > 0, span.2 > 0 else { return total + span.2 * hours }
            // the nudge keeps 0.15 / 0.05 = 2.999… from losing a pulse
            return total + (span.2 * hours / pulseUnits + 1E-9).rounded(.down) * pulseUnits
        }
        let given = boluses + temps
        let covered = spans.map { ($0.0, $0.1) }
        let schedule = basalProfile.sorted { $0.minutes < $1.minutes }
        guard !schedule.isEmpty else { return given }
        var scheduled = 0.0
        var minute = start
        while minute < end {
            let next = min(minute.addingTimeInterval(60), end)
            if !covered.contains(where: { minute >= $0.0 && minute < $0.1 }) {
                let parts = calendar.dateComponents([.hour, .minute], from: minute)
                let minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                let rate = schedule.last(where: { $0.minutes <= minuteOfDay })?.rate ?? schedule[0].rate
                scheduled += Double(truncating: rate as NSNumber) * next.timeIntervalSince(minute) / 3600
            }
            minute = next
        }
        return given + scheduled
    }
}

extension WatchLoopAudit {
    /// The doses a pump history records, as the audit reads them: a temp ends at its duration or the next temp or
    /// suspend, a suspend at the resume, a bolus is spread over `bolusDuration`. External insulin is left out: the
    /// pump never delivered it, and a placeholder booked for unexplained insulin must not explain the next.
    static func doses(
        _ history: [PumpHistoryEvent],
        now: Date,
        bolusDuration: (Double) -> TimeInterval = { _ in 0 }
    ) -> [WatchLoopDose] {
        let events = history.sorted { $0.timestamp < $1.timestamp }
        return events.enumerated().compactMap { index, event in
            let later = events[(index + 1)...]
            switch event.type {
            case .bolus,
                 .smb:
                guard event.isExternal != true else { return nil }
                let units = event.amount ?? 0
                let duration = bolusDuration(Double(truncating: units as NSNumber))
                return dose(event, .bolus, value: units, end: event.timestamp.addingTimeInterval(duration))
            case .tempBasal:
                // its duration is the entry beside it at the same time (`PumpEventStored.toPumpHistoryEvents`)
                let minutes = events.first { $0.type == .tempBasalDuration && $0.timestamp == event.timestamp }?.durationMin
                let programmed = event.timestamp.addingTimeInterval(Double(minutes ?? 0) * 60)
                let next = later.first { $0.type == .tempBasal || $0.type == .pumpSuspend }?.timestamp
                return dose(event, .tempBasal, value: event.rate ?? 0, end: min(programmed, next ?? programmed))
            case .pumpSuspend:
                let resume = later.first { $0.type == .pumpResume }?.timestamp ?? now
                return dose(event, .suspend, value: 0, end: resume)
            default:
                return nil
            }
        }
    }

    private static func dose(_ event: PumpHistoryEvent, _ kind: WatchLoopDose.Kind, value: Decimal, end: Date) -> WatchLoopDose {
        WatchLoopDose(
            kind: kind,
            syncIdentifier: event.id,
            startDate: event.timestamp,
            endDate: end,
            value: Double(truncating: value as NSNumber),
            deliveredUnits: nil,
            automatic: true,
            isMutable: false
        )
    }
}

/// LoopKit derives a pump event's identity from its raw bytes, so the phone hex-decodes the dose's `syncIdentifier`
/// back into the raw it came from (as Loop's LoanSeedIdentity).
enum WatchLoopIdentity {
    static func raw(_ syncIdentifier: String) -> Data {
        hexDecoded(syncIdentifier) ?? Data(syncIdentifier.utf8)
    }

    /// Strict: nil on odd length, non-hex, or empty.
    static func hexDecoded(_ string: String) -> Data? {
        let units = Array(string.utf8)
        guard !units.isEmpty, units.count % 2 == 0 else { return nil }
        var data = Data(capacity: units.count / 2)
        var index = 0
        while index < units.count {
            guard let high = nibble(units[index]), let low = nibble(units[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    private static func nibble(_ unit: UInt8) -> UInt8? {
        switch unit {
        case 0x30 ... 0x39: return unit - 0x30
        case 0x41 ... 0x46: return unit - 0x41 + 10
        case 0x61 ... 0x66: return unit - 0x61 + 10
        default: return nil
        }
    }

    static func hexEncoded(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
