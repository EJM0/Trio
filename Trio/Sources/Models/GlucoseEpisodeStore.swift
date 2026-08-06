import CoreData
import Foundation

/// Keeps the sustained glucose excursions the chart marks, in Core Data alongside the readings
/// they were found in.
///
/// Episodes used to be re-derived from the whole fetch window on every reading. That was wrong
/// as well as wasteful: the window's leading edge moves, so an excursion that began before it
/// lost its start reading by reading, and its length — the one thing the marker exists to
/// report — counted down as it aged out. Found once and stored, an episode keeps the length it
/// actually ran until it leaves the chart, and survives a relaunch instead of being recomputed
/// from a window that no longer contains its beginning.
///
/// Each update therefore scans only from the last stored episode's end, less
/// `episodeRescanOverlap` so a routine CGM backfill still reshapes the episode it belongs to.
/// Within that stretch the scan decides; behind it, storage does. A backfill older than the
/// overlap will not rewrite an episode already recorded — the trade for not re-deriving them.
///
/// Rows carry the thresholds they were measured against, so changing `low`/`high` — which
/// redefines what an excursion even is — discards them and rebuilds from the window.
///
/// Eviction matches the chart's history: an episode is deleted once its *end* falls out of
/// `chartHistorySeconds`. One that merely *started* before the window stays, because the chart
/// still draws it from its own leading edge. `TrioApp.purgeOldNSManagedObjects` sweeps the same
/// entity at launch, as it does for every other chart-feeding entity.
actor GlucoseEpisodeStore {
    private let makeContext: () -> NSManagedObjectContext

    init(contextProvider: (() -> NSManagedObjectContext)? = nil) {
        makeContext = contextProvider ?? { CoreDataStack.shared.newTaskContext() }
    }

    /// Folds a fetch of the glucose window into the store and returns everything the chart
    /// should draw: the stored episodes plus the one still running, if any.
    ///
    /// - Parameter readings: The whole fetched window, ascending by date.
    func update(
        with readings: [GlucoseReading],
        lowThreshold: Decimal,
        highThreshold: Decimal,
        now: Date = Date()
    ) async -> [GlucoseEpisode] {
        let context = makeContext()
        context.name = "updateGlucoseEpisodes"
        let low = NSDecimalNumber(decimal: lowThreshold).doubleValue
        let high = NSDecimalNumber(decimal: highThreshold).doubleValue
        let cutoff = now.addingTimeInterval(-MainChartHelper.Config.chartHistorySeconds)

        return await context.perform {
            let request = GlucoseEpisodeStored.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \GlucoseEpisodeStored.start, ascending: true)]

            var stored: [GlucoseEpisodeStored]
            do {
                stored = try context.fetch(request)
            } catch {
                debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to fetch glucose episodes: \(error)")
                return []
            }

            // Rows that have aged out, or that were measured against thresholds the user has
            // since changed, are gone — in the latter case the whole window is scanned again.
            stored.removeAll { episode in
                let expired = (episode.end ?? .distantPast) < cutoff
                let restated = episode.lowThreshold != low || episode.highThreshold != high
                guard expired || restated else { return false }
                context.delete(episode)
                return true
            }

            // Everything up to the last stored end is settled; the scan resumes from there,
            // reaching back far enough to take in a backfill of the last few hours.
            let resume = stored.last?.end?
                .addingTimeInterval(-MainChartHelper.Config.episodeRescanOverlap)
            let tail = resume.map { start in readings.drop(while: { $0.date < start }) } ?? readings[...]
            let detected = GlucoseEpisode.detect(
                in: tail,
                lowThreshold: lowThreshold,
                highThreshold: highThreshold,
                now: now
            )

            // An episode the scan has seen before is matched on its end — the one boundary that
            // cannot move once the recovery is in, where the start is exactly what the window's
            // leading edge trims away. The longer of the two lengths wins: a backfill can
            // genuinely deepen an excursion, ageing out can only appear to shorten it.
            var known = Dictionary(
                stored.compactMap { row in row.end.map { ($0, row) } },
                uniquingKeysWith: { first, _ in first }
            )
            var ongoing: GlucoseEpisode?

            for episode in detected {
                guard let end = episode.end, let measured = episode.duration else {
                    ongoing = episode
                    continue
                }
                if let row = known[end], row.type == episode.type.rawValue {
                    if measured > row.duration {
                        row.start = episode.start
                        row.duration = measured
                    }
                    continue
                }
                let row = GlucoseEpisodeStored(context: context)
                row.start = episode.start
                row.end = end
                row.type = episode.type.rawValue
                row.duration = measured
                row.lowThreshold = low
                row.highThreshold = high
                known[end] = row
                stored.append(row)
            }

            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to save glucose episodes: \(error)")
                }
            }

            let settled = stored
                .compactMap(GlucoseEpisode.init(stored:))
                .sorted { $0.start < $1.start }
            return ongoing.map { settled + [$0] } ?? settled
        }
    }
}

extension GlucoseEpisode {
    /// Value copy of a stored row. Rows without the boundaries that define an episode are
    /// skipped rather than guessed at.
    init?(stored: GlucoseEpisodeStored) {
        guard let start = stored.start,
              let end = stored.end,
              let type = stored.type.flatMap(EpisodeType.init(rawValue:))
        else { return nil }

        self.init(start: start, end: end, type: type, duration: stored.duration)
    }
}
