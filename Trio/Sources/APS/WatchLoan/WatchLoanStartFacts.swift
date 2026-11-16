import Foundation

/// What the watch's Start screen shows before the user confirms. The phone answers a live query with them.
struct WatchLoanStartFacts: Codable, Equatable {
    static let queryKey = "watchLoanStartFactsQuery"
    static let replyKey = "watchLoanStartFacts"

    var override: WatchLoanSnapshot.Adjustment?
    var tempTarget: WatchLoanSnapshot.Adjustment?
    var podEndsAt: Date?
    var sensorEndsAt: Date?

    static func isQuery(_ payload: [String: Any]) -> Bool {
        payload[queryKey] != nil
    }
}
