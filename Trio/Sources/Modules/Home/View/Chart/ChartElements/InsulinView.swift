import Charts
import Foundation
import SwiftUI

struct InsulinView: ChartContent {
    let glucoseData: [GlucoseStored]
    let insulinData: [PumpEventStored]
    let units: GlucoseUnits
    let bolusDisplayThreshold: BolusDisplayThreshold
    let bolusDisplayThresholdMultiplier: Decimal
    /// Source for the SMB average. Kept separate from `insulinData`, which only holds the
    /// visible window: the label threshold must not shift while panning or zooming.
    var smbAverageData: [PumpEventStored] = []

    private var smbAverageThreshold: Decimal? {
        let smbAmounts = smbAverageData.compactMap { insulin -> Decimal? in
            guard insulin.bolus?.isSMB == true, let amount = insulin.bolus?.amount as Decimal? else {
                return nil
            }
            return amount
        }

        guard !smbAmounts.isEmpty else {
            return nil
        }

        let total = smbAmounts.reduce(Decimal.zero, +)
        let average = total / Decimal(smbAmounts.count)
        return average * bolusDisplayThresholdMultiplier
    }

    var body: some ChartContent {
        drawBoluses()
    }

    private func drawBoluses() -> some ChartContent {
        ForEach(insulinData) { insulin in
            let amount = insulin.bolus?.amount ?? 0 as NSDecimalNumber
            let bolusDate = insulin.timestamp ?? Date()

            if amount != 0, let glucose = MainChartHelper.timeToNearestGlucose(
                glucoseValues: glucoseData,
                time: bolusDate.timeIntervalSince1970
            )?.glucose {
                let yPosition = (units == .mgdL ? Decimal(glucose) : Decimal(glucose).asMmolL) + MainChartHelper
                    .bolusOffset(units: units)
                let size = (MainChartHelper.Config.bolusSize + CGFloat(truncating: amount) * MainChartHelper.Config.bolusScale)

                PointMark(
                    x: .value("Time", bolusDate, unit: .second),
                    y: .value("Value", yPosition)
                )
                .symbol {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: size)).foregroundStyle(Color.insulin)
                }
                .annotation(position: .top) {
                    if shouldDisplayLabel(for: amount as Decimal) {
                        Text(Formatter.bolusFormatter.string(from: amount) ?? "")
                            .font(.caption2)
                            .foregroundStyle(Color.primary)
                    }
                }
            }
        }
    }

    private func shouldDisplayLabel(for amount: Decimal) -> Bool {
        switch bolusDisplayThreshold {
        case .aboveAverageSMBFactor:
            guard let smbAverageThreshold else {
                return true
            }
            return amount > smbAverageThreshold
        default:
            return amount >= bolusDisplayThreshold.rawValue
        }
    }
}
