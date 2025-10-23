import Charts
import SwiftUI
import Swinject

extension ISFEditor {
    struct RootView: BaseView {
        let resolver: Resolver
        @State var state = StateModel()
        @State private var refreshUI = UUID()
        @State private var now = Date()
        @Namespace private var bottomID

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private var numberFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = state.units == .mmolL ? 1 : 0
            return formatter
        }

        var saveButton: some View {
            ZStack {
                let shouldDisableButton = state.items.isEmpty || !state.hasChanges

                Rectangle()
                    .frame(width: UIScreen.main.bounds.width, height: 65)
                    .foregroundStyle(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color.white)
                    .background(.thinMaterial)
                    .opacity(0.8)
                    .clipShape(Rectangle())

                Group {
                    HStack {
                        HStack {
                            if state.shouldDisplaySaving {
                                ProgressView().padding(.trailing, 10)
                            }

                            Button {
                                let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
                                impactHeavy.impactOccurred()
                                state.save()

                                // deactivate saving display after 1.25 seconds
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
                                    state.shouldDisplaySaving = false
                                }
                            } label: {
                                HStack {
                                    if state.shouldDisplaySaving {
                                        ProgressView().padding(.trailing, 10)
                                    }
                                    Text(state.shouldDisplaySaving ? "Saving..." : "Save")
                                }
                                .frame(width: UIScreen.main.bounds.width * 0.9, alignment: .center)
                                .padding(10)
                            }
                        }
                        .frame(width: UIScreen.main.bounds.width * 0.9, alignment: .center)
                        .disabled(shouldDisableButton)
                        .background(shouldDisableButton ? Color(.systemGray4) : Color(.systemBlue))
                        .tint(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(5)
            }
        }

        var body: some View {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack {
                            VStack(alignment: .leading, spacing: 0) {
                                // Chart visualization
                                if !state.items.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack {
                                                Image(systemName: "drop.fill")
                                                    .font(.title2)
                                                    .foregroundStyle(.cyan)
                                                Text("Insulin Sensitivities")
                                                    .font(.headline)
                                                Spacer()
                                            }

                                            Text(
                                                "Your insulin sensitivity factor (ISF) indicates how much one unit of insulin will lower your blood glucose. This helps calculate correction boluses."
                                            )
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal)
                                        .padding(.top)

                                        isfChart
                                            .frame(height: 180)
                                            .padding(.horizontal)
                                            .padding(.bottom)
                                    }
                                    .background(Color.chart.opacity(0.65))
                                    .clipShape(
                                        .rect(
                                            topLeadingRadius: 10,
                                            bottomLeadingRadius: 0,
                                            bottomTrailingRadius: 0,
                                            topTrailingRadius: 10
                                        )
                                    )
                                    .padding(.horizontal)
                                    .padding(.top)
                                }

                                // ISF list
                                TherapySettingEditorView(
                                    items: $state.therapyItems,
                                    unit: state.units == .mgdL ? .mgdLPerUnit : .mmolLPerUnit,
                                    timeOptions: state.timeValues,
                                    valueOptions: state.rateValues,
                                    validateOnDelete: state.validate,
                                    onItemAdded: {
                                        withAnimation {
                                            proxy.scrollTo(bottomID, anchor: .bottom)
                                        }
                                    }
                                )
                                .padding(.horizontal)

                                // Example calculation based on first ISF
                                if !state.items.isEmpty {
                                    Spacer(minLength: 20)

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Example Calculation")
                                            .font(.headline)
                                            .padding(.horizontal)

                                        VStack(alignment: .leading, spacing: 8) {
                                            let aboveTarget = state.units == .mgdL ? Decimal(40) : 40.asMmolL
                                            let firstIsfRate: Decimal = state.rateValues[state.items.first?.rateIndex ?? 0]
                                            let isfValue = state.units == .mgdL ? firstIsfRate : firstIsfRate.asMmolL
                                            let insulinNeeded = aboveTarget / isfValue

                                            Text(
                                                "If you are \(numberFormatter.string(from: aboveTarget as NSNumber) ?? "--") \(state.units.rawValue) above target:"
                                            )
                                            .font(.subheadline)
                                            .padding(.horizontal)

                                            Text(
                                                "\(aboveTarget.description) \(state.units.rawValue) / \(isfValue.description) \(state.units.rawValue)/\(String(localized: "U", comment: "Insulin unit abbreviation")) = \(String(format: "%.1f", Double(insulinNeeded))) \(String(localized: "U", comment: "Insulin unit abbreviation"))"
                                            )
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(.cyan)
                                            .padding()
                                            .frame(maxWidth: .infinity, alignment: .center)
                                            .background(Color.chart.opacity(0.65))
                                            .cornerRadius(10)
                                        }
                                    }

                                    Spacer(minLength: 20)

                                    // Information about ISF
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("What This Means")
                                            .font(.headline)
                                            .padding(.horizontal)

                                        VStack(alignment: .leading, spacing: 4) {
                                            let isfValue = "\(state.units == .mgdL ? Decimal(50) : 50.asMmolL)"
                                            Text(
                                                "• An ISF of \(isfValue) \(state.units.rawValue)/U means 1 U lowers your glucose by \(isfValue) \(state.units.rawValue)"
                                            )
                                            Text("• A lower number means you're less sensitive (more resistant) to insulin")
                                            Text("• A higher number means you're more sensitive (less resistant) to insulin")
                                        }
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)
                                    }
                                    .id(bottomID)
                                }
                            }
                        }
                    }

                    saveButton
                }
                .background(appState.trioBackgroundColor(for: colorScheme))
                .onAppear(perform: configureView)
                .navigationTitle("Insulin Sensitivities")
                .navigationBarTitleDisplayMode(.automatic)
                .onAppear {
                    state.validate()
                    state.therapyItems = state.getTherapyItems()
                }
                .onChange(of: state.therapyItems) { _, newItems in
                    state.updateFromTherapyItems(newItems)
                    refreshUI = UUID()
                }
            }
        }

        // Chart for visualizing ISF profile
        private var isfChart: some View {
            Chart {
                ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                    let displayValue = state.rateValues[item.rateIndex]

                    let startDate = Calendar.current
                        .startOfDay(for: now)
                        .addingTimeInterval(state.timeValues[item.timeIndex])

                    var offset: TimeInterval {
                        if state.items.count > index + 1 {
                            return state.timeValues[state.items[index + 1].timeIndex]
                        } else {
                            return state.timeValues.last! + 30 * 60
                        }
                    }

                    let endDate = Calendar.current.startOfDay(for: now).addingTimeInterval(offset)

                    RectangleMark(
                        xStart: .value("start", startDate),
                        xEnd: .value("end", endDate),
                        yStart: .value("rate-start", displayValue),
                        yEnd: .value("rate-end", 0)
                    ).foregroundStyle(
                        .linearGradient(
                            colors: [
                                Color.cyan.opacity(0.6),
                                Color.cyan.opacity(0.1)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    ).alignsMarkStylesWithPlotArea()

                    LineMark(x: .value("End Date", startDate), y: .value("ISF", displayValue))
                        .lineStyle(.init(lineWidth: 1)).foregroundStyle(Color.cyan)

                    LineMark(x: .value("Start Date", endDate), y: .value("ISF", displayValue))
                        .lineStyle(.init(lineWidth: 1)).foregroundStyle(Color.cyan)
                }
            }
            .id(refreshUI) // Force chart update
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel(format: .dateTime.hour())
                    AxisGridLine(centered: true, stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                }
            }
            .chartXScale(
                domain: Calendar.current.startOfDay(for: now) ... Calendar.current.startOfDay(for: now)
                    .addingTimeInterval(60 * 60 * 24)
            )
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel()
                    AxisGridLine(centered: true, stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                }
            }
        }
    }
}
