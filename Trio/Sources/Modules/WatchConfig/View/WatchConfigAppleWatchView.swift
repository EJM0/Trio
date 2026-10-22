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
                headerText: String(localized: "Display")
            )

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
                    "When this is off, neither the iPhone nor the watch starts untethered mode, the watch hides its status page and the iPhone sends it no copy to start without it. A session still running hands back."
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
                        "For when you leave without starting untethered mode. While this is on, the phone keeps a copy of your settings, carbs and doses on the watch, renewed at least every 30 minutes. With the iPhone out of reach, and that copy younger than your insulin's action time, the watch offers Start Without Phone on its untethered page; it never starts by itself. The watch first books insulin the pod delivered that the copy doesn't know of, and the phone stops dosing as soon as it hears from the watch. When this is off, the phone sends no copy and the watch hides the button."
                    ),
                    headerText: nil
                )

                if state.allowUntetheredStartWithoutPhoneWatch {
                    SettingInputSection(
                        decimalValue: $decimalPlaceholder,
                        booleanValue: $state.fallbackLoopWatch,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: Binding(
                            get: { selectedVerboseHint },
                            set: {
                                selectedVerboseHint = $0.map { AnyView($0) }
                                hintLabel = String(localized: "Start by Itself When iPhone Stops")
                            }
                        ),
                        units: state.units,
                        type: .boolean,
                        label: String(localized: "Start by Itself When iPhone Stops"),
                        miniHint: String(localized: "The watch takes over the loop when the iPhone is gone"),
                        verboseHint: Text(
                            "Needs the Watch sensor switch on the watch (its own G7 reading). When the iPhone is out of reach and its newest reading is 11 minutes old, while the watch has read two of its own, the watch starts untethered mode by itself from the iPhone's copy, as Start Without Phone does, once per outage. When the iPhone is back in reach for a minute, the watch hands the pump back by itself. Idea and design by Elias Maurer."
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
