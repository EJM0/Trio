import Foundation

/// What every page shows while the watch loops (as LoopKit/Loop#2545's glance model): IOB, COB, the last loop and
/// the forecast from the watch's own determination; the phone's would be stale.
extension WatchLoopSession {
    func publishDisplay() {
        let state = WatchState.shared
        guard self.state.phase == .active, let determination = self.state.lastDetermination else {
            state.watchLoopOwnsDisplay = false
            return
        }
        state.watchLoopOwnsDisplay = true
        if let iob = determination.iob {
            state.iob = Formatter.decimalFormatterWithTwoFractionDigits.string(from: iob as NSNumber)
        }
        if let cob = determination.cob {
            state.cob = Formatter.integerFormatter.string(from: cob as NSNumber)
        }
        if let loopedAt = self.state.lastLoopAt {
            state.lastLoopTime = "\(max(0, Int(Date().timeIntervalSince(loopedAt) / 60))) min"
            state.lastLoopDate = loopedAt
        }
        publishForecast(determination, on: state)
        ComplicationStore.update(from: state)
    }

    /// As the phone builds it (`AppleWatchManager`): two hours, lines or the cone the phone chose.
    private func publishForecast(_ determination: Determination, on state: WatchState) {
        guard let predictions = determination.predictions else { return }
        let mmol = self.state.grant?.units == .mmolL
        func convert(_ values: [Int]?) -> [Double]? {
            values.map { $0.prefix(24).map { mmol ? Double(truncating: Decimal($0).asMmolL as NSNumber) : Double($0) } }
        }
        let series = [
            "iob": convert(predictions.iob),
            "zt": convert(predictions.zt),
            "cob": convert(predictions.cob),
            "uam": convert(predictions.uam)
        ].compactMapValues { $0 }.filter { !$0.value.isEmpty }
        state.forecastStartDate = determination.deliverAt ?? self.state.lastLoopAt
        if !state.forecastConeMin.isEmpty {
            let count = series.values.map(\.count).min() ?? 0
            state.forecastConeMin = (0 ..< count).map { i in series.values.map { $0[i] }.min() ?? 0 }
            state.forecastConeMax = (0 ..< count).map { i in series.values.map { $0[i] }.max() ?? 0 }
            state.forecastLines = [:]
        } else {
            state.forecastLines = series
        }
    }
}
