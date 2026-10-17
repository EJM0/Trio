import Foundation

/// The bolus calculator's arithmetic, shared by the phone and the untethered watch so both
/// recommend the same bolus from the same inputs.
enum BolusCalculator {
    /// Calculates the recommended insulin dose based on various parameters
    static func calculate(_ input: CalculationInput, roundBolus: (Decimal) -> Decimal) -> CalculationResult {
        // insulin needed for the current blood glucose
        let targetDifference = input.currentBG - input.target
        debug(.default, "Target difference: \(targetDifference)")

        let targetDifferenceInsulin = targetDifference / input.isf
        debug(.default, "Target difference insulin: \(targetDifferenceInsulin)")

        // more or less insulin because of bg trend in the last 15 minutes
        let fifteenMinutesInsulin = input.deltaBG / input.isf
        debug(.default, "15min insulin: \(fifteenMinutesInsulin)")

        // determine whole COB for which we want to dose insulin for and then determine insulin for wholeCOB
        // we need to take backdated carbs into account - so we are using a freshly created (simulated) COB if carbs are backdated, otherwise it will default to the mostRecentDeterminations' COB value (as before)
        let wholeCob = min(Decimal(input.cob) + input.carbs, input.maxCOB)
        let wholeCobInsulin = wholeCob / input.carbRatio
        debug(.default, "Whole COB: \(wholeCob), COB insulin: \(wholeCobInsulin)")

        // determine how much the calculator reduces/ increases the bolus because of IOB
        let iobInsulinReduction = (-1) * input.iob
        debug(.default, "IOB reduction: \(iobInsulinReduction)")

        // adding everything together
        // add a calc for the case that no fifteenMinInsulin is available
        let wholeCalc: Decimal
        if input.deltaBG != 0 {
            wholeCalc = (targetDifferenceInsulin + iobInsulinReduction + wholeCobInsulin + fifteenMinutesInsulin)
            debug(.default, "Whole calc (with delta): \(wholeCalc)")
        } else {
            // add (rare) case that no glucose value is available -> maybe display warning?
            // if no bg is available, ?? sets its value to 0
            if input.currentBG == 0 {
                wholeCalc = (iobInsulinReduction + wholeCobInsulin)
                debug(.default, "Whole calc (no BG): \(wholeCalc)")
            } else {
                wholeCalc = (targetDifferenceInsulin + iobInsulinReduction + wholeCobInsulin)
                debug(.default, "Whole calc (no delta): \(wholeCalc)")
            }
        }

        // apply custom factor at the end of the calculations
        // apply custom factor if reduced bolus toggle in bolus calc config settings is on and the box for reduced bolus is checked (in RootView)
        var factoredInsulin = wholeCalc
        debug(.default, "Initial factored insulin: \(factoredInsulin)")

        // Apply Recommended Bolus Percentage (input.fraction) and if selected apply Reduced Bolus Percentage (input.fattyMealFactor)
        // If factoredInsulin is negative, though, don't apply either
        if factoredInsulin > 0 {
            factoredInsulin *= input.fraction
            debug(.default, "After fraction (\(input.fraction)): \(factoredInsulin)")

            if input.useFattyMealCorrectionFactor {
                factoredInsulin *= input.fattyMealFactor
                debug(.default, "After reduced bolus factor (\(input.fattyMealFactor)): \(factoredInsulin)")
            }
        }

        // Calculate and add super bolus insulin if enabled
        var superBolusInsulin: Decimal = 0
        if input.useSuperBolus {
            superBolusInsulin = input.sweetMealFactor * input.basal
            factoredInsulin += superBolusInsulin
            debug(.default, "After super bolus (\(superBolusInsulin)): \(factoredInsulin)")
        }

        // the final result for recommended insulin amount
        var insulinCalculated: Decimal
        let isLoopStale = Date().timeIntervalSince(input.lastLoopDate) > 15 * 60
        debug(.default, "Loop stale: \(isLoopStale), currentBG: \(input.currentBG), minPredBG: \(input.minPredBG)")

        // don't recommend insulin when current glucose or minPredBG is < 54 or last sucessful loop was over 15 minutes ago
        if input.currentBG < 54 || input.minPredBG < 54 || isLoopStale {
            insulinCalculated = 0
            debug(.default, "Insulin set to 0 due to safety check - BG < 54 or stale loop")
        } else {
            // no negative insulinCalculated
            insulinCalculated = max(factoredInsulin, 0)
            debug(.default, "After max(0): \(insulinCalculated)")

            // don't exceed maxBolus
            insulinCalculated = min(insulinCalculated, input.maxBolus)
            debug(.default, "After maxBolus (\(input.maxBolus)): \(insulinCalculated)")

            // don't exceed maxIOB
            insulinCalculated = min(insulinCalculated, input.maxIOB - input.iob)
            debug(.default, "After maxIOB check (\(input.maxIOB) - \(input.iob)): \(insulinCalculated)")

            // round calculated recommendation to allowed bolus increment
            insulinCalculated = roundBolus(insulinCalculated)
            debug(.default, "Final rounded insulin: \(insulinCalculated)")
        }

        return CalculationResult(
            insulinCalculated: insulinCalculated,
            factoredInsulin: factoredInsulin,
            wholeCalc: wholeCalc,
            iobInsulinReduction: iobInsulinReduction,
            superBolusInsulin: superBolusInsulin,
            targetDifference: targetDifference,
            targetDifferenceInsulin: targetDifferenceInsulin,
            fifteenMinutesInsulin: fifteenMinutesInsulin,
            wholeCob: wholeCob,
            wholeCobInsulin: wholeCobInsulin
        )
    }

    /// The value of a daily schedule (basal, carb ratio, target, ISF) at `now`.
    static func scheduleValue(
        _ entries: [(start: String, value: Decimal)],
        at now: Date,
        calendar: Calendar = .current
    ) -> Decimal {
        for (index, entry) in entries.enumerated() {
            guard let entryTime = TherapySettingsUtil.parseTime(entry.start) else {
                debug(.default, "Invalid entry start time: \(entry.start)")
                continue
            }

            let entryComponents = calendar.dateComponents([.hour, .minute, .second], from: entryTime)
            let entryStartTime = calendar.date(
                bySettingHour: entryComponents.hour!,
                minute: entryComponents.minute!,
                second: entryComponents.second ?? 0, // Set seconds to 0 if not provided
                of: now
            )!

            let entryEndTime: Date
            if index < entries.count - 1 {
                if let nextEntryTime = TherapySettingsUtil.parseTime(entries[index + 1].start) {
                    let nextEntryComponents = calendar.dateComponents([.hour, .minute, .second], from: nextEntryTime)
                    entryEndTime = calendar.date(
                        bySettingHour: nextEntryComponents.hour!,
                        minute: nextEntryComponents.minute!,
                        second: nextEntryComponents.second ?? 0,
                        of: now
                    )!
                } else {
                    entryEndTime = calendar.date(byAdding: .day, value: 1, to: entryStartTime)!
                }
            } else {
                entryEndTime = calendar.date(byAdding: .day, value: 1, to: entryStartTime)!
            }

            if now >= entryStartTime, now < entryEndTime {
                return entry.value
            }
        }
        return 0
    }

    /// Current glucose is the newest reading regardless of age; the delta spans the readings of the
    /// last 20 minutes. `newestFirst` as stored, newest first.
    static func glucoseVariables(
        newestFirst: [(date: Date?, glucose: Decimal)],
        now: Date
    ) -> (currentBG: Decimal, deltaBG: Decimal) {
        let lastGlucose = newestFirst.first?.glucose ?? 0
        let twentyMinutesAgo = now.addingTimeInterval(-20 * 60)
        let recent = newestFirst.filter { ($0.date ?? .distantPast) > twentyMinutesAgo }
        let delta = recent.count >= 2 ? (recent.first?.glucose ?? 0) - (recent.last?.glucose ?? 0) : 0
        return (lastGlucose, delta)
    }
}

/// Input parameters required for bolus calculation
struct CalculationInput: Sendable {
    let carbs: Decimal // Carbohydrates to be consumed (in grams)
    let currentBG: Decimal // Current blood glucose level
    let deltaBG: Decimal // Blood glucose change in last 15 minutes
    let target: Decimal // Target blood glucose level
    let isf: Decimal // Insulin Sensitivity Factor
    let carbRatio: Decimal // Carb to insulin ratio
    let iob: Decimal // Insulin on Board
    let cob: Int16 // Carbs on Board
    let useFattyMealCorrectionFactor: Bool // Whether to apply reduced bolus correction
    let fattyMealFactor: Decimal // Factor for reduced bolus adjustment
    let useSuperBolus: Bool // Whether to use super bolus calculation
    let sweetMealFactor: Decimal // Factor for sweet meal adjustment
    let basal: Decimal // Current basal rate
    let fraction: Decimal // General correction factor
    let maxBolus: Decimal // Maximum allowed bolus
    let maxIOB: Decimal // Maximum allowed IOB to be used for rec. bolus calculation
    let maxCOB: Decimal // Maximum allowed COB to be used for rec. bolus calculation
    let minPredBG: Decimal // Minimum Predicted Glucose determined by Oref
    let lastLoopDate: Date // Date at which loop last completed successfully
}

/// Results of the bolus calculation
struct CalculationResult: Sendable {
    let insulinCalculated: Decimal // Final calculated insulin amount which respects limits
    let factoredInsulin: Decimal // Total calculation after adjustments
    let wholeCalc: Decimal // Total calculation before adjustments
    let iobInsulinReduction: Decimal // IOB reduction amount
    let superBolusInsulin: Decimal // Additional insulin for super bolus
    let targetDifference: Decimal // Difference from target BG
    let targetDifferenceInsulin: Decimal // Insulin needed for target difference
    let fifteenMinutesInsulin: Decimal // Trend-based insulin adjustment
    let wholeCob: Decimal // Total carbs (COB + new carbs)
    let wholeCobInsulin: Decimal // Insulin needed for total carbs
}
