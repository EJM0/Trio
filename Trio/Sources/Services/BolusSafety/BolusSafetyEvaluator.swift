import Foundation

/// The individual checks `BolusSafetyEvaluator` runs. The raw values travel between the phone and the Watch.
enum BolusSafetyCheck: String, CaseIterable {
    case maxBolus = "max_bolus"
    case iobAvailable = "iob_available"
    case maxIOB = "max_iob"
    case recentBolus = "recent_bolus"

    /// Max bolus is a hard limit, as on the main bolus screen. The other checks only ask the user to confirm.
    var canBeOverridden: Bool {
        self != .maxBolus
    }

    /// How long a user's confirmation past a failed check stays valid. It matches the recent-bolus window, so the
    /// reason the user saw is at most about one loop cycle old.
    static let overrideLifetimeMinutes = BolusSafetyEvaluator.recentBolusWindowMinutes

    /// The checks a user confirmed to bolus through, or none if the confirmation has expired, so that every check
    /// runs again on current data.
    /// - Parameters:
    ///   - rawValues: The confirmed checks' raw values; unknown values are ignored
    ///   - issuedAt: When the user was asked to confirm, as seconds since 1970 on this device's clock
    static func overridden(_ rawValues: [String], issuedAt: TimeInterval?, now: Date = Date()) -> Set<BolusSafetyCheck> {
        guard let issuedAt,
              (0 ... TimeInterval(overrideLifetimeMinutes * 60)).contains(now.timeIntervalSince1970 - issuedAt)
        else { return [] }
        return Set(rawValues.compactMap(BolusSafetyCheck.init(rawValue:)))
    }
}

enum BolusSafetyResult: Equatable {
    case allowed
    case rejected(BolusSafetyRejection)
}

enum BolusSafetyRejection: Equatable {
    case exceedsMaxBolus(maxBolus: Decimal)
    case iobUnavailable
    case exceedsMaxIOB(currentIOB: Decimal, maxIOB: Decimal)
    case recentBolusWithinWindow(totalRecent: Decimal)

    var check: BolusSafetyCheck {
        switch self {
        case .exceedsMaxBolus: return .maxBolus
        case .iobUnavailable: return .iobAvailable
        case .exceedsMaxIOB: return .maxIOB
        case .recentBolusWithinWindow: return .recentBolus
        }
    }
}

extension BolusSafetyRejection {
    /// User-facing explanation of the rejection, shown by Shortcuts and on the Watch.
    func localizedMessage(requestedAmount: Decimal) -> String {
        switch self {
        case let .exceedsMaxBolus(maxBolus):
            return String(
                localized:
                "The bolus cannot be larger than the pump setting max bolus (\(maxBolus.description))."
            )
        case .iobUnavailable:
            return String(
                localized:
                "Bolus blocked: current IOB is not available."
            )
        case let .exceedsMaxIOB(currentIOB, maxIOB):
            return String(
                localized:
                "Bolus blocked: a \(requestedAmount.formatted()) U bolus would exceed max IOB (\(maxIOB.formatted()) U). Current IOB: \(currentIOB.formattedIOB()) U."
            )
        case .recentBolusWithinWindow:
            return String(
                localized:
                "Bolus blocked: a significant bolus was delivered within the last \(BolusSafetyEvaluator.recentBolusWindowMinutes) minutes."
            )
        }
    }
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

    /// - Parameter overriding: checks to skip; those that cannot be overridden are run regardless.
    ///   With `.iobAvailable` overridden and no IOB, the max IOB check cannot run and is skipped too.
    static func evaluate(
        bolusAmount: Decimal,
        inputs: BolusSafetyInputs,
        overriding: Set<BolusSafetyCheck> = []
    ) -> BolusSafetyResult {
        let skipped = overriding.filter(\.canBeOverridden)
        if bolusAmount > inputs.maxBolus {
            return .rejected(.exceedsMaxBolus(maxBolus: inputs.maxBolus))
        }
        if let currentIOB = inputs.currentIOB {
            if !skipped.contains(.maxIOB), (currentIOB + bolusAmount) > inputs.maxIOB {
                return .rejected(.exceedsMaxIOB(currentIOB: currentIOB, maxIOB: inputs.maxIOB))
            }
        } else if !skipped.contains(.iobAvailable) {
            return .rejected(.iobUnavailable)
        }
        if !skipped.contains(.recentBolus), inputs.totalRecentBolus >= bolusAmount * recentBolusThreshold {
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
