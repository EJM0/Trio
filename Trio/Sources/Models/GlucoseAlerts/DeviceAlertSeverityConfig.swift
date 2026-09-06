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
    /// How long the alarm tone keeps sounding once it starts. `.untilAcknowledged`
    /// keeps the pre-existing behavior: loop until the alert is acknowledged or
    /// retracted.
    var soundDuration: AlarmSoundDuration
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
        soundDuration = .untilAcknowledged
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
        soundDuration = try container.decodeIfPresent(
            AlarmSoundDuration.self,
            forKey: .soundDuration
        ) ?? .untilAcknowledged
        overridesSilenceAndDND = try container.decodeIfPresent(
            Bool.self,
            forKey: .overridesSilenceAndDND
        ) ?? severity.defaultOverridesSilenceAndDND
        activeOption = try container.decodeIfPresent(ActiveOption.self, forKey: .activeOption) ?? .always
    }
}

/// How long a device alarm keeps sounding after it starts.
///
/// The critical-audio player loops its tone until something stops it, which for
/// an alarm nobody is there to acknowledge means "forever". This caps that: the
/// notification stays, the noise doesn't.
enum AlarmSoundDuration: String, CaseIterable, Codable, Identifiable {
    case untilAcknowledged
    case seconds15
    case seconds30
    case minutes1
    case minutes2
    case minutes5

    var id: String { rawValue }

    /// Playback cap in seconds, or nil to keep looping until acknowledged.
    var seconds: TimeInterval? {
        switch self {
        case .untilAcknowledged: return nil
        case .seconds15: return 15
        case .seconds30: return 30
        case .minutes1: return 60
        case .minutes2: return 120
        case .minutes5: return 300
        }
    }

    var displayName: String {
        switch self {
        case .untilAcknowledged: return String(localized: "Until Acknowledged")
        case .seconds15: return String(localized: "15 seconds")
        case .seconds30: return String(localized: "30 seconds")
        case .minutes1: return String(localized: "1 minute")
        case .minutes2: return String(localized: "2 minutes")
        case .minutes5: return String(localized: "5 minutes")
        }
    }
}
