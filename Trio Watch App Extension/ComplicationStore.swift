import Foundation
import SwiftUI
import WatchKit
import WidgetKit

/// What the watch-face complications show. The watch app writes it to the Trio app group; the complication only
/// reads it. Keep in step with the copy in TrioWatchComplication.swift.
struct TrioComplicationData: Codable, Equatable {
    struct Point: Codable, Equatable {
        let date: Date
        /// In the display units.
        let value: Double
        /// "#RRGGBB" by Trio's glucose color scheme, as the phone colors it.
        var color: String?
    }

    var points: [Point]
    var isMmol: Bool
    /// The shaded range, in the display units.
    var low: Double
    var high: Double
    /// Nightscout direction name of the newest reading.
    var trend: String?
    var delta: String?
    /// The loop ring turns yellow and red from here, without a reload.
    var lastLoop: Date?
    var iob: String?
    var cob: String?
    /// The watch runs the loop (untethered).
    var watchLoops: Bool
}

/// The watch app's side of the complications, as LoopKit/Loop#2562 and #2563 publish theirs: a snapshot in the app
/// group, and a reload only when what the face shows changed. watchOS grants a background reload about once every
/// 300 s per app, and only while the app holds a Bluetooth link; ages, the ring's color and staleness advance from
/// timeline entries instead.
enum ComplicationStore {
    /// Every complication that shows the loop's data (not the Meal & Bolus shortcut).
    static let kinds = ["TrioWatchComplication", "TrioIOBComplication", "TrioCOBComplication", "TrioOnBoardComplication"]
    private static let key = "complication.glucose"
    private static let reloadedKey = "complication.reloadedAt"
    /// The graph spans 3 hours.
    private static let span: TimeInterval = 3 * 60 * 60
    private static let backgroundReloadInterval: TimeInterval = 300

    private static var defaults: UserDefaults? {
        (Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String).flatMap { UserDefaults(suiteName: $0) }
    }

    static func load() -> TrioComplicationData? {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(TrioComplicationData.self, from: $0) }
    }

    /// After the phone's state, the watch's own reading or untethered mode's loop reached the watch state.
    static func update(from state: WatchState, watchLoops: Bool = false) {
        guard let defaults else { return }
        let cutoff = Date().addingTimeInterval(-span)
        let points = state.glucoseValues.filter { $0.date >= cutoff }
            .map { TrioComplicationData.Point(date: $0.date, value: $0.glucose, color: $0.color.toHexString()) }
        guard !points.isEmpty else { return }
        let range = state.glucoseRange
        let data = TrioComplicationData(
            points: points,
            isMmol: range.isMmol,
            low: range.display(NSDecimalNumber(decimal: range.low).intValue),
            high: range.display(NSDecimalNumber(decimal: range.high).intValue),
            trend: state.trend,
            delta: state.delta,
            lastLoop: state.lastLoopDate,
            iob: state.iob,
            cob: state.cob,
            watchLoops: watchLoops
        )
        let old = load()
        guard data != old, let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: key)

        // In front every reload is free. In the background watchOS builds one about every 300 s per app, and only
        // while the app holds a Bluetooth link; one asked for sooner is refused (LoopKit/Loop#2563). So in the
        // background at most one per window, whatever changed: a reading, or the loop's IOB and COB a little after it,
        // which then also serves as the retry for a reading that came a moment too early. (2026-10-19: some 20 redraws
        // an hour overnight went past the budget, and the face went stale.)
        let now = Date()
        let reloadedAt = defaults.object(forKey: reloadedKey) as? Date ?? .distantPast
        let isInFront = WKApplication.shared().applicationState == .active
        guard isInFront || now.timeIntervalSince(reloadedAt) >= backgroundReloadInterval else { return }
        defaults.set(now, forKey: reloadedKey)
        kinds.forEach { WidgetCenter.shared.reloadTimelines(ofKind: $0) }
    }
}
