import Foundation

/// Everything one oref run reads, as plain values. The phone gathers them from Core Data and the
/// settings files; `OrefRun` turns them into a determination.
struct OrefInputs: Codable {
    /// The active temp target as stored in Core Data; feeds the half basal target adjustment.
    struct TempTargetState: Codable {
        var target: Decimal
        var halfBasalTarget: Decimal?
    }

    /// The active override, as far as `trio_custom_oref_variables` reads it.
    struct OverrideState: Codable {
        var enabled: Bool
        var percentage: Double
        var indefinite: Bool
        var smbIsOff: Bool
        var target: Decimal?
        var duration: Decimal?
        var advancedSettings: Bool
        var isfAndCr: Bool
        var isf: Bool
        var cr: Bool
        var smbIsScheduledOff: Bool
        var start: Decimal?
        var end: Decimal?
        var smbMinutes: Decimal?
        var uamMinutes: Decimal?
    }

    /// A stored TDD row from the last 10 days with a total above 0.
    struct TDDRow: Codable {
        var date: Date?
        var total: Decimal?
    }

    // Therapy settings, decoded from settings/*.json (bundled defaults for a missing file)
    var pumpSettings: PumpSettings
    var bgTargets: BGTargets
    var basalProfile: [BasalProfileEntry]
    var insulinSensitivities: InsulinSensitivities
    var carbRatios: CarbRatios
    var tempTargets: [TempTarget]
    /// preferences.json as stored, unclamped; nil when the file is missing.
    var preferences: Preferences?
    var dosingMode: DosingMode

    // Adjustments
    var activeTempTarget: TempTargetState?
    var activeOverride: OverrideState?

    // Dynamic ISF
    /// Oldest first.
    var tddHistory: [TDDRow]
    var hasSufficientTDD: Bool

    // Device data
    /// The last 24 h, newest first. The determination uses the last `maxMealAbsorptionTime` + 0.5 h of it.
    var glucose: [BloodGlucose]
    /// The last 24 h without orphaned resumes, newest first.
    var pumpHistory: [PumpHistoryEvent]
    /// The last 24 h, newest first.
    var carbs: [CarbsEntry]
    var currentTemp: TempBasal
    var supportedBasalRates: [Decimal]

    /// The last autosens result while the caller still considers it fresh; nil runs autosens.
    var autosens: Autosens?
    var clock: Date
}
