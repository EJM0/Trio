import CoreData
import SwiftDate
import SwiftUI

struct GlucoseSectorChart: View {
    let highLimit: Decimal
    let units: GlucoseUnits
    let glucose: [GlucoseStored]
    let timeInRangeType: TimeInRangeType
    let showChart: Bool

    @State private var selectedRange: GlucoseRange?

    /// Represents the different ranges of glucose values that can be displayed in the sector chart
    /// - high: Above target range
    /// - inRange: Within target range
    /// - low: Below target range
    private enum GlucoseRange: String {
        case high = "High"
        case inRange = "In Range"
        case low = "Low"
    }

    var body: some View {
        if glucose.isEmpty {
            Text("No glucose readings found.")
        } else if showChart {
            rangeBarLayout
        } else {
            detailedColumns
        }
    }

    // MARK: - Distribution

    /// Every count the layouts need, from a single walk of the readings. These were ten
    /// separate `filter` calls over the same array, each one re-run on every body evaluation.
    private struct Distribution {
        var total = 0
        var veryLow = 0
        var moderatelyLow = 0
        var below70 = 0
        var belowThreshold = 0
        var tight = 0
        var normal = 0
        var high = 0
        var moderatelyHigh = 0
        var veryHigh = 0
        var values: [Int] = []
    }

    private var distribution: Distribution {
        var result = Distribution()
        result.values.reserveCapacity(glucose.count)
        let highThreshold = Int(highLimit)
        let bottom = timeInRangeType.bottomThreshold
        let top = timeInRangeType.topThreshold

        for reading in glucose {
            let value = Int(reading.glucose)
            result.values.append(value)
            if value < 54 { result.veryLow += 1 }
            if value < 63 { result.moderatelyLow += 1 }
            if value < 70 { result.below70 += 1 }
            if value < bottom { result.belowThreshold += 1 }
            if value >= bottom, value <= top { result.tight += 1 }
            if value >= bottom, value <= highThreshold { result.normal += 1 }
            if value > highThreshold { result.high += 1 }
            if value > 220 { result.moderatelyHigh += 1 }
            if value > 250 { result.veryHigh += 1 }
        }
        result.total = glucose.count
        return result
    }

    private func share(_ count: Int, of total: Int) -> Decimal {
        total > 0 ? Decimal(count) / Decimal(total) * 100 : 0
    }

    // MARK: - Range bar

    /// One label row. Scaled rather than fixed so the rows still fit their text at larger
    /// content sizes — and so the card's height comes from this number alone, never from
    /// which glyphs a percentage happens to contain.
    @ScaledMetric(relativeTo: .body) private var labelRowHeight: CGFloat = 25

    /// A fixed column for the percentages. Without it, 9,9 % turning into 10,1 % widens the
    /// text and shunts every descriptor sideways on each new reading.
    @ScaledMetric(relativeTo: .body) private var percentColumnWidth: CGFloat = 64

    /// The boxed in-range sum gets its own narrow column beside the bar.
    /// The bar is exactly as tall as the four label rows beside it, so the two read as one
    /// block and neither can push the card taller than the other. At the default content
    /// size that is the 100pt the donut occupied. The labels sit in the bar's own order
    /// rather than pinned to their segments: a 1 % segment is thinner than its own text.
    private var barHeight: CGFloat { labelRowHeight * 4 }

    /// The four stacked shares, top to bottom. They are mutually exclusive and sum to 100,
    /// so every label beside the bar names a contiguous block of it: the teal and green
    /// segments together are the in-range figure, green alone is the tight range.
    @ViewBuilder private var rangeBarLayout: some View {
        let stats = distribution
        let inRange = share(stats.normal, of: stats.total)
        let tight = share(stats.tight, of: stats.total)
        let above = share(stats.high, of: stats.total)
        let below = share(stats.belowThreshold, of: stats.total)

        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 0) {
                segment(above, .dynamicPurple, range: .high)
                segment(inRange - tight, .dynamicTeal, range: .inRange)
                segment(tight, .dynamicGreen, range: .inRange)
                segment(below, .dynamicRed, range: .low)
            }
            .frame(width: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Time in range distribution chart"))

            VStack(alignment: .leading, spacing: 0) {
                labelRow("> \(highLimit.formatted(for: units))", above, .dynamicPurple)
                labelRow(
                    "\(Decimal(timeInRangeType.bottomThreshold).formatted(for: units))-\(highLimit.formatted(for: units))",
                    inRange,
                    .dynamicTeal,
                    emphasized: true
                )
                labelRow(
                    "\(Decimal(timeInRangeType.bottomThreshold).formatted(for: units))-\(Decimal(timeInRangeType.topThreshold).formatted(for: units))",
                    tight,
                    .dynamicGreen
                )
                labelRow(
                    "< \(Decimal(timeInRangeType.bottomThreshold).formatted(for: units))",
                    below,
                    .dynamicRed
                )
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 10) {
                averageAndMedian(for: stats, longLabels: true)
            }
            .padding(.trailing, 4)
        }
        .overlay {
            if let selectedRange {
                RangeDetailPopover(data: getDetailedData(for: selectedRange))
                    .transition(.scale.combined(with: .opacity))
                    .onTapGesture { withAnimation { self.selectedRange = nil } }
            }
        }
    }

    /// ponytail: a non-zero share gets at least 3pt of bar so a handful of lows cannot
    /// disappear, which overstates tiny shares. Scale the remaining segments down to
    /// compensate if that ever reads as wrong.
    private func segmentHeight(_ share: Decimal) -> CGFloat {
        guard share > 0 else { return 0 }
        return max(3, barHeight * CGFloat(truncating: (share / 100) as NSDecimalNumber))
    }

    private func segment(_ share: Decimal, _ color: Color, range: GlucoseRange) -> some View {
        Rectangle()
            .fill(color)
            .frame(height: segmentHeight(share))
            .opacity(selectedRange == nil || selectedRange == range ? 1 : 0.35)
            .onTapGesture {
                withAnimation { selectedRange = selectedRange == range ? nil : range }
            }
    }

    private func labelRow(
        _ descriptor: String,
        _ value: Decimal,
        _ color: Color,
        emphasized: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(formatPercentage(value, tight: true))
                .font(emphasized ? .title3.weight(.semibold) : .body)
                .monospacedDigit()
                .foregroundStyle(color)
                .frame(width: percentColumnWidth, alignment: .trailing)
            Text(descriptor)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(height: labelRowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Detailed columns

    /// The layout the by-day distribution chart embeds: no bar, but every sub-range broken
    /// out. Unchanged by the bar refactor beyond being fed from the single-pass counts.
    private var detailedColumns: some View {
        let stats = distribution

        return HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                statPair(
                    "\(Decimal(timeInRangeType.bottomThreshold).formatted(for: units))-\(highLimit.formatted(for: units))",
                    share(stats.normal, of: stats.total),
                    .dynamicTeal
                )
                statPair(
                    "\(Decimal(timeInRangeType.bottomThreshold).formatted(for: units))-\(Decimal(timeInRangeType.topThreshold).formatted(for: units))",
                    share(stats.tight, of: stats.total),
                    .dynamicGreen
                )
            }.padding(.leading, 5)

            VStack(alignment: .leading, spacing: 10) {
                statPair("> \(highLimit.formatted(for: units))", share(stats.high, of: stats.total), .dynamicBlue)
                statPair("< \(Decimal(70).formatted(for: units))", share(stats.below70, of: stats.total), .dynamicOrange)
            }

            VStack(alignment: .leading, spacing: 10) {
                statPair("> \(Decimal(220).formatted(for: units))", share(stats.moderatelyHigh, of: stats.total), .dynamicBlue)
                statPair("< \(Decimal(63).formatted(for: units))", share(stats.moderatelyLow, of: stats.total), .dynamicOrange)
            }

            VStack(alignment: .leading, spacing: 10) {
                statPair("> \(Decimal(250).formatted(for: units))", share(stats.veryHigh, of: stats.total), .dynamicPurple)
                statPair("< \(Decimal(54).formatted(for: units))", share(stats.veryLow, of: stats.total), .dynamicRed)
            }

            VStack(alignment: .leading, spacing: 10) {
                averageAndMedian(for: stats, longLabels: false)
            }
        }
    }

    private func statPair(_ descriptor: String, _ value: Decimal, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(descriptor)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            Text(formatPercentage(value, tight: true))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder private func averageAndMedian(for stats: Distribution, longLabels: Bool) -> some View {
        let average = stats.total > 0 ? Decimal(stats.values.reduce(0, +)) / Decimal(stats.total) : 0
        // `medianCalculation` returns a Double; the average is a Decimal. One type for both.
        let median = Decimal(StatChartUtils.medianCalculation(array: stats.values))

        VStack(alignment: .leading, spacing: 5) {
            (longLabels ? Text("Average") : Text("Avg")).font(.subheadline).foregroundStyle(Color.secondary)
            Text(formatGlucose(average))
        }

        VStack(alignment: .leading, spacing: 5) {
            (longLabels ? Text("Median") : Text("Med")).font(.subheadline).foregroundStyle(Color.secondary)
            Text(formatGlucose(median))
        }
    }

    private func formatGlucose(_ value: Decimal) -> String {
        units == .mgdL
            ? value.formatted(.number.grouping(.never).rounded().precision(.fractionLength(0)))
            : value.asMmolL.formatted(.number.grouping(.never).rounded().precision(.fractionLength(1)))
    }

    /// Gets detailed statistics for a specific glucose range category
    ///
    /// This function calculates detailed statistics for a given glucose range (high, in-range, or low),
    /// breaking down the readings into subcategories and calculating percentages.
    ///
    /// - Parameter range: The glucose range category to analyze
    /// - Returns: A RangeDetail object containing the title, color and detailed statistics
    private func getDetailedData(for range: GlucoseRange) -> RangeDetail {
        let total = Decimal(glucose.count)

        switch range {
        case .high:
            let veryHigh = glucose.filter { $0.glucose > 250 }.count
            let high = glucose.filter { $0.glucose > Int(highLimit) && $0.glucose <= 250 }.count

            let highGlucoseValues = glucose.filter { $0.glucose > Int(highLimit) }
            let highGlucoseValuesAsInt = highGlucoseValues.map { Int($0.glucose) }
            let (average, median, standardDeviation) = calculateDetailedStatistics(for: highGlucoseValuesAsInt)

            return RangeDetail(
                title: String(localized: "High Glucose"),
                color: .dynamicPurple,
                items: [
                    (
                        String(localized: "Very High (>\(Decimal(250).formatted(for: units)))"),
                        formatPercentage(Decimal(veryHigh) / total * 100)
                    ),
                    (
                        String(localized: "High (\(highLimit.formatted(for: units))-\(Decimal(250).formatted(for: units)))"),
                        formatPercentage(Decimal(high) / total * 100)
                    ),
                    (String(localized: "Average"), average.formatted(for: units)),
                    (String(localized: "Median"), median.formatted(for: units)),
                    (String(localized: "SD"), formatSD(standardDeviation))
                ]
            )

        case .inRange:
            let tight = glucose
                .filter { $0.glucose >= Int(timeInRangeType.bottomThreshold) && $0.glucose <= timeInRangeType.topThreshold }.count
            let glucoseValues = glucose.filter { $0.glucose >= timeInRangeType.bottomThreshold && $0.glucose <= Int(highLimit) }
            let glucoseValuesAsInt = glucoseValues.map { Int($0.glucose) }
            let (average, median, standardDeviation) = calculateDetailedStatistics(for: glucoseValuesAsInt)

            return RangeDetail(
                title: String(localized: "In Range"),
                color: .dynamicGreen,
                items: [
                    (
                        String(
                            localized: "Normal (\(Decimal(timeInRangeType.bottomThreshold).formatted(for: units))-\(highLimit.formatted(for: units)))"
                        ),
                        formatPercentage(Decimal(glucoseValues.count) / total * 100)
                    ),
                    (
                        String(
                            localized: "\(timeInRangeType == .timeInTightRange ? "TITR" : "TING") (\(Decimal(timeInRangeType.bottomThreshold).formatted(for: units))-\(Decimal(timeInRangeType.topThreshold).formatted(for: units)))"
                        ),
                        formatPercentage(Decimal(tight) / total * 100)
                    ),
                    (String(localized: "Average"), average.formatted(for: units)),
                    (String(localized: "Median"), median.formatted(for: units)),
                    (String(localized: "SD"), formatSD(standardDeviation))
                ]
            )

        case .low:
            let veryLow = glucose.filter { $0.glucose <= 54 }.count
            let low = glucose.filter { $0.glucose > 54 && $0.glucose < timeInRangeType.bottomThreshold }.count

            let lowGlucoseValues = glucose.filter { $0.glucose < timeInRangeType.bottomThreshold }
            let lowGlucoseValuesAsInt = lowGlucoseValues.map { Int($0.glucose) }
            let (average, median, standardDeviation) = calculateDetailedStatistics(for: lowGlucoseValuesAsInt)

            return RangeDetail(
                title: String(localized: "Low Glucose"),
                color: .dynamicRed,
                items: [
                    (
                        String(
                            localized: "Low (\(Decimal(54).formatted(for: units))-\(Decimal(timeInRangeType.bottomThreshold).formatted(for: units)))"
                        ),
                        formatPercentage(Decimal(low) / total * 100)
                    ),
                    (
                        String(localized: "Very Low (<\(Decimal(54).formatted(for: units)))"),
                        formatPercentage(Decimal(veryLow) / total * 100)
                    ),
                    (String(localized: "Average"), average.formatted(for: units)),
                    (String(localized: "Median"), median.formatted(for: units)),
                    (String(localized: "SD"), formatSD(standardDeviation))
                ]
            )
        }
    }

    /// Formats a percentage value to a string with one decimal place.
    /// - Parameter value: A decimal value representing the percentage.
    /// - Returns: A formatted percentage string
    private func formatPercentage(_ value: Decimal, tight: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = value == 100 ? 0 : 1
        formatter.maximumFractionDigits = value == 100 ? 0 : 1
        if tight {
            formatter.positiveSuffix = "%"
        }
        return formatter.string(from: NSDecimalNumber(decimal: value / 100)) ?? "0%"
    }

    /// Calculates statistical values for a given array of glucose readings.
    /// - Parameter values: An array of glucose readings as integers.
    /// - Returns: A tuple containing the average, median, and standard deviation.
    private func calculateDetailedStatistics(for values: [Int]) -> (Decimal, Decimal, Double) {
        guard !values.isEmpty else { return (0, 0, 0) }

        let total = values.reduce(0, +)
        let average = Decimal(total / values.count)
        let median = Decimal(StatChartUtils.medianCalculation(array: values))

        let sumOfSquares = values.reduce(0.0) { sum, value in
            sum + pow(Double(value) - Double(average), 2)
        }

        let standardDeviation = sqrt(sumOfSquares / Double(values.count))
        return (average, median, standardDeviation)
    }

    /// Formats the standard deviation value based on glucose units.
    /// - Parameter sd: The standard deviation as a Double.
    /// - Returns: A formatted string representing the standard deviation.
    private func formatSD(_ sd: Double) -> String {
        units == .mgdL ? sd.formatted(
            .number.grouping(.never).rounded().precision(.fractionLength(0))
        ) : sd.formattedAsMmolL
    }
}

/// Represents details about a specific glucose range category including title, color and percentage breakdowns
private struct RangeDetail {
    /// The title of this range category (e.g. "High Glucose", "In Range", "Low Glucose")
    let title: String
    /// The color used to represent this range in the UI
    let color: Color
    /// Array of tuples containing label and percentage for each sub-range
    let items: [(label: String, value: String)]
}

/// A popover view that displays detailed breakdown of glucose percentages for a range category
private struct RangeDetailPopover: View {
    let data: RangeDetail

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(data.title)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(data.color)
                .padding(.bottom, 4)

            ForEach(Array(data.items.enumerated()), id: \..offset) { index, item in
                if index < 2 {
                    HStack {
                        Text(item.label)
                        Text(item.value).bold()
                    }
                    .font(.footnote)
                }
            }

            HStack(spacing: 20) {
                ForEach(Array(data.items.enumerated()), id: \..offset) { index, item in
                    if index > 1 {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.label)
                            HStack {
                                Text(item.value).bold()
                            }
                        }
                        .font(.footnote)
                    }
                }
            }
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(colorScheme == .dark ? Color.bgDarkBlue.opacity(0.9) : Color.white.opacity(0.95))
                .shadow(color: Color.secondary, radius: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(data.color, lineWidth: 2)
                )
        }
    }
}
