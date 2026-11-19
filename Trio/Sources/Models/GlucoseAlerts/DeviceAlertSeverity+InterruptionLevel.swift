import LoopKit

extension DeviceAlertSeverity {
    init?(level: Alert.InterruptionLevel) {
        switch level {
        case .critical: self = .critical
        case .timeSensitive: self = .timeSensitive
        case .active: self = .normal
        }
    }
}
