import Foundation

/// A sustained glucose excursion: a period spent above the high threshold or below the low one.
///
/// Episodes are detected once, as the readings arrive, and then kept by `GlucoseEpisodeStore`
/// until their end leaves the chart's 72 h history — see there for why they are held rather
/// than re-derived from the window on every update.
struct GlucoseEpisode: Identifiable, Equatable, Sendable {
    enum EpisodeType: String, Sendable {
        case high
        case low
    }

    /// The first reading past the threshold.
    let start: Date
    /// The first reading back in range once the recovery is sustained; `nil` while the
    /// episode is still running.
    let end: Date?
    let type: EpisodeType
    /// Set once the episode is evaluated as done, so a finished episode carries its own
    /// length; `nil` while it is still running.
    let duration: TimeInterval?

    /// Stable for the life of the episode, so Charts keeps the identity of marks it has
    /// already laid out.
    var id: String { "\(type.rawValue)-\(start.timeIntervalSince1970)" }

    var isOngoing: Bool { end == nil }

    /// The episode's final length once closed, else how long it has run so far.
    func elapsed(asOf now: Date = Date()) -> TimeInterval {
        duration ?? max(now.timeIntervalSince(start), 0)
    }

    /// Right edge of the marker: where the episode ended, or wherever "now" is while it runs.
    func displayEnd(asOf now: Date = Date()) -> Date {
        end ?? max(now, start)
    }

    /// `hh:mm` — a 3 h 5 min high reads `3:05`.
    func formattedDuration(asOf now: Date = Date()) -> String {
        let total = Int(elapsed(asOf: now).rounded())
        return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
    }
}

// MARK: - Detection

extension GlucoseEpisode {
    /// Walks a chronologically ascending series of readings and returns the excursions in it.
    ///
    /// An episode opens on the first reading past a threshold and closes only once the
    /// recovery is *sustained* — `Config.episodeRecoveryReadings` consecutive in-range
    /// readings (or `Config.episodeRecoveryDuration` of them, whichever comes first). A
    /// briefer dip back into range, the 3-5 readings that a correction or a compression low
    /// typically produces before the excursion resumes, leaves the episode running: the
    /// marker spans the whole event instead of being chopped into fragments.
    ///
    /// When it does close, it closes at the *first* reading of the recovery run — the moment
    /// glucose came back — not at the reading that proved the recovery had held.
    ///
    /// Gaps in the series are bridged: readings are not assumed to be continuous, so the scan
    /// simply carries on with the next one. Only a gap longer than `Config.episodeMaxGap`
    /// ends the episode (at the last reading before it), since nothing is known about the
    /// glucose in between and a dead sensor should not inflate an excursion.
    ///
    /// - Parameters:
    ///   - readings: Glucose readings in ascending date order.
    ///   - lowThreshold: Below this (mg/dL) a reading counts as low.
    ///   - highThreshold: Above this (mg/dL) a reading counts as high.
    ///   - now: Reference point for deciding whether a trailing episode is still running.
    static func detect(
        in readings: some Collection<GlucoseReading>,
        lowThreshold: Decimal,
        highThreshold: Decimal,
        now: Date = Date()
    ) -> [GlucoseEpisode] {
        func classify(_ value: Int) -> EpisodeType? {
            let glucose = Decimal(value)
            if glucose > highThreshold { return .high }
            if glucose < lowThreshold { return .low }
            return nil
        }

        var episodes: [GlucoseEpisode] = []
        var openType: EpisodeType?
        var openStart = Date.distantPast
        /// First in-range reading of the run that may yet close the open episode.
        var recoveryStart: Date?
        var recoveryCount = 0
        var previousDate: Date?

        func close(at end: Date) {
            guard let type = openType else { return }
            episodes.append(GlucoseEpisode(
                start: openStart,
                end: end,
                type: type,
                duration: max(end.timeIntervalSince(openStart), 0)
            ))
            openType = nil
            recoveryStart = nil
            recoveryCount = 0
        }

        for reading in readings {
            if let previous = previousDate,
               reading.date.timeIntervalSince(previous) > MainChartHelper.Config.episodeMaxGap
            {
                close(at: recoveryStart ?? previous)
            }
            previousDate = reading.date

            let readingType = classify(reading.value)

            guard let current = openType else {
                if let readingType {
                    openType = readingType
                    openStart = reading.date
                    recoveryStart = nil
                    recoveryCount = 0
                }
                continue
            }

            if readingType == current {
                // Still in the excursion — whatever recovery was pending was too short to count.
                recoveryStart = nil
                recoveryCount = 0
            } else if readingType == nil {
                let runStart = recoveryStart ?? reading.date
                recoveryStart = runStart
                recoveryCount += 1
                let sustained = recoveryCount >= MainChartHelper.Config.episodeRecoveryReadings
                    || reading.date.timeIntervalSince(runStart) >= MainChartHelper.Config.episodeRecoveryDuration
                if sustained {
                    close(at: runStart)
                }
            } else {
                // Straight through range into the opposite excursion.
                close(at: recoveryStart ?? reading.date)
                openType = readingType
                openStart = reading.date
            }
        }

        if let current = openType {
            // The series running dry is not a recovery, but an episode must not keep growing
            // against a sensor that stopped reporting either: close it at the last reading.
            if let last = previousDate, now.timeIntervalSince(last) > MainChartHelper.Config.episodeMaxGap {
                close(at: last)
            } else {
                episodes.append(GlucoseEpisode(start: openStart, end: nil, type: current, duration: nil))
            }
        }

        return episodes
    }
}
