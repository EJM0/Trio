import Foundation

/// A single configurable glucose alarm. Multiple entries of the same type are
/// allowed — e.g. a Low alarm `active: .day` at 80 mg/dL plus a second Low
/// `active: .night` at 70 mg/dL.
struct GlucoseAlert: Identifiable, Codable, Equatable {
    var id: UUID
    var type: GlucoseAlertType
    var name: String
    var isEnabled: Bool
    var thresholdMgDL: Decimal
    var soundFilename: String
    /// When false, the alarm fires the banner / notification but no sound.
    /// iOS still drives haptics from the interruption level.
    var playsSound: Bool
    /// Whether the tone is cut short at all. Off is the untrimmed behavior: the
    /// player loops until the alarm is acknowledged or retracted.
    var trimsSound: Bool
    /// What the tone is trimmed to when `trimsSound` is on.
    var soundTrim: AlarmSoundTrim
    /// Seconds the tone sounds for when `soundTrim` is `.length`.
    var soundDuration: TimeInterval
    /// When true, this alarm bypasses Focus Mode / silent switch
    /// modes. Maps to `Alert.InterruptionLevel.critical` and triggers the
    /// in-process `CriticalAlertAudioPlayer` fallback for builds without the
    /// Critical Alerts entitlement.
    var overridesSilenceAndDND: Bool
    var activeOption: ActiveOption
    /// Per-alarm snooze. Distinct from the global mute on `AlertMuter`.
    var snoozedUntil: Date?

    init(type: GlucoseAlertType) {
        id = UUID()
        self.type = type
        name = type.displayName
        isEnabled = true
        thresholdMgDL = type.defaultThresholdMgDL
        soundFilename = type.defaultSoundFilename
        playsSound = true
        trimsSound = false
        soundTrim = .length
        soundDuration = AlarmSoundDurationRange.defaultSeconds
        overridesSilenceAndDND = type.defaultOverridesSilenceAndDND
        activeOption = .always
        snoozedUntil = nil
    }

    /// Whether the coordinator should fire this alarm when a reading breaches.
    /// Urgent-low is the safety floor — the editor hides the Enabled toggle so
    /// the user can't accidentally turn it off, and stored `isEnabled = false`
    /// from a prior install is ignored here.
    var shouldEvaluate: Bool {
        type == .urgentLow || isEnabled
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case name
        case isEnabled
        case thresholdMgDL
        case soundFilename
        case playsSound
        case trimsSound
        case soundTrim
        case soundDuration
        case overridesSilenceAndDND
        case activeOption
        case snoozedUntil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(GlucoseAlertType.self, forKey: .type)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        thresholdMgDL = try container.decode(Decimal.self, forKey: .thresholdMgDL)
        soundFilename = try container.decodeIfPresent(String.self, forKey: .soundFilename) ?? type.defaultSoundFilename
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
        ) ?? type.defaultOverridesSilenceAndDND
        activeOption = try container.decodeIfPresent(ActiveOption.self, forKey: .activeOption) ?? .always
        snoozedUntil = try container.decodeIfPresent(Date.self, forKey: .snoozedUntil)
    }
}

extension GlucoseAlert {
    var playback: AlarmSoundPlayback {
        AlarmSoundPlayback(trimsSound: trimsSound, trim: soundTrim, seconds: soundDuration)
    }
}
