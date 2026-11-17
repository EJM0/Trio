import Foundation

enum BolusSafetyResult: Equatable {
    case allowed
    case rejected(BolusSafetyRejection)
}

enum BolusSafetyRejection: Equatable {
    case exceedsMaxBolus(maxBolus: Decimal)
    case iobUnavailable
    case exceedsMaxIOB(currentIOB: Decimal, maxIOB: Decimal)
    case recentBolusWithinWindow(totalRecent: Decimal)
}

struct BolusSafetyInputs: Equatable {
    let maxBolus: Decimal
    let maxIOB: Decimal
    let currentIOB: Decimal?
    /// Sum of bolus amounts delivered within the recent-bolus window (see `BolusSafetyEvaluator.recentBolusWindowMinutes`).
    let totalRecentBolus: Decimal
}

enum BolusSafetyEvaluator {
    static let recentBolusThreshold: Decimal = 0.2
    static let recentBolusWindowMinutes: Int = 6

    static func evaluate(bolusAmount: Decimal, inputs: BolusSafetyInputs) -> BolusSafetyResult {
        if bolusAmount > inputs.maxBolus {
            return .rejected(.exceedsMaxBolus(maxBolus: inputs.maxBolus))
        }
        guard let currentIOB = inputs.currentIOB else {
            return .rejected(.iobUnavailable)
        }
        if (currentIOB + bolusAmount) > inputs.maxIOB {
            return .rejected(.exceedsMaxIOB(currentIOB: currentIOB, maxIOB: inputs.maxIOB))
        }
        if inputs.totalRecentBolus >= bolusAmount * recentBolusThreshold {
            return .rejected(.recentBolusWithinWindow(totalRecent: inputs.totalRecentBolus))
        }
        return .allowed
    }
}

/// The Treatments warning before a pump bolus: glucose or the forecast minimum below 54 mg/dL. The message always shows;
/// a confirmation is asked only with "confirm bolus" on. Shared with the watch.
enum LowGlucoseBolusWarning {
    static let threshold: Decimal = 54

    static func message(currentBG: Decimal, minPredBG: Decimal) -> String? {
        if currentBG < threshold { return String(localized: "Glucose is very low.") }
        if minPredBG < threshold { return String(localized: "Glucose forecast is very low.") }
        return nil
    }

    static func shouldConfirm(confirmBolus: Bool, currentBG: Decimal, minPredBG: Decimal) -> Bool {
        confirmBolus && message(currentBG: currentBG, minPredBG: minPredBG) != nil
    }
}
