import Foundation
import LoopKit

extension WatchLoanHost {
    enum CycleTrigger: String {
        case reading
        case user
    }

    /// The CGM manager's new readings: store, check glucose alarms, then loop once.
    func receiveReadings(_ readings: [BloodGlucose]) async {
        guard let snapshot, state.mayCommandPump || isReturning else { return }
        let previous = (snapshot.oref.glucose + records.snapshot.glucose).map(\.dateString).max()
        let kept: [BloodGlucose]
        do {
            let records = records
            kept = try await WatchLoanFiles.io { try records.storeGlucose(readings, newestKnown: previous) }
        } catch {
            WatchLogger.shared.error(.loop, "Storing glucose failed", error: error)
            alerts.postNotSaved()
            return
        }
        guard let latest = kept.max(by: { $0.dateString < $1.dateString }) else { return }
        let now = env.now()
        if awaitingFirstReading {
            awaitingFirstReading = false
            WatchLogger.shared.info(
                .loop,
                "First watch CGM reading \(adoptedAt.map { "\(Self.seconds(since: $0, now: now)) s" } ?? "") after the adopt"
            )
        }
        let gap = previous.map { Int(latest.dateString.timeIntervalSince($0) / 60) }
        WatchLogger.shared.info(
            .loop,
            "CGM reading after \(Int(now.timeIntervalSince(latest.dateString))) s, gap \(gap.map { "\($0) min" } ?? "none")"
        )
        evaluateGlucoseAlarms(latest: latest, now: now)
        await runCycle(trigger: .reading)
    }

    private var isReturning: Bool {
        if case .returning = state { return true }
        return false
    }

    /// Holds background time for the whole cycle and gives it back on every path.
    func runCycle(trigger: CycleTrigger) async {
        let held = env.beginActivity("Trio loop cycle")
        await serially {
            self.activity = held
            await self.cycle(trigger: trigger)
            self.activity = nil
        }
        held.end()
        onCycleFinished?()
    }

    /// The algorithm runs off the main thread.
    nonisolated static func runOref(_ inputs: OrefInputs) async throws -> OrefRun.Outputs {
        try await Task.detached(priority: .userInitiated) { try OrefRun.run(inputs) }.value
    }

    /// One loop: restore checks, pump status, oref, gate, write-ahead, enact, record, alerts.
    private func cycle(trigger: CycleTrigger) async {
        guard case let .holding(epoch) = state, let pump, let snapshot else {
            WatchLogger.shared.debug(.loop, "Cycle skipped: not holding the pump")
            return
        }
        let start = env.now()
        isCycleRunning = true
        defer { isCycleRunning = false }
        WatchLogger.shared.info(.loop, "Cycle started (\(trigger.rawValue)), foreground \(env.isForeground())")

        // the kit refuses every session after another controller used the pod
        if pump.refusesSessions || pump.foreignSessionDetectedAt != nil {
            await process(.foreignPodSession)
            return
        }

        let lastSync = await pump.ensureCurrentPumpData()
        let statusRead = env.now()
        guard let lastSync, statusRead.timeIntervalSince(lastSync) <= WatchLoopPolicy.pumpStatusMaxAge else {
            WatchLogger.shared.warning(.loop, "Cycle stopped: no fresh pump status")
            noPodContact(now: statusRead)
            finish(start: start, confirmed: false)
            return
        }
        if pump.refusesSessions {
            await process(.foreignPodSession)
            return
        }

        if intent != nil {
            await resolveIntent()
        }
        let uncertain = pump.status.deliveryIsUncertain || intent != nil

        let glucoseDates = (snapshot.oref.glucose + records.snapshot.glucose).map(\.dateString)
        if let failure = LoopGlucoseGuard.check(
            lastHour: LoopGlucoseGuard.lastHour(glucoseDates, now: statusRead),
            now: statusRead
        ) {
            WatchLogger.shared.warning(.loop, "Cycle stopped: glucose check failed (\(failure))")
            finish(start: start, confirmed: false)
            return
        }

        let now = env.now()
        let microBolusAllowed = WatchLoopPolicy.microBolusAllowed(inForeground: env.isForeground()) && !uncertain
        let bolusIncrement = snapshot.oref.preferences?.bolusIncrement ?? Preferences().bolusIncrement
        var inputs = WatchLoopInputs.orefInputs(
            snapshot: snapshot,
            records: records.loopRecords(bolusIncrement: bolusIncrement),
            now: now,
            currentTemp: Self.currentTemp(pump.status.basalDeliveryState, now: now),
            autosens: cycleInfo.autosens,
            microBolusAllowed: microBolusAllowed
        )
        // the phone books today's insulin before each determination
        let tdd = WatchLoopInputs.tddRow(inputs, roundToSupportedBasalRate: pump.roundToSupportedBasalRate)
        do {
            let records = records
            try await WatchLoanFiles.io { try records.storeTDD(tdd) }
        } catch {
            WatchLogger.shared.warning(.loop, "Storing the TDD row failed", error: error)
        }
        inputs.tddHistory = OrefInputs.tddHistory(inputs.tddHistory + [tdd], now: now)

        let orefStart = env.now()
        let outputs: OrefRun.Outputs
        do {
            outputs = try await Self.runOref(inputs)
        } catch {
            WatchLogger.shared.error(.loop, "Cycle stopped: oref failed", error: error)
            finish(start: start, confirmed: false)
            return
        }
        guard let determination = outputs.determination else {
            WatchLogger.shared.error(.loop, "Cycle stopped: no determination")
            finish(start: start, confirmed: false)
            return
        }
        lastOutputs = outputs
        if cycleInfo.autosens == nil { cycleInfo.autosens = outputs.autosens }
        WatchLogger.shared.info(
            .loop,
            "Determination in \(Self.seconds(since: orefStart, now: env.now())) s, SMB \(microBolusAllowed ? "allowed" : "off"): eventual BG \(determination.eventualBG.map { "\($0) mg/dL" } ?? "none"), temp basal \(determination.rate.map { "\($0) U/h for \(determination.duration ?? 0) min" } ?? "none"), SMB \(determination.units ?? 0) U"
        )
        evaluateDeterminationAlarms(determination, now: now)

        let plan = WatchDosingGate.plan(
            rate: determination.rate,
            durationMinutes: determination.duration,
            units: determination.units,
            scheduledBasal: outputs.profile.currentBasal ?? 0,
            suspended: pump.status.basalDeliveryState?.isSuspended ?? false,
            deliveryUncertain: uncertain
        )
        var confirmed = plan.heldBack.allSatisfy { $0 == .pumpSuspended }
        if !plan.heldBack.isEmpty {
            WatchLogger.shared.warning(.loop, "Held back: \(plan.heldBack.map { "\($0)" }.joined(separator: ", "))")
        }
        if let temp = plan.tempBasal {
            WatchLogger.shared.info(.loop, "Command starts \(Self.seconds(since: start, now: env.now())) s after the wake")
            confirmed = await command(.tempBasal(unitsPerHour: temp.unitsPerHour, minutes: temp.minutes)) && confirmed
        }
        if let units = plan.bolus {
            confirmed = await command(.bolus(units: units, automatic: true)) && confirmed
        }

        updateLoopStatus(outputs, pump: pump)
        finish(start: start, confirmed: confirmed)
        checkBattery()
        await sendRecords(epoch: epoch)

        // the heaviest stage runs after the commands, on its 30-minute cadence
        if !OrefRun.isAutosensFresh(cycleInfo.autosens, now: now) {
            var fresh = inputs
            fresh.autosens = nil
            if let computed = try? await Self.runOref(fresh).autosens {
                cycleInfo.autosens = computed
                saveCycleInfo()
                WatchLogger.shared.info(.loop, "Autosens updated after enactment, ratio \(computed.ratio)")
            }
        }
    }

    /// The phone's current-temp rule (`APSManager.fetchCurrentTempBasal`) on the pump's own state.
    static func currentTemp(_ state: PumpManagerStatus.BasalDeliveryState?, now: Date) -> TempBasal {
        if case let .tempBasal(dose) = state {
            let minutes = max(0, Int((dose.endDate.timeIntervalSince1970 - now.timeIntervalSince1970) / 60))
            return TempBasal(duration: minutes, rate: Decimal(dose.unitsPerHour), temp: .absolute, timestamp: now)
        }
        return TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now)
    }

    private func finish(start: Date, confirmed: Bool) {
        let now = env.now()
        cycleInfo.lastCycleAt = now
        if confirmed {
            cycleInfo.lastConfirmedCycleAt = now
            cycleInfo.podContactFailures = 0
            cycleInfo.podLinkNoticeShown = false
            alerts.armNotLooping(after: now, now: now)
        }
        saveCycleInfo()
        loop.lastCycleAt = cycleInfo.lastCycleAt
        loop.lastConfirmedCycleAt = cycleInfo.lastConfirmedCycleAt
        WatchLogger.shared.info(
            .loop,
            "Cycle finished in \(Self.seconds(since: start, now: now)) s, \(confirmed ? "pump state confirmed" : "not confirmed")"
        )
    }

    /// Two cycles in a row without the pod and 5 minutes without a confirmed cycle: tell the user once.
    private func noPodContact(now: Date) {
        cycleInfo.podContactFailures += 1
        let since = cycleInfo.lastConfirmedCycleAt ?? cycleInfo.holdingSince ?? now
        guard cycleInfo.podContactFailures >= 2, now.timeIntervalSince(since) >= WatchLoopPolicy.podLinkNoticeDelay,
              !cycleInfo.podLinkNoticeShown
        else { return }
        cycleInfo.podLinkNoticeShown = true
        alerts.postPodUnreachable(phoneReachable: env.transport.isReachable)
    }

    func saveCycleInfo() {
        let (files, info) = (env.files, cycleInfo)
        WatchLoanFiles.later("the cycle info") { try files.save(info, to: .cycle) }
    }

    private func updateLoopStatus(_ outputs: OrefRun.Outputs, pump: LoanPump) {
        loop.iob = outputs.iob.first?.iob
        loop.cob = outputs.meal?.mealCOB
        loop.eventualGlucose = outputs.determination?.eventualBG
        if case let .tempBasal(dose) = pump.status.basalDeliveryState {
            loop.tempBasalRate = Decimal(dose.unitsPerHour)
        } else {
            loop.tempBasalRate = nil
        }
        loop.pumpSuspended = pump.status.basalDeliveryState?.isSuspended ?? false
    }

    static func seconds(since start: Date, now: Date) -> String {
        String(format: "%.1f", now.timeIntervalSince(start))
    }

    // MARK: - Commands

    /// Writes the intent, then sends. A failed write sends nothing. Keeps the intent while the pump is uncertain.
    func command(_ kind: WatchDoseIntent.Kind) async -> Bool {
        // End cancels the temp after `returning` is saved and before the release; nothing else runs then
        let epoch: Int64
        switch state {
        case let .holding(holding): epoch = holding
        case let .returning(returning) where kind == .tempBasal(unitsPerHour: 0, minutes: 0): epoch = returning
        default: return false
        }
        guard let pump else { return false }
        if activity?.isExpired == true {
            WatchLogger.shared.warning(.loop, "Command \(Self.name(kind)) not started: the wake ran out of time")
            return false
        }
        let pending = WatchDoseIntent(
            id: UUID(),
            kind: kind,
            createdAt: env.now(),
            epoch: epoch,
            addsInsulin: addsInsulin(kind),
            deliveredBefore: pump.deliveredUnits?.units
        )
        do {
            // the cycle waits for the write: nothing is sent before the intent is on disk
            let files = env.files
            try await WatchLoanFiles.io { try files.save(pending, to: .intent) }
        } catch {
            WatchLogger.shared.error(.loop, "Command not sent: saving its intent failed", error: error)
            alerts.postNotSaved()
            return false
        }
        intent = pending
        let sentAt = env.now()
        do {
            switch kind {
            case let .tempBasal(rate, minutes):
                try await pump.enactTempBasal(
                    decisionId: nil,
                    unitsPerHour: rate.nearestDouble,
                    for: TimeInterval(minutes * 60)
                )
            case let .bolus(units, automatic):
                try await pump.enactBolus(
                    decisionId: nil,
                    units: units.nearestDouble,
                    activationType: automatic ? .automatic : .manualRecommendationAccepted
                )
            case .suspend:
                try await pump.suspendDelivery()
            case .resume:
                try await pump.resumeDelivery()
            }
        } catch {
            if pump.status.deliveryIsUncertain {
                WatchLogger.shared.error(.loop, "Command \(Self.name(kind)) unconfirmed; kept for the next cycle", error: error)
                return false
            }
            WatchLogger.shared.warning(.loop, "Command \(Self.name(kind)) failed", error: error)
            await clearIntent()
            return false
        }
        WatchLogger.shared.info(.loop, "Command \(Self.name(kind)) confirmed in \(Self.seconds(since: sentAt, now: env.now())) s")
        await clearIntent()
        return true
    }

    private func addsInsulin(_ kind: WatchDoseIntent.Kind) -> Bool {
        switch kind {
        case .bolus: return true
        case let .tempBasal(rate, _): return rate > (lastOutputs?.profile.currentBasal ?? 0)
        case .resume: return true
        case .suspend: return false
        }
    }

    private func clearIntent() async {
        intent = nil
        let files = env.files
        do { try await WatchLoanFiles.io { try files.remove(.intent) } } catch {
            WatchLogger.shared.warning(.loop, "Removing the settled intent failed", error: error)
        }
    }

    /// Settles a command left from an earlier wake: by the kit, by the odometer, or booked as delivered.
    func resolveIntent() async {
        guard let pending = intent, let pump else { return }
        let uncertain = pump.status.deliveryIsUncertain
        if !uncertain, pending.deliveredBefore != nil {
            _ = await pump.refreshDeliveredUnits()
        }
        let resolution = pending.resolve(
            kitUncertain: uncertain,
            kitBookedIt: records.kitRecorded(pending),
            deliveredNow: pump.deliveredUnits?.units,
            pulseUnits: pump.deliveryPulseUnits
        )
        switch resolution {
        case nil:
            WatchLogger.shared.warning(.loop, "Earlier command \(Self.name(pending.kind)) still unconfirmed")
            return
        case .notDelivered,
             .settledByKit:
            WatchLogger.shared.info(.loop, "Earlier command \(Self.name(pending.kind)) settled: \(resolution!)")
        case .bookAsDelivered:
            do {
                let records = records
                try await WatchLoanFiles.io { try records.book(pending) }
            } catch {
                WatchLogger.shared.error(.loop, "Booking the unconfirmed command failed; kept", error: error)
                alerts.postNotSaved()
                return
            }
            WatchLogger.shared.warning(.loop, "Earlier command \(Self.name(pending.kind)) booked as delivered")
            alerts.postBookedIntent()
        }
        await clearIntent()
    }

    static func name(_ kind: WatchDoseIntent.Kind) -> String {
        switch kind {
        case let .tempBasal(rate, minutes): return "temp basal \(rate) U/h for \(minutes) min"
        case let .bolus(units, automatic): return "\(automatic ? "SMB" : "bolus") \(units) U"
        case .suspend: return "suspend"
        case .resume: return "resume"
        }
    }

    // MARK: - Glucose alarms

    private func evaluateGlucoseAlarms(latest: BloodGlucose, now: Date) {
        guard let snapshot, let value = latest.glucose ?? latest.sgv else { return }
        var firing = cycleInfo.firingGlucoseAlarms
        let actions = GlucoseAlarmEvaluation.evaluateReading(
            latestMgDL: Decimal(value),
            alarms: snapshot.glucoseAlarms,
            configuration: snapshot.glucoseAlarmConfiguration,
            firing: &firing,
            now: now,
            timeZone: snapshot.timeZone ?? env.timeZone()
        )
        cycleInfo.firingGlucoseAlarms = firing
        alerts.apply(actions, units: snapshot.bolusCalculator.units)
        saveCycleInfo()
    }

    private func evaluateDeterminationAlarms(_ determination: Determination, now: Date) {
        guard let snapshot else { return }
        var firing = cycleInfo.firingGlucoseAlarms
        let zone = snapshot.timeZone ?? env.timeZone()
        var actions = GlucoseAlarmEvaluation.evaluateForecast(
            determination,
            alarms: snapshot.glucoseAlarms,
            configuration: snapshot.glucoseAlarmConfiguration,
            firing: &firing,
            now: now,
            timeZone: zone
        )
        actions += GlucoseAlarmEvaluation.evaluateCarbsRequired(
            determination.carbsReq,
            alarms: snapshot.glucoseAlarms,
            configuration: snapshot.glucoseAlarmConfiguration,
            firing: &firing,
            now: now,
            timeZone: zone
        )
        cycleInfo.firingGlucoseAlarms = firing
        alerts.apply(actions, units: snapshot.bolusCalculator.units)
    }

    // MARK: - Battery, records

    private func checkBattery() {
        guard let level = env.batteryLevel() else { return }
        cycleInfo.batteryNotice = alerts.postBattery(level: level, previousNotice: cycleInfo.batteryNotice)
        saveCycleInfo()
    }

    /// Queues what the phone hasn't acknowledged yet.
    func sendRecords(epoch: Int64) async {
        do {
            let (records, now) = (records, env.now())
            let batch = try await WatchLoanFiles.io { try records.nextBatch(epoch: epoch, now: now) }
            let data = try batch.encoded()
            env.transport.send([WatchLoanWireKey.records: data])
            WatchLogger.shared.info(
                .connectivity,
                "Record batch queued: \(batch.pumpEvents.count) pump events, \(batch.glucose.count) readings, \(data.count) bytes"
            )
        } catch {
            WatchLogger.shared.warning(.connectivity, "Record batch not sent", error: error)
        }
    }
}
