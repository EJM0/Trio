import Foundation
import LoopKit

/// Treatments on the watch while it holds the pump: bolus and carbs, suspend and resume, and cancelling the
/// override or temp target the loan started with, and start one of the phone's presets.
extension WatchLoanHost {
    /// The calculator's recommendation from the last determination; nil before the first cycle.
    func recommendBolus(carbs: Decimal) -> CalculationResult? {
        guard let snapshot, let pump, let outputs = lastOutputs, let determination = outputs.determination,
              let isf = determination.isf ?? outputs.profile.sens,
              let carbRatio = outputs.profile.carbRatio,
              let target = determination.current_target
        else { return nil }
        let now = env.now()
        let readings = (snapshot.oref.glucose + records.snapshot.glucose)
            .sorted { $0.dateString > $1.dateString }
            .map { (date: Optional($0.dateString), glucose: Int16($0.glucose ?? $0.sgv ?? 0)) }
        let glucose = BolusCalculator.glucoseVariables(readings: readings, now: now)
        let preferences = snapshot.oref.preferences ?? Preferences()
        let input = CalculationInput(
            carbs: carbs,
            currentBG: glucose.currentBG,
            deltaBG: glucose.deltaBG,
            target: target,
            isf: isf,
            carbRatio: carbRatio,
            iob: outputs.iob.first?.iob ?? 0,
            cob: Int16(truncating: (outputs.meal?.mealCOB ?? 0) as NSNumber),
            useFattyMealCorrectionFactor: false,
            fattyMealFactor: snapshot.bolusCalculator.fattyMealFactor,
            useSuperBolus: false,
            sweetMealFactor: snapshot.bolusCalculator.sweetMealFactor,
            basal: outputs.profile.currentBasal ?? 0,
            fraction: snapshot.bolusCalculator.fraction,
            maxBolus: snapshot.oref.pumpSettings.maxBolus,
            maxIOB: preferences.maxIOB,
            maxCOB: preferences.maxCOB,
            minPredBG: determination.minPredBG ?? 0,
            lastLoopDate: cycleInfo.lastConfirmedCycleAt ?? .distantPast
        )
        return BolusCalculator.calculate(input, now: now) {
            Decimal(pump.roundToSupportedBolusVolume(units: $0.nearestDouble))
        }
    }

    /// A manual bolus, with optional carbs recorded first. Checked against max bolus, max IOB (recomputed now)
    /// and recent boluses, then written down before it is sent. An unconfirmed bolus is never retried.
    func requestBolus(units: Decimal, carbs: Decimal = 0) async {
        var accepted: LoanPump?
        await serially { accepted = await self.bolusNow(units: units, carbs: carbs) }
        if let accepted {
            await followDelivery(accepted)
        }
    }

    /// The pump when it accepted the bolus.
    private func bolusNow(units: Decimal, carbs: Decimal) async -> LoanPump? {
        bolus = .requested
        guard case .holding = state, let pump, let snapshot, units > 0 else {
            bolus = .failed(String(localized: "Trio on Watch doesn't control the pump.", comment: "Watch bolus failure"))
            return nil
        }
        if !intents.isEmpty { await resolveIntents() }
        guard intents.isEmpty, !pump.status.deliveryIsUncertain else {
            bolus = .failed(String(
                localized: "The pump hasn't confirmed the last command. Check recent doses before trying again.",
                comment: "Watch bolus failure"
            ))
            return nil
        }
        let now = env.now()
        let preferences = snapshot.oref.preferences ?? Preferences()
        let bolusIncrement = preferences.bolusIncrement
        var inputs = WatchLoopInputs.orefInputs(
            snapshot: snapshot,
            records: records.loopRecords(bolusIncrement: bolusIncrement),
            now: now,
            currentTemp: currentTemp(pump.status.basalDeliveryState, now: now),
            autosens: cycleInfo.autosens,
            microBolusAllowed: false
        )
        inputs.autosens = inputs.autosens ?? lastOutputs?.autosens
        let currentIOB = try? await Self.runOref(inputs).iob.first?.iob
        let recent = records.recentBolusUnits(
            since: now.addingTimeInterval(-Double(BolusSafetyEvaluator.recentBolusWindowMinutes * 60))
        ) + snapshot.oref.pumpHistory
            .filter {
                $0.type == .bolus && $0.timestamp > now
                    .addingTimeInterval(-Double(BolusSafetyEvaluator.recentBolusWindowMinutes * 60))
            }
            .reduce(Decimal(0)) { $0 + ($1.amount ?? 0) }
        let safety = BolusSafetyEvaluator.evaluate(
            bolusAmount: units,
            inputs: BolusSafetyInputs(
                maxBolus: snapshot.oref.pumpSettings.maxBolus,
                maxIOB: preferences.maxIOB,
                currentIOB: currentIOB,
                totalRecentBolus: recent
            )
        )
        if case let .rejected(reason) = safety {
            WatchLogger.shared.warning(.bolus, "Watch bolus of \(units) U refused: \(reason)")
            bolus = .failed(Self.text(for: reason))
            return nil
        }

        if carbs > 0 {
            do {
                let (records, entry) = (records, Self.carbsEntry(carbs, at: now))
                try await WatchLoanFiles.io { try records.storeCarbs(entry) }
            } catch {
                WatchLogger.shared.error(.treatments, "Storing carbs failed; no bolus sent", error: error)
                alerts.postNotSaved()
                bolus =
                    .failed(String(localized: "Trio on Watch couldn't save. Nothing was sent.", comment: "Watch bolus failure"))
                return nil
            }
        }

        WatchLogger.shared.info(.bolus, "Watch bolus of \(units) U requested, IOB \(currentIOB.map { "\($0) U" } ?? "unknown")")
        let outcome = await command(.bolus(units: units, automatic: false))
        if outcome == .confirmed {
            bolus = .accepted
            return pump
        }
        if outcome == .uncertain {
            bolus = .uncertain
        } else {
            bolus =
                .failed(String(localized: "The pump didn't take the bolus. Nothing was given.", comment: "Watch bolus failure"))
        }
        return nil
    }

    /// Accepted, then delivering until the pump reports no bolus running.
    private func followDelivery(_ pump: LoanPump) async {
        bolus = .delivering
        for _ in 0 ..< 600 {
            guard pump.status.bolusState != .noBolus else { break }
            if bolus == .cancelled { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if bolus == .delivering {
            bolus = .done
            WatchLogger.shared.info(.bolus, "Watch bolus delivered")
        }
    }

    func cancelBolus() async {
        guard let pump, bolus == .delivering || bolus == .accepted else { return }
        do {
            _ = try await pump.cancelBolus()
            bolus = .cancelled
            WatchLogger.shared.info(.bolus, "Watch bolus cancelled")
        } catch {
            WatchLogger.shared.warning(.bolus, "Cancelling the bolus failed", error: error)
        }
    }

    /// Carbs alone; the next cycle reads them.
    func addCarbs(_ grams: Decimal) async {
        await serially {
            guard case .holding = self.state, grams > 0 else { return }
            do {
                let (records, entry) = (self.records, Self.carbsEntry(grams, at: self.env.now()))
                try await WatchLoanFiles.io { try records.storeCarbs(entry) }
                WatchLogger.shared.info(.treatments, "Carbs entered on the watch: \(grams) g")
            } catch {
                WatchLogger.shared.error(.treatments, "Storing carbs failed", error: error)
                self.alerts.postNotSaved()
            }
        }
        await runCycle(trigger: .user)
    }

    static func carbsEntry(_ grams: Decimal, at date: Date) -> CarbsEntry {
        OrefInputs.carbsEntry(id: UUID(), date: date, carbs: grams.nearestDouble, fat: 0, protein: 0, isFPU: false)
    }

    func suspendInsulin() async {
        await serially {
            let outcome = await self.command(.suspend)
            WatchLogger.shared.info(.treatments, "Insulin suspend from the watch: \(outcome)")
        }
    }

    func resumeInsulin() async {
        await serially {
            let outcome = await self.command(.resume)
            WatchLogger.shared.info(.treatments, "Insulin resume from the watch: \(outcome)")
        }
        await runCycle(trigger: .user)
    }

    func cancelOverride() async {
        await serially {
            guard case .holding = self.state else { return }
            let (records, now) = (self.records, self.env.now())
            do { try await WatchLoanFiles.io { try records.cancelOverride(at: now) } } catch {
                WatchLogger.shared.error(.treatments, "Cancelling the override failed", error: error)
                self.alerts.postNotSaved()
                return
            }
            WatchLogger.shared.info(.treatments, "Override cancelled on the watch")
        }
        await runCycle(trigger: .user)
    }

    /// Starts one of the phone's presets in place of whatever runs; false when it couldn't be saved.
    func startAdjustmentConfirmed(_ kind: WatchLoanAdjustmentChange.Kind, presetID: String) async -> Bool {
        var saved = false
        await serially {
            guard case .holding = self.state, let snapshot = self.snapshot else { return }
            let name: String?
            switch kind {
            case .tempTarget: name = snapshot.tempTargetPresets.first { $0.id == presetID }?.name
            case .override: name = nil
            }
            guard let name else { return }
            let (records, now) = (self.records, self.env.now())
            do {
                try await WatchLoanFiles.io { try records.startAdjustment(kind, presetID: presetID, name: name, at: now) }
                saved = true
                WatchLogger.shared.info(.treatments, "\(kind.rawValue) \(name) started on the watch")
            } catch {
                WatchLogger.shared.error(.treatments, "Starting the \(kind.rawValue) failed", error: error)
                self.alerts.postNotSaved()
            }
        }
        if saved { await runCycle(trigger: .user) }
        return saved
    }

    func cancelTempTarget() async {
        await serially {
            guard case .holding = self.state else { return }
            let (records, now) = (self.records, self.env.now())
            do { try await WatchLoanFiles.io { try records.cancelTempTarget(at: now) } } catch {
                WatchLogger.shared.error(.treatments, "Cancelling the temp target failed", error: error)
                self.alerts.postNotSaved()
                return
            }
            WatchLogger.shared.info(.treatments, "Temp target cancelled on the watch")
        }
        await runCycle(trigger: .user)
    }

    static func text(for rejection: BolusSafetyRejection) -> String {
        switch rejection {
        case let .exceedsMaxBolus(maxBolus):
            return String(
                localized: "More than your max bolus of \(WatchLoanAlerts.insulin(maxBolus)).",
                comment: "Watch bolus refusal; the value is an amount of insulin with its unit"
            )
        case .iobUnavailable:
            return String(localized: "Insulin on board can't be worked out right now.", comment: "Watch bolus refusal")
        case let .exceedsMaxIOB(_, maxIOB):
            return String(
                localized: "This would go over your max IOB of \(WatchLoanAlerts.insulin(maxIOB)).",
                comment: "Watch bolus refusal; the value is an amount of insulin with its unit"
            )
        case .recentBolusWithinWindow:
            return String(localized: "A bolus was given in the last few minutes.", comment: "Watch bolus refusal")
        }
    }
}

extension PumpManager {
    func suspendDelivery() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            suspendDelivery { error in error.map { done.resume(throwing: $0) } ?? done.resume() }
        }
    }

    func resumeDelivery() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            resumeDelivery { error in error.map { done.resume(throwing: $0) } ?? done.resume() }
        }
    }
}
