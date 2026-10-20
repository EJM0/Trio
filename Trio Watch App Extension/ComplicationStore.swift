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

/// The watch app publishes snapshots to the app group and asks WidgetKit to reload only kinds whose visible data
/// changed. Background requests are throttled per kind; WidgetKit still decides when to serve them.
enum ComplicationStore {
    /// Every complication that shows the loop's data (not the Meal & Bolus shortcut).
    private static let glucoseKind = "TrioWatchComplication"
    private static let iobKind = "TrioIOBComplication"
    private static let cobKind = "TrioCOBComplication"
    private static let onBoardKind = "TrioOnBoardComplication"
    private static let kinds = [glucoseKind, iobKind, cobKind, onBoardKind]
    private static let key = "complication.glucose"
    private static let reloadStateKey = "complication.reloadState"
    /// Migrate the previous single timestamp so an app update cannot immediately burst-reload every kind.
    private static let legacyReloadedKey = "complication.reloadedAt"
    /// The graph spans 3 hours.
    private static let span: TimeInterval = 3 * 60 * 60
    private static let backgroundReloadInterval: TimeInterval = 300

    private struct ReloadState: Codable {
        var lastBackgroundReloadByKind: [String: Date] = [:]
        var owedKinds: Set<String> = []
    }

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
        let now = Date()
        let changedKinds = changedKinds(from: old, to: data)
        if data != old {
            guard let encoded = try? JSONEncoder().encode(data) else { return }
            defaults.set(encoded, forKey: key)
        }

        var reloadState = loadReloadState(from: defaults)
        reloadState.owedKinds.formUnion(changedKinds)
        guard !reloadState.owedKinds.isEmpty else { return }

        let isInFront = WKApplication.shared().applicationState == .active
        for kind in kinds where reloadState.owedKinds.contains(kind) {
            if isInFront {
                WidgetCenter.shared.reloadTimelines(ofKind: kind)
                reloadState.owedKinds.remove(kind)
            } else {
                let lastReload = reloadState.lastBackgroundReloadByKind[kind] ?? .distantPast
                guard now.timeIntervalSince(lastReload) >= backgroundReloadInterval else { continue }
                WidgetCenter.shared.reloadTimelines(ofKind: kind)
                reloadState.lastBackgroundReloadByKind[kind] = now
                reloadState.owedKinds.remove(kind)
            }
        }
        saveReloadState(reloadState, to: defaults)
    }

    /// Each kind reloads only when one of its displayed values changes. Timeline entries handle age and staleness.
    private static func changedKinds(from old: TrioComplicationData?, to new: TrioComplicationData) -> Set<String> {
        guard let old else { return Set(kinds) }
        var changed = Set<String>()
        if old.points != new.points || old.isMmol != new.isMmol || old.low != new.low || old.high != new.high
            || old.trend != new.trend || old.delta != new.delta || old.lastLoop != new.lastLoop
            || old.iob != new.iob || old.cob != new.cob || old.watchLoops != new.watchLoops
        {
            changed.insert(glucoseKind)
        }
        if old.iob != new.iob || old.lastLoop != new.lastLoop { changed.insert(iobKind) }
        if old.cob != new.cob || old.lastLoop != new.lastLoop { changed.insert(cobKind) }
        if old.iob != new.iob || old.cob != new.cob || old.lastLoop != new.lastLoop { changed.insert(onBoardKind) }
        return changed
    }

    private static func loadReloadState(from defaults: UserDefaults) -> ReloadState {
        if let data = defaults.data(forKey: reloadStateKey),
           let state = try? JSONDecoder().decode(ReloadState.self, from: data)
        {
            return state
        }
        var state = ReloadState()
        if let previousReload = defaults.object(forKey: legacyReloadedKey) as? Date {
            state.lastBackgroundReloadByKind = Dictionary(uniqueKeysWithValues: kinds.map { ($0, previousReload) })
        }
        return state
    }

    private static func saveReloadState(_ state: ReloadState, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: reloadStateKey)
    }
}
