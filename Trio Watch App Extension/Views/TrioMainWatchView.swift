import Charts
import SwiftUI
import WatchKit

struct TrioMainWatchView: View {
    /// Extended Untethered Mode shows its minimal screen on each wrist raise until tapped.
    @State private var showsFullApp = false
    @Environment(\.scenePhase) private var glanceScenePhase
    @State private var state = WatchState.shared
    @State private var untethered = UntetheredWatchManager.shared

    // Pages in order: bubble, chart, the watch's own G7 reading, alarm snooze, then untethered mode's status page, where it
    // starts from the wrist and its history opens, and while it loops, the watch's own loop status.
    private let watchSensorPage = 2
    private let snoozePage = 3
    /// Untethered mode off on the phone: no status page, but a session still running keeps it.
    private var showsUntethered: Bool { state.untetheredMode || untethered.isActive }
    private var statusPage: Int { snoozePage + 1 }
    /// The watch's own loop status, while it loops.
    private var loopPage: Int? { untethered.isActive ? statusPage + 1 : nil }
    private var lastPage: Int { showsUntethered ? loopPage ?? statusPage : snoozePage }

    // misc
    @State private var currentPage: Int = 0
    /// Scrubbing the chart with the crown (see GlucoseChartView).
    @State private var isScrubbingChart = false
    @State private var chartScrubSteps = 0.0
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

    var isWatchStateDated: Bool {
        // If `lastWatchStateUpdate` is nil, treat as "dated"
        guard let lastUpdateTimestamp = state.lastWatchStateUpdate else {
            return true
        }
        let now = Date().timeIntervalSince1970
        let secondsSinceUpdate = now - lastUpdateTimestamp
        // Return true if last update older than 5 min, so 1 loop cycle
        return secondsSinceUpdate > 5 * 60
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
        Group {
            if untethered.isKeptAwake, state.glanceEnabled, !showsFullApp {
                UntetheredGlanceView(state: state, manager: untethered) { showsFullApp = true }
            } else {
                fullApp
            }
        }
        .onChange(of: glanceScenePhase) { _, phase in
            if phase != .active { showsFullApp = false }
        }
    }

    private var fullApp: some View {
        NavigationStack(path: $navigationPath) {
            TabView(selection: $currentPage) {
                // Page 1: Current glucose trend in "BG bobble"
                ZStack {
                    // Re-evaluated every 15 s: "stale" and "the watch has a newer
                    // reading" depend on the clock, not only on new data, so the
                    // bubble switches as soon as the phone's data ages out.
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        GlucoseTrendView(
                            state: state,
                            rotationDegrees: rotationDegrees,
                            isWatchStateDated: isWatchStateDated || isSessionUnreachable
                        )
                    }

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
                }.tag(0)

                // Page 2: Glucose chart
                GlucoseChartView(
                    state: state,
                    glucoseValues: state.glucoseValues,
                    isScrubbing: $isScrubbingChart,
                    scrubSteps: $chartScrubSteps
                )
                .tag(1)

                // Page 3: the watch reading the G7 itself
                WatchG7View()
                    .tag(watchSensorPage)

                // Page 4: alarm snooze (nightscout/Trio#1576, t1dude)
                AlarmSnoozeView(state: state)
                    .tag(snoozePage)

                if showsUntethered {
                    UntetheredStatusView(manager: untethered).tag(statusPage)
                }
                if let loopPage {
                    UntetheredLoopStatusView(manager: untethered).tag(loopPage)
                }
            }
            .onChange(of: untethered.isActive) { _, isActive in
                if isActive || currentPage > statusPage { currentPage = statusPage }
            }
            // the pairing note is on the status page
            .onChange(of: untethered.isPairingSensor) { _, isPairing in
                if isPairing { currentPage = statusPage }
            }
            // the loop page goes with the session; stay on the status page, not on none
            .onChange(of: lastPage) { _, _ in
                if currentPage > lastPage { currentPage = lastPage }
            }
            .onChange(of: showsUntethered) { _, _ in
                if currentPage > lastPage { currentPage = lastPage }
            }
            .onAppear {
                /// Hard reset variables when main view appears
                /// Reset `bolusAmount` and `recommendedBolus` to ensure no stale / old value is set when user opens bolus input or meal combo the next time.
                state.bolusAmount = 0
                state.recommendedBolus = 0
            }
            .background(trioBackgroundColor)
            .tabViewStyle(.verticalPage)
            .digitalCrownRotation($currentPage.doubleBinding(), from: 0, through: Double(lastPage), by: 1)
            .modifier(ChartScrubEnd(isScrubbing: $isScrubbingChart, scrubSteps: $chartScrubSteps, currentPage: currentPage))
            .onChange(of: state.trend) { _, newTrend in
                withAnimation {
                    updateRotation(for: newTrend)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    VStack {
                        Image(systemName: "syringe.fill")
                            .font(.system(size: 15))
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
                            .font(.system(size: 15))
                            .foregroundStyle(Color.orange)

                        Text(isPhoneDataUnusable ? "--" : state.cob ?? "--")
                            .foregroundStyle(isPhoneDataUnusable ? Color.secondary : Color.white)
                            .frame(alignment: .trailing)
                            .minimumScaleFactor(0.5)
                    }.font(.caption2)
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    if currentPage == 0 {
                        // treatments, overrides and temp targets on the first page only; the chart gets the room
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
        }
        .ignoresSafeArea()
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
struct ChartScrubEnd: ViewModifier {
    @Binding var isScrubbing: Bool
    @Binding var scrubSteps: Double
    let currentPage: Int

    func body(content: Content) -> some View {
        content
            .onChange(of: scrubSteps) { _, steps in
                if isScrubbing, steps < 0 { stop() }
            }
            .onChange(of: currentPage) { _, page in
                if page != 1, isScrubbing { stop() }
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
