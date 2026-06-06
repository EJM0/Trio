import Charts
import Foundation
import SwiftUI

struct CombinedGlucoseChartview: View {
    let state: WatchState
    let rotationDegrees: Double
    let isWatchStateDated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: left box | chart top (6h label + y-axis top) | right box
            // The chart occupies full width here — the 6h label and 300 marker sit in this zone
            // This row is handled by the chart itself via chartYAxisLabel + top axis marks
            // We just give the chart its full container and let it render top labels in this band

            // Main content: circle bottom-left, chart fills right
            HStack(alignment: .bottom, spacing: 4) {
                // Left: circle + time/delta below
                VStack(alignment: .center, spacing: 2) {
                    Spacer()

                    MinimizedGlucoseTrendView(
                        state: state,
                        rotationDegrees: rotationDegrees,
                        isWatchStateDated: isWatchStateDated
                    )
                    .scaleEffect(0.55, anchor: .center)
                    .frame(width: 55, height: 55)

                    VStack(alignment: .center, spacing: -2) {
                        Text(state.lastLoopTime ?? "--")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        if let delta = state.delta {
                            Text(isWatchStateDated ? "--" : delta)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 2)

                // Right: chart fills remaining space, top label + plot + bottom
                MinimizedGlucoseChartView(
                    glucoseValues: state.glucoseValues,
                    minYAxisValue: state.minYAxisValue,
                    maxYAxisValue: state.maxYAxisValue
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .offset(y: -8)
        .padding(.bottom, -8)
    }
}
