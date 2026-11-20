import SwiftUI
import Swinject

struct WatchConfigAppleWatchView: BaseView {
    let resolver: Resolver
    @ObservedObject var state: WatchConfig.StateModel

    @State private var shouldDisplayHint: Bool = false
    @State var hintDetent = PresentationDetent.large
    @State var selectedVerboseHint: AnyView?
    @State var hintLabel: String?
    @State private var decimalPlaceholder: Decimal = 0.0
    @State private var booleanPlaceholder: Bool = false

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private func onDelete(offsets: IndexSet) {
        state.devices.remove(atOffsets: offsets)
        state.deleteGarminDevice()
    }

    private var previewState: ComplicationState {
        ComplicationState.sample(
            units: state.units.rawValue,
            settings: ComplicationSlotSettings(
                cornerValue: state.complicationCornerValue,
                secondaryValue: state.complicationSecondaryValue
            )
        )
    }

    private func previewSlots(for kind: ComplicationKind) -> [ComplicationSlot] {
        kind.slots.filter { $0 != .inline }
    }

    var body: some View {
        List {
            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.confirmBolusFaster,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Confirm Bolus Faster")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Confirm Bolus Faster"),
                miniHint: String(localized: "Reduce the number of crown rotations required for bolus confirmation."),
                verboseHint: Text(
                    "Enabling this feature lowers the number of turns on the crown dial required when confirming a bolus."
                ),
                headerText: String(localized: "Apple Watch Configuration")
            )

            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.showForecastWatch,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Show forecast on Watch")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Show Forecast on Watch"),
                miniHint: String(localized: "Shows forecast on the Apple Watch"),
                verboseHint: Text(
                    "Enable this feature to show the forecast on the Apple Watch"
                ),
                headerText: String(localized: "Apple Watch Configuration")
            )

            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.useCriticalAlertsWatch,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Critical Alerts on Watch")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Critical Alerts on Watch"),
                miniHint: String(localized: "The watch’s urgent low alarm sounds through Silent Mode"),
                verboseHint: Text(
                    "When this is on, the urgent low alarm the watch raises for its own readings sounds even in Silent Mode. The watch asks for permission the first time."
                )
            )

            #if TRIO_ON_WATCH
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.trioOnWatchEnabled,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Trio on Watch")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Trio on Watch"),
                    miniHint: String(localized: "The watch can take over the pod and loop"),
                    verboseHint: Text(
                        "When this is on, the watch app can take over the pod: it reads the CGM, loops with Trio’s algorithm and your settings, and records what it does. The iPhone doesn’t dose until the watch hands the pod back or you take it back. Needs Read on Apple Watch in the CGM’s settings."
                    ),
                    headerText: String(localized: "Looping on the Watch")
                )

                if state.trioOnWatchEnabled {
                    SettingInputSection(
                        decimalValue: $decimalPlaceholder,
                        booleanValue: $state.trioOnWatchWithoutPhone,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: Binding(
                            get: { selectedVerboseHint },
                            set: {
                                selectedVerboseHint = $0.map { AnyView($0) }
                                hintLabel = String(localized: "Allow Without iPhone")
                            }
                        ),
                        units: state.units,
                        type: .boolean,
                        label: String(localized: "Allow Without iPhone"),
                        miniHint: String(localized: "The watch can start from the iPhone’s copy when the iPhone isn’t there"),
                        verboseHint: Text(
                            "When this is on, the iPhone leaves a copy of its settings and history with the watch after each of its loops. While the copy is younger than 15 minutes, the watch offers Start Without iPhone. Before its first loop the watch checks the pod’s insulin total and counts anything the copy doesn’t explain as a bolus. When the iPhone comes back while the watch loops, the watch keeps the pod."
                        )
                    )
                }

                // the fallback starts from the copy Allow Without iPhone leaves
                if state.trioOnWatchEnabled, state.trioOnWatchWithoutPhone {
                    SettingInputSection(
                        decimalValue: $decimalPlaceholder,
                        booleanValue: $state.trioOnWatchFallback,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: Binding(
                            get: { selectedVerboseHint },
                            set: {
                                selectedVerboseHint = $0.map { AnyView($0) }
                                hintLabel = String(localized: "Fallback Loop")
                            }
                        ),
                        units: state.units,
                        type: .boolean,
                        label: String(localized: "Fallback Loop"),
                        miniHint: String(localized: "The watch starts by itself when the iPhone has stopped looping"),
                        verboseHint: Text(
                            "When this is on, the watch starts by itself when the iPhone hasn’t looped or read the sensor for 10 minutes, doesn’t answer, and the watch has two fresh readings of its own. Noisy readings, a warming up or failed sensor never start it. It hands the pod back once the iPhone answers again with fresh readings."
                        )
                    )
                }
            #endif

            if state.cgmSharesWithWatch {
                Section(
                    header: Text("Glucose on the Watch"),
                    footer: Text(
                        String(
                            localized: "The watch reads the \(state.cgmName) itself while “Read on Apple Watch” is on in its settings. It shows the iPhone’s readings while they come, and its own, with a watch symbol in the glucose bubble, once they stop."
                        )
                    ),
                    content: {
                        HStack {
                            Text("Read on Apple Watch")
                            Spacer()
                            Text(state.watchReadsSensor ? "On" : "Off").foregroundStyle(.secondary)
                        }
                        NavigationLink(String(localized: "Change in the \(state.cgmName) Settings")) {
                            CGMSettings.RootView(
                                resolver: resolver,
                                displayClose: false,
                                bluetoothManager: resolver.resolve(BluetoothStateManager.self)!
                            )
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                ).listRowBackground(Color.chart)
            }

            Section(
                header: Text("Complication Settings"),
                footer: Text(
                    "A reading older than 5 minutes shows its time in place of the delta, and greys after 10 minutes; IOB and COB show -- when the loop has not run for 10 minutes. Corner Label is the curved text on Trio Glucose corner slots. Small Line is the text under the glucose on Trio Glucose circular slots, beside the ring on Trio Gauge rectangular slots, and the second line of Trio Chart. Trio IOB has a fixed layout."
                ),
                content: {
                    Picker("Corner Label", selection: $state.complicationCornerValue) {
                        ForEach(WatchComplicationValue.allCases) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    Picker("Small Line", selection: $state.complicationSecondaryValue) {
                        ForEach(WatchComplicationValue.allCases) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                }
            ).listRowBackground(Color.chart)

            Section(
                header: Text("Available Complications"),
                footer: Text(
                    "Previews use sample data in your units and follow the settings above. Add them from the watch face editor under Trio. Corner slots curve the label round the face."
                ),
                content: {
                    let preview = previewState
                    ForEach(ComplicationKind.allCases) { kind in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(kind.displayName).font(.headline)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(previewSlots(for: kind), id: \.self) { slot in
                                        ComplicationPreview(kind: kind, slot: slot, state: preview)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            Text(kind.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            ).listRowBackground(Color.chart)

            Section(
                header: Text("Contact Image"),
                content: {
                    VStack {
                        HStack {
                            NavigationLink("Contacts Configuration") {
                                ContactImage.RootView(resolver: resolver)
                            }.foregroundStyle(Color.accentColor)
                        }
                    }
                }
            ).listRowBackground(Color.chart)
        }
        .listSectionSpacing(sectionSpacing)
        // back from the CGM's settings
        .onAppear { state.refreshWatchSensor() }
        .sheet(isPresented: $shouldDisplayHint) {
            SettingInputHintView(
                hintDetent: $hintDetent,
                shouldDisplayHint: $shouldDisplayHint,
                hintLabel: hintLabel ?? "",
                hintText: selectedVerboseHint ?? AnyView(EmptyView()),
                sheetTitle: String(localized: "Help", comment: "Help sheet title")
            )
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.automatic)
        .settingsHighlightScroll()
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
    }
}
