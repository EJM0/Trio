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
      Section(
        header: Text("Connect to Scale"),
        content: {
          HStack {
            TextField("IP Address", text: $state.scaleIP)
              .disableAutocorrection(true)
              .autocapitalization(.none)
              .keyboardType(.numbersAndPunctuation)
            if state.scaleIP.isEmpty {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            }
          }
        }
      ).listRowBackground(Color.chart)

      Section(header: Text("Actions")) {
        Button {
          state.tareScale()
        } label: {
          Label("Tare Scale", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.plain)
        .disabled(state.scaleIP.isEmpty)

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
          .disabled(state.scaleIP.isEmpty)
          .padding(.top, 5)
        }
      }
      .listRowBackground(Color.chart)
    }
    .listSectionSpacing(sectionSpacing)
    .navigationTitle("Scale Settings")
    .navigationBarTitleDisplayMode(.automatic)
    .scrollContentBackground(.hidden)
    .background(appState.trioBackgroundColor(for: colorScheme))
    .onAppear {
      calibrationWeightString = formatter.string(from: state.calibrationWeight as NSNumber) ?? ""
    }
    .onChange(of: calibrationWeightString) { newValue in
      if let val = formatter.number(from: newValue) {
        state.calibrationWeight = val.decimalValue
      }
    }
  }
}
