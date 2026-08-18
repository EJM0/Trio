import CoreData
import SwiftUI

extension UserInterfaceSettings {
    final class StateModel: BaseStateModel<Provider> {
        @Published var low: Decimal = 70
        @Published var high: Decimal = 180
        @Published var xGridLines = false
        @Published var yGridLines: Bool = false
        @Published var showGlucoseEpisodes: Bool = true
        @Published var rulerMarks: Bool = true
        @Published var showGlucosePeaks: Bool = false
        @Published var bolusDisplayThreshold: BolusDisplayThreshold = .allUnits
        @Published var bolusDisplayThresholdMultiplier: Decimal = 1.3
        @Published var forecastDisplayType: ForecastDisplayType = .cone
        @Published var showCarbsRequiredBadge: Bool = true
        @Published var carbsRequiredThreshold: Decimal = 0
        @Published var glucoseColorScheme: GlucoseColorScheme = .dynamicColor
        @Published var eA1cDisplayUnit: EstimatedA1cDisplayUnit = .percent
        @Published var timeInRangeType: TimeInRangeType = .timeInTightRange
        @Published var averageSMBBolus: Decimal?
        @Published var homeStatsPanelFace: HomeStatsPanelFace = .timeInRange
        @Published var requireAdjustmentsConfirmation: Bool = false
        @Published var currentGlucoseTarget: Decimal = 100

        var units: GlucoseUnits = .mgdL
        private let pumpHistoryFetchContext = CoreDataStack.shared.newTaskContext()

        override func subscribe() {
            let units = settingsManager.settings.units
            self.units = units

            subscribeSetting(\.xGridLines, on: $xGridLines) { xGridLines = $0 }
            subscribeSetting(\.yGridLines, on: $yGridLines) { yGridLines = $0 }
            subscribeSetting(\.showGlucoseEpisodes, on: $showGlucoseEpisodes) { showGlucoseEpisodes = $0 }
            subscribeSetting(\.rulerMarks, on: $rulerMarks) { rulerMarks = $0 }
            subscribeSetting(\.showGlucosePeaks, on: $showGlucosePeaks) { showGlucosePeaks = $0 }
            subscribeSetting(\.bolusDisplayThreshold, on: $bolusDisplayThreshold) { bolusDisplayThreshold = $0 }
            subscribeSetting(
                \.bolusDisplayThresholdMultiplier,
                on: $bolusDisplayThresholdMultiplier
            ) {
                let sanitizedMultiplier = sanitizedBolusDisplayThresholdMultiplier(from: $0)
                bolusDisplayThresholdMultiplier = sanitizedMultiplier
                if sanitizedMultiplier != $0 {
                    settingsManager.settings.bolusDisplayThresholdMultiplier = sanitizedMultiplier
                }
            }

            subscribeSetting(\.forecastDisplayType, on: $forecastDisplayType) { forecastDisplayType = $0 }

            subscribeSetting(\.low, on: $low) { low = $0 }

            subscribeSetting(\.high, on: $high) { high = $0 }

            subscribeSetting(\.showCarbsRequiredBadge, on: $showCarbsRequiredBadge) { showCarbsRequiredBadge = $0 }

            subscribeSetting(
                \.carbsRequiredThreshold,
                on: $carbsRequiredThreshold
            ) { carbsRequiredThreshold = $0 }

            subscribeSetting(\.glucoseColorScheme, on: $glucoseColorScheme) { glucoseColorScheme = $0 }

            subscribeSetting(\.eA1cDisplayUnit, on: $eA1cDisplayUnit) { eA1cDisplayUnit = $0 }

            subscribeSetting(\.timeInRangeType, on: $timeInRangeType) { timeInRangeType = $0 }
            subscribeSetting(\.homeStatsPanelFace, on: $homeStatsPanelFace) { homeStatsPanelFace = $0 }

            subscribeSetting(\.requireAdjustmentsConfirmation, on: $requireAdjustmentsConfirmation) {
                requireAdjustmentsConfirmation = $0 }

            updateAverageSMBBolus()
            Task { await getCurrentGlucoseTarget() }
        }

        /// Resolves the glucose target active right now from the BG target schedule.
        func getCurrentGlucoseTarget() async {
            let bgTargets = await provider.getBGTargets()
            if let target = bgTargets.currentTarget() {
                await MainActor.run { currentGlucoseTarget = target }
            }
        }

        var currentBolusDisplayCutoff: Decimal? {
            guard let averageSMBBolus, bolusDisplayThreshold == .aboveAverageSMBFactor else {
                return nil
            }
            return averageSMBBolus * bolusDisplayThresholdMultiplier
        }

        func updateAverageSMBBolus() {
            Task {
                do {
                    let average = try await fetchAverageSMBBolus()
                    await MainActor.run {
                        self.averageSMBBolus = average
                    }
                } catch {
                    debug(.default, "\(DebuggingIdentifiers.failed) Error fetching average SMB bolus: \(error)")
                }
            }
        }

        private func fetchAverageSMBBolus() async throws -> Decimal? {
            try await pumpHistoryFetchContext.perform {
                let request = PumpEventStored.fetchRequest()
                request.predicate = NSPredicate(
                    format: "timestamp >= %@ AND bolus != nil AND bolus.isSMB == YES",
                    Date(timeIntervalSinceNow: -24 * 60 * 60) as NSDate
                )
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

                let results = try self.pumpHistoryFetchContext.fetch(request)
                let amounts = results.compactMap { $0.bolus?.amount as Decimal? }
                guard !amounts.isEmpty else {
                    return nil
                }

                let total = amounts.reduce(Decimal.zero, +)
                return total / Decimal(amounts.count)
            }
        }

        private func sanitizedBolusDisplayThresholdMultiplier(from value: Decimal) -> Decimal {
            let setting = PickerSettingsProvider.shared.settings.bolusDisplayThresholdMultiplier
            let pickerValues = PickerSettingsProvider.shared.generatePickerValues(from: setting, units: units)
            guard !pickerValues.isEmpty else {
                return value.clamp(to: setting)
            }

            let clampedValue = value.clamp(to: setting)
            return pickerValues.min {
                abs(NSDecimalNumber(decimal: $0 - clampedValue).doubleValue)
                    < abs(NSDecimalNumber(decimal: $1 - clampedValue).doubleValue)
            } ?? clampedValue
        }
    }
}

extension UserInterfaceSettings.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
        updateAverageSMBBolus()
    }
}
