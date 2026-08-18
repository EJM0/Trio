import CoreData
import Foundation

/// Type of extremum detected at a glucose data point.
enum ExtremumType {
    case max
    case min
    case none
}

/// A minimal glucose data point for peak detection.
struct GlucosePoint {
    let date: Date
    let glucose: Int
}

/// Sliding-window local extrema picker.
///
/// A point is a local maximum if it equals the largest value in the window
/// `[time − W, time + W]` and a local minimum if it equals the smallest. Implemented
/// with two monotonic deques so each point enters and leaves at most once — O(n).
enum PeakPicker {
    /// Pick maxima and minima within ±`windowHours` of each point. Larger windows
    /// surface only the most prominent swings; smaller windows surface more peaks.
    static func pick(
        data: [GlucosePoint],
        windowHours: Double = 2
    ) -> [(point: GlucosePoint, type: ExtremumType)] {
        let W: TimeInterval = windowHours * 3600

        let asc = data.filter { $0.glucose > 0 }.sorted { $0.date < $1.date }
        let n = asc.count
        guard n > 0 else { return [] }

        let times = asc.map(\.date)
        let vals = asc.map { Double($0.glucose) }

        // Monotonic deques of indices — keep only the *latest* among equal values
        // so flat plateaus collapse to a single peak.
        var maxDQ: [Int] = [] // decreasing by value
        var minDQ: [Int] = [] // increasing by value
        var maxHead = 0
        var minHead = 0

        @inline(__always) func maxFront() -> Int? { maxHead < maxDQ.count ? maxDQ[maxHead] : nil }
        @inline(__always) func minFront() -> Int? { minHead < minDQ.count ? minDQ[minHead] : nil }

        func maxPush(_ j: Int) {
            while maxHead < maxDQ.count, vals[j] >= vals[maxDQ.last!] { _ = maxDQ.popLast() }
            maxDQ.append(j)
        }
        func minPush(_ j: Int) {
            while minHead < minDQ.count, vals[j] <= vals[minDQ.last!] { _ = minDQ.popLast() }
            minDQ.append(j)
        }
        func maxPopFrontIf(_ idx: Int) { if let f = maxFront(), f == idx { maxHead += 1 } }
        func minPopFrontIf(_ idx: Int) { if let f = minFront(), f == idx { minHead += 1 } }

        var L = 0
        var R = -1

        var result: [(point: GlucosePoint, type: ExtremumType)] = []

        for i in 0 ..< n {
            let ti = times[i]

            while R + 1 < n, times[R + 1].timeIntervalSince(ti) <= W {
                R += 1
                maxPush(R)
                minPush(R)
            }
            while L <= R, ti.timeIntervalSince(times[L]) > W {
                maxPopFrontIf(L)
                minPopFrontIf(L)
                L += 1
            }

            if let mf = maxFront(), mf == i { result.append((asc[i], .max)) }
            if let nf = minFront(), nf == i { result.append((asc[i], .min)) }
        }

        return result
    }

    /// Convenience overload accepting `[GlucoseStored]` from Core Data.
    static func pick(
        data: [GlucoseStored],
        windowHours: Double = 2
    ) -> [(date: Date, glucose: Int16, type: ExtremumType)] {
        let points = data.compactMap { g -> GlucosePoint? in
            guard let date = g.date else { return nil }
            return GlucosePoint(date: date, glucose: Int(g.glucose))
        }

        return pick(data: points, windowHours: windowHours)
            .map { (date: $0.point.date, glucose: Int16($0.point.glucose), type: $0.type) }
    }
}
