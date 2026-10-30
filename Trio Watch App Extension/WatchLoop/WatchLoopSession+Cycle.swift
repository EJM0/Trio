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
            dosingMode: grant.dosingMode,
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
            dosingMode: grant.dosingMode,
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
        if let resumingUntil, Date() < resumingUntil { return }
        if let last = state.lastLoopAt, Date().timeIntervalSince(last) < Self.minimumCycleInterval, reason == "reading" { return }
        cycleRunning = true
        defer {
            cycleRunning = false
            scheduleBackstop()
        }

        // control row 14: a cycle that can't reach the pump doses nothing and reports nothing
        state.pumpReachable = await pump.refreshStatus(timeout: 30)
        guard state.pumpReachable, state.phase == .active, pumpManager === pump else {
            state.lastError = String(localized: "Couldn't reach the pod.")
            WatchLogger.shared.warning(.treatments, "Watch Loop cycle (\(reason)): the pod didn't answer")
            return
        }

        let now = Date()
        let inputs = CycleInputs(
            grant: grant,
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

        if let determination = result.determination, state.closedLoop, grant.dosingMode.automation != .off {
            do {
                try await enact(determination, on: pump)
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
        WatchLogger.shared.info(
            .treatments,
            "Watch Loop cycle (\(reason)): \(result.determination?.rate.map { "\($0) U/h" } ?? "no temp"), SMB \(result.determination?.units ?? 0) U"
        )
        sendCheckpoint()
    }

    /// As the phone enacts (`APSManager.enactDetermination`): the temp, then an SMB.
    private func enact(_ determination: Determination, on pump: PumpManager) async throws {
        if pump.status.basalDeliveryState?.isSuspended == true { return }
        if let rate = determination.rate, let duration = determination.duration {
            try await pump.enactTempBasal(
                unitsPerHour: Double(truncating: rate as NSNumber),
                for: Double(truncating: duration as NSNumber) * 60
            )
        }
        if let units = determination.units, units > 0 {
            try await pump.enactBolus(units: Double(truncating: units as NSNumber), automatic: true)
        }
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
                closedLoop: state.closedLoop
            )
        )))
    }

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
}
