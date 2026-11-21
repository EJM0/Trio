import Foundation
import LoopKit
import MedtrumKit
import OmnipodKit

/// Read-only values and the one query the Trio on Watch screens need. Nothing here commands the pump.
extension WatchLoanHost {
    var phoneIsReachable: Bool { env.transport.isReachable }

    /// The screens' view of the loan, read once per render.
    func uiStatus() -> TrioOnWatchStatus {
        var status = TrioOnWatchStatus()
        switch state {
        case .idle:
            status.phase = .phone
        case .requesting:
            status.phase = .starting
        case .holding:
            status.phase = awaitingFirstReading ? .waitingForReading : .inControl
        case .returning:
            status.phase = .ending
        case let .stopped(_, reason):
            status.phase = .stopped(reason)
        }
        status.phoneReachable = env.transport.isReachable
        status.pumpAdopted = pump != nil
        status.lastLoopAt = loop.lastConfirmedCycleAt
        status.lastCycleAt = loop.lastCycleAt
        status.iob = loop.iob
        status.cob = loop.cob
        status.tempBasalRate = loop.tempBasalRate
        status.tempBasalEndsAt = loop.tempBasalEndsAt
        status.eventualGlucose = loop.eventualGlucose
        status.reason = loop.reason
        status.forecast = loop.forecast
        status.lastCycleResult = cycleInfo.lastResult
        status.watchModeSince = cycleInfo.holdingSince
        status.confirmedLoops = cycleInfo.confirmedLoops ?? 0
        status.phoneReadings = cycleInfo.phoneReadings ?? 0
        status.insulinSuspended = loop.pumpSuspended
        status.bolus = bolus
        status.lastAlert = lastAlert
        status.battery = env.batteryLevel()
        status.podUnreachable = cycleInfo.podLinkNoticeShown
        status.insulinPaused = !intents.isEmpty || pump?.status.deliveryIsUncertain == true
        if let snapshot {
            status.units = snapshot.bolusCalculator.units
            status.readings = (snapshot.oref.glucose + records.snapshot.glucose)
                .compactMap { reading in
                    (reading.glucose ?? reading.sgv).map {
                        .init(date: reading.dateString, mgdl: $0, direction: reading.direction?.rawValue)
                    }
                }
                .sorted { $0.date > $1.date }
                .prefix(2)
                .map { $0 }
            var byDate: [Date: TrioOnWatchStatus.Reading] = [:]
            for reading in snapshot.oref.glucose + records.snapshot.glucose {
                guard let mgdl = reading.glucose ?? reading.sgv else { continue }
                byDate[reading.dateString] = .init(date: reading.dateString, mgdl: mgdl, direction: reading.direction?.rawValue)
            }
            status.chartReadings = byDate.values.sorted { $0.date < $1.date }
            if let since = cycleInfo.holdingSince {
                var counted: Date?
                status.watchReadings = records.snapshot.glucose.map(\.dateString).filter { $0 >= since }.sorted()
                    .reduce(0) { count, date in
                        guard date.timeIntervalSince(counted ?? .distantPast) >= Self.countedSpacing else { return count }
                        counted = date
                        return count + 1
                    }
            }
            status.sensorEndsAt = snapshot.sensorEndsAt
            status.sensorNeedsPairing = env.cgm?.needsPairing ?? false
            status.podEndsAt = snapshot.podEndsAt
            let now = env.now()
            let records = records.snapshot
            status.override = Self.runningOverride(snapshot: snapshot, change: records.overrideChange, now: now)
            status.overridePresets = snapshot.overridePresets.map { .init(id: $0.id, name: $0.name) }
            status.tempTarget = Self.runningTempTarget(snapshot: snapshot, change: records.tempTargetChange, now: now)
            status.tempTargetPresets = snapshot.tempTargetPresets.map { .init(id: $0.id, name: $0.name) }
            status.recentDoses = recentBoluses(snapshot: snapshot, now: now)
        }
        if let omnipod = pump as? OmniPumpManager {
            status.pumpLastContact = omnipod.lastSync
            // above 50 U the pod reports a placeholder (51.15), as the phone's DeviceDataManager handles it
            let reservoir = omnipod.state.podState?.lastInsulinMeasurements?.reservoirLevel
            status.reservoir = reservoir
            status.reservoirAboveReadingLimit = reservoir.map { $0 > 50 } ?? false
            status.podEndsAt = omnipod.state.podState?.expiresAt ?? status.podEndsAt
            status.podFaulted = omnipod.deliveredUnitsAreFinal
        } else if let medtrum = pump as? MedtrumPumpManager {
            status.pumpLastContact = medtrum.lastSync
            status.reservoir = medtrum.state.reservoir
            status.podEndsAt = medtrum.deliveryEndsAt ?? status.podEndsAt
            status.podFaulted = medtrum.deliveredUnitsAreFinal
        }
        return status
    }

    private static func runningOverride(
        snapshot: WatchLoanSnapshot,
        change: WatchLoanAdjustmentChange?,
        now: Date
    ) -> TrioOnWatchStatus.Adjustment? {
        if let preset = WatchLoopInputs.startedOverride(snapshot: snapshot, change: change), let change {
            let endsAt = WatchLoopInputs.endDate(of: preset, startedAt: change.at)
            return endsAt.map { $0 > now } ?? true ? .init(name: preset.name, endsAt: endsAt) : nil
        }
        return running(snapshot.overrideAtGrant, cancelledAt: change?.at, now: now)
    }

    private static func runningTempTarget(
        snapshot: WatchLoanSnapshot,
        change: WatchLoanAdjustmentChange?,
        now: Date
    ) -> TrioOnWatchStatus.Adjustment? {
        if let preset = WatchLoopInputs.startedTempTarget(snapshot: snapshot, change: change), let change {
            let endsAt = WatchLoopInputs.endDate(of: preset, startedAt: change.at)
            return endsAt > now ? .init(name: preset.name, endsAt: endsAt) : nil
        }
        return running(snapshot.tempTargetAtGrant, cancelledAt: change?.at, now: now)
    }

    private static func running(
        _ adjustment: WatchLoanSnapshot.Adjustment?,
        cancelledAt: Date?,
        now: Date
    ) -> TrioOnWatchStatus.Adjustment? {
        guard let adjustment, cancelledAt == nil, adjustment.endsAt.map({ $0 > now }) ?? true else { return nil }
        return .init(name: adjustment.name, endsAt: adjustment.endsAt)
    }

    /// Boluses of the last 6 hours: the phone's from the grant, then the watch's own, newest first.
    private func recentBoluses(snapshot: WatchLoanSnapshot, now: Date) -> [TrioOnWatchStatus.Dose] {
        let since = now.addingTimeInterval(-6 * 60 * 60)
        let phone = snapshot.oref.pumpHistory
            .filter { $0.type == .bolus && $0.timestamp > since }
            .map { TrioOnWatchStatus.Dose(date: $0.timestamp, units: $0.amount ?? 0, isAutomatic: $0.isSMB ?? false) }
        let watch = records.snapshot.pumpEvents.values
            .map(\.record.dose)
            .filter { $0.type == .bolus && $0.startDate > since }
            .map {
                TrioOnWatchStatus.Dose(
                    date: $0.startDate,
                    units: Decimal($0.deliveredUnits ?? $0.programmedUnits),
                    isAutomatic: $0.automatic ?? true,
                    isUnconfirmed: $0.isMutable
                )
            }
        return (phone + watch).sorted { $0.date > $1.date }
    }

    /// Asks the phone for the facts Start shows. Nil when it doesn't answer in time.
    func startFacts() async -> WatchLoanStartFacts? {
        let timeout = env.phoneAnswerTimeout
        return await withCheckedContinuation { (done: CheckedContinuation<WatchLoanStartFacts?, Never>) in
            let once = ResumeOnce(done)
            let sent = env.transport.sendLive([WatchLoanStartFacts.queryKey: true]) { reply in
                let facts = (reply[WatchLoanStartFacts.replyKey] as? Data)
                    .flatMap { try? JSONDecoder().decode(WatchLoanStartFacts.self, from: $0) }
                once.resume(facts)
            }
            guard sent else { return once.resume(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }

    /// The watch's limits for manual entry while it holds the pump.
    var bolusLimits: (maxBolus: Decimal, increment: Decimal)? {
        guard let snapshot else { return nil }
        let preferences = snapshot.oref.preferences ?? Preferences()
        return (snapshot.oref.pumpSettings.maxBolus, preferences.bolusIncrement)
    }

    func carbsSaved(since date: Date) -> Bool {
        records.snapshot.carbs.contains { $0.createdAt >= date }
    }
}

// MARK: - Actions that report their outcome to the screens

extension WatchLoanHost {
    static let suspendReminderPrefix = "trio.loan.suspended."
    static let suspendReminderMinutes = Array(stride(from: 30, through: 240, by: 30))

    /// Suspends insulin and says whether the pump confirmed it. While suspended, reminders run every 30 min (G-M4).
    func suspendInsulinConfirmed() async -> Bool {
        var outcome = CommandOutcome.notSent
        await serially { outcome = await self.command(.suspend) }
        WatchLogger.shared.info(.treatments, "Insulin suspend from the watch: \(outcome)")
        guard outcome == .confirmed else { return false }
        let now = env.now()
        for minutes in Self.suspendReminderMinutes {
            env.notifier.post(
                id: Self.suspendReminderPrefix + String(minutes),
                title: String(localized: "Insulin Still Suspended", comment: "Watch reminder title while insulin is suspended"),
                body: String(
                    localized: "Insulin is still suspended. Trio isn't looping. Resume insulin on your watch.",
                    comment: "Watch reminder body while insulin is suspended"
                ),
                at: now.addingTimeInterval(Double(minutes) * 60),
                timeSensitive: true,
                category: nil
            )
        }
        return true
    }

    /// A resume from anywhere, or the pump leaving this watch, ends the reminders.
    func cancelSuspendReminders() {
        env.notifier.cancel(ids: Self.suspendReminderMinutes.map { Self.suspendReminderPrefix + String($0) })
    }

    func resumeInsulinConfirmed() async -> Bool {
        var outcome = CommandOutcome.notSent
        await serially { outcome = await self.command(.resume) }
        WatchLogger.shared.info(.treatments, "Insulin resume from the watch: \(outcome)")
        guard outcome == .confirmed else { return false }
        cancelSuspendReminders()
        await runCycle(trigger: .user)
        return true
    }

    /// Stops the running override or temp target; false when it couldn't be saved.
    func stopAdjustmentConfirmed(override: Bool) async -> Bool {
        let since = env.now()
        if override { await cancelOverride() } else { await cancelTempTarget() }
        let cancelledAt = override ? records.snapshot.overrideChange?.at : records.snapshot.tempTargetChange?.at
        return (cancelledAt ?? .distantPast) >= since
    }

    /// End is tried, not pre-blocked on a reachability flag (G-15): the phone must answer a live query first.
    /// End asks until the phone answers or `phoneAnswerWindow` has passed: one unanswered try, or a moment the
    /// phone isn't reachable, isn't enough to refuse. Each try is logged.
    func phoneAnswers() async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        let window = Duration.seconds(env.phoneAnswerWindow)
        var tries = 0
        var waitedForReach = false
        while clock.now - start < window {
            guard env.transport.isReachable else {
                if !waitedForReach {
                    WatchLogger.shared.info(.connectivity, "End: the phone isn't reachable, waiting for it")
                    waitedForReach = true
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            tries += 1
            let asked = clock.now
            if await askPhoneOnce() {
                let seconds = (clock.now - asked).components.seconds
                WatchLogger.shared.info(.connectivity, "End: the phone answered in \(seconds) s, try \(tries)")
                return true
            }
            WatchLogger.shared.warning(
                .connectivity,
                "End: the phone didn't answer within \(Int(env.phoneAnswerTimeout)) s, try \(tries), reachable \(env.transport.isReachable)"
            )
        }
        WatchLogger.shared.warning(
            .connectivity,
            "End not started: no answer from the phone in \(Int(env.phoneAnswerWindow)) s, \(tries) tries"
        )
        return false
    }

    private func askPhoneOnce() async -> Bool {
        let envelope = WatchLoanEnvelope(
            protocolVersion: WatchLoanEnvelope.currentProtocolVersion,
            messageID: UUID(),
            sentAt: env.now(),
            message: WatchLoanMessage(epoch: state.epoch, kind: .statusQuery)
        )
        guard let data = try? WatchLoanWire.encode(envelope) else { return false }
        let timeout = env.phoneAnswerTimeout
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(done)
            let sent = env.transport.sendLive([WatchLoanWireKey.message: data]) { _ in once.resume(true) }
            guard sent else { return once.resume(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(false) }
        }
    }
}

// MARK: - Snooze on the watch (G-M8)

extension WatchLoanHost {
    private static let snoozeKey = "trio.loan.snooze"

    /// The watch's own snooze for this loan; nil until the user snoozes on the watch.
    private var localSnooze: Date? {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.snoozeKey),
              (saved["epoch"] as? NSNumber)?.int64Value == state.epoch
        else { return nil }
        return saved["until"] as? Date
    }

    /// The watch evaluates its own alarms while it reads the sensor.
    var ownsGlucoseAlarms: Bool {
        switch state {
        case .holding,
             .returning: return true
        case let .stopped(_, reason): return reason != .superseded
        case .idle,
             .requesting: return false
        }
    }

    /// A snooze set on the watch, else one carried over from the iPhone at the grant. Urgent low never (iOS rule).
    var snoozedUntil: Date {
        localSnooze ?? snapshot?.glucoseAlarms.filter { $0.type != .urgentLow }.compactMap(\.snoozedUntil).max()
            ?? .distantPast
    }

    func alarmsHonoringSnooze(_ alarms: [GlucoseAlert]) -> [GlucoseAlert] {
        guard let localSnooze else { return alarms }
        return alarms.map { alarm in
            var alarm = alarm
            if alarm.type != .urgentLow { alarm.snoozedUntil = localSnooze }
            return alarm
        }
    }

    /// 0 ends the snooze. Retracts the snoozed alarms now, as the phone does.
    func snoozeAlarms(minutes: Int) {
        let until = minutes > 0 ? env.now().addingTimeInterval(Double(minutes) * 60) : Date.distantPast
        UserDefaults.standard.set(["epoch": NSNumber(value: state.epoch), "until": until], forKey: Self.snoozeKey)
        let snoozed = (snapshot?.glucoseAlarms ?? []).filter { $0.type != .urgentLow }
        if minutes > 0 {
            env.notifier.cancel(ids: snoozed.map { WatchLoanAlerts.glucosePrefix + $0.id.uuidString })
        }
        cycleInfo.firingGlucoseAlarms.subtract(snoozed.map(\.id))
        saveCycleInfo()
        WatchLogger.shared.info(.loop, minutes > 0 ? "Watch alarms snoozed for \(minutes) min" : "Watch alarm snooze ended")
    }
}

// MARK: - Low-glucose bolus warning (DD-8)

extension WatchLoanHost {
    /// The phone's Treatments rule on the watch's own reading and last forecast. Without a fresh reading or a forecast
    /// that side doesn't warn, as the phone's doesn't without values.
    func lowGlucoseBolusWarning() -> (message: String, shouldConfirm: Bool)? {
        guard let snapshot else { return nil }
        let now = env.now()
        let latest = (snapshot.oref.glucose + records.snapshot.glucose)
            .filter { now.timeIntervalSince($0.dateString) <= TrioOnWatchRules.readingMaxAge }
            .max { $0.dateString < $1.dateString }
        let currentBG = (latest?.glucose ?? latest?.sgv).map { Decimal($0) } ?? .greatestFiniteMagnitude
        let minPredBG = lastOutputs?.determination?.minPredBG ?? .greatestFiniteMagnitude
        guard let message = LowGlucoseBolusWarning.message(currentBG: currentBG, minPredBG: minPredBG) else { return nil }
        // grants from before the setting was sent confirm, the safer side
        let confirm = LowGlucoseBolusWarning.shouldConfirm(
            confirmBolus: snapshot.bolusCalculator.confirmBolus ?? true,
            currentBG: currentBG,
            minPredBG: minPredBG
        )
        return (message, confirm)
    }
}
