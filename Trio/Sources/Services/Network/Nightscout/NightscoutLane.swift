import Foundation

/// Logical upload “paths” handled by NightscoutManager.
/// Each lane has its own throttled queue so we don’t double-upload
/// when multiple sources trigger the same work close together.
public enum NightscoutLane: String, CaseIterable {
    case carbs
    case pumpHistory
    case overrides
    case tempTargets
    case glucose
    case manualGlucose
    case deviceStatus
}

/// Keys used in Nightscout upload notifications.
public enum NightscoutNotificationKey {
    /// Array of lane rawValues to upload, e.g. ["carbs", "pumpHistory"].
    public static let lanes = "lanes"
    /// Optional string that says who asked for the upload (debug/diagnostics).
    public static let source = "source"
}

public extension Foundation.Notification.Name {
    /// Post this to request one or more uploads by lane.
    static let nightscoutUploadRequested = Notification.Name("nightscoutUploadRequested")
    /// Posted after we enqueue all requested lanes (not a network completion).
    static let nightscoutUploadDidFinish = Notification.Name("nightscoutUploadDidFinish")
}

/// Convenience helper any component (e.g. APSManager) can call to
/// request uploads. The work is enqueued and deduped per lane via throttle,
/// so rapid duplicate calls won’t double-upload.
///
/// - Parameters:
///   - lanes: Which lanes to kick (carbs, pumpHistory, etc).
///   - source: Optional tag for debugging (e.g. "APSManager").
public func requestNightscoutUpload(_ lanes: [NightscoutLane], source: String? = nil) {
    var userInfo: [AnyHashable: Any] = [NightscoutNotificationKey.lanes: lanes.map(\.rawValue)]
    if let source { userInfo[NightscoutNotificationKey.source] = source }
    Foundation.NotificationCenter.default.post(name: .nightscoutUploadRequested, object: nil, userInfo: userInfo)
}
