import Foundation
import HealthKit
import LoopKit
import SwiftUI
import UserNotifications
import WatchConnectivity
import WatchKit

// MARK: - The loop

/// As on the phone, only a new reading loops: its pump heartbeat and timers start no loop (`FetchGlucoseManager`
/// heartbeats after storing a new reading, `pumpManagerBLEHeartbeatDidFire` does nothing).
enum UntetheredLoopTrigger {
    /// A new CGM reading: the loop.
    case newGlucose
    /// Carbs, a bolus, an override or a temp target changed what the algorithm reads: a determination for
    /// the screens without dosing, as the phone's `determineBasalSync`.
    case treatment
    /// A dosing mode changed: determine and enact again with that mode's constraints on the current readings.
    case modeChanged
}

extension UntetheredWatchManager {
    /// One cycle, as the phone's `APSManager.loop()`: refresh the pump, determine, enact, record.
    func runLoop(_ trigger: UntetheredLoopTrigger) {
        // a hand-back doses on while its history drains, until its last stage
        let phase = data.session.phase
        guard phase == .active || (phase == .ending && !isFinalizing), !data.podEnded, let pump = pumpManager,
              let grant = data.grant else { return }
        guard !isLooping else {
            // as `determineBasalSync`, which waits for a loop in flight: run once it is done
            if trigger == .treatment { isDeterminationPending = true }
            if trigger == .modeChanged { isModeChangePending = true }
            return
        }
        let newestGlucose = data.glucose.map(\.dateString).max()
        // each reading loops once; the phone's last loop, carried over at the takeover, counts as one
        if trigger == .newGlucose, let used = data.lastLoopGlucose, let newestGlucose, newestGlucose <= used { return }
        let enacts = trigger != .treatment
        isLooping = true
        if enacts { store.update { $0.lastLoopGlucose = newestGlucose } }
        // A Bluetooth wake often comes with almost no time from watchOS; without time of its own the app can be
        // suspended in the middle of reaching the pod, and the loop stalls until the app is opened.
        let releaseHold = Self.holdProcess(reason: "Untethered loop", upTo: Self.loopHoldLimit)
        Task { @MainActor in
            defer {
                releaseHold()
                self.isLooping = false
                if self.isModeChangePending {
                    self.isModeChangePending = false
                    self.runLoop(.modeChanged)
                } else if self.isDeterminationPending {
                    self.isDeterminationPending = false
                    self.runLoop(.treatment)
                }
            }
            if enacts {
                _ = await withCheckedContinuation { (continuation: CheckedContinuation<Date?, Never>) in
                    pump.ensureCurrentPumpData { continuation.resume(returning: $0) }
                }
            }
            self.expireAdjustments(now: Date())
            self.checkLinkedOverride()
            let now = Date()
            self.store.trim(now: now)
            do {
                // as `APSManager.determineBasal`: three readings in the last hour, the newest at most 12 minutes old
                let lastHour = self.store.data.glucose.filter { $0.dateString >= now.addingTimeInterval(-60 * 60) }
                guard lastHour.count > 2 else { throw UntetheredWatchError.notEnoughGlucose }
                guard let newest = lastHour.map(\.dateString).max(), newest >= now.addingTimeInterval(-12 * 60) else {
                    throw UntetheredWatchError.staleGlucose
                }
                // as `APSManager.calculateAndStoreTDD`, before the determination reads it
                if enacts { self.calculateTDD(pump: pump, grant: grant, now: now) }
                let previousAutosens = self.store.data.autosens?.timestamp
                let inputs = self.loopInputs(pump: pump, grant: grant, now: now)
                guard let result = try await Task.detached(operation: { try UntetheredAlgorithm.determine(inputs) }).value
                else { throw UntetheredWatchError.noDetermination }
                let (determination, autosens) = result
                if let autosens, let timestamp = autosens.timestamp, timestamp != previousAutosens {
                    // the phone continues from it after the hand-back
                    self.store.record(
                        UntetheredRecord(
                            key: UntetheredRecord.autosensKey(timestamp),
                            date: timestamp,
                            kind: .autosens(autosens)
                        ),
                        epoch: self.data.session.epoch
                    )
                }
                self.store.update {
                    $0.autosens = autosens
                    $0.lastDetermination = determination
                }
                // one version for the phone, with its forecasts and whether the pump took it, as the phone's own
                // determination is marked enacted after the pump acted
                let key = UntetheredRecord.determinationKey(determination.deliverAt ?? now)
                let epoch = self.data.session.epoch
                func record(enactedAt: Date?) {
                    self.store.record(
                        UntetheredRecord(key: key, date: now, kind: .determination(determination, enactedAt: enactedAt)),
                        epoch: epoch
                    )
                }
                func looped() {
                    self.store.update {
                        $0.lastLoopDate = now
                        $0.lastLoopError = nil
                    }
                    self.podLinkRecovered(pump)
                }
                if enacts {
                    do {
                        // A selection made while this determination was running invalidates its old permissions.
                        guard self.data.grant?.dosingMode == grant.dosingMode else {
                            record(enactedAt: nil)
                            return
                        }
                        if grant.dosingMode.automation == .off {
                            record(enactedAt: nil)
                            looped()
                        } else {
                            try await self.enact(determination, pump: pump, dosingMode: grant.dosingMode)
                            record(enactedAt: Date())
                            looped()
                            self.scheduleNotLoopingAlert(from: now)
                            self.recordPumpStatus()
                            self.store.record(
                                UntetheredRecord(
                                    key: UntetheredRecord.loopCompletedKey,
                                    date: now,
                                    kind: .loopCompleted(now)
                                ),
                                epoch: self.data.session.epoch
                            )
                        }
                    } catch {
                        record(enactedAt: nil)
                        throw error
                    }
                    let rate = determination.rate.map { "\($0) U/h" } ?? "-"
                    let smb = determination.units.map { "\($0) U" } ?? "-"
                    let battery = Self.batteryText
                    Task {
                        await WatchLogger.shared.log(
                            "⌚️ Untethered loop: BG \(determination.bg ?? 0), temp \(rate), SMB \(smb), battery \(battery)",
                            force: true
                        )
                    }
                } else {
                    record(enactedAt: nil)
                }
            } catch {
                // a failed determination for the screens is no loop error
                if enacts { self.store.update { $0.lastLoopError = error.localizedDescription } }
                Task { await WatchLogger.shared.log("⌚️ Untethered loop failed: \(error)", force: true) }
            }
            self.refresh()
            self.streamRecords()
            self.publishToWatchState()
        }
    }

    func loopInputs(pump: PumpManager, grant: UntetheredGrant, now: Date) -> UntetheredAlgorithm.Inputs {
        let data = store.data
        let currentTemp: TempBasal
        switch pump.status.basalDeliveryState {
        case let .tempBasal(dose):
            currentTemp = TempBasal(
                duration: max(0, Int((dose.endDate.timeIntervalSince1970 - now.timeIntervalSince1970) / 60)),
                rate: Decimal(dose.unitsPerHour),
                temp: .absolute,
                timestamp: now
            )
        case .active:
            currentTemp = TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now)
        default:
            currentTemp = UntetheredAlgorithm.historyTempBasal(data.pumpHistory, now: now)
        }
        return UntetheredAlgorithm.Inputs(
            grant: grant,
            pumpHistory: UntetheredAlgorithm.withoutOrphanedResumes(data.pumpHistory).sorted { $0.timestamp > $1.timestamp },
            glucose: UntetheredAlgorithm.algorithmGlucose(
                data.glucose,
                smoothed: data.smoothedGlucose,
                smoothing: grant.smoothGlucose
            ),
            carbs: data.carbs,
            tempTargets: data.tempTargets,
            activeTempTarget: activeTempTarget(at: now),
            override: activeOverride(at: now),
            autosens: data.autosens,
            tdd: UntetheredAlgorithm.tddSummary(rows: data.tddRows, hours: data.tddHours, now: now) ?? grant.tdd,
            hasSufficientTDD: UntetheredAlgorithm.hasSufficientTDD(hours: data.tddHours, now: now) ?? grant.hasSufficientTDD,
            currentTemp: currentTemp,
            supportedBasalRates: pump.supportedBasalRates.map { Decimal($0) },
            reservoir: data.reservoir ?? 100,
            now: now
        )
    }

    /// As `APSManager.calculateAndStoreTDD`: a TDD row from the last day of pump history, kept for the
    /// averages and sent to the phone.
    func calculateTDD(pump: PumpManager, grant: UntetheredGrant, now: Date) {
        let result = TDDCalculator.calculate(
            pumpHistory: store.data.tddPumpHistory.sorted { $0.timestamp > $1.timestamp },
            basalProfile: grant.basalProfile,
            now: now,
            roundToSupportedBasalRate: pump.roundToSupportedBasalRate
        )
        let data = store.data
        let weightedAverage = UntetheredAlgorithm.weightedAverage(
            rows: data.tddRows,
            hours: data.tddHours,
            weight: grant.preferences.weightPercentage,
            now: now
        )
        let row = UntetheredTDD(
            date: now,
            total: result.total,
            bolus: result.bolus,
            tempBasal: result.tempBasal,
            scheduledBasal: result.scheduledBasal,
            weightedAverage: weightedAverage
        )
        store.update {
            $0.tddRows.append(row)
            UntetheredTDDHour.add(row, to: &$0.tddHours)
            $0.tddHours = UntetheredTDDHour.inWindow($0.tddHours, now: now)
        }
        store.record(UntetheredRecord(key: UntetheredRecord.tddKey(now), date: now, kind: .tdd(row)), epoch: data.session.epoch)
    }

    /// The phone's `exponentialSmoothingGlucose` over the watch's readings: CGM only, the last day, at most
    /// `GlucoseSmoothing.maximumReadings`.
    func smoothGlucose() {
        guard data.grant?.smoothGlucose == true else { return }
        let dayAgo = Date().addingTimeInterval(-24 * 60 * 60)
        let readings = data.glucose
            .filter { $0.sgv != nil && $0.dateString >= dayAgo }
            .sorted { $0.dateString < $1.dateString }
            .suffix(GlucoseSmoothing.maximumReadings)
        let smoothed = GlucoseSmoothing.smoothed(readings.map { (date: $0.dateString, glucose: $0.sgv ?? 0) })
        store.update { data in
            for (reading, value) in zip(readings, smoothed) {
                if let value { data.smoothedGlucose[reading.id] = value }
            }
        }
    }

    /// The phone's `APSManager.enactDetermination`.
    private func enact(_ determination: Determination, pump: PumpManager, dosingMode: DosingMode) async throws {
        if case .suspended = pump.status.basalDeliveryState { return }
        if let rate = determination.rate, let duration = determination.duration {
            try await pump.enactTempBasal(
                unitsPerHour: rate.nearestDouble,
                for: TimeInterval(truncating: duration as NSNumber) * 60
            )
        }
        // as the phone: no SMB on top of a bolus still running, e.g. the meal bolus just started
        if data.grant?.dosingMode == dosingMode, let units = determination.units, units > 0,
           pump.status.bolusState == .noBolus
        {
            try await pump.enactBolus(units: units.nearestDouble, automatic: true)
        }
    }

    func activeOverride(at date: Date) -> Override? {
        guard let override = store.data.activeOverride, override.enabled else { return nil }
        if override.indefinite { return override }
        return override.date.addingTimeInterval(Double(truncating: override.duration as NSNumber) * 60) > date ? override : nil
    }

    func activeTempTarget(at date: Date) -> TempTarget? {
        guard let last = store.data.tempTargets.max(by: { $0.createdAt < $1.createdAt }), last.duration > 0,
              last.createdAt.addingTimeInterval(Double(truncating: last.duration as NSNumber) * 60) > date
        else { return nil }
        return last
    }

    /// Untethered mode started from an override ends with it, once the phone can take the pump.
    func checkLinkedOverride() {
        guard data.session.phase == .active, let linked = data.session.linkedOverrideID else { return }
        guard activeOverride(at: Date())?.id != linked, !isBolusing else { return }
        if WCSession.default.isReachable { end() }
    }
}

enum UntetheredWatchError: LocalizedError {
    case noDetermination
    case noPump
    case notEnoughGlucose
    case staleGlucose

    var errorDescription: String? {
        switch self {
        case .notEnoughGlucose: return String(localized: "Not enough glucose data: at least three readings in the last hour are needed.")
        case .staleGlucose: return String(localized: "Glucose data is stale: the most recent reading is more than 12 minutes old.")
        case .noDetermination: return String(localized: "The algorithm gave no result.")
        case .noPump: return String(localized: "The watch doesn't have the pump.")
        }
    }
}

extension PumpManager {
    func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enactTempBasal(unitsPerHour: unitsPerHour, for: duration) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func enactBolus(units: Double, automatic: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enactBolus(units: units, activationType: automatic ? .automatic : .manualRecommendationAccepted) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

// MARK: - Bolus recommendation

extension UntetheredWatchManager {
    /// What the phone answers a watch's request with (`BaseWatchManager`, `requestBolusRecommendation`):
    /// a loop simulated with the entered carbs sets the safety floor, then the phone's bolus calculator runs
    /// on the watch's own determination, glucose and settings.
    func recommendBolus(carbs: Int, useReducedBolus: Bool, useSuperBolus: Bool) async -> Decimal {
        guard let grant = data.grant, let pump = pumpManager else { return 0 }
        let now = Date()
        let settings = grant.bolusCalculator
        let useReducedBolus = useReducedBolus && settings.fattyMeals
        let useSuperBolus = !useReducedBolus && useSuperBolus && settings.sweetMeals
        let determination = data.lastDetermination
            .flatMap { ($0.deliverAt ?? .distantPast) > now.addingTimeInterval(-30 * 60) ? $0 : nil }

        var minPredBG = determination?.minPredBGFromReason ?? 54
        if carbs > 0 {
            var inputs = loopInputs(pump: pump, grant: grant, now: now)
            inputs.carbs.append(CarbsEntry(
                id: UUID().uuidString, createdAt: now, actualDate: now, carbs: Decimal(carbs), fat: 0, protein: 0,
                note: nil, enteredBy: CarbsEntry.local, isFPU: false, fpuID: nil
            ))
            if let simulated = try? await Task.detached(operation: { try UntetheredAlgorithm.determine(inputs) }).value?.0
                .minPredBGFromReason
            {
                minPredBG = simulated
            }
        }

        func current(_ entries: [(start: String, value: Decimal)]) -> Decimal {
            BolusCalculator.scheduleValue(entries, at: now)
        }
        let glucose = BolusCalculator.glucoseVariables(
            newestFirst: data.glucose.sorted { $0.dateString > $1.dateString }
                .map { (date: $0.dateString, glucose: Decimal($0.glucose ?? $0.sgv ?? 0)) },
            now: now
        )
        let input = CalculationInput(
            carbs: Decimal(carbs),
            currentBG: glucose.currentBG,
            deltaBG: glucose.deltaBG,
            target: determination?.current_target ?? current(grant.bgTargets.targets.map { ($0.start, $0.low) }),
            isf: determination?.isf ?? current(grant.insulinSensitivities.sensitivities.map { ($0.start, $0.sensitivity) }),
            carbRatio: determination?.carbRatio ?? current(grant.carbRatios.schedule.map { ($0.start, $0.ratio) }),
            iob: determination?.iob ?? 0,
            cob: Int16(truncatingIfNeeded: NSDecimalNumber(
                decimal: (determination?.cob ?? 0)
                    .rounded(scale: 0, roundingMode: .down)
            ).intValue),
            useFattyMealCorrectionFactor: useReducedBolus,
            fattyMealFactor: settings.fattyMealFactor,
            useSuperBolus: useSuperBolus,
            sweetMealFactor: settings.sweetMealFactor,
            basal: current(grant.basalProfile.map { ($0.start, $0.rate) }),
            fraction: settings.fraction,
            maxBolus: grant.pumpSettings.maxBolus,
            // the dosing mode's limit, as the phone's calculator reads it
            maxIOB: grant.preferences.clamped(for: grant.dosingMode).maxIOB,
            maxCOB: grant.preferences.maxCOB,
            minPredBG: minPredBG,
            lastLoopDate: data.lastLoopDate ?? .distantPast
        )
        // as `APSManager.roundBolus`: the pump's increment, never above max bolus
        let maxBolus = Decimal(pump.roundToSupportedBolusVolume(units: grant.pumpSettings.maxBolus.nearestDouble))
        return BolusCalculator.calculate(input) {
            min(Decimal(pump.roundToSupportedBolusVolume(units: $0.nearestDouble)), maxBolus)
        }.insulinCalculated
    }
}

// MARK: - Treatments on the wrist

extension UntetheredWatchManager {
    func bolus(_ units: Decimal, completion: @escaping (Bool, String) -> Void) {
        guard !isFinalizing, let pump = pumpManager, let grant = data.grant else {
            return completion(false, UntetheredWatchError.noPump.localizedDescription)
        }
        let amount = min(units, grant.maxBolus)
        Task { @MainActor in
            do {
                try await pump.enactBolus(units: pump.roundToSupportedBolusVolume(units: amount.nearestDouble), automatic: false)
                completion(true, String(localized: "Bolus started."))
                // as the phone's `enactBolus`: IOB and the forecast take the bolus in at once
                self.runLoop(.treatment)
            } catch {
                completion(false, error.localizedDescription)
            }
        }
    }

    // MARK: Ending the pod

    /// Deactivates the pod, e.g. one that alarms: it stops delivering, goes quiet and must come off. The watch can't
    /// pair the next one, so it hands back to the phone as soon as the phone is reachable.
    func deactivatePod(completion: @escaping (_ error: String?) -> Void) {
        guard let pump = pumpManager else { return completion(UntetheredWatchError.noPump.localizedDescription) }
        let started = watchDeactivatePod(pump) { error in
            DispatchQueue.main.async {
                if let error {
                    completion(error.localizedDescription)
                } else {
                    self.podDidEnd()
                    completion(nil)
                }
            }
        }
        if !started { completion(String(localized: "The watch can't deactivate this pump.")) }
    }

    /// For a pod that doesn't answer: forgotten without its last word. It may go on alarming until it is removed.
    func discardPod() {
        guard let pump = pumpManager else { return }
        _ = watchDiscardPod(pump) { DispatchQueue.main.async { self.podDidEnd() } }
    }

    private func podDidEnd() {
        let now = Date()
        store.update {
            $0.podEnded = true
            $0.pendingPumpAlerts.removeAll { $0.managerIdentifier == self.pumpManager?.pluginIdentifier }
        }
        // no loop follows until the phone pairs the next pod
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notLoopingID])
        store.record(
            UntetheredRecord(key: UntetheredRecord.podEndedKey, date: now, kind: .podEnded(now)),
            epoch: data.session.epoch
        )
        savePumpState()
        refresh()
        streamRecords()
        Task { await WatchLogger.shared.log("⌚️ Untethered: pod ended on the watch", force: true) }
        if WCSession.default.isReachable { end() }
    }

    func cancelBolus() {
        pumpManager?.cancelBolus { result in
            DispatchQueue.main.async {
                if case let .failure(error) = result {
                    self.setError(error.localizedDescription)
                } else {
                    // in case the pod books the cancelled bolus only later: what it delivered so far counts now
                    self.runLoop(.treatment)
                }
            }
        }
    }

    func addCarbs(_ grams: Int, fat: Int = 0, protein: Int = 0, at date: Date) {
        guard let grant = data.grant else { return }
        let entry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: date,
            actualDate: date,
            carbs: min(Decimal(grams), grant.maxCarbs),
            fat: fat > 0 ? Decimal(fat) : nil,
            protein: protein > 0 ? Decimal(protein) : nil,
            note: nil,
            enteredBy: CarbsEntry.local,
            isFPU: false,
            fpuID: fat > 0 || protein > 0 ? UUID().uuidString : nil
        )
        // ponytail: fat and protein travel to the phone, which converts them; the watch's own loop counts carbs only
        store.update { $0.carbs.append(entry) }
        store.record(
            UntetheredRecord(key: UntetheredRecord.carbsKey(entry.id ?? ""), date: date, kind: .carbs(entry)),
            epoch: data.session.epoch
        )
        refresh()
        runLoop(.treatment)
    }

    /// Deleted for the loop and the screens; the same key's new version tells the phone.
    func deleteGlucose(id: String) {
        guard let reading = data.glucose.first(where: { $0.id == id }) else { return }
        store.update {
            $0.glucose.removeAll { $0.id == id }
            $0.smoothedGlucose[id] = nil
        }
        smoothGlucose()
        store.record(
            UntetheredRecord(
                key: UntetheredRecord.glucoseKey(reading.dateString),
                date: reading.dateString,
                kind: .glucoseDeleted(date: reading.dateString)
            ),
            epoch: data.session.epoch
        )
        refresh()
        publishToWatchState()
    }

    func deleteCarbs(id: String) {
        store.update { $0.carbs.removeAll { $0.id == id } }
        store.record(
            UntetheredRecord(key: UntetheredRecord.carbsKey(id), date: Date(), kind: .carbsDeleted(id: id)),
            epoch: data.session.epoch
        )
        refresh()
        runLoop(.treatment)
    }

    func activateOverride(named name: String) {
        guard let preset = data.grant?.overridePresets.first(where: { $0.name == name }) else { return }
        endOverride()
        let now = Date()
        let override = Override(
            name: preset.name, enabled: true, date: now, duration: preset.duration, indefinite: preset.indefinite,
            percentage: preset.percentage, smbIsOff: preset.smbIsOff, isPreset: true, id: preset.id,
            overrideTarget: preset.overrideTarget, target: preset.target, advancedSettings: preset.advancedSettings,
            isfAndCr: preset.isfAndCr, isf: preset.isf, cr: preset.cr, smbIsScheduledOff: preset.smbIsScheduledOff,
            start: preset.start, end: preset.end, smbMinutes: preset.smbMinutes, uamMinutes: preset.uamMinutes,
            showUntetheredButton: preset.showUntetheredButton
        )
        let key = UntetheredRecord.overrideKey(now)
        store.update {
            $0.activeOverride = override
            $0.activeOverrideKey = key
        }
        store.record(UntetheredRecord(key: key, date: now, kind: .override(override)), epoch: data.session.epoch)
        refresh()
        runLoop(.treatment)
    }

    func endOverride(at date: Date = Date()) {
        guard let override = activeOverride(at: Date()), let key = data.activeOverrideKey else { return }
        store.update {
            $0.activeOverride = nil
            $0.activeOverrideKey = nil
        }
        store.record(
            UntetheredRecord(key: key, date: date, kind: .overrideEnded(start: override.date)),
            epoch: data.session.epoch
        )
        refresh()
        checkLinkedOverride()
        runLoop(.treatment)
    }

    func activateTempTarget(named name: String) {
        guard let preset = data.grant?.tempTargetPresets.first(where: { $0.name == name }) else { return }
        endTempTarget()
        let now = Date()
        let tempTarget = TempTarget(
            id: preset.id, name: preset.name, createdAt: now, targetTop: preset.targetTop, targetBottom: preset.targetBottom,
            duration: preset.duration, enteredBy: TempTarget.local, reason: TempTarget.custom, isPreset: true,
            enabled: true, halfBasalTarget: preset.halfBasalTarget
        )
        let key = UntetheredRecord.tempTargetKey(now)
        store.update {
            $0.tempTargets.append(tempTarget)
            $0.activeTempTargetKey = key
        }
        store.record(UntetheredRecord(key: key, date: now, kind: .tempTarget(tempTarget)), epoch: data.session.epoch)
        refresh()
        runLoop(.treatment)
    }

    func endTempTarget(at date: Date = Date()) {
        guard let tempTarget = activeTempTarget(at: Date()), let key = data.activeTempTargetKey else { return }
        store.update {
            $0.tempTargets.append(TempTarget.cancel(at: date))
            $0.activeTempTargetKey = nil
        }
        store.record(
            UntetheredRecord(key: key, date: date, kind: .tempTargetEnded(start: tempTarget.createdAt)),
            epoch: data.session.epoch
        )
        refresh()
        runLoop(.treatment)
    }

    /// An override or temp target that ran out on the watch reaches the phone as ended at its scheduled end,
    /// so the phone doesn't keep it running when the watch's history arrives.
    func expireAdjustments(now: Date) {
        let epoch = data.session.epoch
        if let override = data.activeOverride, override.enabled, !override.indefinite, activeOverride(at: now) == nil,
           let key = data.activeOverrideKey
        {
            let end = override.date.addingTimeInterval(Double(truncating: override.duration as NSNumber) * 60)
            store.update {
                $0.activeOverride = nil
                $0.activeOverrideKey = nil
            }
            store.record(UntetheredRecord(key: key, date: end, kind: .overrideEnded(start: override.date)), epoch: epoch)
        }
        if let key = data.activeTempTargetKey, activeTempTarget(at: now) == nil,
           let tempTarget = data.tempTargets.last(where: { UntetheredRecord.tempTargetKey($0.createdAt) == key })
        {
            let end = tempTarget.createdAt.addingTimeInterval(Double(truncating: tempTarget.duration as NSNumber) * 60)
            store.update { $0.activeTempTargetKey = nil }
            store.record(UntetheredRecord(key: key, date: end, kind: .tempTargetEnded(start: tempTarget.createdAt)), epoch: epoch)
        }
        refresh()
    }

    func acknowledgePumpAlert(_ alert: UntetheredWatchData.PendingPumpAlert) {
        pumpManager?.acknowledgeAlert(alertIdentifier: alert.alertIdentifier) { _ in }
        store.update { $0.pendingPumpAlerts.removeAll { $0.id == alert.id } }
        refresh()
    }
}

// MARK: - Pump

private struct WatchReservoir: ReservoirValue {
    let startDate: Date
    let unitVolume: Double
}

extension UntetheredWatchManager: PumpManagerDelegate {
    /// As on the phone: the pod's heartbeat keeps the link, the CGM drives the loop.
    func pumpManagerBLEHeartbeatDidFire(_: PumpManager) {}

    func pumpManagerMustProvideBLEHeartbeat(_: PumpManager) -> Bool { false }

    func pumpManagerWillDeactivate(_: PumpManager) {
        setError(String(localized: "The pod was deactivated. Pair a new one on the phone."))
    }

    func pumpManagerPumpWasReplaced(_: PumpManager) {}

    func pumpManager(_: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents _: Bool) {}

    func pumpManager(_: PumpManager, didError error: PumpManagerError) {
        setError(error.localizedDescription)
    }

    func pumpManager(
        _: PumpManager,
        hasNewPumpEvents events: [NewPumpEvent],
        lastReconciliation _: Date?,
        replacePendingEvents: Bool,
        completion: @escaping (Error?) -> Void
    ) {
        let increment = data.grant?.preferences.bolusIncrement ?? 0.05
        let epoch = data.session.epoch
        let identifiers = events.map { event in
            event.dose?.syncIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? event.raw.map { String(format: "%02x", $0) }.joined()
        }
        // a bolus that ends, or is cancelled, is booked with what it delivered: IOB and the forecast follow at once
        let wasMutable = store.data.mutablePumpEventIDs
        let bolusFinalized = zip(events, identifiers).contains { event, id in
            event.type == .bolus && event.dose?.isMutable == false && wasMutable.contains(id)
        }
        if replacePendingEvents {
            let asserted = Set(identifiers)
            let dropped = store.data.mutablePumpEventIDs.subtracting(asserted)
            store.update {
                $0.removePumpEvents(dropped)
                $0.mutablePumpEventIDs = []
            }
            for id in dropped {
                store.record(
                    UntetheredRecord(key: UntetheredRecord.pumpEventKey(id), date: Date(), kind: .pumpEventDropped(id)),
                    epoch: epoch
                )
            }
        }
        store.update { data in
            for (event, id) in zip(events, identifiers) where event.dose?.isMutable == true {
                data.mutablePumpEventIDs.insert(id)
            }
        }
        for (event, identifier) in zip(events, identifiers) {
            store.update {
                $0.upsertPumpEvent(
                    id: identifier,
                    history: UntetheredAlgorithm.historyEvents(event, id: identifier, bolusIncrement: increment),
                    tdd: UntetheredAlgorithm.tddEvent(event, id: identifier, bolusIncrement: increment)
                )
            }
            if let raw = try? PropertyListSerialization.data(fromPropertyList: event.rawValue, format: .binary, options: 0) {
                store.record(
                    UntetheredRecord(key: UntetheredRecord.pumpEventKey(identifier), date: event.date, kind: .pumpEvent(raw)),
                    epoch: epoch
                )
            }
        }
        refresh()
        completion(nil)
        if bolusFinalized { DispatchQueue.main.async { self.runLoop(.treatment) } }
    }

    func pumpManager(
        _: PumpManager,
        didReadReservoirValue units: Double,
        at date: Date,
        completion: @escaping (Result<
            (newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool),
            Error
        >)
            -> Void
    ) {
        store.update { $0.reservoir = Decimal(units) }
        completion(.success((
            newValue: WatchReservoir(startDate: date, unitVolume: units),
            lastValue: nil,
            areStoredValuesContinuous: true
        )))
    }

    func pumpManager(_: PumpManager, didAdjustPumpClockBy _: TimeInterval) {}

    func pumpManagerDidUpdateState(_: PumpManager) {
        savePumpState()
    }

    func pumpManager(
        _: PumpManager,
        didRequestBasalRateScheduleChange _: BasalRateSchedule,
        completion: @escaping (Error?) -> Void
    ) {
        completion(nil)
    }

    func startDateToFilterNewPumpEvents(for _: PumpManager) -> Date {
        Date().addingTimeInterval(-24 * 60 * 60)
    }

    var detectedSystemTimeOffset: TimeInterval { 0 }

    var automaticDosingEnabled: Bool { data.grant.map { $0.dosingMode.automation != .off } ?? false }

    func pumpManager(_: PumpManager, didUpdate status: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
        updateBolusState(status)
        refresh()
    }

    func deviceManager(
        _: DeviceManager,
        logEventForDeviceIdentifier _: String?,
        type: DeviceLogEntryType,
        message: String,
        completion: ((Error?) -> Void)?
    ) {
        Task { await WatchLogger.shared.log("⌚️ Device: \(message)") }
        // ponytail: matched on G7SensorKit's log line, which is the only place it reports a link error;
        // move to a delegate call if the kit ever reports one. 14 = the peer removed the pairing,
        // 15 = encryption timed out: the sensor no longer has this watch's bond.
        if type == .error, message.contains("CBErrorDomain Code=14") || message.contains("CBErrorDomain Code=15") {
            DispatchQueue.main.async {
                self.setError(String(
                    localized: "The sensor refuses this watch's Bluetooth pairing. On the watch, open Settings › Bluetooth, forget the DXCM device and wait for the next reading."
                ))
            }
        }
        completion?(nil)
    }

    func deviceManagerControlDidBecomeReady(_: DeviceManager) {
        Task { await WatchLogger.shared.log("⌚️ Untethered: pump link ready") }
    }

    // MARK: Alerts

    /// A scheduled alert (the G7 schedules its session-end warnings days ahead) shows from when it is due.
    func issueAlert(_ alert: LoopKit.Alert) {
        let content = alert.foregroundContent ?? alert.backgroundContent
        let delay: TimeInterval?
        switch alert.trigger {
        case .immediate: delay = nil
        case let .delayed(interval): delay = interval
        case let .repeating(interval): delay = interval
        }
        let pending = UntetheredWatchData.PendingPumpAlert(
            managerIdentifier: alert.identifier.managerIdentifier,
            alertIdentifier: alert.identifier.alertIdentifier,
            title: content.title,
            body: content.body,
            due: delay.map { Date().addingTimeInterval($0) }
        )
        store.update {
            $0.pendingPumpAlerts.removeAll { $0.id == pending.id }
            $0.pendingPumpAlerts.append(pending)
        }
        refresh()
        // the phone sounds its own devices' alerts until the watch takes over
        if isActive { notify(id: pending.id, title: pending.title, body: pending.body, after: delay) }
    }

    /// Alerts issued before the takeover sound on the wrist from it on; at the hand-back the phone's again.
    func handOverAlertNotifications(toWatch: Bool) {
        let alerts = data.pendingPumpAlerts
        guard toWatch else {
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: alerts.map(\.id) + [Self.notLoopingID, Self.noReadingsID])
            return
        }
        scheduleNotLoopingAlert(from: data.lastLoopDate ?? Date())
        scheduleNoReadingsAlert(from: data.glucose.map(\.dateString).max() ?? Date())
        for alert in alerts {
            guard let due = alert.due, due > Date() else { continue }
            notify(id: alert.id, title: alert.title, body: alert.body, after: due.timeIntervalSinceNow)
        }
    }

    func retractAlert(identifier: LoopKit.Alert.Identifier) {
        let id = identifier.managerIdentifier + "." + identifier.alertIdentifier
        store.update { $0.pendingPumpAlerts.removeAll { $0.id == id } }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        refresh()
    }

    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier, completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(
            data.pendingPumpAlerts
                .contains { $0.id == identifier.managerIdentifier + "." + identifier.alertIdentifier }
        ))
    }

    func lookupAllUnretracted(managerIdentifier _: String, completion: @escaping (Result<[PersistedAlert], Error>) -> Void) {
        completion(.success([]))
    }

    func lookupAllUnacknowledgedUnretracted(
        managerIdentifier _: String,
        completion: @escaping (Result<[PersistedAlert], Error>) -> Void
    ) {
        completion(.success([]))
    }

    func recordRetractedAlert(_: LoopKit.Alert, at _: Date) {}
}

// MARK: - CGM

extension UntetheredWatchManager: CGMManagerDelegate {
    func startDateToFilterNewData(for _: CGMManager) -> Date? {
        data.glucose.map(\.dateString).max()
    }

    /// The most a loop holds the app awake: a pod command, retries included, is done well within it.
    static let loopHoldLimit: TimeInterval = 30

    /// Keeps the app running until `release` is called, `wait` has passed, or watchOS ends it, whichever comes first.
    static func holdProcess(reason: String, upTo wait: TimeInterval) -> () -> Void {
        let gate = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
                if expired { return }
                _ = gate.wait(timeout: .now() + wait)
            }
        }
        let once = NSLock()
        var released = false
        return {
            once.lock()
            defer { once.unlock() }
            guard !released else { return }
            released = true
            gate.signal()
        }
    }

    /// Readings arrive but no loop got through for this long: the pod link is presumed stuck.
    static let podLinkStallLimit: TimeInterval = 15 * 60
    /// At most one reconnect per this interval, so a pod that is really out of reach isn't hammered.
    static let podLinkResetInterval: TimeInterval = 10 * 60

    /// A loop that keeps failing to reach the pod while readings come in usually has a stuck connection, which
    /// otherwise only opening the app clears. The link is torn down and searched for afresh.
    func checkPodLink(now: Date = Date()) {
        guard data.session.phase == .active, !isLooping, !isBolusing, let pump = pumpManager,
              let lastLoop = data.lastLoopDate ?? data.session.startStatus?.date,
              now.timeIntervalSince(lastLoop) > Self.podLinkStallLimit,
              now.timeIntervalSince(lastPodLinkReset ?? .distantPast) > Self.podLinkResetInterval,
              // without readings the sensor is what's missing, and its own alarm says so (2026-10-19 18:04)
              let newest = data.glucose.map(\.dateString).max(), now.timeIntervalSince(newest) < 11 * 60
        else { return }
        if lastPodLinkReset == nil {
            notify(
                id: Self.podLinkID,
                title: Self.podLinkTitle,
                body: Self.podLinkBody(minutes: Int(Self.podLinkStallLimit / 60))
            )
        }
        lastPodLinkReset = now
        let releaseHold = Self.holdProcess(reason: "Untethered pod reconnect", upTo: Self.loopHoldLimit)
        let minutes = Int(now.timeIntervalSince(lastLoop) / 60)
        let outcome = pump.escalateTakeControl() ?? "nothing to escalate"
        let diagnostics = pump.connectionDiagnostics() ?? ""
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: no loop for \(minutes) min, reconnecting the pod: \(outcome) \(diagnostics)",
                force: true
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loopHoldLimit) { releaseHold() }
    }

    /// A loop reached the pod again: the search an escalation started ends, and so does its notice.
    func podLinkRecovered(_ pump: PumpManager & ExclusiveDeviceControl) {
        guard lastPodLinkReset != nil else { return }
        lastPodLinkReset = nil
        pump.endTakeEscalation()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.podLinkID])
    }

    static let podLinkID = "untethered.podLink"
    private static var podLinkTitle: String { String(localized: "Pod Not Reachable") }
    private static func podLinkBody(minutes: Int) -> String {
        String(
            localized: "The watch hasn't reached the pod for \(minutes) minutes. Open Trio on the watch: it reconnects there."
        )
    }

    func cgmManager(_: CGMManager, hasNew readingResult: CGMReadingResult) {
        // outside a session the link only stays warm; the phone reads the same sensor
        guard isActive, case let .newData(samples) = readingResult, !samples.isEmpty else { return }
        let known = Set(data.glucose.map { Int($0.dateString.timeIntervalSince1970 / 30) })
        // as `GlucoseStorage.filterTooFrequentGlucose`: a new reading within 3.5 min of the previous one is
        // dropped; older readings are backfill and only need to be new
        var lastDate = data.glucose.map(\.dateString).max() ?? .distantPast
        var fresh: [NewGlucoseSample] = []
        for sample in samples.sorted(by: { $0.date < $1.date })
            where !sample.wasUserEntered && !known.contains(Int(sample.date.timeIntervalSince1970 / 30))
        {
            if sample.date > lastDate {
                guard sample.date.addingTimeInterval(-3.5 * 60) > lastDate else { continue }
                lastDate = sample.date
            }
            fresh.append(sample)
        }
        guard !fresh.isEmpty else { return }
        let epoch = data.session.epoch
        for sample in fresh {
            let value = Int(sample.quantity.doubleValue(for: HKUnit(from: "mg/dL")))
            let glucose = BloodGlucose(
                id: UUID().uuidString,
                sgv: value,
                direction: .untethered(sample.trend),
                date: Decimal(Int(sample.date.timeIntervalSince1970 * 1000)),
                dateString: sample.date,
                unfiltered: Decimal(value),
                glucose: value,
                type: "sgv"
            )
            store.update { $0.glucose.append(glucose) }
            store.record(
                UntetheredRecord(key: UntetheredRecord.glucoseKey(sample.date), date: sample.date, kind: .glucose(glucose)),
                epoch: epoch
            )
        }
        smoothGlucose()
        refresh()
        checkAlarms()
        scheduleNoReadingsAlert(from: lastDate)
        publishToWatchState()
        checkPodLink()
        runLoop(.newGlucose)
    }

    func cgmManager(_: CGMManager, hasNew _: [PersistedCgmEvent]) {}

    func cgmManagerWantsDeletion(_: CGMManager) {}

    func cgmManagerDidUpdateState(_: CGMManager) {
        saveCGMState()
    }

    func credentialStoragePrefix(for _: CGMManager) -> String { "untethered" }

    func cgmManager(_: CGMManager, didUpdate _: CGMManagerStatus) {}
}

private extension BloodGlucose.Direction {
    static func untethered(_ trend: LoopKit.GlucoseTrend?) -> BloodGlucose.Direction {
        switch trend {
        case .upUpUp: return .doubleUp
        case .upUp: return .singleUp
        case .up: return .fortyFiveUp
        case .flat: return .flat
        case .down: return .fortyFiveDown
        case .downDown: return .singleDown
        case .downDownDown: return .doubleDown
        default: return .none
        }
    }
}

// MARK: - Alarms and the screens

extension UntetheredWatchManager {
    private static var lastAlarm: [String: Date] = [:]

    /// The watch is the only device watching glucose: low, high and a stalled loop sound here.
    /// Run on every reading and every wake: the loop and sensor alarms are for exactly the times no reading comes.
    /// The same fixed urgent-low line Trio's own glucose alarms use by default.
    private static let urgentLowMgDL = 54

    private static func formatted(_ mgdl: Int, units: GlucoseUnits) -> String {
        units == .mmolL ? String(format: "%.1f", Double(mgdl) * 0.0555) : "\(mgdl)"
    }

    func checkAlarms() {
        guard isActive, let grant = data.grant else { return }
        let now = Date()
        let latest = data.glucose.max(by: { $0.dateString < $1.dateString })
        // a reading old enough to be stale doesn't sound as low or high again
        if let latest, let value = latest.glucose ?? latest.sgv, now.timeIntervalSince(latest.dateString) < 12 * 60 {
            let body = "\(Self.formatted(value, units: grant.units)) \(grant.units.rawValue)"
            if value <= Self.urgentLowMgDL {
                alarm("urgentLow", title: String(localized: "Urgent Low"), body: body, every: 5 * 60)
            } else if Decimal(value) <= grant.lowGlucose {
                alarm("low", title: String(localized: "Low Glucose"), body: body, every: 15 * 60)
            } else if Decimal(value) >= grant.highGlucose {
                alarm("high", title: String(localized: "High Glucose"), body: body, every: 60 * 60)
            }
        }
        // two missed readings on the sensor's 5-minute grid
        if let newest = latest?.dateString, now.timeIntervalSince(newest) > Self.noReadingsAfter {
            let minutes = Int(now.timeIntervalSince(newest) / 60)
            alarm("sensor", title: Self.noReadingsTitle, body: Self.noReadingsBody(minutes: minutes), every: 30 * 60)
        }
        if !data.podEnded, let lastLoop = data.lastLoopDate ?? data.session.startStatus?.date,
           now.timeIntervalSince(lastLoop) > Self.notLoopingAfter
        {
            alarm("loop", title: Self.notLoopingTitle, body: Self.notLoopingBody, every: 30 * 60)
        }
    }

    /// The pod as the Devices page shows it, for the phone's home screen while the watch has the pump. One key, so
    /// only the newest goes home.
    func recordPumpStatus() {
        guard isActive else { return }
        publishToWatchState()
        var isSuspended = false
        if case .suspended = pumpManager?.status.basalDeliveryState { isSuspended = true }
        let now = Date()
        let status = UntetheredPumpStatus(
            date: now,
            reservoir: watchPumpReservoir(pumpManager) ?? data.reservoir,
            expiresAt: watchPumpExpiresAt(pumpManager),
            isSuspended: isSuspended
        )
        store.record(
            UntetheredRecord(key: UntetheredRecord.pumpStatusKey, date: now, kind: .pumpStatus(status)),
            epoch: data.session.epoch
        )
    }

    /// The sensor alarm's own identifier, so the booked one and the one `checkAlarms` raises are one notification.
    static let noReadingsID = "untethered.sensor"
    /// Two readings missed on the sensor's 5-minute grid.
    private static let noReadingsAfter: TimeInterval = 11 * 60
    private static var noReadingsTitle: String { String(localized: "No Sensor Readings") }
    private static func noReadingsBody(minutes: Int) -> String {
        String(
            localized: "The watch has had no glucose reading for \(minutes) minutes. Keep it near the sensor; it keeps trying."
        )
    }

    /// Booked after every new reading, and at the takeover: it sounds when nothing wakes the watch app any more, as
    /// when a lost Bluetooth callback leaves no connect standing; opening the app is what puts that right.
    func scheduleNoReadingsAlert(from lastReading: Date) {
        notify(
            id: Self.noReadingsID,
            title: Self.noReadingsTitle,
            body: Self.noReadingsBody(minutes: Int(Self.noReadingsAfter / 60)),
            after: lastReading.addingTimeInterval(Self.noReadingsAfter).timeIntervalSinceNow
        )
    }

    static let notLoopingID = "untethered.loop"
    private static let notLoopingAfter: TimeInterval = 20 * 60
    private static var notLoopingTitle: String { String(localized: "Not Looping") }
    private static var notLoopingBody: String { String(localized: "The watch hasn't looped for 20 minutes.") }

    /// Booked 20 minutes ahead after every loop, and at the takeover: it sounds even when nothing wakes the watch app
    /// to check. The next loop books it again; a hand-back or a pod ended on the watch takes it back.
    func scheduleNotLoopingAlert(from lastLoop: Date) {
        notify(
            id: Self.notLoopingID,
            title: Self.notLoopingTitle,
            body: Self.notLoopingBody,
            after: lastLoop.addingTimeInterval(Self.notLoopingAfter).timeIntervalSinceNow
        )
    }

    /// Every untethered notification's identifier starts with it, so they show with Trio open on the wrist too.
    static let notificationPrefix = "untethered."

    private func alarm(_ kind: String, title: String, body: String, every interval: TimeInterval) {
        guard (Self.lastAlarm[kind] ?? .distantPast).addingTimeInterval(interval) < Date() else { return }
        Self.lastAlarm[kind] = Date()
        notify(id: Self.notificationPrefix + kind, title: title, body: body)
        // felt at once while the app runs, as the watch's G7 reader alerts; the notification may wait for the screen
        WKInterfaceDevice.current().play(kind == "high" ? .notification : .failure)
        Task { await WatchLogger.shared.log("⌚️ Untethered alarm: \(title) \(body)", force: true) }
    }

    func notify(id: String, title: String, body: String, after delay: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // not time-sensitive: the watch app has no entitlement for it; plain, as the reader's alerts that do arrive
        let trigger = delay.flatMap { $0 > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) : nil }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            Task {
                await WatchLogger.shared.log("⌚️ Untethered: notification \(id) failed: \(error.localizedDescription)", force: true)
            }
        }
    }

    /// What the pump delivers now, for the status page: the running temp, else the scheduled rate. A loop that keeps
    /// the running temp sets no rate of its own, so its determination can't say.
    var deliveredBasalRate: Decimal? {
        guard let pump = pumpManager, let grant = data.grant else { return nil }
        switch pump.status.basalDeliveryState {
        case let .tempBasal(dose): return Decimal(dose.unitsPerHour)
        case .active: return BolusCalculator.scheduleValue(grant.basalProfile.map { ($0.start, $0.rate) }, at: Date())
        default: return nil
        }
    }

    /// The main screens read `WatchState`; while untethered it shows the watch's own data.
    func publishToWatchState() {
        guard isActive, let grant = data.grant else { return }
        let state = WatchState.shared
        let units = grant.units
        func display(_ mgdl: Int) -> Double {
            units == .mgdL ? Double(mgdl) : NSDecimalNumber(decimal: Decimal(mgdl).asMmolL).doubleValue
        }
        // as `BaseWatchManager.setupWatchState`: the dynamic scheme ramps between fixed ends around the target
        let scheme = GlucoseColorScheme(rawValue: grant.glucoseColorScheme) ?? .staticColor
        let isDynamic = scheme == .dynamicColor
        let target = BolusCalculator.scheduleValue(grant.bgTargets.targets.map { ($0.start, $0.low) }, at: Date())
        func color(_ mgdl: Int) -> Color {
            getDynamicGlucoseColor(
                glucoseValue: Decimal(mgdl),
                highGlucoseColorValue: isDynamic ? 220 : grant.highGlucose,
                lowGlucoseColorValue: isDynamic ? 55 : grant.lowGlucose,
                targetGlucose: target,
                glucoseColorScheme: scheme
            )
        }
        let readings = data.glucose.sorted { $0.dateString < $1.dateString }
            .compactMap { reading in (reading.glucose ?? reading.sgv).map { (reading.dateString, $0) } }
        state.glucoseValues = readings.map { (date: $0.0, glucose: display($0.1), color: color($0.1)) }
        if let latest = readings.last {
            state.currentGlucose = units == .mgdL ? "\(latest.1)" : Decimal(latest.1).formattedAsMmolL
            let inRange = Decimal(latest.1) > grant.lowGlucose && Decimal(latest.1) < grant.highGlucose
            state
                .currentGlucoseColorString = inRange ? "#ffffff" : color(latest.1).toHexString()
            state.trend = data.glucose.max(by: { $0.dateString < $1.dateString })?.direction?.rawValue
            if readings.count >= 2 {
                let delta = display(latest.1) - display(readings[readings.count - 2].1)
                let formatted = units == .mgdL ? String(format: "%.0f", delta) : String(format: "%.1f", delta)
                state.delta = delta < 0 ? formatted : "+" + formatted
            }
        }
        if let determination = data.lastDetermination {
            state.iob = determination.iob.map { String(format: "%.2f", NSDecimalNumber(decimal: $0).doubleValue) }
            state.cob = determination.cob.map { $0.formatted(.number.precision(.fractionLength(0))) }
            // as `AppleWatchManager`: two hours of each line, or the cone between them
            let series = [
                "iob": determination.predictions?.iob, "cob": determination.predictions?.cob,
                "uam": determination.predictions?.uam, "zt": determination.predictions?.zt
            ].compactMapValues { $0.map { Array($0.prefix(24)) } }.filter { !$0.value.isEmpty }
            state.forecastStartDate = series.isEmpty ? nil : determination.deliverAt ?? determination.timestamp
            if state.isForecastCone {
                let count = series.values.map(\.count).min() ?? 0
                state.forecastConeMin = (0 ..< count).map { index in display(series.values.map { $0[index] }.min() ?? 0) }
                state.forecastConeMax = (0 ..< count).map { index in display(series.values.map { $0[index] }.max() ?? 0) }
                state.forecastLines = [:]
            } else {
                state.forecastLines = series.mapValues { $0.map(display) }
                state.forecastConeMin = []
                state.forecastConeMax = []
            }
        }
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        let boluses = data.pumpHistory.filter { [.bolus, .smb].contains($0.type) && $0.timestamp >= dayAgo }
            .map { event in
                WatchTreatmentMarker(
                    id: event.id,
                    date: event.timestamp,
                    kind: event.type == .smb || event.isSMB == true ? .smb : .bolus
                )
            }
        let carbs = data.carbs.filter { ($0.actualDate ?? $0.createdAt) >= dayAgo && !($0.isFPU ?? false) && $0.carbs > 0 }
            .map { entry in
                let date = entry.actualDate ?? entry.createdAt
                return WatchTreatmentMarker(id: entry.id ?? "\(date.timeIntervalSince1970)", date: date, kind: .carbs)
            }
        state.treatmentMarkers = boluses + carbs
        if let lastLoop = data.lastLoopDate {
            // the phone's own rounding, so the ring turns as it does there
            let minutes = Int((Date().timeIntervalSince(lastLoop) - 30) / 60) + 1
            state.lastLoopTime = minutes > 1440 ? "--" : "\(minutes) min"
        }
        state.lastWatchStateUpdate = Date().timeIntervalSince1970
        state.showSyncingAnimation = false
        let activeOverrideID = activeOverride(at: Date())?.id
        state.overridePresets = grant.overridePresets
            .map { OverridePresetWatch(name: $0.name, isEnabled: $0.id == activeOverrideID) }
        let activeTempTargetID = activeTempTarget(at: Date())?.id
        state.tempTargetPresets = grant.tempTargetPresets.map {
            TempTargetPresetWatch(name: $0.name ?? "", isEnabled: $0.id == activeTempTargetID)
        }
        state.maxBolus = grant.maxBolus
        state.maxCarbs = grant.maxCarbs
        ComplicationStore.update(
            from: state,
            isMmol: units != .mgdL,
            lowMgDL: NSDecimalNumber(decimal: grant.lowGlucose).doubleValue,
            highMgDL: NSDecimalNumber(decimal: grant.highGlucose).doubleValue,
            colorScheme: grant.glucoseColorScheme,
            targetMgDL: NSDecimalNumber(decimal: target).doubleValue
        )
    }
}
