import CoreData
import SpriteKit
import SwiftDate
import SwiftUI
import Swinject

extension Home {
    struct RootView: BaseView {
        let resolver: Resolver

        @Environment(\.managedObjectContext) var moc
        @Environment(\.colorScheme) var colorScheme
        @Environment(\.verticalSizeClass) var verticalSizeClass
        @Environment(\.layoutDirection) var layoutDirection
        @Environment(AppState.self) var appState

        @State var state = StateModel()

        @State var settingsPath = NavigationPath()
        @State var settingsSearchHighlight = SettingsSearchHighlight()
        @State var isStatusPopupPresented = false
        @State var showCancelAlert = false
        @State var showCancelConfirmDialog = false
        @State var isConfirmStopOverrideShown = false
        @State var isConfirmStopOverridePresented = false
        @State var isConfirmStopTempTargetShown = false
        @State var isMenuPresented = false
        @State var showTreatments = false
        @State var selectedTab: Int = 0
        static let treatmentTabTag = 4
        @State var showQuickPickTreatmentsPicker = false
        @State var showQuickPickTreatmentsNoHistory = false
        @State var showPumpSelection: Bool = false
        @State var showCGMSelection: Bool = false
        @State var pendingPump: PumpCatalogEntry?
        @State var pendingCGM: CGMCatalogEntry?
        @State var showSnoozeSheet: Bool = false
        @State var showManualGlucose: Bool = false
        @State var showReleaseNotes: Bool = false
        @State var alarmsSnoozeUntil: Date = .distantPast
        @ObservedObject var releaseNotesService = ReleaseNotesService.shared
        // Pull-down-to-force-loop (see HomeRootView+Refresh.swift)
        @State var pullOffset: CGFloat = 0
        @State var isRefreshArmed = false
        @State var isForcingLoop = false
        @State var notificationsDisabled = false
        /// Date under the finger while the main chart is being scrubbed, else nil. Owned
        /// here because the readout lives in the meal slot, outside the chart.
        @State var chartSelection: Date? = nil
        /// Last scrub position that resolved to a glucose reading / to a determination. The
        /// readout renders from these, not from `chartSelection`, so holes in either series
        /// decay instead of flickering the slot (see `updateChartReadout`).
        @State var chartReadoutDate: Date? = nil
        @State var chartReadoutDeterminationDate: Date? = nil
        /// Where the display cutout sits, and how wide it is. Re-read on every rotation
        /// (see `HousingInsetsReader`); zero in portrait.
        @State var housingInsets = HousingInsets()

        @FetchRequest(fetchRequest: OverrideStored.fetch(
            NSPredicate.lastActiveOverride,
            ascending: false,
            fetchLimit: 1
        )) var latestOverride: FetchedResults<OverrideStored>

        @FetchRequest(fetchRequest: TempTargetStored.fetch(
            NSPredicate.lastActiveTempTarget,
            ascending: false,
            fetchLimit: 1
        )) var latestTempTarget: FetchedResults<TempTargetStored>

        /// iPhone held sideways. A compact height is the phone-landscape signal specifically:
        /// iPad stays regular in both orientations, so it keeps the full dashboard.
        ///
        /// Gates the whole landscape treatment — chart-only layout, no tab bar, no treatment
        /// button (see `HomeRootView+Landscape`).
        var isLandscapeChart: Bool { verticalSizeClass == .compact }

        var historySFSymbol: String {
            if #available(iOS 17.0, *) {
                return "book.pages"
            } else {
                return "book"
            }
        }

        @ViewBuilder func mainChart(geo: GeometryProxy) -> some View {
            // the chart is the only flexible zone: it takes what the fixed slots leave over
            let chartHeight = max(
                geo.size.height - HomeLayout.headerHeight - HomeLayout.mealSlotHeight - HomeLayout.bottomZoneHeight,
                HomeLayout.chartMinHeight
            )
            ZStack {
                MainChartView(
                    geo: geo,
                    chartHeight: chartHeight,
                    units: state.units,
                    highGlucose: state.highGlucose,
                    lowGlucose: state.lowGlucose,
                    currentGlucoseTarget: state.currentGlucoseTarget,
                    glucoseColorScheme: state.glucoseColorScheme,
                    displayXgridLines: state.displayXgridLines,
                    displayYgridLines: state.displayYgridLines,
                    showGlucoseEpisodes: state.showGlucoseEpisodes,
                    thresholdLines: state.thresholdLines,
                    state: state,
                    selection: $chartSelection
                )
            }
            // enforce the zone budget; panes flex within it
            .frame(height: chartHeight)
            .overlay(alignment: .bottomTrailing) {
                chartInfoButton
                    .offset(x: 0, y: -10)
            }
        }

        @ViewBuilder private var chartInfoButton: some View {
            ChartOverlayButton(systemImage: "info") {
                state.isLegendPresented.toggle()
            }
            .padding(.bottom, 6)
            // same trailing inset as the meal row
            .padding(.trailing, 16)
        }

        @ViewBuilder func mainViewElements(_ geo: GeometryProxy) -> some View {
            if isLandscapeChart {
                // Sideways the chart claims the whole display, safe area included: it runs
                // under the sensor housing behind a frost rather than stopping short of it,
                // and flush to every other edge, none of which has hardware to protect. All
                // edges, not just the horizontal ones — leaving the bottom inset in place
                // left the home-indicator strip standing there as a black band under the
                // chart, which reads as a border rather than as a margin.
                //
                // The reader below therefore reports the full size — and, having had the safe
                // area taken off it, no insets at all, which is why the housing is measured
                // off the window instead (`HousingInsets`).
                GeometryReader { fullGeo in
                    landscapeChart(geo: fullGeo, housing: housingInsets)
                }
                .ignoresSafeArea()
                .modifier(HousingInsetsReader(insets: $housingInsets))
                .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
            } else {
                portraitDashboard(geo)
            }
        }

        /// The dashboard proper: header, meal slot, chart, bottom zone, pull-to-loop.
        @ViewBuilder private func portraitDashboard(_ geo: GeometryProxy) -> some View {
            // viewport-sized content: rubber-bands for the pull-down, never scrolls
            ScrollView(.vertical, showsIndicators: false) {
                dashboardContent(geo)
                    .padding(.top, isForcingLoop ? HomeLayout.refreshIndicatorHeight : 0)
                    .animation(.easeInOut(duration: 0.25), value: isForcingLoop)
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(
                                key: HomePullOffsetKey.self,
                                value: g.frame(in: .named("homeScroll")).minY
                            )
                        }
                    )
            }
            .coordinateSpace(name: "homeScroll")
            .scrollBounceBehavior(.always, axes: [.vertical])
            .modifier(HomePullOffsetReader(onChange: handlePullChange))
            .onPreferenceChange(HomePullOffsetKey.self) { handlePullChange($0) }
            .overlay(alignment: .top) { pullToRefreshIndicator }
            // safe-area anchor: the tab bar can never cover the bottom controls
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomControls()
            }
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onReceive(
                resolver.resolve(AlertPermissionsChecker.self)!.$notificationsDisabled,
                perform: {
                    if notificationsDisabled != $0 {
                        notificationsDisabled = $0
                        if notificationsDisabled {
                            debug(.default, "notificationsDisabled")
                        }
                    }
                }
            )
        }

        @ViewBuilder private func dashboardContent(_ geo: GeometryProxy) -> some View {
            VStack(spacing: 0) {
                ZStack {
                    if let apsManager = state.apsManager, let bluetoothManager = apsManager.bluetoothManager,
                       bluetoothManager.bluetoothAuthorization != .authorized
                    {
                        BluetoothRequiredView()
                    } else {
                        /// right panel with loop status and evBG
                        HStack {
                            Spacer()
                            rightHeaderPanel()
                        }.padding(.trailing, 20)

                        /// glucose bobble
                        glucoseView

                        /// left panel with pump related info
                        HStack {
                            pumpView
                            Spacer()
                        }.padding(.leading, 20)
                    }
                }
                // fixed slot: header state changes never reflow the zones below
                .frame(height: HomeLayout.headerHeight)

                mealPanel()
                    .frame(height: HomeLayout.mealSlotHeight)
                    .task(id: chartSelection) { await updateChartReadout() }
                    // only the swap in and out animates; the values inside must not, or
                    // scrubbing smears them. Appearing is immediate, letting go fades — the
                    // readout should never look like it blinked out.
                    .animation(
                        chartReadoutDate == nil ? .easeOut(duration: 0.3) : .easeIn(duration: 0.12),
                        value: chartReadoutDate == nil
                    )

                mainChart(geo: geo)
            }
            .frame(maxWidth: .infinity)
        }

        @ViewBuilder func mainView() -> some View {
            GeometryReader { geo in
                mainViewElements(geo)
                    // fixed zones bust beyond XXL; cap dashboard type size
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
            // no inline text input here; a stale keyboard inset must never shrink the zone budget
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onAppear {
                configureView()
                refreshAlarmsSnooze()
            }
            .task {
                await releaseNotesService.load()
            }
            // UserDefaults changes don't invalidate views; refresh on sheet dismissal
            .onChange(of: showSnoozeSheet) {
                if !showSnoozeSheet { refreshAlarmsSnooze() }
            }
            .navigationTitle("Home")
            .navigationBarHidden(true)
            // sideways the chart owns the screen; the bar would spend a fifth of its height
            .toolbar(isLandscapeChart ? .hidden : .visible, for: .tabBar)
            .blur(radius: state.isLoopStatusPresented ? 3 : 0)
            .sheet(isPresented: $state.isLoopStatusPresented) {
                LoopStatusView(state: state)
            }
            .sheet(isPresented: $state.isLegendPresented) {
                ChartLegendView(state: state)
            }
            .sheet(isPresented: $showSnoozeSheet) {
                SnoozeAlertsSheetView(resolver: resolver, isPresented: $showSnoozeSheet)
            }
            .sheet(isPresented: $showReleaseNotes) {
                if let notes = releaseNotesService.notes {
                    ReleaseNotesSheetView(notes: notes) {
                        releaseNotesService.acknowledge()
                    }
                }
            }
            .sheet(isPresented: $showManualGlucose) {
                ManualGlucoseEntryView(units: state.units, isPresented: $showManualGlucose) { amount in
                    state.addManualGlucose(amount)
                }
            }
            // DEVICE SELECTION (pump + CGM)
            .devicePickers(
                showPumpSelection: $showPumpSelection,
                showCGMSelection: $showCGMSelection,
                pendingPump: $pendingPump,
                pendingCGM: $pendingCGM,
                state: state
            )
            .sheet(isPresented: $state.shouldDisplayPumpSetupSheet) {
                if let pumpManager = state.provider.apsManager.pumpManager {
                    PumpConfig.PumpSettingsView(
                        pumpManager: pumpManager,
                        bluetoothManager: state.provider.apsManager.bluetoothManager!,
                        completionDelegate: state,
                        setupDelegate: state
                    )
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .ignoresSafeArea(.all, edges: .bottom)
                } else if let pumpEntry = state.setupPumpEntry {
                    PumpConfig.PumpSetupView(
                        pumpEntry: pumpEntry,
                        pumpInitialSettings: state.pumpInitialSettings,
                        bluetoothManager: state.provider.apsManager.bluetoothManager!,
                        completionDelegate: state,
                        setupDelegate: state
                    )
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .ignoresSafeArea(.all, edges: .bottom)
                }
            }
            // CGM RELATED
            .sheet(isPresented: $state.shouldDisplayCGMSetupSheet) {
                Group {
                    switch state.cgmCurrent.type {
                    case .enlite,
                         .nightscout,
                         .none,
                         .simulator,
                         .xdrip:
                        CGMSettings.CustomCGMOptionsView(
                            resolver: self.resolver,
                            state: state.cgmStateModel,
                            cgmCurrent: state.cgmCurrent,
                            deleteCGM: state.deleteCGM
                        )
                    case .plugin:
                        if let fetchGlucoseManager = state.fetchGlucoseManager,
                           let cgmManager = fetchGlucoseManager.cgmManager,
                           state.cgmCurrent.type == fetchGlucoseManager.cgmGlucoseSourceType,
                           state.cgmCurrent.id == fetchGlucoseManager.cgmGlucosePluginId
                        {
                            CGMSettings.CGMSettingsView(
                                cgmManager: cgmManager,
                                bluetoothManager: state.provider.apsManager.bluetoothManager!,
                                unit: state.settingsManager.settings.units,
                                completionDelegate: state
                            )
                            .ignoresSafeArea(.keyboard, edges: .bottom)
                            .ignoresSafeArea(.all, edges: .bottom)
                        } else {
                            CGMSettings.CGMSetupView(
                                CGMType: state.cgmCurrent,
                                bluetoothManager: state.provider.apsManager.bluetoothManager!,
                                unit: state.settingsManager.settings.units,
                                completionDelegate: state,
                                setupDelegate: state,
                                pluginCGMManager: self.state.pluginCGMManager
                            )
                            .ignoresSafeArea(.keyboard, edges: .bottom)
                            .ignoresSafeArea(.all, edges: .bottom)
                        }
                    }
                }
            }
        }

        @ViewBuilder func tabBar() -> some View {
            if #available(iOS 26.0, *) {
                modernTabBar()
            } else {
                legacyTabBar()
            }
        }

        /// Legacy layout on the glass bar: a dead middle slot with the
        /// treatment button overlaid; the slot's selection is swallowed.
        @available(iOS 26.0, *)
        @ViewBuilder private func modernTabBar() -> some View {
            ZStack(alignment: .bottom) {
                TabView(selection: modernTabSelection) {
                    let carbsRequiredBadge: String? = carbsRequiredBadgeValue

                    NavigationStack { mainView() }
                        .tabItem { Label("", systemImage: "chart.xyaxis.line") }
                        .badge(carbsRequiredBadge).tag(0)
                        .accessibilityLabel(Text("Main"))

                    NavigationStack { History.RootView(resolver: resolver) }
                        .tabItem { Label("", systemImage: historySFSymbol) }.tag(1)
                        .accessibilityLabel(Text("History"))

                    Spacer()
                        // nbsp title + empty image: invisible item that still
                        // holds a full-width slot for the overlaid button
                        .tabItem { Label {
                            Text(String(repeating: "\u{00A0}", count: 12))
                        } icon: {
                            Image(uiImage: UIImage())
                        } }
                        .tag(RootView.treatmentTabTag)

                    NavigationStack { Adjustments.RootView(resolver: resolver) }
                        .tabItem {
                            Label(
                                "",
                                systemImage: "slider.horizontal.2.gobackward"
                            ) }.tag(2)
                        .accessibilityLabel(Text("Adjustments"))

                    NavigationStack(path: self.$settingsPath) {
                        Settings.RootView(resolver: resolver) }
                        .environment(settingsSearchHighlight)
                        .tabItem { Label(
                            "",
                            systemImage: "gear"
                        ) }.tag(3)
                        .accessibilityLabel(Text("Settings"))
                }
                .tint(Color.tabBar)

                // fixed distance from the physical screen bottom; immune to
                // safe-area changes (keyboard, accessories)
                if !isLandscapeChart {
                    GeometryReader { geo in
                        treatmentButton
                            .position(x: geo.size.width / 2, y: geo.size.height - 52)
                    }
                    .ignoresSafeArea(.all, edges: .bottom)
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .blur(radius: state.waitForSuggestion ? 8 : 0)
            .onChange(of: selectedTab) {
                if selectedTab != 3, !settingsPath.isEmpty {
                    settingsPath = NavigationPath()
                }
            }
        }

        private var modernTabSelection: Binding<Int> {
            Binding(
                get: { selectedTab },
                set: { newValue in
                    if newValue == RootView.treatmentTabTag {
                        let previous = selectedTab
                        selectedTab = newValue
                        DispatchQueue.main.async {
                            selectedTab = previous
                        }
                    } else {
                        selectedTab = newValue
                    }
                }
            )
        }

        private var treatmentButton: some View {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.tabBar)
                .padding(.vertical, 2)
                .padding(.horizontal, 24)
                .contentShape(Rectangle())
                .onTapGesture {
                    state.showModal(for: .treatmentView)
                }
                .onLongPressGesture(minimumDuration: 0.5) {
                    guard state.enableQuickPickTreatments else { return }
                    let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
                    impactHeavy.impactOccurred()
                    Task {
                        await state.loadQuickPickTreatmentSuggestions()
                        if state.quickPickBolusSuggestions.isEmpty, state.quickPickCarbSuggestions.isEmpty {
                            showQuickPickTreatmentsNoHistory = true
                        } else {
                            showQuickPickTreatmentsPicker = true
                        }
                    }
                }
                .accessibilityLabel(Text("Add Treatment"))
        }

        private var carbsRequiredBadgeValue: String? {
            guard let carbsRequired = state.enactedAndNonEnactedDeterminations.first?.carbsRequired,
                  state.showCarbsRequiredBadge
            else {
                return nil
            }
            let carbsRequiredDecimal = Decimal(carbsRequired)
            if carbsRequiredDecimal > state.settingsManager.settings.carbsRequiredThreshold {
                let numberAsNSNumber = NSDecimalNumber(decimal: carbsRequiredDecimal)
                return (Formatter.decimalFormatterWithTwoFractionDigits.string(from: numberAsNSNumber) ?? "") + " g"
            }
            return nil
        }

        @ViewBuilder private func legacyTabBar() -> some View {
            ZStack(alignment: .bottom) {
                TabView(selection: $selectedTab) {
                    let carbsRequiredBadge: String? = {
                        guard let carbsRequired = state.enactedAndNonEnactedDeterminations.first?.carbsRequired,
                              state.showCarbsRequiredBadge
                        else {
                            return nil
                        }
                        let carbsRequiredDecimal = Decimal(carbsRequired)
                        if carbsRequiredDecimal > state.settingsManager.settings.carbsRequiredThreshold {
                            let numberAsNSNumber = NSDecimalNumber(decimal: carbsRequiredDecimal)
                            return (Formatter.decimalFormatterWithTwoFractionDigits.string(from: numberAsNSNumber) ?? "") + " g"
                        }
                        return nil
                    }()

                    NavigationStack { mainView() }
                        .tabItem { Label("Main", systemImage: "chart.xyaxis.line") }
                        .badge(carbsRequiredBadge).tag(0)

                    NavigationStack { History.RootView(resolver: resolver) }
                        .tabItem { Label("History", systemImage: historySFSymbol) }.tag(1)

                    Spacer()

                    NavigationStack { Adjustments.RootView(resolver: resolver) }
                        .tabItem {
                            Label(
                                "Adjustments",
                                systemImage: "slider.horizontal.2.gobackward"
                            ) }.tag(2)

                    NavigationStack(path: self.$settingsPath) {
                        Settings.RootView(resolver: resolver) }
                        .environment(settingsSearchHighlight)
                        .tabItem { Label(
                            "Settings",
                            systemImage: "gear"
                        ) }.tag(3)
                }
                .tint(Color.tabBar)

                if !isLandscapeChart {
                    treatmentButton
                }
            }.ignoresSafeArea(.keyboard, edges: .bottom).blur(radius: state.waitForSuggestion ? 8 : 0)
                .onChange(of: selectedTab) {
                    // reset only when leaving Settings; programmatic pushes survive the switch
                    if selectedTab != 3, !settingsPath.isEmpty {
                        settingsPath = NavigationPath()
                    }
                }
        }

        var body: some View {
            ZStack(alignment: .center) {
                tabBar()

                if state.waitForSuggestion {
                    CustomProgressView(text: String(localized: "Updating IOB...", comment: "Progress text when updating IOB"))
                }
            }
            // Landscape exists for the Home chart alone; every other tab is portrait-only
            // (see `OrientationGate`).
            .onAppear { OrientationGate.setAllowsLandscape(selectedTab == 0) }
            .onChange(of: selectedTab) { _, newValue in
                // The treatment tag is a transient bounce, not a destination (see
                // `modernTabSelection`); acting on it would flip the app to portrait and back.
                guard newValue != RootView.treatmentTabTag else { return }
                OrientationGate.setAllowsLandscape(newValue == 0)
            }
            .sheet(isPresented: $showQuickPickTreatmentsPicker) {
                QuickPickTreatmentsView(
                    bolusSuggestions: state.quickPickBolusSuggestions,
                    carbSuggestions: state.quickPickCarbSuggestions,
                    onEnact: { bolusAmount, carbAmount in
                        await state.enactQuickPickTreatment(bolusAmount: bolusAmount, carbAmount: carbAmount)
                    },
                    isPresented: $showQuickPickTreatmentsPicker
                )
            }
            .alert(
                String(
                    localized: "No treatment history yet",
                    comment: "Alert title when no quick-pick treatments history exists"
                ),
                isPresented: $showQuickPickTreatmentsNoHistory
            ) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(String(
                    localized: "Quick-Pick Treatments learns from your manual boluses and carb entries over time. Once you've logged a few, it will suggest amounts based on what you typically enter at this time of day.",
                    comment: "Alert body explaining that quick-pick treatments history is empty"
                ))
            }
        }
    }
}

/// Checks if the device is using a 24-hour time format.
func is24HourFormat() -> Bool {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    let dateString = formatter.string(from: Date())

    return !dateString.contains("AM") && !dateString.contains("PM")
}

/// Converts a duration in minutes to a formatted string (e.g., "1 h 30 m").
func formatHrMin(_ durationInMinutes: Int) -> String {
    let hours = durationInMinutes / 60
    let minutes = durationInMinutes % 60

    switch (hours, minutes) {
    case let (0, m):
        return "\(m)\u{00A0}" + String(localized: "m", comment: "Abbreviation for Minutes")
    case let (h, 0):
        return "\(h)\u{00A0}" + String(localized: "h", comment: "h")
    default:
        return hours.description + "\u{00A0}" + String(localized: "h", comment: "h") + "\u{00A0}" + minutes
            .description + "\u{00A0}" + String(localized: "m", comment: "Abbreviation for Minutes")
    }
}

// Helper function to convert a start and end hour to either 24-hour or AM/PM format
func formatTimeRange(start: String?, end: String?) -> String {
    guard let start = start, let end = end else {
        return ""
    }

    // Check if the format is 24-hour or AM/PM
    if is24HourFormat() {
        // Return the original 24-hour format
        return "\(start)-\(end)"
    } else {
        // Convert to AM/PM format using DateFormatter
        let formatter = DateFormatter()
        formatter.dateFormat = "HH"

        if let startHour = Int(start), let endHour = Int(end) {
            let startDate = Calendar.current.date(bySettingHour: startHour, minute: 0, second: 0, of: Date()) ?? Date()
            let endDate = Calendar.current.date(bySettingHour: endHour, minute: 0, second: 0, of: Date()) ?? Date()

            // Customize the format to "2p" or "2a"
            formatter.dateFormat = "ha"
            let startFormatted = formatter.string(from: startDate).lowercased().replacingOccurrences(of: "m", with: "")
            let endFormatted = formatter.string(from: endDate).lowercased().replacingOccurrences(of: "m", with: "")

            return "\(startFormatted)-\(endFormatted)"
        } else {
            return ""
        }
    }
}
