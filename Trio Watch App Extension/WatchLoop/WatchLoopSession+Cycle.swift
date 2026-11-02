import Foundation
import LoopKit
import WatchKit

/// The watch's loop cycle: read the pump, run the oref phases the phone runs (`OrefPipeline`), enact, report.
extension WatchLoopSession {
    /// A cycle runs at most this often; a reading, carbs or a schedule can each ask for one.
    static let minimumCycleInterval: TimeInterval = 60
    /// A background refresh this long after each cycle runs one if no reading has (the watch's last resort).
    static let cycleBackstop: TimeInterval = 6 * 60

    struct CycleInputs {
        let grant: WatchLoopGrant
        let dosingMode: DosingMode
        let glucose: [BloodGlucose]
        let pumpHistory: [PumpHistoryEvent]
        let carbs: [CarbsEntry]
        let tempTargets: [TempTarget]
        let activeTempTarget: TempTarget?
        let override: Override?
        let autosens: Autosens?
        let currentTemp: TempBasal
        let reservoir: Decimal
        let supportedBasalRates: [Decimal]
        let now: Date
    }

    struct CycleResult {
        let autosens: Autosens?
        let determination: Determination?
    }

    /// The phone's cycle, without its stores (`OpenAPS.determineBasal`).
    nonisolated static func determine(_ inputs: CycleInputs) throws -> CycleResult {
        let grant = inputs.grant
        let now = inputs.now
        let profile = try OrefPipeline.profile(
            pumpSettings: grant.pumpSettings,
            bgTargets: grant.bgTargets,
            basalProfile: grant.basalProfile,
            isf: grant.insulinSensitivities,
            carbRatios: grant.carbRatios,
            tempTargets: inputs.tempTargets,
            preferences: grant.preferences,
            activeTempTarget: inputs.activeTempTarget.flatMap { target in
                target.targetBottom.map { ($0, target.halfBasalTarget) }
            },
            dosingMode: inputs.dosingMode,
            clock: now
        )
        var autosens = inputs.autosens
        if !OrefPipeline.autosensIsCurrent(autosens, now: now) {
            autosens = try OrefPipeline.autosens(
                glucose: inputs.glucose,
                pumpHistory: inputs.pumpHistory,
                basalProfile: grant.basalProfile,
                profile: profile,
                carbs: inputs.carbs,
                tempTargets: inputs.tempTargets,
                clock: now
            )
            autosens?.timestamp = now
        }
        let glucoseSince = now
            .addingTimeInterval(-Double(truncating: OrefPipeline.glucoseHours(grant.preferences) as NSNumber) * 3600)
        var glucose = inputs.glucose.filter { $0.dateString >= glucoseSince }
        if grant.smoothGlucose { glucose = WatchLoopWatchState.smoothed(glucose) }
        let dosing = try OrefPipeline.dose(
            profile: profile,
            basalProfile: grant.basalProfile,
            autosens: autosens,
            glucose: glucose,
            pumpHistory: inputs.pumpHistory,
            carbs: inputs.carbs,
            currentTemp: inputs.currentTemp,
            reservoir: inputs.reservoir,
            preferences: grant.preferences,
            dosingMode: inputs.dosingMode,
            hasSufficientTDD: grant.hasSufficientTDD,
            supportedBasalRates: inputs.supportedBasalRates,
            trioCustomOrefVariables: OrefPipeline.customOrefVariables(
                override: inputs.override,
                tdd: grant.tdd,
                preferences: grant.preferences,
                now: now
            ),
            clock: now,
            currentTime: now
        )
        return CycleResult(autosens: autosens, determination: try dosing.determination.get())
    }

    func runCycle(reason: String) async {
        guard state.phase == .active, !cycleRunning, let pump = pumpManager, let grant = state.grant else { return }
        cycleTimeEnded = false
        let releaseWake = holdProcess(reason: "Watch Loop cycle", upTo: 60) { [weak self] in self?.cycleTimeEnded = true }
        defer { releaseWake() }
        if let resumingUntil, Date() < resumingUntil {
            guard reason == "reading" else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(Date().distance(to: resumingUntil) * 1_000_000_000))
            } catch {
                return
            }
            guard state.phase == .active, pumpManager === pump else { return }
            self.resumingUntil = nil
        }
        if let last = state.lastLoopAt, Date().timeIntervalSince(last) < Self.minimumCycleInterval, reason == "reading" { return }
        cycleRunning = true
        defer {
            cycleRunning = false
            scheduleBackstop()
        }
        // the pod only once the sensor's link has closed: both share the watch's one radio, and a pod command cut off
        // at a reading began every pod stall (2026-11-01 01:10, as on feat/direct-to-watch, 11d2412 and 19aa4dd)
        let linkOpen = await watchWaitForSensorLink()
        if reason == "reading" {
            WatchLogger.shared.info(.treatments, String(format: "Watch Loop: the sensor's link closed after %.1f s", linkOpen))
        }
        guard state.phase == .active, pumpManager === pump else { return }

        // a pod command watchOS freezes half-way is how pod-link stalls begin: none starts once the cycle's time ended
        guard !cycleTimeEnded else {
            WatchLogger.shared.warning(.treatments, "Watch Loop cycle (\(reason)): no background time left for the pod")
            return
        }
        // control row 14: a cycle that can't reach the pump doses nothing. It says so at once rather than waiting for
        // the phone's overdue query, which a phone asleep in the background asks late (2026-11-02: 18 min).
        state.pumpReachable = await pump.refreshStatus(timeout: 30)
        guard state.pumpReachable, state.phase == .active, pumpManager === pump else {
            state.lastError = String(localized: "Couldn't reach the pod.")
            WatchLogger.shared.warning(.treatments, "Watch Loop cycle (\(reason)): the pod didn't answer")
            if state.phase == .active { sendStatus(replyTo: nil) }
            notePodUnreachable()
            publishDisplay()
            return
        }
        podUnreachableNoticeAt = nil
        // as the phone's `verifyStatus`: no loop while a bolus runs; its end starts the next (`updateBolusState`)
        if case .noBolus = pump.status.bolusState {} else {
            WatchLogger.shared.info(.treatments, "Watch Loop cycle (\(reason)): a bolus is running, skipped")
            return
        }

        let now = Date()
        let inputs = CycleInputs(
            grant: grant,
            dosingMode: state.dosingMode,
            glucose: state.allGlucose,
            pumpHistory: state.pumpHistory,
            carbs: state.allCarbs,
            tempTargets: state.tempTargets,
            activeTempTarget: state.activeTempTarget(at: now),
            override: state.activeOverride(at: now),
            autosens: state.autosens,
            currentTemp: currentTemp(pump, now: now),
            reservoir: Decimal(watchPumpReservoir(pump) ?? 100),
            supportedBasalRates: pump.supportedBasalRates.map { Decimal($0).rounded(scale: 3) },
            now: now
        )
        let result: CycleResult
        do {
            result = try await Task.detached(priority: .userInitiated) { try Self.determine(inputs) }.value
        } catch {
            state.lastError = error.localizedDescription
            WatchLogger.shared.warning(.treatments, "Watch Loop cycle (\(reason)) failed", error: error)
            sendCheckpoint()
            return
        }
        state.autosens = result.autosens

        var enacted = false
        if let determination = result.determination, state.dosingMode.automation != .off {
            do {
                enacted = try await enact(determination, on: pump)
                state.lastError = nil
            } catch {
                state.lastError = error.localizedDescription
                WatchLogger.shared.warning(.treatments, "Watch Loop enact failed", error: error)
            }
        } else {
            state.lastError = nil
        }
        state.lastDetermination = result.determination
        state.lastLoopAt = now
        if var determination = result.determination {
            // the phone's charts, loop status and Nightscout show the watch's loops from these
            determination.timestamp = now
            state.record(.determination(determination, enacted: enacted), at: now)
        }
        publishDisplay()
        armNotLoopingWatchdog()
        // the cycle settled the command the driver was waiting on
        if handBackAfterNextContact {
            handBackAfterNextContact = false
            Task { await end() }
        }
        WatchLogger.shared.info(
            .treatments,
            "Watch Loop cycle (\(reason)): \(result.determination?.rate.map { "\($0) U/h" } ?? "no temp"), SMB \(result.determination?.units ?? 0) U"
        )
        sendCheckpoint()
    }

    /// As the phone enacts (`APSManager.enactDetermination`): the temp, then an SMB. False: skipped, the pump is
    /// suspended.
    private func enact(_ determination: Determination, on pump: PumpManager) async throws -> Bool {
        if pump.status.basalDeliveryState?.isSuspended == true { return false }
        if let rate = determination.rate, let duration = determination.duration {
            guard !cycleTimeEnded else { throw WatchLoopCycleError.noBackgroundTime }
            try await pump.enactTempBasal(
                unitsPerHour: Double(truncating: rate as NSNumber),
                for: Double(truncating: duration as NSNumber) * 60
            )
        }
        if let units = determination.units, units > 0 {
            guard !cycleTimeEnded else { throw WatchLoopCycleError.noBackgroundTime }
            try await pump.enactBolus(units: Double(truncating: units as NSNumber), automatic: true)
        }
        return true
    }

    private func currentTemp(_ pump: PumpManager, now: Date) -> TempBasal {
        guard case let .tempBasal(dose) = pump.status.basalDeliveryState else {
            return TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now)
        }
        return TempBasal(
            duration: max(0, Int(dose.endDate.timeIntervalSince(now) / 60)),
            rate: Decimal(dose.unitsPerHour),
            temp: .absolute,
            timestamp: now
        )
    }

    /// Records since the last acknowledgement, and the sign of life (`WatchLoopCheckpoint`).
    func sendCheckpoint() {
        guard state.phase == .active, let startedAt = state.startedAt else { return }
        let determination = state.lastDetermination
        send(.checkpoint(WatchLoopCheckpoint(
            session: state.session,
            sentAt: Date(),
            startedAt: startedAt,
            records: state.pending,
            status: WatchLoopLiveStatus(
                lastLoopAt: state.lastLoopAt,
                glucose: state.allGlucose.first?.glucose,
                iob: determination?.iob,
                cob: determination?.cob,
                tempBasalRate: pumpManager.flatMap { pump in
                    if case let .tempBasal(dose) = pump.status.basalDeliveryState { return Decimal(dose.unitsPerHour) }
                    return nil
                },
                reservoir: watchPumpReservoir(pumpManager).map { Decimal($0) },
                pumpExpiresAt: watchPumpExpiresAt(pumpManager),
                closedLoop: state.dosingMode.automation != .off
            )
        )))
    }

    /// No loop for 10 min because the pod doesn't answer: the looper is told, and again every 10 min while it lasts.
    private func notePodUnreachable() {
        let now = Date()
        guard now.timeIntervalSince(state.lastLoopAt ?? state.startedAt ?? now) >= Self.podUnreachableNotice,
              now.timeIntervalSince(podUnreachableNoticeAt ?? .distantPast) >= Self.podUnreachableNotice
        else { return }
        podUnreachableNoticeAt = now
        WKInterfaceDevice.current().play(.failure)
        notify(
            String(localized: "Pod Not Reachable"),
            String(localized: "The watch can't reach the pod and isn't looping. Keep the watch near the pod, or hand back to your iPhone.")
        )
        WatchLogger.shared.warning(.treatments, "Watch Loop: Pod Not Reachable told")
    }

    static let podUnreachableNotice: TimeInterval = 10 * 60

    /// The watch's last resort: a background refresh runs a cycle no reading has.
    private func scheduleBackstop() {
        guard state.phase == .active else { return }
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: Self.cycleBackstop),
            userInfo: nil
        ) { error in
            if let error { WatchLogger.shared.warning(.lifecycle, "Could not schedule the Watch Loop backstop", error: error) }
        }
    }

    /// A background refresh: a cycle if none ran since the backstop was set.
    func cycleIfOverdue() async {
        guard state.phase == .active else { return }
        if let last = state.lastLoopAt, Date().timeIntervalSince(last) < Self.cycleBackstop - 30 { return }
        await runCycle(reason: "backstop")
    }

    /// Keeps the process alive while a cycle waits for Bluetooth or the pod. A cycle can outlast the Bluetooth
    /// wake that started it, so it needs its own activity rather than relying on the app delegate's task hold.
    /// watchOS ends the hold by calling the block again with `expired`, or calls it only so when it grants no time: the
    /// waiting call lets go at once, as an app that holds on past that gets less background time from then on, the
    /// time it had is logged, and `onExpire` tells the cycle to start nothing new (kristinkand 001202d52).
    func holdProcess(
        reason: String,
        upTo wait: TimeInterval,
        onExpire: @escaping @MainActor () -> Void
    ) -> () -> Void {
        let gate = DispatchSemaphore(value: 0)
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
                guard expired else {
                    _ = gate.wait(timeout: .now() + wait)
                    return
                }
                gate.signal()
                WatchLogger.shared.warning(
                    .lifecycle,
                    String(format: "%@: background time ended by watchOS after %.1f s", reason, Date().timeIntervalSince(started))
                )
                Task { @MainActor in onExpire() }
            }
        }
        return { gate.signal() }
    }
}

enum WatchLoopCycleError: LocalizedError {
    case noBackgroundTime

    var errorDescription: String? {
        String(localized: "watchOS gave the watch no background time for the pod.")
    }
}
