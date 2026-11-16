import Foundation

/// The loop's glucose preconditions, the same on the phone and the watch. A failure means nothing is enacted,
/// including oref's stale-glucose fallback.
enum LoopGlucoseGuard {
    enum Failure: Equatable {
        case notEnoughReadings(count: Int)
        case stale
    }

    static let window: TimeInterval = 60 * 60
    static let minimumReadings = 3
    static let maximumAge: TimeInterval = 12 * 60

    /// `lastHour`: the readings dated at or after `now - window`, newest first. A reading without a date counts as fresh.
    static func check(lastHour: [Date?], now: Date) -> Failure? {
        guard lastHour.count >= minimumReadings else { return .notEnoughReadings(count: lastHour.count) }
        guard (lastHour.first ?? nil) ?? now >= now.addingTimeInterval(-maximumAge) else { return .stale }
        return nil
    }

    static func lastHour(_ dates: [Date], now: Date) -> [Date?] {
        dates.filter { $0 >= now.addingTimeInterval(-window) }.sorted(by: >)
    }
}
