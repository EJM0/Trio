import Foundation

/// The oref pipeline as pure stages: profile, autosens, meal, IOB and determination.
/// The phone's `OpenAPS` calls the stages one by one and persists between them; `run` chains them.
enum OrefRun {
    struct Outputs: Codable {
        var pumpProfile: Profile
        var profile: Profile
        var autosens: Autosens
        var meal: ComputedCarbs?
        var iob: [IobResult]
        var trioCustomOrefVariables: TrioCustomOrefVariables
        var determination: Determination?
    }

    static let autosensMaxAge = TimeInterval(minutes: 30)

    static func run(_ inputs: OrefInputs) throws -> Outputs {
        let storedPreferences = inputs.preferences ?? Preferences()

        let profiles = try profiles(
            pumpSettings: inputs.pumpSettings,
            bgTargets: inputs.bgTargets,
            basalProfile: inputs.basalProfile,
            insulinSensitivities: inputs.insulinSensitivities,
            carbRatios: inputs.carbRatios,
            tempTargets: inputs.tempTargets,
            preferences: profilePreferences(
                storedPreferences,
                activeTempTarget: inputs.activeTempTarget,
                dosingMode: inputs.dosingMode
            ),
            clock: inputs.clock
        )
        // the phone reads profile, autosens and the custom variables back from JSON files; same round trips here
        let profile = try JSONBridge.profile(from: profiles.profile.rawJSON)

        let autosens: Autosens
        if let cached = inputs.autosens {
            autosens = cached
        } else {
            var computed = try self.autosens(
                glucose: inputs.glucose,
                pumpHistory: inputs.pumpHistory,
                basalProfile: inputs.basalProfile,
                profile: profile,
                carbs: inputs.carbs,
                tempTargets: inputs.tempTargets,
                clock: inputs.clock
            )
            computed.timestamp = inputs.clock
            autosens = try JSONBridge.from(string: computed.rawJSON)
        }

        let preferences = storedPreferences.clamped(for: inputs.dosingMode)
        let glucose = OrefInputs.glucose(
            inputs.glucose,
            since: OrefInputs.glucoseStart(hours: OrefInputs.determinationGlucoseHours(preferences), now: inputs.clock)
        )
        let determinationProfile = determinationProfile(
            profile,
            supportedBasalRates: inputs.supportedBasalRates,
            dosingMode: inputs.dosingMode
        )

        let meal = try meal(
            pumphistory: inputs.pumpHistory,
            profile: determinationProfile,
            basalProfile: inputs.basalProfile,
            clock: inputs.clock,
            carbs: inputs.carbs,
            glucose: glucose
        )
        let iob = try iob(pumphistory: inputs.pumpHistory, profile: determinationProfile, clock: inputs.clock, autosens: autosens)

        let trioCustomOrefVariables = try JSONBridge.trioCustomOrefVariables(
            from: trioCustomOrefVariables(
                preferences: inputs.preferences,
                tddHistory: inputs.tddHistory,
                activeOverride: inputs.activeOverride,
                now: inputs.clock
            ).rawJSON
        )

        let determination = try determine(
            glucose: glucose,
            currentTemp: inputs.currentTemp,
            iob: iob,
            profile: determinationProfile,
            autosens: autosens,
            meal: meal,
            preferences: preferences,
            hasSufficientTDD: inputs.hasSufficientTDD,
            trioCustomOrefVariables: trioCustomOrefVariables,
            currentTime: inputs.clock
        )

        return Outputs(
            pumpProfile: profiles.pumpProfile,
            profile: profiles.profile,
            autosens: autosens,
            meal: meal,
            iob: iob,
            trioCustomOrefVariables: trioCustomOrefVariables,
            determination: determination
        )
    }

    // MARK: - Profile

    /// Preferences for profile generation: the active temp target's half basal target, then the dosing-mode clamp.
    static func profilePreferences(
        _ preferences: Preferences,
        activeTempTarget: OrefInputs.TempTargetState?,
        dosingMode: DosingMode
    ) -> Preferences {
        let defaultHalfBasalTarget = preferences.halfBasalExerciseTarget
        var adjustedPreferences = preferences

        if let activeTempTarget {
            // Compute effective HBT - handles both custom HBT and standard TT (where HBT might need adjustment)
            let effectiveHBT = TempTargetCalculations.computeEffectiveHBT(
                tempTargetHalfBasalTarget: activeTempTarget.halfBasalTarget,
                settingHalfBasalTarget: defaultHalfBasalTarget,
                target: activeTempTarget.target,
                autosensMax: preferences.autosensMax
            )

            if let effectiveHBT, effectiveHBT != defaultHalfBasalTarget {
                adjustedPreferences.halfBasalExerciseTarget = effectiveHBT
                let percentage = Int(TempTargetCalculations.computeAdjustedPercentage(
                    halfBasalTarget: effectiveHBT,
                    target: activeTempTarget.target,
                    autosensMax: preferences.autosensMax
                ).rounded())
                debug(
                    .algorithm,
                    "Temp target \(activeTempTarget.target) mg/dL: half basal target \(defaultHalfBasalTarget) -> \(effectiveHBT) mg/dL, \(percentage)%"
                )
            }
        }
        // Overwrite the lowTTlowersSens if autosensMax does not support it
        if preferences.lowTemptargetLowersSensitivity, preferences.autosensMax <= 1 {
            adjustedPreferences.lowTemptargetLowersSensitivity = false
            debug(.algorithm, "Low temp target lowers sensitivity off: autosens max \(preferences.autosensMax) is 1 or below")
        }

        // clamp after the HBT block above, which needs the user's real autosensMax
        return adjustedPreferences.clamped(for: dosingMode)
    }

    static func profiles(
        pumpSettings: PumpSettings,
        bgTargets: BGTargets,
        basalProfile: [BasalProfileEntry],
        insulinSensitivities: InsulinSensitivities,
        carbRatios: CarbRatios,
        tempTargets: [TempTarget],
        preferences: Preferences,
        clock: Date
    ) throws -> (pumpProfile: Profile, profile: Profile) {
        let pumpProfile = try ProfileGenerator.generate(
            pumpSettings: pumpSettings,
            bgTargets: bgTargets,
            basalProfile: basalProfile,
            isf: insulinSensitivities,
            preferences: preferences,
            carbRatios: carbRatios,
            tempTargets: tempTargets,
            clock: clock
        )

        let profile = try ProfileGenerator.generate(
            pumpSettings: pumpSettings,
            bgTargets: bgTargets,
            basalProfile: basalProfile,
            isf: insulinSensitivities,
            preferences: preferences,
            carbRatios: carbRatios,
            tempTargets: tempTargets,
            clock: clock
        )

        return (pumpProfile, profile)
    }

    // MARK: - Autosens

    /// The caller reruns autosens once the stored result is older than 30 min.
    static func isAutosensFresh(_ autosens: Autosens?, now: Date) -> Bool {
        guard let autosens else { return false }
        return (autosens.timestamp ?? .distantPast).addingTimeInterval(autosensMaxAge) > now
    }

    static func autosens(
        glucose: [BloodGlucose],
        pumpHistory: [PumpHistoryEvent],
        basalProfile: [BasalProfileEntry],
        profile: Profile,
        carbs: [CarbsEntry],
        tempTargets: [TempTarget],
        clock: Date
    ) throws -> Autosens {
        // both runs use identical inputs, so compute the treatments once;
        // gated on the same count as the generate early return
        let precomputedTreatments = glucose.count >= 72 ? try IobHistory.calcTempTreatments(
            history: pumpHistory.map { $0.computedEvent() },
            profile: profile,
            clock: clock,
            autosens: nil,
            zeroTempDuration: nil
        ) : nil

        // this logic is from prepare/autosens.js
        let ratio8h = try AutosensGenerator.generate(
            glucose: glucose,
            pumpHistory: pumpHistory,
            basalProfile: basalProfile,
            profile: profile,
            carbs: carbs,
            tempTargets: tempTargets,
            maxDeviations: 96,
            clock: clock,
            precomputedTreatments: precomputedTreatments
        )

        let ratio24h = try AutosensGenerator.generate(
            glucose: glucose,
            pumpHistory: pumpHistory,
            basalProfile: basalProfile,
            profile: profile,
            carbs: carbs,
            tempTargets: tempTargets,
            maxDeviations: 288,
            clock: clock,
            precomputedTreatments: precomputedTreatments
        )

        return ratio8h.ratio < ratio24h.ratio ? ratio8h : ratio24h
    }

    // MARK: - Determination

    static func trioCustomOrefVariables(
        preferences: Preferences?,
        tddHistory: [OrefInputs.TDDRow],
        activeOverride: OrefInputs.OverrideState?,
        now: Date
    ) -> TrioCustomOrefVariables {
        let weightPercentage = preferences?.weightPercentage ?? 1.0
        let maxSMBBasalMinutes = preferences?.maxSMBBasalMinutes ?? 30
        let maxUAMBasalMinutes = preferences?.maxUAMSMBBasalMinutes ?? 30
        let twoHoursAgo = now.addingTimeInterval(-TimeInterval(hours: 2))

        let isOverrideActive = activeOverride?.enabled ?? false
        let overridePercentage = Decimal(activeOverride?.percentage ?? 100)
        let isOverrideIndefinite = activeOverride?.indefinite ?? true
        let disableSMBs = activeOverride?.smbIsOff ?? false
        let overrideTargetBG = activeOverride?.target ?? 0

        // Calculate averages for Total Daily Dose (TDD)
        let totalTDD = tddHistory.compactMap(\.total).reduce(0, +)
        let totalDaysCount = max(tddHistory.count, 1)

        // Recent TDD data for the past two hours
        let recentTDDData = tddHistory.filter { ($0.date ?? now) >= twoHoursAgo }
        let recentDataCount = max(recentTDDData.count, 1)
        let recentTotalTDD = recentTDDData.compactMap(\.total).reduce(0, +)

        let currentTDD = tddHistory.last?.total ?? 0
        let averageTDDLastTwoHours = recentTotalTDD / Decimal(recentDataCount)
        let averageTDDLastTenDays = totalTDD / Decimal(totalDaysCount)
        let weightedTDD = weightPercentage * averageTDDLastTwoHours + (1 - weightPercentage) * averageTDDLastTenDays

        return TrioCustomOrefVariables(
            average_total_data: currentTDD > 0 ? averageTDDLastTenDays : 0,
            weightedAverage: currentTDD > 0 ? weightedTDD : 1,
            currentTDD: currentTDD,
            past2hoursAverage: currentTDD > 0 ? averageTDDLastTwoHours : 0,
            date: now,
            overridePercentage: overridePercentage,
            useOverride: isOverrideActive,
            duration: activeOverride?.duration ?? 0,
            unlimited: isOverrideIndefinite,
            overrideTarget: overrideTargetBG,
            smbIsOff: disableSMBs,
            advancedSettings: activeOverride?.advancedSettings ?? false,
            isfAndCr: activeOverride?.isfAndCr ?? false,
            isf: activeOverride?.isf ?? false,
            cr: activeOverride?.cr ?? false,
            smbIsScheduledOff: activeOverride?.smbIsScheduledOff ?? false,
            start: activeOverride?.start ?? 0,
            end: activeOverride?.end ?? 0,
            smbMinutes: activeOverride?.smbMinutes ?? maxSMBBasalMinutes,
            uamMinutes: activeOverride?.uamMinutes ?? maxUAMBasalMinutes
        )
    }

    /// The stored profile as the determination sees it.
    static func determinationProfile(_ profile: Profile, supportedBasalRates: [Decimal], dosingMode: DosingMode) -> Profile {
        var profile = profile
        // pump capability is injected here rather than persisted, so it can never go stale
        profile.supportedBasalRates = supportedBasalRates
        // derived here, not baked into profile.json, which the JS parity goldens compare
        profile.suspendOnly = dosingMode.automation == .hypoSuspendOnly
        return profile
    }

    static func iob(
        pumphistory: [PumpHistoryEvent],
        profile: Profile,
        clock: Date,
        autosens: Autosens?
    ) throws -> [IobResult] {
        // FIXME: For now we'll just remove duplicate suspends here (ISSUE-399)
        let pumphistory = pumphistory.removingDuplicateSuspendResumeEvents()

        return try IobGenerator.generate(
            history: pumphistory,
            profile: profile,
            clock: clock,
            autosens: autosens
        )
    }

    static func meal(
        pumphistory: [PumpHistoryEvent],
        profile: Profile,
        basalProfile: [BasalProfileEntry],
        clock: Date,
        carbs: [CarbsEntry],
        glucose: [BloodGlucose]
    ) throws -> ComputedCarbs? {
        try MealGenerator.generate(
            pumpHistory: pumphistory,
            profile: profile,
            basalProfile: basalProfile,
            clock: clock,
            carbHistory: carbs,
            glucoseHistory: glucose
        )
    }

    /// `preferences` are already clamped for the dosing mode. The returned determination's
    /// timestamp equals its `deliverAt`; enactment updates it later.
    static func determine(
        glucose: [BloodGlucose],
        currentTemp: TempBasal,
        iob: [IobResult],
        profile: Profile,
        autosens: Autosens?,
        meal: ComputedCarbs?,
        preferences: Preferences,
        hasSufficientTDD: Bool,
        trioCustomOrefVariables: TrioCustomOrefVariables,
        currentTime: Date
    ) throws -> Determination? {
        var preferences = preferences
        if !hasSufficientTDD, preferences.useNewFormula || (preferences.useNewFormula && preferences.sigmoid) {
            debug(.algorithm, "Dynamic ISF off for this run: not enough TDD history")
            preferences.useNewFormula = false
            preferences.sigmoid = false
        }

        guard let meal = meal, let autosens = autosens else {
            throw DeterminationError.missingInputs
        }

        var determination = try DeterminationGenerator.generate(
            profile: profile,
            preferences: preferences,
            currentTemp: currentTemp,
            iobData: iob,
            mealData: meal,
            autosensData: autosens,
            glucose: glucose,
            microBolusAllowed: true,
            trioCustomOrefVariables: trioCustomOrefVariables,
            currentTime: currentTime
        )
        // AAPS does it the same way: timestamp starts as deliverAt and is updated once enacted
        if let deliverAt = determination?.deliverAt {
            determination?.timestamp = deliverAt
        }
        return determination
    }
}
