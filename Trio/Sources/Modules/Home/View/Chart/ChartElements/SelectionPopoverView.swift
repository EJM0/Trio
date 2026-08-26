import Charts
import Foundation
import SwiftUI

/// The selection detail card: the readout as it looked while it floated over the glucose
/// pane, before `ChartSelectionRow` moved it into the Home meal slot.
///
/// Kept, unused, as the fallback if the meal-slot readout doesn't work out. Plain SwiftUI
/// (no longer `ChartContent`): it was rendered by the shell's selection overlay in a fixed
/// slot, so it could neither be clipped by the viewport nor force a canvas re-layout while
/// scrubbing. To revive it, drop it back into `MainChartView.selectionOverlay` and pass
/// `selectedDetermination` for both determination arguments.
struct SelectionPopoverView: View {
    let selectedGlucose: GlucoseStored
    let selectedIOBValue: OrefDetermination?
    let selectedCOBValue: OrefDetermination?
    let units: GlucoseUnits
    let highGlucose: Decimal
    let lowGlucose: Decimal
    let currentGlucoseTarget: Decimal
    let glucoseColorScheme: GlucoseColorScheme
    let isSmoothingEnabled: Bool

    private var glucoseToDisplay: Decimal {
        units == .mgdL ? Decimal(selectedGlucose.glucose) : Decimal(selectedGlucose.glucose).asMmolL
    }

    private var pointMarkColor: Color {
        selectionMarkColor(
            for: selectedGlucose,
            highGlucose: highGlucose,
            lowGlucose: lowGlucose,
            currentGlucoseTarget: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }

    @ViewBuilder var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(systemName: "clock")
                Text(selectedGlucose.date?.formatted(.dateTime.hour().minute(.twoDigits)) ?? "")
                    .font(.body).bold()
            }
            .font(.body).padding(.bottom, 2)

            HStack {
                Text("CGM: ") + Text(glucoseToDisplay.description).bold() + Text(" \(units.rawValue)")
            }
            .foregroundStyle(pointMarkColor)
            .font(.body)

            if isSmoothingEnabled, let smoothedGlucose = selectedGlucose.smoothedGlucose {
                var smoothedGlucoseToDisplay: Decimal {
                    units == .mgdL ? smoothedGlucose.decimalValue : smoothedGlucose.decimalValue.asMmolL
                }
                HStack {
                    Image(systemName: "sparkles")
                    Text(smoothedGlucoseToDisplay.description) + Text(" \(units.rawValue)")
                }.font(.body)
            }

            if let selectedIOBValue, let iob = selectedIOBValue.iob {
                HStack {
                    Image(systemName: "syringe.fill").frame(width: 15)
                    Text(Formatter.decimalFormatterWithTwoFractionDigits.string(from: iob) ?? "")
                        .bold()
                        + Text(String(localized: " U", comment: "Insulin unit"))
                }
                .foregroundStyle(Color.insulin).font(.body)
            }

            if let selectedCOBValue {
                HStack {
                    Image(systemName: "fork.knife").frame(width: 15)
                    Text(Formatter.integerFormatter.string(from: selectedCOBValue.cob as NSNumber) ?? "")
                        .bold()
                        + Text(String(localized: " g", comment: "gram of carbs"))
                }
                .foregroundStyle(Color.orange).font(.body)
            }

            if let selectedIOBValue, let isf = selectedIOBValue.insulinSensitivity {
                HStack {
                    Image(systemName: "arrow.up.arrow.down").frame(width: 15)
                    Text(Formatter.integerFormatter.string(from: isf) ?? "")
                        .bold()
                        + Text(String(localized: " ISF", comment: "Insulin Sensitivity Factor"))
                }
                .foregroundStyle(Color.white).font(.body)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.chart.opacity(0.85))
                .shadow(color: Color.secondary, radius: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary, lineWidth: 2)
                )
        }
    }
}
