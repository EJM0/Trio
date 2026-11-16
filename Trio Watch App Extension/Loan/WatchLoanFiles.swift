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
        case intent = "dose-intent.json"
        case records = "loan-records.json"
        case inbox = "loan-inbox.json"
        case cycle = "loan-cycle.json"
    }

    func url(_ name: Name) -> URL {
        directory.appendingPathComponent(name.rawValue)
    }

    func write(_ data: Data, to name: Name) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Nil when there is no file. A file that exists but can't be read throws.
    func read(_ name: Name) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url(name).path) else { return nil }
        return try Data(contentsOf: url(name))
    }

    func remove(_ name: Name) throws {
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
}
