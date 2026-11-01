import Foundation

/// Starting on the watch without the phone, from the copy of the grant the phone leaves with it (LoopKit/Loop#2545's
/// dormant grant), and the pump-total check that keeps two controllers from dosing beside each other.
enum WatchLoopStanding {
    /// The phone sends a new copy at least this often, and after a change of insulin, carbs or settings.
    static let refreshInterval: TimeInterval = 30 * 60

    /// A copy is usable for an hour: it is renewed every 30 min while the phone loops, and an older one could start
    /// the watch beside a phone that is still dosing.
    static func isUsable(_ copy: WatchLoopGrant, now: Date) -> Bool {
        now.timeIntervalSince(copy.issuedAt) < 60 * 60
    }
}

/// When the watch starts the Watch Loop by itself: the phone has stopped looping, and the watch's own sensor
/// readings show the body is with the watch. Noisy readings and a sensor with a problem never start it.
enum WatchLoopFallback {
    struct Inputs {
        /// The watch's own readings that arrived live (not backfill) with a valid glucose, any order.
        var ownReadings: [Date]
        var phoneNewestReading: Date?
        var phoneLastLoop: Date?
        /// The phone answered the watch's last question.
        var phoneAnswered: Bool
        var sensorProblemNow: Bool
        var lastSensorProblemAt: Date?
        var copyUsable: Bool
        var now: Date
    }

    static let phoneSilence: TimeInterval = 10 * 60
    static let readingWindow: TimeInterval = 12 * 60
    static let sensorCalm: TimeInterval = 15 * 60

    static func shouldStart(_ i: Inputs) -> Bool {
        guard !i.phoneAnswered, i.copyUsable, !i.sensorProblemNow else { return false }
        if let problem = i.lastSensorProblemAt, i.now.timeIntervalSince(problem) < sensorCalm { return false }
        let phoneReading = i.phoneNewestReading ?? .distantPast
        guard i.now.timeIntervalSince(phoneReading) > phoneSilence,
              i.now.timeIntervalSince(i.phoneLastLoop ?? .distantPast) > phoneSilence
        else { return false }
        // two consecutive readings of the sensor's own 5-minute cadence, recent, and ones the phone doesn't have
        let readings = i.ownReadings
            .filter { $0 > phoneReading && i.now.timeIntervalSince($0) <= readingWindow }
            .sorted()
        return zip(readings, readings.dropFirst()).contains { earlier, later in
            (3.5 * 60 ... 6.5 * 60).contains(later.timeIntervalSince(earlier))
        }
    }
}
