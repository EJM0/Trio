import Charts
import SwiftUI
import WatchKit

struct TrioMainWatchView: View {
    @State private var state = WatchState.shared
    @State private var untethered = UntetheredWatchManager.shared

    // Pages in order; the bubble page is a phone setting, the history page exists while untethered and while
    // its history still syncs, the status page (where untethered mode starts from the wrist) always.
    private var bubblePage: Int? { state.showGlucoseBubble ? 1 : nil }
    private var chartPage: Int { bubblePage.map { $0 + 1 } ?? 1 }
    private var peripheralsPage: Int { chartPage + 1 }
    private var historyPage: Int? { showsHistory ? peripheralsPage + 1 : nil }
    private var statusPage: Int { (historyPage ?? peripheralsPage) + 1 }
    /// The watch's own loop status, while it loops.
    private var loopPage: Int? { untethered.isActive ? statusPage + 1 : nil }
    private var lastPage: Int { loopPage ?? statusPage }

    private var showsHistory: Bool {
        untethered.data.session.phase != .idle || untethered.data.pending.values.contains { !$0.isEmpty }
    }

    @State private var historyKind = UntetheredHistoryView.Kind.glucose

    // misc
    @State private var currentPage: Int = 0
    @State private var rotationDegrees: Double = 0.0
    @State private var showingTempTargetSheet = false

    // view visbility
    @State private var showingTreatmentMenuSheet: Bool = false
    @State private var showingOverrideSheet: Bool = false
    // navigation flag for meal bolus combo
    @State private var continueToBolus = false
    @State private var navigationPath = NavigationPath()

    // treatments
    @State private var selectedTreatment: TreatmentOption?

    /// Advanced by a timer, so the view goes stale even when nothing new arrives.
    @State private var now = Date()
    @Environment(\.scenePhase) private var scenePhase

    /// Dated by the newest reading, or by the last update when there is none. The extra minute covers the
    /// next reading's delivery; unchanged messages are not resent, so the last update alone would go stale.
    var isWatchStateDated: Bool {
        if let newestReading = state.glucoseValues.last?.date {
            return now.timeIntervalSince(newestReading) > 6 * 60
        }
        guard let lastUpdateTimestamp = state.lastWatchStateUpdate else { return true }
        return now.timeIntervalSince1970 - lastUpdateTimestamp > 5 * 60
    }

    /// Treatments and IOB/COB rely on the phone's data, unless the watch runs the loop itself.
    private var isPhoneDataUnusable: Bool {
        !untethered.isActive && (isWatchStateDated || isSessionUnreachable)
    }

    var isSessionUnreachable: Bool {
        guard let session = state.session else {
            return true // No session at all => unreachable
        }
        // Return true if not .activated OR not reachable
        return session.activationState != .activated
    }

    // Active adjustment indicator
    private func isAdjustmentActive<T>(for presets: [T], predicate: (T) -> Bool) -> Bool {
        let sortedPresets = presets.sorted { predicate($0) && !predicate($1) }
        return !sortedPresets.isEmpty && sortedPresets.first(where: predicate) != nil
    }

    private var isTempTargetActive: Bool {
        isAdjustmentActive(for: state.tempTargetPresets) { $0.isEnabled }
    }

    private var isOverrideActive: Bool {
        isAdjustmentActive(for: state.overridePresets) { $0.isEnabled }
    }

    private var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        NavigationStack(path: $navigationPath) {
            TabView(selection: $currentPage) {
                // Page 1: Combined View of glucose trend and chart view
                CombinedGlucoseChartview(
                    state: state,
                    rotationDegrees: rotationDegrees,
                    isWatchStateDated: isWatchStateDated || isSessionUnreachable
                )
                .tag(0)
                // Page 2: Current glucose trend in "BG bobble", unless turned off on the phone
                if let bubblePage {
                    ZStack {
                        GlucoseTrendView(
                            state: state,
                            rotationDegrees: rotationDegrees,
                            isWatchStateDated: isWatchStateDated || isSessionUnreachable
                        )

                        if state.showSyncingAnimation {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.primary, Color.tabBar, Color.clear)
                                .symbolEffect(
                                    .variableColor.iterative,
                                    options: .repeating,
                                    value: state.showSyncingAnimation
                                )
                                .position(
                                    x: 20,
                                    y: (WKInterfaceDevice.current().screenBounds.height / 4) -
                                        7 // Font .body == 14, so half of default size for the SF Symbol image
                                )
                        }
                    }.tag(bubblePage)
                }

                // Page 3: Glucose chart
                GlucoseChartView(
                    state: state,
                    glucoseValues: state.glucoseValues
                )
                .tag(chartPage)

                // Page 4: Pump and CGM peripheral info
                PeripheralsView(
                    state: state,
                    isWatchStateDated: isWatchStateDated || isSessionUnreachable
                )
                .tag(peripheralsPage)

                if let historyPage {
                    UntetheredHistoryView(manager: untethered, kind: historyKind, page: $currentPage, lastPage: lastPage)
                        .tag(historyPage)
                }
                UntetheredStatusView(manager: untethered).tag(statusPage)
                if let loopPage {
                    UntetheredLoopStatusView(manager: untethered).tag(loopPage)
                }
            }
            .onChange(of: untethered.isActive) { _, isActive in
                if isActive || currentPage > statusPage { currentPage = statusPage }
            }
            // the history page goes once its records are on the phone; stay on the status page, not on none
            .onChange(of: showsHistory) { _, _ in
                if currentPage > lastPage { currentPage = lastPage }
            }
            .onChange(of: state.showGlucoseBubble) { _, _ in
                if currentPage > lastPage { currentPage = lastPage }
            }
            .onAppear {
                /// Hard reset variables when main view appears
                /// Reset `bolusAmount` and `recommendedBolus` to ensure no stale / old value is set when user opens bolus input or meal combo the next time.
                state.bolusAmount = 0
                state.recommendedBolus = 0
                // Like the phone's Treatments view, every new bolus starts without reduced or super bolus.
                state.useReducedBolus = false
                state.useSuperBolus = false
            }
            .background(trioBackgroundColor)
            .tabViewStyle(.verticalPage)
            .digitalCrownRotation($currentPage.doubleBinding(), from: 0, through: Double(lastPage), by: 1)
            .onChange(of: state.trend) { _, newTrend in
                withAnimation {
                    updateRotation(for: newTrend)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    VStack {
                        Image(systemName: "syringe.fill")
                            .foregroundStyle(Color.insulin)

                        Text(isPhoneDataUnusable ? "--" : state.iob ?? "--")
                            .foregroundStyle(isWatchStateDated ? Color.secondary : Color.white)
                            .frame(alignment: .leading)
                            .minimumScaleFactor(0.5)
                    }.font(.caption2)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    VStack {
                        Image(systemName: "fork.knife")
                            .foregroundStyle(Color.orange)

                        Text(isPhoneDataUnusable ? "--" : state.cob ?? "--")
                            .foregroundStyle(isPhoneDataUnusable ? Color.secondary : Color.white)
                            .frame(alignment: .trailing)
                            .minimumScaleFactor(0.5)
                    }.font(.caption2)
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    if currentPage == historyPage {
                        // what the history page lists
                        ForEach(UntetheredHistoryView.Kind.allCases, id: \.self) { kind in
                            Button { historyKind = kind } label: {
                                Image(systemName: kind.symbol)
                                    .foregroundStyle(historyKind == kind ? Color.primary : kind.color)
                            }
                            .tint(historyKind == kind ? kind.color : nil)
                        }
                    } else if currentPage != peripheralsPage, currentPage != statusPage, currentPage != loopPage {
                        // the Devices, status and loop pages have no treatment controls
                        Button {
                            showingOverrideSheet = true
                        } label: {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .foregroundStyle(Color.primary, isOverrideActive ? Color.primary : Color.purple)
                        }
                        .tint(isOverrideActive ? Color.purple : nil)
                        .disabled(isPhoneDataUnusable)

                        // while the watch's pump delivers a bolus, the button stops it
                        Button {
                            if untethered.isBolusing {
                                untethered.cancelBolus()
                            } else {
                                showingTreatmentMenuSheet = true
                            }
                        } label: {
                            Image(systemName: untethered.isBolusing ? "square.fill" : "plus")
                                .foregroundStyle(Color.bgDarkerDarkBlue)
                        }
                        .controlSize(.large)
                        .buttonStyle(WatchOSButtonStyle(deviceType: state.deviceType))
                        .overlay {
                            if untethered.isBolusing { BolusProgressRing(window: untethered.bolusWindow) }
                        }
                        .disabled(!untethered.isBolusing && isPhoneDataUnusable)

                        Button {
                            showingTempTargetSheet = true
                        } label: {
                            Image(systemName: "target")
                                .foregroundStyle(isTempTargetActive ? Color.primary : Color.loopGreen.opacity(0.75))
                        }
                        .tint(isTempTargetActive ? Color.loopGreen.opacity(0.75) : nil)
                        .disabled(isPhoneDataUnusable)
                    }
                }
            }
            .fullScreenCover(isPresented: $showingTreatmentMenuSheet) {
                TreatmentMenuView(deviceType: state.deviceType, selectedTreatment: $selectedTreatment) {
                    handleTreatmentSelection()
                }
                .onAppear {
                    // reset the conditional navigation flag when opening
                    continueToBolus = false
                }
            }
            .sheet(isPresented: $showingOverrideSheet) {
                OverridePresetsView(
                    state: state,
                    overridePresets: state.overridePresets
                ) {
                    showingOverrideSheet = false
                    navigationPath.append(NavigationDestinations.acknowledgmentPending)
                }
            }
            .sheet(isPresented: $showingTempTargetSheet) {
                TempTargetPresetsView(
                    state: state,
                    tempTargetPresets: state.tempTargetPresets
                ) {
                    showingTempTargetSheet = false
                    navigationPath.append(NavigationDestinations.acknowledgmentPending)
                }
            }
            .navigationDestination(for: NavigationDestinations.self) { destination in
                switch destination {
                case .acknowledgmentPending:
                    AcknowledgementPendingView(
                        navigationPath: $navigationPath,
                        state: state,
                        shouldNavigateToRoot: $state.shouldNavigateToRoot
                    )
                case .carbsInput:
                    CarbsInputView(
                        navigationPath: $navigationPath,
                        state: state,
                        continueToBolus: continueToBolus
                    )
                case .bolusInput:
                    BolusInputView(
                        navigationPath: $navigationPath,
                        state: state
                    )
                case .bolusConfirm:
                    BolusConfirmationView(
                        navigationPath: $navigationPath,
                        state: state,
                        bolusAmount: $state.bolusAmount,
                        confirmationProgress: $state.confirmationProgress
                    )
                }
            }
            .onChange(of: navigationPath) { _, newPath in
                if newPath.isEmpty {
                    // Reset conditional view navigation when returning to root view
                    continueToBolus = false
                }
            }
            // The "Meal & Bolus" complication or App Intent, on launch or while running.
            .onAppear {
                openMealBolusShortcutIfPending()
            }
            .onChange(of: state.isMealBolusShortcutPending) { _, isPending in
                if isPending { openMealBolusShortcutIfPending() }
            }
        }
        .ignoresSafeArea()
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { now = Date() }
        }
    }

    private func updateRotation(for trend: String?) {
        switch trend {
        case "DoubleUp",
             "SingleUp":
            rotationDegrees = -90
        case "FortyFiveUp":
            rotationDegrees = -45
        case "Flat":
            rotationDegrees = 0
        case "FortyFiveDown":
            rotationDegrees = 45
        case "DoubleDown",
             "SingleDown":
            rotationDegrees = 90
        default:
            rotationDegrees = 0
        }
    }

    /// Starts the "Meal & Bolus" flow from its first step, closing whatever was open, as if picked from the
    /// treatment menu.
    private func openMealBolusShortcutIfPending() {
        guard state.isMealBolusShortcutPending else { return }
        state.isMealBolusShortcutPending = false

        showingTreatmentMenuSheet = false
        showingOverrideSheet = false
        showingTempTargetSheet = false

        state.carbsAmount = 0
        state.bolusAmount = 0
        state.recommendedBolus = 0
        state.useReducedBolus = false
        state.useSuperBolus = false

        navigationPath = NavigationPath()

        // Push once the dismissals and the pop to root have settled: on a cold launch, or with a sheet still
        // closing, a push in the same update is dropped and the app stays on the main screen.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            continueToBolus = true
            navigationPath.append(NavigationDestinations.carbsInput)
        }
    }

    private func handleTreatmentSelection() {
        showingTreatmentMenuSheet = false // Dismiss the sheet

        guard let treatment = selectedTreatment else { return }

        switch treatment {
        case .meal:
            navigationPath.append(NavigationDestinations.carbsInput)
        case .bolus:
            // Reset carbs amount when directly going to bolus input
            state.carbsAmount = 0
            navigationPath.append(NavigationDestinations.bolusInput)
        case .mealBolusCombo:
            continueToBolus = true // Explicitely set subsequent view navigation
            navigationPath.append(NavigationDestinations.carbsInput)
        }
    }
}

#Preview {
    TrioMainWatchView()
}
