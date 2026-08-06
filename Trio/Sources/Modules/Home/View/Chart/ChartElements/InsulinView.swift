import Charts
import Foundation
import SwiftUI

struct InsulinView: ChartContent {
    let glucoseData: [GlucoseStored]
    let insulinData: [PumpEventStored]
    let units: GlucoseUnits
    let bolusDisplayThreshold: BolusDisplayThreshold
    /// Average SMB × multiplier, pre-computed by the state model whenever pump history or the
    /// setting changes. `nil` means no cutoff applies, so every label shows.
    let smbBolusDisplayCutoff: Decimal?

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

                let mark = PointMark(
                    x: .value("Time", bolusDate, unit: .second),
                    y: .value("Value", yPosition)
                )
                .symbol(TreatmentTriangleSymbol(pointsDown: true))
                // `size` was an SF Symbol point size; as a bounding box it keeps the same
                // amount-driven growth the Image had.
                .symbolSize(CGSize(width: size, height: size))
                .foregroundStyle(Color.insulin)

                // The annotation is attached only when the label actually shows. Attaching
                // it unconditionally with empty content still builds an annotation container
                // per bolus — with SMBs every few minutes that is hundreds of them per
                // canvas re-layout, most of them drawing nothing.
                if shouldDisplayLabel(for: amount as Decimal) {
                    mark.annotation(position: .top) {
                        Text(Formatter.bolusFormatter.string(from: amount) ?? "")
                            .font(.caption2)
                            .foregroundStyle(Color.primary)
                    }
                } else {
                    mark
                }
            }
        }
    }

    /// Pure comparison — no scanning, no Core Data access beyond the mark's own amount.
    private func shouldDisplayLabel(for amount: Decimal) -> Bool {
        switch bolusDisplayThreshold {
        case .aboveAverageSMBFactor:
            guard let smbBolusDisplayCutoff else {
                return true
            }
            return amount > smbBolusDisplayCutoff
        default:
            return amount >= bolusDisplayThreshold.rawValue
        }
    }
}
