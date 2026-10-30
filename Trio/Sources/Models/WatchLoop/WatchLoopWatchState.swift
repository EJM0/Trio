import Foundation

/// What the watch keeps of a session across relaunches. Decoded leniently: a field added later never resets the rest.
struct WatchLoopWatchState: Codable {
    enum Phase: String, Codable {
        case idle
        /// Start tapped; waiting for the grant.
        case requested
        /// The watch holds the pump and loops.
        case active
        /// End tapped; the pump is released and offered back.
        case handingBack
    }

    var phase: Phase = .idle
    /// The highest session this watch has known.
    var session = 0
    var startedAt: Date?
    /// The live session's settings and starting history.
    var grant: WatchLoopGrant?
    /// Records not yet acknowledged, oldest first.
    var pending: [WatchLoopRecord] = []
    var nextSeq = 1
    /// Off: the watch suggests and the looper enacts (the phone's open loop).
    var closedLoop = true
    /// The watch's own doses since the grant, as the algorithm reads them.
    var history: [PumpHistoryEvent] = []
    /// Carbs entered on the watch since the grant.
    var carbs: [CarbsEntry] = []
    /// Grant carbs deleted on the watch.
    var deletedCarbIDs: [String] = []
    /// The watch's own readings since the grant.
    var glucose: [BloodGlucose] = []
    var override: Override?
    /// The temp targets file the algorithm reads: the grant's, then the watch's.
    var tempTargets: [TempTarget] = []
    var autosens: Autosens?
    var lastDetermination: Determination?
    var lastLoopAt: Date?
    /// Whether the last cycle reached the pump (control row 14).
    var pumpReachable = true
    var lastError: String?
    var deliveredAtStart: Double?
    var deliveredAtStartReadAt: Date?
    /// The phone's copy to start from without it.
    var standing: WatchLoopGrant?
    var startedWithoutPhone = false
    var startedByFallback = false
    /// The pump's total at the last reading the watch's records explained.
    var verifiedDelivered: Double?
    var verifiedAt: Date?
    /// After a hand-back nobody answered: each dose waits for the phone's word first, until it has answered once.
    var checkWithPhoneBeforeDosing = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WatchLoopWatchState()
        phase = (try? c.decodeIfPresent(Phase.self, forKey: .phase)) ?? d.phase
        session = (try? c.decodeIfPresent(Int.self, forKey: .session)) ?? d.session
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        grant = try? c.decodeIfPresent(WatchLoopGrant.self, forKey: .grant)
        pending = (try? c.decodeIfPresent([WatchLoopRecord].self, forKey: .pending)) ?? d.pending
        nextSeq = (try? c.decodeIfPresent(Int.self, forKey: .nextSeq)) ?? d.nextSeq
        closedLoop = (try? c.decodeIfPresent(Bool.self, forKey: .closedLoop)) ?? d.closedLoop
        history = (try? c.decodeIfPresent([PumpHistoryEvent].self, forKey: .history)) ?? d.history
        carbs = (try? c.decodeIfPresent([CarbsEntry].self, forKey: .carbs)) ?? d.carbs
        deletedCarbIDs = (try? c.decodeIfPresent([String].self, forKey: .deletedCarbIDs)) ?? d.deletedCarbIDs
        glucose = (try? c.decodeIfPresent([BloodGlucose].self, forKey: .glucose)) ?? d.glucose
        override = try? c.decodeIfPresent(Override.self, forKey: .override)
        tempTargets = (try? c.decodeIfPresent([TempTarget].self, forKey: .tempTargets)) ?? d.tempTargets
        autosens = try? c.decodeIfPresent(Autosens.self, forKey: .autosens)
        lastDetermination = try? c.decodeIfPresent(Determination.self, forKey: .lastDetermination)
        lastLoopAt = try? c.decodeIfPresent(Date.self, forKey: .lastLoopAt)
        pumpReachable = (try? c.decodeIfPresent(Bool.self, forKey: .pumpReachable)) ?? d.pumpReachable
        lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
        deliveredAtStart = try? c.decodeIfPresent(Double.self, forKey: .deliveredAtStart)
        deliveredAtStartReadAt = try? c.decodeIfPresent(Date.self, forKey: .deliveredAtStartReadAt)
        standing = try? c.decodeIfPresent(WatchLoopGrant.self, forKey: .standing)
        startedWithoutPhone = (try? c.decodeIfPresent(Bool.self, forKey: .startedWithoutPhone)) ?? d.startedWithoutPhone
        startedByFallback = (try? c.decodeIfPresent(Bool.self, forKey: .startedByFallback)) ?? d.startedByFallback
        verifiedDelivered = try? c.decodeIfPresent(Double.self, forKey: .verifiedDelivered)
        verifiedAt = try? c.decodeIfPresent(Date.self, forKey: .verifiedAt)
        checkWithPhoneBeforeDosing = (try? c.decodeIfPresent(Bool.self, forKey: .checkWithPhoneBeforeDosing))
            ?? d.checkWithPhoneBeforeDosing
    }

    /// Starts a session from its grant.
    mutating func begin(_ grant: WatchLoopGrant, at now: Date) {
        phase = .active
        session = grant.session
        startedAt = now
        self.grant = grant
        history = []
        carbs = []
        deletedCarbIDs = []
        glucose = []
        override = grant.activeOverride
        tempTargets = grant.tempTargets
        autosens = grant.autosens
        lastDetermination = grant.lastDetermination
        lastLoopAt = nil
        pumpReachable = true
        lastError = nil
        startedWithoutPhone = false
        startedByFallback = false
        verifiedDelivered = nil
        verifiedAt = nil
        checkWithPhoneBeforeDosing = false
    }

    /// Back to rest. Unacknowledged records stay until the phone has them.
    mutating func end() {
        phase = .idle
        grant = nil
        startedAt = nil
        history = []
        carbs = []
        deletedCarbIDs = []
        glucose = []
        override = nil
        tempTargets = []
        autosens = nil
        lastDetermination = nil
        deliveredAtStart = nil
        deliveredAtStartReadAt = nil
        startedWithoutPhone = false
        startedByFallback = false
        verifiedDelivered = nil
        verifiedAt = nil
        checkWithPhoneBeforeDosing = false
    }

    mutating func record(_ kind: WatchLoopRecord.Kind, at now: Date) {
        pending.append(WatchLoopRecord(seq: nextSeq, session: session, loggedAt: now, kind: kind))
        nextSeq += 1
    }

    mutating func acknowledge(_ ids: [UUID]) {
        let acked = Set(ids)
        pending.removeAll { acked.contains($0.id) }
    }

    /// A dose the pump reported: kept for the algorithm and recorded for the phone. A dose reported again (a bolus
    /// finishing) replaces its earlier form in both.
    mutating func noteDose(_ dose: WatchLoopDose, at now: Date) {
        history.removeAll { $0.id == dose.syncIdentifier }
        history.append(contentsOf: dose.historyEvents)
        history.sort { $0.timestamp < $1.timestamp }
        pending.removeAll {
            if case let .dose(earlier) = $0.kind { return earlier.syncIdentifier == dose.syncIdentifier }
            return false
        }
        record(.dose(dose), at: now)
    }

    /// The pump history the algorithm reads: the phone's last day, then the watch's own.
    var pumpHistory: [PumpHistoryEvent] {
        Self.merged(phone: grant?.pumpHistory ?? [], own: history)
    }

    /// The watch's own form of an event the phone also has wins: it is the pump's latest word on it.
    static func merged(phone: [PumpHistoryEvent], own: [PumpHistoryEvent]) -> [PumpHistoryEvent] {
        let ownIDs = Set(own.map(\.id))
        return (phone.filter { !ownIDs.contains($0.id) } + own).sorted { $0.timestamp > $1.timestamp }
    }

    var allCarbs: [CarbsEntry] {
        let deleted = Set(deletedCarbIDs)
        return ((grant?.carbs ?? []) + carbs).filter { !deleted.contains($0.id ?? "") }
    }

    /// The phone's readings, then the watch's own newer ones, newest first as the algorithm reads them.
    var allGlucose: [BloodGlucose] {
        let phoneNewest = grant?.glucose.map(\.dateString).max() ?? .distantPast
        return ((grant?.glucose ?? []) + glucose.filter { $0.dateString > phoneNewest.addingTimeInterval(60) })
            .sorted { $0.dateString > $1.dateString }
    }

    /// The temp target running at `now`: the newest entry decides, as on the phone.
    func activeTempTarget(at now: Date) -> TempTarget? {
        guard let newest = tempTargets.filter({ $0.createdAt <= now }).max(by: { $0.createdAt < $1.createdAt }),
              newest.enabled != false, newest.duration > 0,
              newest.createdAt.addingTimeInterval(Double(truncating: newest.duration as NSNumber) * 60) > now
        else { return nil }
        return newest
    }

    func activeOverride(at now: Date) -> Override? {
        guard let override, override.enabled else { return nil }
        if override.indefinite { return override }
        let end = override.date.addingTimeInterval(Double(truncating: override.duration as NSNumber) * 60)
        return end > now ? override : nil
    }
}

extension WatchLoopWatchState {
    /// The algorithm's glucose as the phone reads it with smoothing on (`GlucoseStorage.algorithmGlucoseValue`): a
    /// CGM reading takes its smoothed value, a manual one stays as it is. `readings` newest first, as returned.
    static func smoothed(_ readings: [BloodGlucose]) -> [BloodGlucose] {
        let cgm = readings.filter { $0.sgv != nil }.sorted { $0.dateString < $1.dateString }
        let values = GlucoseSmoothing.smoothed(cgm.map { ($0.dateString, $0.sgv ?? 0) })
        var smoothedByID: [String: Int] = [:]
        for (reading, value) in zip(cgm, values) {
            guard let value, value != 0 else { continue }
            smoothedByID[reading.id] = Int(truncating: value.rounded(scale: 0) as NSNumber)
        }
        return readings.map { reading in
            var reading = reading
            if let value = smoothedByID[reading.id] { reading.sgv = value }
            return reading
        }
    }
}

extension Override {
    /// The preset as started now.
    func started(at date: Date) -> Override {
        Override(
            name: name, enabled: true, date: date, duration: duration, indefinite: indefinite, percentage: percentage,
            smbIsOff: smbIsOff, isPreset: false, id: UUID().uuidString, overrideTarget: overrideTarget, target: target,
            advancedSettings: advancedSettings, isfAndCr: isfAndCr, isf: isf, cr: cr, smbIsScheduledOff: smbIsScheduledOff,
            start: start, end: end, smbMinutes: smbMinutes, uamMinutes: uamMinutes
        )
    }
}

extension WatchLoopDose {
    /// As the phone's pump history reads for the algorithm (`PumpHistoryStorage.getPumpHistory`).
    var historyEvents: [PumpHistoryEvent] {
        switch kind {
        case .bolus:
            return [PumpHistoryEvent(
                id: syncIdentifier,
                type: .bolus,
                timestamp: startDate,
                amount: Decimal(deliveredUnits ?? value),
                isSMB: automatic
            )]
        case .tempBasal:
            return [PumpHistoryEvent(
                id: syncIdentifier,
                type: .tempBasal,
                timestamp: startDate,
                amount: Decimal(value),
                duration: Int((endDate.timeIntervalSince(startDate) / 60).rounded())
            )]
        case .suspend:
            return [PumpHistoryEvent(id: syncIdentifier, type: .pumpSuspend, timestamp: startDate)]
        case .resume:
            return [PumpHistoryEvent(id: syncIdentifier, type: .pumpResume, timestamp: startDate)]
        }
    }
}
