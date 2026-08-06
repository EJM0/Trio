import CoreData
import Foundation

public extension GlucoseEpisodeStored {
    @nonobjc class func fetchRequest() -> NSFetchRequest<GlucoseEpisodeStored> {
        NSFetchRequest<GlucoseEpisodeStored>(entityName: "GlucoseEpisodeStored")
    }

    /// First reading past the threshold. Kept as measured, even once the readings behind it
    /// have aged out of the chart's window.
    @NSManaged var start: Date?
    /// First reading back in range once the recovery held. Only closed episodes are stored;
    /// a running one is re-derived from the readings on every update.
    @NSManaged var end: Date?
    /// `GlucoseEpisode.EpisodeType` raw value.
    @NSManaged var type: String?
    @NSManaged var duration: Double
    /// The thresholds the excursion was measured against. Changing either redefines what
    /// counts as an episode, so rows recorded under the old limits are discarded.
    @NSManaged var lowThreshold: Double
    @NSManaged var highThreshold: Double
}

extension GlucoseEpisodeStored: Identifiable {}
