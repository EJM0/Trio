import Foundation

/// The bolus calculator math over plain values. `BaseBolusCalculationManager` gathers the inputs
/// from settings, Core Data and the last determination, then calls it.
enum BolusCalculator {
    struct GlucoseVariables {
        var currentBG: Decimal
        var deltaBG: Decimal
    }

    /// `readings` newest first. The current glucose is the newest reading regardless of age; the delta
    /// spans the newest and oldest dated reading of the last 20 minutes.
    static func glucoseVariables(readings: [(date: Date?, glucose: Int16)], now: Date) -> GlucoseVariables {
        // Always use the most recent reading for current glucose regardless of time
        let lastGlucose = readings.first?.glucose ?? 0

        // Filter for readings less than 20 minutes old
        let twentyMinutesAgo = now.addingTimeInterval(-20 * 60)
        let recentReadings = readings.filter {
            guard let date = $0.date else { return false }
            return date > twentyMinutesAgo
        }

        // Calculate delta using newest and oldest readings within 20-minute window
        let delta: Decimal
        if recentReadings.count >= 2 {
            // Newest is at index 0, oldest is at the last index
            let newestInWindow = recentReadings.first?.glucose ?? 0
            let oldestInWindow = recentReadings.last?.glucose ?? 0
            delta = Decimal(newestInWindow) - Decimal(oldestInWindow)
        } else {
            // Not enough data points in the window
            delta = 0
        }

        return GlucoseVariables(currentBG: Decimal(lastGlucose), deltaBG: delta)
    }

    /// Calculates the recommended insulin dose. `roundBolus` rounds to what the pump can deliver.
    static func calculate(_ input: CalculationInput, now: Date, roundBolus: (Decimal) -> Decimal) -> CalculationResult {
        // insulin needed for the current blood glucose
        let targetDifference = input.currentBG - input.target

        let targetDifferenceInsulin = targetDifference / input.isf

        // more or less insulin because of bg trend in the last 15 minutes
        let fifteenMinutesInsulin = input.deltaBG / input.isf

        // determine whole COB for which we want to dose insulin for and then determine insulin for wholeCOB
        // we need to take backdated carbs into account - so we are using a freshly created (simulated) COB if carbs are backdated, otherwise it will default to the mostRecentDeterminations' COB value (as before)
        let wholeCob = min(Decimal(input.cob) + input.carbs, input.maxCOB)
        let wholeCobInsulin = wholeCob / input.carbRatio

        // determine how much the calculator reduces/ increases the bolus because of IOB
        let iobInsulinReduction = (-1) * input.iob

        // adding everything together
        // add a calc for the case that no fifteenMinInsulin is available
        let wholeCalc: Decimal
        if input.deltaBG != 0 {
            wholeCalc = (targetDifferenceInsulin + iobInsulinReduction + wholeCobInsulin + fifteenMinutesInsulin)
        } else {
            // add (rare) case that no glucose value is available -> maybe display warning?
            // if no bg is available, ?? sets its value to 0
            if input.currentBG == 0 {
                wholeCalc = (iobInsulinReduction + wholeCobInsulin)
            } else {
                wholeCalc = (targetDifferenceInsulin + iobInsulinReduction + wholeCobInsulin)
            }
        }

        // apply custom factor at the end of the calculations
        // apply custom factor if reduced bolus toggle in bolus calc config settings is on and the box for reduced bolus is checked (in RootView)
        var factoredInsulin = wholeCalc

        // Apply Recommended Bolus Percentage (input.fraction) and if selected apply Reduced Bolus Percentage (input.fattyMealFactor)
        // If factoredInsulin is negative, though, don't apply either
        if factoredInsulin > 0 {
            factoredInsulin *= input.fraction

            if input.useFattyMealCorrectionFactor {
                factoredInsulin *= input.fattyMealFactor
            }
        }

        // Calculate and add super bolus insulin if enabled
        var superBolusInsulin: Decimal = 0
        if input.useSuperBolus {
            superBolusInsulin = input.sweetMealFactor * input.basal
            factoredInsulin += superBolusInsulin
        }

        // the final result for recommended insulin amount
        var insulinCalculated: Decimal
        let isLoopStale = now.timeIntervalSince(input.lastLoopDate) > 15 * 60

        // don't recommend insulin when current glucose or minPredBG is < 54 or last sucessful loop was over 15 minutes ago
        if input.currentBG < 54 || input.minPredBG < 54 || isLoopStale {
            insulinCalculated = 0
            debug(.bolus, "Recommendation set to 0 U: BG or min predicted BG below 54 mg/dL, or last loop over 15 min ago")
        } else {
            // no negative insulinCalculated
            insulinCalculated = max(factoredInsulin, 0)

            // don't exceed maxBolus
            insulinCalculated = min(insulinCalculated, input.maxBolus)

            // don't exceed maxIOB
            insulinCalculated = min(insulinCalculated, input.maxIOB - input.iob)

            // round calculated recommendation to allowed bolus increment
            insulinCalculated = roundBolus(insulinCalculated)
        }

        debug(
            .bolus,
            "Recommendation \(insulinCalculated) U: BG \(input.currentBG) mg/dL, delta \(input.deltaBG) mg/dL, target \(input.target) mg/dL, ISF \(input.isf) mg/dL/U, CR \(input.carbRatio) g/U, COB \(wholeCob) g, IOB \(input.iob) U, unadjusted \(wholeCalc.rounded(toPlaces: 2)) U, adjusted \(factoredInsulin.rounded(toPlaces: 2)) U"
        )

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
