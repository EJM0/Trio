//
//  WatchStateSnapshot.swift
//  Trio
//
//  Created by Cengiz Deniz on 18.04.25.
//
import Foundation
import SwiftUI
import WidgetKit

enum WatchStateSnapshot {
    private static let storageKey = "WatchStateSnapshot.latest"

    static func saveLatestDateToDisk(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: storageKey)
    }

    static func loadLatestDateFromDisk() -> Date {
        let interval = UserDefaults.standard.double(forKey: storageKey)
        return Date(timeIntervalSince1970: interval)
    }
}

// MARK: - Glucose for the watch face

/// What the watch-face graph shows. The watch app writes it to the app group whenever a newer reading
/// arrives (from the phone or untethered mode); the complication only reads
/// it. Keep in step with the copy in TrioWatchComplication.swift.
struct TrioComplicationData: Codable {
    struct Point: Codable {
        let date: Date
        /// In the display units.
        let value: Double
        /// "#RRGGBB" by Trio's glucose color scheme, as the phone and the Live Activity color it.
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
    /// The phone's color scheme and target, to color the watch's own readings the same way.
    var colorScheme: String?
    var targetMgDL: Double?
}

enum ComplicationStore {
    static let kind = "TrioWatchComplication"
    private static let key = "complication.glucose"
    /// The graph spans 3 hours.
    private static let span: TimeInterval = 3 * 60 * 60
    private static let mmolFactor = 0.0555

    private static var defaults: UserDefaults? {
        (Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String)
            .flatMap { UserDefaults(suiteName: $0) }
    }

    static func load() -> TrioComplicationData? {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(TrioComplicationData.self, from: $0) }
    }

    private static func save(_ data: TrioComplicationData, previousLatest: Date?) {
        guard let defaults, let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: key)
        // redraw only for a newer reading: watchOS budgets the redraws. The phone's copy of a reading the
        // watch read itself carries a timestamp a few seconds apart; that is the same reading, not a new one
        // (2026-10-19: some 20 redraws an hour overnight, likely past the budget: the face went stale).
        if let latest = data.points.last?.date,
           previousLatest.map({ abs(latest.timeIntervalSince($0)) > 60 }) ?? true
        {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }

    private static func range(isMmol: Bool, lowMgDL: Double? = nil, highMgDL: Double? = nil) -> (low: Double, high: Double) {
        let low = lowMgDL ?? 70
        let high = highMgDL ?? 180
        return isMmol ? (low * mmolFactor, high * mmolFactor) : (low, high)
    }

    /// After the phone's data or untethered mode's own reached the watch state, with the units and range
    /// each sends.
    static func update(
        from state: WatchState,
        isMmol: Bool? = nil,
        lowMgDL: Double? = nil,
        highMgDL: Double? = nil,
        colorScheme: String? = nil,
        targetMgDL: Double? = nil
    ) {
        guard let newest = state.glucoseValues.last else { return }
        let old = load()
        let isMmol = isMmol ?? old?.isMmol ?? false
        let cutoff = Date().addingTimeInterval(-span)
        // the phone and untethered mode already colored each reading by the scheme
        var points = state.glucoseValues.filter { $0.date >= cutoff }
            .map { TrioComplicationData.Point(date: $0.date, value: $0.glucose, color: $0.color.toHexString()) }
        var trend = state.trend
        var delta = state.delta
        // untethered mode may be ahead of the phone's last message: keep its newer readings
        if let old, old.isMmol == isMmol {
            let newer = old.points.filter { $0.date > newest.date.addingTimeInterval(60) }
            if !newer.isEmpty {
                points += newer
                trend = old.trend
                delta = old.delta
            }
        }
        let shaded = range(isMmol: isMmol, lowMgDL: lowMgDL, highMgDL: highMgDL)
        save(
            TrioComplicationData(
                points: points,
                isMmol: isMmol,
                low: shaded.low,
                high: shaded.high,
                trend: trend,
                delta: delta,
                colorScheme: colorScheme ?? old?.colorScheme,
                targetMgDL: targetMgDL ?? old?.targetMgDL
            ),
            previousLatest: old?.points.last?.date
        )
    }
}
