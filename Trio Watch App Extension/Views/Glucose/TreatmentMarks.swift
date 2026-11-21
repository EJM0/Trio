import Charts
import Foundation
import SwiftUI

/// A bolus, SMB or carb entry the phone sent, placed on the glucose chart as a marker.
struct WatchTreatmentMarker: Identifiable {
    enum Kind { case bolus, smb, carbs }
    let id: String
    let date: Date
    let kind: Kind
}

/// IOB and COB at one loop, for the chart's scrub line (as the phone's chart shows them).
struct WatchIobCobPoint {
    let date: Date
    let iob: Double
    let cob: Double
}

/// As on the phone's main chart: a blue triangle pointing down above the reading for insulin, an orange one pointing
/// up below it for carbs.
struct TreatmentMarks: ChartContent {
    let markers: [WatchTreatmentMarker]
    let glucose: [(date: Date, glucose: Double, color: Color)]

    private struct Placed: Identifiable {
        let marker: WatchTreatmentMarker
        let y: Double
        var id: String { marker.id }
    }

    var body: some ChartContent {
        ForEach(placed) { placed in
            PointMark(x: .value("Time", placed.marker.date), y: .value("Glucose", placed.y))
                .symbol {
                    switch placed.marker.kind {
                    case .bolus,
                         .smb:
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: placed.marker.kind == .smb ? 6 : 9))
                            .foregroundStyle(Color.insulin)
                            .offset(y: -8)
                    case .carbs:
                        Image(systemName: "arrowtriangle.up.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.orange)
                            .offset(y: 8)
                    }
                }
        }
    }

    /// Each marker on the reading nearest to it; none without a reading within 15 minutes.
    private var placed: [Placed] {
        guard let start = glucose.first?.date else { return [] }
        return markers.filter { $0.date >= start }.compactMap { marker -> Placed? in
            func gap(_ reading: (date: Date, glucose: Double, color: Color)) -> TimeInterval {
                abs(reading.date.timeIntervalSince(marker.date))
            }
            guard let nearest = glucose.min(by: { gap($0) < gap($1) }), gap(nearest) <= 15 * 60 else { return nil }
            return Placed(marker: marker, y: nearest.glucose)
        }
    }
}
