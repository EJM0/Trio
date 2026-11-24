import SwiftUI
import WatchKit

enum NavigationDestinations: String {
    case acknowledgmentPending = "AcknowledgmentPendingView"
    case carbsInput = "CarbsInputView"
    case bolusInput = "BolusInputView"
    case bolusConfirm = "BolusConfirmView"
}

enum MealBolusStep: String {
    case savingCarbs = "Saving Carbs..."
    case enactingBolus = "Enacting Bolus..."
}

enum AcknowledgementStatus: String, CaseIterable {
    case success
    case failure
    case pending
}

enum AcknowledgmentCode: String, Codable {
    case savingCarbs = "saving_carbs"
    case enactingBolus = "enacting_bolus"
    case comboComplete = "combo_complete"
    case carbsLogged = "carbs_logged"
    case overrideStarted = "override_started"
    case overrideStopped = "override_stopped"
    case tempTargetStarted = "temp_target_started"
    case tempTargetStopped = "temp_target_stopped"
    case genericSuccess = "success"
    case genericFailure = "failure"
    /// A bolus failed a safety check the user may confirm to bolus through.
    case bolusNeedsOverride = "bolus_needs_override"
}

/// A bolus the phone blocked on a safety check the user may confirm with the digital crown to bolus through.
struct PendingBolusOverride: Equatable {
    let amount: Decimal
    /// The phone's explanation of the failed check
    let reason: String
    /// The checks to send back with the bolus if the user confirms, including the one that just failed
    let overriddenChecks: [String]
    /// When the phone asked, on the phone's clock. Sent back unchanged so the phone can tell an expired confirmation.
    let issuedAt: TimeInterval
}

enum WatchSize {
    case watch40mm
    case watch41mm
    case watch42mm
    case watch44mm
    case watch45mm
    case watch49mm
    case unknown

    static var current: WatchSize {
        let bounds = WKInterfaceDevice.current().screenBounds

        switch bounds {
        case CGRect(x: 0, y: 0, width: 162, height: 197):
            return .watch40mm // check

        case CGRect(x: 0, y: 0, width: 176, height: 215):
            return .watch41mm // check

        case CGRect(x: 0, y: 0, width: 187, height: 223):
            return .watch42mm // check

        case CGRect(x: 0, y: 0, width: 184, height: 224):
            return .watch44mm

        case CGRect(x: 0, y: 0, width: 198, height: 242):
            return .watch45mm

        case CGRect(x: 0, y: 0, width: 205, height: 251):
            return .watch49mm
        default:
            return .unknown
        }
    }
}

/// The glucose chart's zoom, in hours. Stored per chart (full-screen vs. combined) so each keeps its own
/// zoom across launches. The stored value is the window in hours, so it stays readable if the cases grow.
enum WatchChartTimeWindow: Int, CaseIterable {
    /// The full-screen chart's only (`nextFullScreen`); the combined chart starts at three hours.
    case oneHour = 1
    case threeHours = 3
    case sixHours = 6
    case twelveHours = 12
    case twentyFourHours = 24

    static let fullScreenStorageKey = "watchChartTimeWindow.fullScreen"
    static let combinedStorageKey = "watchChartTimeWindow.combined"

    var next: WatchChartTimeWindow {
        switch self {
        case .oneHour: return .threeHours
        case .threeHours: return .sixHours
        case .sixHours: return .twelveHours
        case .twelveHours: return .twentyFourHours
        case .twentyFourHours: return .threeHours
        }
    }

    /// The full-screen chart's cycle, from the last hour.
    var nextFullScreen: WatchChartTimeWindow {
        self == .twentyFourHours ? .oneHour : next
    }
}

// MARK: - Per-device UI metrics

/// Metrics for the compact glucose circle used by CombinedGlucoseChartview. GlucoseTrendView keeps its own copies
/// as view properties; these mirror those values so the minimized circle matches the full one on every watch.
extension WatchSize {
    /// Diameter of the glucose circle ring.
    var circleSize: CGFloat {
        switch self {
        case .watch40mm: return 82
        case .watch41mm,
             .watch42mm: return 86
        case .watch44mm: return 96
        case .unknown,
             .watch45mm: return 103
        case .watch49mm: return 105
        }
    }

    /// Stroke width of the glucose circle ring.
    var lineWidth: CGFloat {
        switch self {
        case .watch40mm,
             .watch41mm,
             .watch42mm,
             .watch44mm: return 1
        case .unknown,
             .watch45mm,
             .watch49mm: return 1.5
        }
    }

    /// Glow / shadow radius of the glucose circle ring.
    var shadowRadius: CGFloat {
        switch self {
        case .watch40mm,
             .watch41mm,
             .watch42mm: return 8
        case .watch44mm: return 9
        case .unknown,
             .watch45mm,
             .watch49mm: return 12
        }
    }

    /// Font size for the current glucose reading inside the circle.
    var currentGlucoseFontSize: Font {
        switch self {
        case .watch40mm,
             .watch41mm,
             .watch42mm,
             .watch44mm: return .title2
        case .unknown,
             .watch45mm,
             .watch49mm: return .title
        }
    }

    /// Scale factor used when rendering the minimized circle in CombinedGlucoseChartview.
    var minimizedScale: CGFloat { 0.50 }

    /// Width of the spacer that flanks the minimized circle in CombinedGlucoseChartview,
    /// keeping the adjacent texts a consistent distance from the circle edge on every watch.
    var minimizedCircleSpacerWidth: CGFloat {
        circleSize * minimizedScale + 8
    }
}
