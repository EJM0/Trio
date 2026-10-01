import SwiftUI

struct ScaleSettingsView: View {
    @ObservedObject var state: BolusCalculatorConfig.StateModel
    @State private var calibrationWeightString = ""
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    var body: some View {
        List {
            if state.scaleID.isEmpty {
                Section(
                    header: Text("Pair a Scale"),
                    footer: Text("Closest scale first. Each scale shows its code on its display when switched on.")
                ) {
                    if state.scaleCandidates.isEmpty {
                        HStack {
                            Text("Searching…")
                            Spacer()
                            ProgressView()
                        }
                    }
                    ForEach(state.scaleCandidates) { candidate in
                        Button {
                            state.pairScale(candidate)
                        } label: {
                            Label(candidate.name, systemImage: "scalemass")
                        }
                    }
                }
                .listRowBackground(Color.chart)
            } else {
                Section(header: Text("Paired Scale")) {
                    Label(state.scaleName, systemImage: "scalemass")
                    Button("Forget Scale", role: .destructive) {
                        state.forgetScale()
                    }
                }
                .listRowBackground(Color.chart)
            }

            Section(header: Text("Actions")) {
                Button {
                    state.tareScale()
                } label: {
                    Label("Tare Scale", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                .disabled(state.scaleID.isEmpty)

                VStack(alignment: .leading) {
                    HStack {
                        Text("Calibration Weight (g)")
                        Spacer()
                        TextField("Weight", text: $calibrationWeightString)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .frame(maxWidth: 100)
                    }
                    Button {
                        state.calibrateScale()
                    } label: {
                        Label("Calibrate", systemImage: "scalemass")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.scaleID.isEmpty)
                    .padding(.top, 5)
                }
            }
            .listRowBackground(Color.chart)
        }
        .listSectionSpacing(sectionSpacing)
        .navigationTitle("Scale Settings")
        .navigationBarTitleDisplayMode(.automatic)
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
        .onAppear {
            state.startScaleScan()
            calibrationWeightString = formatter.string(from: state.calibrationWeight as NSNumber) ?? ""
        }
        .onDisappear {
            state.stopScaleScan()
        }
        .onChange(of: calibrationWeightString) { newValue in
            if let val = formatter.number(from: newValue) {
                state.calibrationWeight = val.decimalValue
            }
        }
    }
}
