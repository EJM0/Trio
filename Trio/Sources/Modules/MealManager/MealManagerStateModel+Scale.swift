import Combine
import Foundation

// MARK: - Connected Scale

/// Live weight and battery from the optional Bluetooth kitchen scale. The manager reconnects on
/// its own, so this only mirrors the link into the UI.
extension MealManager.StateModel {
    func startScaleStream() {
        guard !settingsManager.settings.scaleID.isEmpty else { return }
        provider.scaleManager.connect(
            onWeight: { [weak self] in self?.liveScaleWeight = $0 },
            onBattery: { [weak self] in self?.scaleBatteryLevel = $0 },
            onConnectionChange: { [weak self] isConnected in
                guard let self else { return }
                // 0.0 so the UI shows the scale as connected before the first reading lands.
                self.liveScaleWeight = isConnected ? (self.liveScaleWeight ?? 0) : nil
                if !isConnected { self.scaleBatteryLevel = nil }
            }
        )
    }

    func stopScaleStream() {
        provider?.scaleManager.disconnect()
        liveScaleWeight = nil
        scaleBatteryLevel = nil
    }

    /// Mean of the next `samples` readings, so a pan still settling does not decide the amount.
    /// The scale sends 5 readings a second, so the default 10 take about 2 s. Nil if the scale
    /// drops before they are in.
    @MainActor func averagedScaleWeight(samples: Int = 10) async -> Double? {
        var readings: [Double] = []
        for await weight in $liveScaleWeight.dropFirst().values {
            guard let weight else { return nil }
            readings.append(weight)
            if readings.count == samples { break }
        }
        guard readings.count == samples else { return nil }
        return readings.reduce(0, +) / Double(samples)
    }

    func tareScale() {
        provider.scaleManager.tare()
    }
}
