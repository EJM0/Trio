import Foundation

public enum NightscoutLane: String, CaseIterable {
    case carbs
    case pumpHistory
    case overrides
    case tempTargets
    case glucose
    case manualGlucose
    case deviceStatus
}

public enum NightscoutNotificationKey {
    public static let lanes = "lanes"
    public static let source = "source"
}

public extension Foundation.Notification.Name {
    static let nightscoutUploadRequested = Notification.Name("nightscoutUploadRequested")
    static let nightscoutUploadDidFinish = Notification.Name("nightscoutUploadDidFinish")
}

/// Simple helper any component (e.g. APSManager) can call.
public func requestNightscoutUpload(_ lanes: [NightscoutLane], source: String? = nil) {
    var userInfo: [AnyHashable: Any] = [NightscoutNotificationKey.lanes: lanes.map(\.rawValue)]
    if let source { userInfo[NightscoutNotificationKey.source] = source }
    Foundation.NotificationCenter.default.post(name: .nightscoutUploadRequested, object: nil, userInfo: userInfo)
}
