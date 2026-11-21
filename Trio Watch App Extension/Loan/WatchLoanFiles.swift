import Foundation
import LoopKit

/// The watch's loan files. Every write is atomic and readable while the watch is locked after its first unlock,
/// so a cycle on a locked watch can still read and write them.
struct WatchLoanFiles {
    let directory: URL

    static var standard: WatchLoanFiles {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return WatchLoanFiles(directory: support.appendingPathComponent("WatchLoan", isDirectory: true))
    }

    enum Name: String {
        case state = "loan-state.json"
        case snapshot = "loan-snapshot.data"
        case pumpState = "pump-state.plist"
        case pumpLocalState = "pump-local-state.plist"
        case cgmState = "cgm-state.plist"
        case cgmLocalState = "cgm-local-state.plist"
        case intent = "dose-intent.json"
        case records = "loan-records.json"
        case inbox = "loan-inbox.json"
        case cycle = "loan-cycle.json"
    }

    func url(_ name: Name) -> URL {
        directory.appendingPathComponent(name.rawValue)
    }

    private static let queue = DispatchQueue(label: "org.nightscout.Trio.watch.loanFiles", qos: .userInitiated)

    /// File work off the main thread, in order; returns once it is done.
    static func io<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in
            queue.async { done.resume(with: Result { try work() }) }
        }
    }

    /// File work off the main thread, in order, without waiting for it. A failure is logged.
    static func later(_ what: String, _ work: @escaping () throws -> Void) {
        queue.async {
            do { try work() } catch {
                WatchLogger.shared.warning(.loop, "Saving \(what) failed", error: error)
            }
        }
    }

    func write(_ data: Data, to name: Name) throws {
        assert(!Thread.isMainThread, "loan file written on the main thread")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Nil when there is no file. A file that exists but can't be read throws.
    func read(_ name: Name) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url(name).path) else { return nil }
        return try Data(contentsOf: url(name))
    }

    func remove(_ name: Name) throws {
        assert(!Thread.isMainThread, "loan file removed on the main thread")
        guard FileManager.default.fileExists(atPath: url(name).path) else { return }
        try FileManager.default.removeItem(at: url(name))
    }

    // MARK: - Typed

    func save<T: Encodable>(_ value: T, to name: Name) throws {
        try write(JSONEncoder().encode(value), to: name)
    }

    func load<T: Decodable>(_: T.Type, from name: Name) throws -> T? {
        try read(name).map { try JSONDecoder().decode(T.self, from: $0) }
    }

    func savePlist(_ value: [String: Any], to name: Name) throws {
        try write(PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0), to: name)
    }

    func loadPlist(from name: Name) throws -> [String: Any]? {
        try read(name).map { try PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] ?? [:] }
    }
}

/// What the cycle keeps between wakes.
struct WatchLoanCycleInfo: Codable {
    var holdingSince: Date?
    var lastCycleAt: Date?
    /// The last cycle that read a fresh pump status and enacted or needed nothing.
    var lastConfirmedCycleAt: Date?
    var autosens: Autosens?
    var firingGlucoseAlarms: Set<UUID> = []
    var batteryNotice: Int = 0
    /// Cycles in a row that got no pump status, and whether the user was told.
    var podContactFailures: Int = 0
    var podLinkNoticeShown = false
    var summary = DailySummary()
    /// Confirmed cycles in this loan, at most one per 4 minutes, for the loop page's count.
    var confirmedLoops: Int?
    var lastCountedLoopAt: Date?
    /// What the last cycle did, as the loop page shows it.
    var lastResult: String?

    /// Counts for one log line a day, so a hardware run shows its wakes, readings and cycles.
    struct DailySummary: Codable {
        var since: Date?
        var readings: Int = 0
        var cycles: Int = 0
        var confirmed: Int = 0
        var wakes: [String: Int] = [:]
        var budgetErrors: Int = 0
        var longestGapSeconds: Int64 = 0
        var batteryAtStart: Float?
    }
}
