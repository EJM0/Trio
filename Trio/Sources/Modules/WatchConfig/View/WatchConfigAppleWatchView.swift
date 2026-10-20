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

    var body: some View {
        List {
            // what the watch shows
            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.showForecastWatch,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Show Forecast on Watch")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Show Forecast on Watch"),
                miniHint: String(localized: "Shows forecast on the Apple Watch"),
                verboseHint: Text(
                    "Enable this feature to show the forecast on the Apple Watch"
                ),
                headerText: String(localized: "Display")
            )

            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.showGlucoseBubbleWatch,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Show Glucose Bubble on Watch")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Show Glucose Bubble on Watch"),
                miniHint: String(localized: "Shows the page with only the glucose bubble on the Apple Watch"),
                verboseHint: Text(
                    "Turn this off to drop the page that shows only the large glucose bubble. The combined page with the bubble and the chart stays."
                ),
                headerText: nil
            )

            // treatments from the wrist
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
                headerText: String(localized: "Treatments")
            )

            // the watch's own link to the G7, with or without untethered mode
            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.watchSensorAlwaysOn,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Watch Reads the Sensor")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Watch Reads the Sensor"),
                miniHint: String(
                    localized: "The watch connects to the Dexcom G7 itself. Turn off on older watches to save battery: the watch then shows only the iPhone's glucose."
                ),
                verboseHint: VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "When this is on, the watch keeps its own link to your Dexcom G7, in the sensor's slot for a watch, next to the iPhone's. Glucose on the watch and on its complication stays current when the iPhone is out of reach or its app is asleep. The link costs some watch battery."
                    )
                    Text("When this is off, the watch reads the sensor only during untethered mode. Until then:")
                    Text(
                        "• Glucose on the watch and on the complication comes only from the iPhone, and stops while the iPhone is away."
                    )
                    Text(
                        "• The complication updates far less often: watchOS redraws it in the background only while the app holds a Bluetooth link, otherwise about every half hour at most."
                    )
                    Text(
                        "• Untethered mode starts without readings: the watch first has to find the sensor, and pair with a new one."
                    )
                },
                headerText: String(localized: "Sensor")
            )

            // the watch running the loop: the switch, then what it allows and the session itself
            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.untetheredModeWatch,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Untethered Mode")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Untethered Mode"),
                miniHint: String(localized: "Let the watch run the loop with its own pump and CGM connection"),
                verboseHint: Text(
                    "When this is off, neither the iPhone nor the watch starts untethered mode, the watch hides its status page and the iPhone stops sending it the copy to start without it. A session still running hands back."
                ),
                headerText: String(localized: "Untethered Mode")
            )

            if state.untetheredModeWatch {
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.allowUntetheredStartWithoutPhoneWatch,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Allow Start Without iPhone")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Allow Start Without iPhone"),
                    miniHint: String(localized: "Let the watch start untethered mode while the iPhone is unavailable"),
                    verboseHint: Text(
                        "When this is off, the watch hides Start Without Phone and won't take over from a saved grant while the iPhone is unavailable."
                    ),
                    headerText: nil
                )

                // starts by itself when the iPhone's readings stop; needs the watch's own sensor link
                if state.allowUntetheredStartWithoutPhoneWatch, state.watchSensorAlwaysOn {
                    SettingInputSection(
                        decimalValue: $decimalPlaceholder,
                        booleanValue: $state.fallbackLoopWatch,
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
                        miniHint: String(localized: "The watch loops on its own when the iPhone's readings stop"),
                        verboseHint: Text(
                            "When two readings reach the watch through its own sensor link but not from the iPhone, and the iPhone is out of reach, the watch waits 10 seconds for it and then starts untethered mode from the saved grant. Once the iPhone is back, the watch hands the pump back. One of them uses the pod at a time: once the watch has it, the iPhone stops dosing until the watch hands back. Needs Watch Reads the Sensor."
                        ),
                        headerText: nil
                    )
                }

                UntetheredSettingsSection(manager: resolver.resolve(UntetheredPhoneManager.self)!)
            }

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
