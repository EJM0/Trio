import Charts
import SwiftUI
import WatchKit

struct TrioMainWatchView: View {
    @State private var state = WatchState.shared

    // Pages in order; the bubble page is a phone setting, then chart, devices and alarm snooze.
    private var bubblePage: Int? { state.showGlucoseBubble ? 1 : nil }
    private var chartPage: Int { bubblePage.map { $0 + 1 } ?? 1 }
    private var peripheralsPage: Int { chartPage + 1 }
    private var snoozePage: Int { peripheralsPage + 1 }
    private var lastPage: Int { snoozePage }

    // misc
    @State private var currentPage: Int = 0
    /// Scrubbing the chart with the crown (see GlucoseChartView).
    @State private var isScrubbingChart = false
    @State private var chartScrubSteps = 0.0
    /// The pages hold the crown, except while the chart scrubs. The chart dropping its focus didn't hand the crown
    /// back: nothing had it and the pages didn't turn until a swipe. So the pages take it again, by their binding,
    /// and the focus is settled again within them as at launch.
    @FocusState private var pagesHaveCrown: Bool
    @Namespace private var pagesFocusScope
    @Environment(\.resetFocus) private var resetFocus
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

    /// Treatments and IOB/COB rely on the phone's data.
    private var isPhoneDataUnusable: Bool {
        isWatchStateDated || isSessionUnreachable
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
                    glucoseValues: state.glucoseValues,
                    isScrubbing: $isScrubbingChart,
                    scrubSteps: $chartScrubSteps
                )
                .tag(chartPage)

                // Page 4: Pump and CGM peripheral info
                PeripheralsView(
                    state: state,
                    isWatchStateDated: isWatchStateDated || isSessionUnreachable
                )
                .tag(peripheralsPage)

                // Page 4: alarm snooze (nightscout/Trio#1576, t1dude)
                AlarmSnoozeView(state: state)
                    .tag(snoozePage)
            }
            .onChange(of: state.showGlucoseBubble) { _, _ in
                if currentPage > lastPage { currentPage = lastPage } }
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
            .focused($pagesHaveCrown)
            // only around the pages: a pushed treatment screen keeps its own default focus
            .focusScope(pagesFocusScope)
            .digitalCrownRotation($currentPage.doubleBinding(), from: 0, through: Double(lastPage), by: 1)
            .modifier(ChartScrubEnd(
                isScrubbing: $isScrubbingChart,
                scrubSteps: $chartScrubSteps,
                currentPage: currentPage,
                chartPage: chartPage
            ))
            // scrubbing over: the crown back to the pages, once the chart has let go of it
            .onChange(of: isScrubbingChart) { _, scrubbing in
                guard !scrubbing else { return }
                DispatchQueue.main.async {
                    pagesHaveCrown = true
                    resetFocus(in: pagesFocusScope)
                }
            }
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
                    if ![peripheralsPage, snoozePage].contains(currentPage) {
                        // the Devices and alarm snooze pages have no treatment controls
                        Button {
                            showingOverrideSheet = true
                        } label: {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .foregroundStyle(Color.primary, isOverrideActive ? Color.primary : Color.purple)
                        }
                        .tint(isOverrideActive ? Color.purple : nil)
                        .disabled(isPhoneDataUnusable)

                        Button {
                            showingTreatmentMenuSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(Color.bgDarkerDarkBlue)
                        }
                        .controlSize(.large)
                        .buttonStyle(WatchOSButtonStyle(deviceType: state.deviceType))
                        .disabled(isPhoneDataUnusable)

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

/// Ends the chart's scrubbing (GlucoseChartView), which then hands the crown back to the pages: by turning the
/// crown back past now, after 10 seconds without a turn, or on leaving the chart page. A tap on the chart ends it too.
/// From Kristin Kandschur's feature/untethered-plus (74732bde4, f5033e743).
struct ChartScrubEnd: ViewModifier {
    @Binding var isScrubbing: Bool
    @Binding var scrubSteps: Double
    let currentPage: Int
    /// The bubble page is a phone setting, so the chart's page moves.
    let chartPage: Int

    func body(content: Content) -> some View {
        content
            .onChange(of: scrubSteps) { _, steps in
                if isScrubbing, steps < 0 { stop() }
            }
            .onChange(of: currentPage) { _, page in
                if page != chartPage, isScrubbing { stop() }
            }
            // restarts with every turn; 10 s still ends it
            .task(id: isScrubbing ? scrubSteps : -2) {
                guard isScrubbing else { return }
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled, isScrubbing { stop() }
            }
    }

    private func stop() {
        withAnimation { isScrubbing = false }
        scrubSteps = 0
    }
}
