import Foundation

/// The phone's side of the Watch Loop, saved as one value so a relaunch mid-session resumes it.
struct WatchLoopPhoneState: Codable, Equatable {
    var role: WatchLoopControl.PhoneRole = .holdsPump
    /// The highest session the phone has granted or adopted.
    var session = 0
    var sessionStartedAt: Date?
    /// The last checkpoint or report from the watch, by its send time.
    var lastReportAt: Date?
    var tookOverOnSilenceAt: Date?
    /// A standing copy is with the watch, so it could start without the phone (Allow without iPhone).
    var standingCopyOut = false
    /// Records already stored, newest last; a record arriving again is acknowledged without storing.
    var storedRecordIDs: [UUID] = []
    /// What the watch last showed of its loop, for the banner, the glow and the chart.
    var liveStatus: WatchLoopLiveStatus?
    /// The pump's total at the moment the phone let go, for the audit when it comes back.
    var deliveredAtRelease: Double?
    var releasedAt: Date?
    /// Sessions refused as revived claims (control row 19).
    var refusedSessions: [Int] = []
    /// When the watch had the pod, for the phone's chart and Nightscout.
    var spans: [WatchLoopSpan] = []
    /// The pump's total at the last reading the records explained; dosing waits for one while a copy is out.
    var verifiedDelivered: Double?
    var verifiedAt: Date?
    var standingCopySentAt: Date?
    /// A stop the watch hasn't confirmed; sent again until it does.
    var stopPendingSession: Int?
    var stopPendingSince: Date?

    static let storedRecordCapacity = 2000

    init() {}

    /// A span opens when the watch takes the pod, from its session's start, and closes when the phone has it back.
    /// A day of them is kept, and one not yet in Nightscout until it is.
    mutating func noteSpan(at now: Date) {
        let running = spans.last.map { $0.end == nil } ?? false
        switch role {
        case .lending,
             .standingAside:
            if !running { spans.append(WatchLoopSpan(start: min(sessionStartedAt ?? now, now))) }
        case .holdsPump:
            if running { spans[spans.count - 1].end = now }
        case .transferring:
            break
        }
        spans.removeAll { $0.uploaded && ($0.end ?? now) < now.addingTimeInterval(-24 * 3600) }
    }

    mutating func noteStored(_ ids: [UUID]) {
        storedRecordIDs.append(contentsOf: ids.filter { !storedRecordIDs.contains($0) })
        if storedRecordIDs.count > Self.storedRecordCapacity {
            storedRecordIDs.removeFirst(storedRecordIDs.count - Self.storedRecordCapacity)
        }
    }

    /// Each field decodes on its own, so a field added in an update doesn't reset the rest (a session survives it).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WatchLoopPhoneState()
        role = (try? c.decodeIfPresent(WatchLoopControl.PhoneRole.self, forKey: .role)) ?? d.role
        session = (try? c.decodeIfPresent(Int.self, forKey: .session)) ?? d.session
        sessionStartedAt = try? c.decodeIfPresent(Date.self, forKey: .sessionStartedAt)
        lastReportAt = try? c.decodeIfPresent(Date.self, forKey: .lastReportAt)
        tookOverOnSilenceAt = try? c.decodeIfPresent(Date.self, forKey: .tookOverOnSilenceAt)
        standingCopyOut = (try? c.decodeIfPresent(Bool.self, forKey: .standingCopyOut)) ?? d.standingCopyOut
        storedRecordIDs = (try? c.decodeIfPresent([UUID].self, forKey: .storedRecordIDs)) ?? d.storedRecordIDs
        liveStatus = try? c.decodeIfPresent(WatchLoopLiveStatus.self, forKey: .liveStatus)
        deliveredAtRelease = try? c.decodeIfPresent(Double.self, forKey: .deliveredAtRelease)
        releasedAt = try? c.decodeIfPresent(Date.self, forKey: .releasedAt)
        refusedSessions = (try? c.decodeIfPresent([Int].self, forKey: .refusedSessions)) ?? d.refusedSessions
        spans = (try? c.decodeIfPresent([WatchLoopSpan].self, forKey: .spans)) ?? d.spans
        verifiedDelivered = try? c.decodeIfPresent(Double.self, forKey: .verifiedDelivered)
        verifiedAt = try? c.decodeIfPresent(Date.self, forKey: .verifiedAt)
        standingCopySentAt = try? c.decodeIfPresent(Date.self, forKey: .standingCopySentAt)
        stopPendingSession = try? c.decodeIfPresent(Int.self, forKey: .stopPendingSession)
        stopPendingSince = try? c.decodeIfPresent(Date.self, forKey: .stopPendingSince)
    }
}

/// A stretch of time the watch had the pod.
struct WatchLoopSpan: Codable, Equatable {
    let start: Date
    /// Nil while it runs.
    var end: Date?
    /// In Nightscout as a note with its duration.
    var uploaded = false
}

/// The one question every phone path that doses, or books as if it had, asks: does the phone hold the pump?
/// While the watch has it, the phone neither loops, nor boluses, nor sets temp targets the pump would act on.
enum WatchLoopGate {
    private static let lock = NSLock()
    private static var cachedRole: WatchLoopControl.PhoneRole = loadRole()
    private static var cachedSpans: [WatchLoopSpan] = []

    static let storageKey = "watchLoopPhoneState"

    static var phoneMayDose: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedRole == .holdsPump
    }

    static var role: WatchLoopControl.PhoneRole {
        lock.lock()
        defer { lock.unlock() }
        return cachedRole
    }

    /// When the watch had the pod, for the chart's band.
    static var spans: [WatchLoopSpan] {
        lock.lock()
        defer { lock.unlock() }
        return cachedSpans
    }

    /// Called by the phone manager whenever the state is saved.
    static func update(_ state: WatchLoopPhoneState) {
        lock.lock()
        cachedRole = state.role
        cachedSpans = state.spans
        lock.unlock()
    }

    private static func loadRole() -> WatchLoopControl.PhoneRole {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(WatchLoopPhoneState.self, from: data)
        else { return .holdsPump }
        return state.role
    }
}
