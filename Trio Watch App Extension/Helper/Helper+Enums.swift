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
}

/// Zoom levels the glucose charts cycle through when tapped.
///
/// The full-screen `GlucoseChartView` and the chart folded into `CombinedGlucoseChartview` each
/// keep their own zoom, under their own key, because the two are read differently — the small
/// chart is a glance, the full one is for scrolling back through the day. Both survive the app
/// being backgrounded or relaunched.
enum WatchChartTimeWindow: Int, CaseIterable {
    case threeHours = 3
    case sixHours = 6
    case twelveHours = 12
    case twentyFourHours = 24

    /// `@AppStorage` keys. The stored value is the window in hours, so it stays readable and
    /// keeps meaning if the cases are ever extended.
    static let fullScreenStorageKey = "watchChartTimeWindow.fullScreen"
    static let combinedStorageKey = "watchChartTimeWindow.combined"

    var next: WatchChartTimeWindow {
        switch self {
        case .threeHours: return .sixHours
        case .sixHours: return .twelveHours
        case .twelveHours: return .twentyFourHours
        case .twentyFourHours: return .threeHours
        }
    }
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

// MARK: - Per-device UI metrics

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

    /// Font size for the "X m ago" label below the circle (GlucoseTrendView).
    var minutesAgoFontSize: CGFloat {
        switch self {
        case .watch40mm,
             .watch41mm: return 9
        case .unknown,
             .watch42mm,
             .watch44mm: return 10
        case .watch45mm: return 11
        case .watch49mm: return 10
        }
    }

    /// Scale factor used when rendering the minimized circle in CombinedGlucoseChartview.
    var minimizedScale: CGFloat { 0.50 }

    /// Width of the spacer that flanks the minimized circle in CombinedGlucoseChartview,
    /// keeping the adjacent texts a consistent 4 pt away from the circle edge on every watch.
    var minimizedCircleSpacerWidth: CGFloat {
        circleSize * minimizedScale + 8 // 4 pt gap on each side
    }

    /// Diameter of the pump / sensor lifetime ring on PeripheralsView.
    var peripheralRingSize: CGFloat {
        switch self {
        case .watch40mm,
             .watch41mm: return 46
        case .watch42mm,
             .watch44mm: return 50
        case .unknown,
             .watch45mm,
             .watch49mm: return 54
        }
    }

    /// Stroke width of the pump / sensor lifetime ring on PeripheralsView.
    var peripheralRingLineWidth: CGFloat {
        switch self {
        case .watch40mm,
             .watch41mm,
             .watch42mm: return 3.5
        case .unknown,
             .watch44mm,
             .watch45mm,
             .watch49mm: return 4
        }
    }
}
