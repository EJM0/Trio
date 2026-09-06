import Foundation

/// One user-configured behavior variant for a device-alarm severity tier.
/// Multiple configs per severity are allowed — each with its own
/// `activeOption` (Day & Night / Day only / Night only) — so the user can
/// e.g. have a Critical config that overrides Silence during the day and
/// a second Critical config that goes silent at night.
///
/// Lookup at fire time picks the variant whose `activeOption` matches the
/// current day/night window, falling back to the `.always` variant.
struct DeviceAlertSeverityConfig: Codable, Equatable, Identifiable {
    var id: UUID
    var severity: DeviceAlertSeverity
    var isEnabled: Bool
    var soundFilename: String
    var playsSound: Bool
    /// Whether the tone is cut short at all. Off is the untrimmed behavior: the
    /// player loops until the alert is acknowledged or retracted.
    var trimsSound: Bool
    /// What the tone is trimmed to when `trimsSound` is on.
    var soundTrim: AlarmSoundTrim
    /// Seconds the tone sounds for when `soundTrim` is `.length`.
    var soundDuration: TimeInterval
    /// When true, alarms in this tier bypass Focus Mode / silent switch
    /// (maps to `Alert.InterruptionLevel.critical` and engages the in-process
    /// `CriticalAlertAudioPlayer` fallback if `playsSound` is true).
    /// When false, the alarm uses `.timeSensitive`.
    var overridesSilenceAndDND: Bool
    var activeOption: ActiveOption

    init(
        id: UUID = UUID(),
        severity: DeviceAlertSeverity,
        activeOption: ActiveOption = .always
    ) {
        self.id = id
        self.severity = severity
        isEnabled = true
        soundFilename = severity.defaultSoundFilename
        playsSound = true
        trimsSound = false
        soundTrim = .length
        soundDuration = AlarmSoundDurationRange.defaultSeconds
        overridesSilenceAndDND = severity.defaultOverridesSilenceAndDND
        self.activeOption = activeOption
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id
        case severity
        case isEnabled
        case soundFilename
        case playsSound
        case trimsSound
        case soundTrim
        case soundDuration
        case overridesSilenceAndDND
        case activeOption
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        severity = try container.decode(DeviceAlertSeverity.self, forKey: .severity)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        soundFilename = try container.decodeIfPresent(String.self, forKey: .soundFilename) ?? severity.defaultSoundFilename
        playsSound = try container.decodeIfPresent(Bool.self, forKey: .playsSound) ?? true
        trimsSound = try container.decodeIfPresent(Bool.self, forKey: .trimsSound) ?? false
        soundTrim = try container.decodeIfPresent(AlarmSoundTrim.self, forKey: .soundTrim) ?? .length
        soundDuration = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .soundDuration
        ) ?? AlarmSoundDurationRange.defaultSeconds
        overridesSilenceAndDND = try container.decodeIfPresent(
            Bool.self,
            forKey: .overridesSilenceAndDND
        ) ?? severity.defaultOverridesSilenceAndDND
        activeOption = try container.decodeIfPresent(ActiveOption.self, forKey: .activeOption) ?? .always
    }
}

/// What a trimmed alarm tone is cut to.
enum AlarmSoundTrim: String, CaseIterable, Codable, Identifiable {
    /// One pass of the sound file, however long that happens to be.
    case playOnce
    /// A fixed stretch, set by the slider.
    case length

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .playOnce: return String(localized: "Play Once")
        case .length: return String(localized: "Set Length")
        }
    }
}

/// How the alarm tone should be played, resolved from the tier config.
enum AlarmSoundPlayback: Equatable {
    /// Loop until something stops it — acknowledgement or retraction.
    case untilAcknowledged
    /// A single pass of the file.
    case once
    /// Loop, then cut off after this many seconds.
    case seconds(TimeInterval)
}

extension DeviceAlertSeverityConfig {
    var playback: AlarmSoundPlayback {
        guard trimsSound else { return .untilAcknowledged }
        switch soundTrim {
        case .playOnce: return .once
        case .length: return .seconds(soundDuration)
        }
    }
}

/// Bounds for the alarm-length slider, and the label that goes with a value.
enum AlarmSoundDurationRange {
    static let minimumSeconds: TimeInterval = 5
    static let maximumSeconds: TimeInterval = 300
    static let step: TimeInterval = 5
    static let defaultSeconds: TimeInterval = 60

    static var bounds: ClosedRange<TimeInterval> { minimumSeconds ... maximumSeconds }

    static func label(for seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        if minutes == 0 {
            return String(format: String(localized: "%d s", comment: "Alarm length in seconds"), remainder)
        }
        if remainder == 0 {
            return String(format: String(localized: "%d min", comment: "Alarm length in minutes"), minutes)
        }
        return String(
            format: String(localized: "%1$d min %2$d s", comment: "Alarm length in minutes and seconds"),
            minutes,
            remainder
        )
    }
}
