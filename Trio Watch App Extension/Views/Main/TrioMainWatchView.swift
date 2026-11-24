import Charts
import SwiftUI
import WatchKit

struct TrioMainWatchView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = WatchState.shared

    // misc
    @State private var currentPage: Int = 0
    /// Scrubbing the glucose chart with the crown (see GlucoseChartView). Owned here, like the page crown.
    @State private var isScrubbingChart = false
    @State private var chartScrubSteps = 0.0
    /// The pages' crown focus; the chart takes focus while scrubbing and this restores it afterwards.
    @FocusState private var pagesFocused: Bool
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
    /// A failed or unconfirmed bolus to show as a message (there is no separate progress page any more).
    @State private var bolusError: LoanBolusRequest?

    /// Trio on Watch; nil in builds without it, so the tethered remote stays as it is.
    private var loanStatus: TrioOnWatchStatus? { TrioOnWatchSource.status }
    private var loanActions: TrioOnWatchActions { TrioOnWatchSource.actions }

    private var lastPage: Int { loanStatus == nil ? 2 : 3 }

    private var debugScrollTo: String? {
        #if DEBUG
            return TrioOnWatchFixture.current?.scrollTo
        #else
            return nil
        #endif
    }

    /// Ticks the bubble's staleness and the switch to the watch's own readings.
    @State private var now = Date()
    private static let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// The bubble is dated by its newest reading, the watch's own included; without readings, by the last update.
    private var isReadingDated: Bool {
        guard let newestReading = state.glucoseValues.last?.date else { return isWatchStateDated }
        return now.timeIntervalSince(newestReading) > 6 * 60
    }

    /// IOB, COB and the buttons go by the phone's last update, so a CGM gap doesn't block treatments.
    var isWatchStateDated: Bool {
        guard let lastUpdateTimestamp = state.lastWatchStateUpdate else { return true }
        // Return true if last update older than 5 min, so 1 loop cycle
        return now.timeIntervalSince1970 - lastUpdateTimestamp > 5 * 60
    }

    /// Left of the bubble: the phone while it syncs; the watch with waves while its link to the sensor is up; the
    /// watch alone while the bubble shows a fresh reading of its own, not merely a sensor it was given. The watch is
    /// yellow while the sensor needs a look (warmup, grace period, an unreliable reading), red once it has failed or
    /// expired, and then always shown.
    private var linkIndicator: (symbol: String, waves: Bool, tint: Color)? {
        // While a loan runs, the control line under the bubble already shows the watch icon; a second one
        // beside the bubble is redundant. The syncing wave (phone handing data over) still shows.
        if !state.showSyncingAnimation, loanStatus?.isLoanActive == true { return nil }
        if state.showSyncingAnimation { return ("iphone.radiowaves.left.and.right", true, .primary) }
        let host = WatchCGMHost.shared
        let tint = host.sensorHasEnded ? Color.loopRed : host.hasSensorProblem ? Color.yellow : .primary
        if host.isTalkingToSensor { return ("applewatch.radiowaves.left.and.right", true, tint) }
        if state.newestReadingIsOwn || host.hasSensorProblem { return ("applewatch", false, tint) }
        return nil
    }

    /// The phone sends its state after each loop, so it is often a few seconds past 5 min old: the loop's age is
    /// counted on for two cycles before it counts as unknown.
    private var isPhoneStateDated: Bool {
        guard let lastUpdate = state.lastWatchStateUpdate else { return true }
        return now.timeIntervalSince1970 - lastUpdate > 10 * 60
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
        if let loan = loanStatus, loan.isLoanActive { return loan.tempTarget != nil }
        return isAdjustmentActive(for: state.tempTargetPresets) { $0.isEnabled }
    }

    private var isOverrideActive: Bool {
        if let loan = loanStatus, loan.isLoanActive { return loan.override != nil }
        return isAdjustmentActive(for: state.overridePresets) { $0.isEnabled }
    }

    private var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        #if DEBUG
            if let fixture = TrioOnWatchFixture.current, let screen = fixtureScreen(fixture) {
                screen
            } else {
                mainBody
            }
        #else
            mainBody
        #endif
    }

    private var mainBody: some View {
        let loan = loanStatus
        let loanActive = loan?.isLoanActive == true
        let loanBlocksTreatments = loanActive && loan?.isInControl != true
        let isBolusRunning = loan?.bolusInProgress != nil || state.phoneBolusProgress != nil
        return NavigationStack(path: $navigationPath) {
            TabView(selection: $currentPage) {
                // Page 1: Current glucose trend in "BG bobble"
                ZStack {
                    GlucoseTrendView(
                        state: state,
                        rotationDegrees: rotationDegrees,
                        isWatchStateDated: isReadingDated,
                        sensorStateText: WatchCGMHost.shared.sensorStateText,
                        isPhoneStateDated: isPhoneStateDated,
                        now: now,
                        loan: loan,
                        onControlLineTap: { currentPage = 3 }
                    )

                    if let linkIndicator {
                        Image(systemName: linkIndicator.symbol)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(linkIndicator.tint, Color.tabBar, Color.clear)
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: linkIndicator.waves)
                            .position(
                                x: 20,
                                y: (WKInterfaceDevice.current().screenBounds.height / 4) -
                                    7 // Font .body == 14, so half of default size for the SF Symbol image
                            )
                    }
                }
                .containerBackground(trioBackgroundColor, for: .tabView)
                .tag(0)

                // Page 2: Glucose chart
                // in watch mode the phone sends no new readings: the graph shows the watch's
                GlucoseChartView(
                    state: state,
                    glucoseValues: loanActive ? loan?
                        .chartValues(phone: state.glucoseValues, color: state.glucoseRange.color) ?? [] : state.glucoseValues,
                    isScrubbing: $isScrubbingChart,
                    scrubSteps: $chartScrubSteps,
                    forecast: loanActive ? loan?.chartForecast(cone: state.isForecastCone) : nil
                )
                .containerBackground(trioBackgroundColor, for: .tabView)
                .tag(1)

                // Page 3: Alarm snooze
                AlarmSnoozeView(state: state)
                    .containerBackground(trioBackgroundColor, for: .tabView)
                    .tag(2)

                // Page 4: Trio on Watch
                if let loan {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        TrioOnWatchStatusView(status: loan, now: context.date, actions: loanActions, scrollTo: debugScrollTo)
                    }
                    .containerBackground(trioBackgroundColor, for: .tabView)
                    .tag(3)
                }
            }
            .onAppear {
                #if DEBUG
                    if case .status = TrioOnWatchFixture.current?.screen { currentPage = 3 }
                    if TrioOnWatchFixture.current?.tetheredFresh == true {
                        state.lastWatchStateUpdate = Date().timeIntervalSince1970
                        state.currentGlucose = "112"
                        state.delta = "+3"
                        state.trend = "Flat"
                        state.lastLoopTime = "2 min"
                        state.iob = "1,25"
                        state.cob = "12"
                    }
                #endif
                /// Hard reset variables when main view appears
                /// Reset `bolusAmount` and `recommendedBolus` to ensure no stale / old value is set when user opens bolus input or meal combo the next time.
                state.bolusAmount = 0
                state.recommendedBolus = 0
                // the pages own the crown by default, so a turn pages right away
                if !isScrubbingChart { pagesFocused = true }
                // Like the phone's Treatments view, every new bolus starts without reduced or super bolus.
                state.useReducedBolus = false
                state.useSuperBolus = false
            }
            // each page draws the phone's gradient: a vertical page view covers anything behind it
            .tabViewStyle(.verticalPage)
            // The pages own the crown, except while the chart scrubs; after scrubbing the focus returns here so the
            // crown turns pages again (otherwise it is left without a target — nightscout/LoopFollow scrub pattern).
            .focusable(!isScrubbingChart)
            .focused($pagesFocused)
            .digitalCrownRotation($currentPage.doubleBinding(), from: 0, through: Double(lastPage), by: 1)
            .modifier(ChartScrubEnd(
                isScrubbing: $isScrubbingChart,
                scrubSteps: $chartScrubSteps,
                currentPage: currentPage,
                chartPage: 1
            ))
            .onChange(of: isScrubbingChart) { _, scrubbing in
                // scrubbing over: hand the crown back to the pages on the next pass, once the chart has let go
                guard !scrubbing else { return }
                DispatchQueue.main.async { pagesFocused = true }
            }
            .onChange(of: state.trend) { _, newTrend in
                withAnimation {
                    updateRotation(for: newTrend)
                }
            }
            // No separate bolus progress page: show a message only when a bolus fails or is unconfirmed (G-3).
            .onChange(of: loan?.bolus) { _, newBolus in
                switch newBolus {
                case .failed,
                     .uncertain:
                    bolusError = LoanBolusRequest(units: 0, withCarbs: false, requestedAt: Date())
                default:
                    break
                }
            }
            .fullScreenCover(item: $bolusError) { request in
                NavigationStack {
                    LoanBolusProgressView(
                        navigationPath: .constant(NavigationPath()),
                        request: request,
                        actions: loanActions,
                        onClose: { bolusError = nil }
                    )
                }
            }
            .toolbar {
                // the status page has its own actions
                if currentPage != 3 {
                    ToolbarItem(placement: .topBarLeading) {
                        VStack {
                            Image(systemName: "syringe.fill")
                                .foregroundStyle(Color.insulin)

                            if let loan, loanActive {
                                Text(loan.mainValues(now: Date()).iob)
                                    .accessibilityLabel(Text(String(
                                        localized: "Insulin on board, \(loan.mainValues(now: Date()).iob)",
                                        comment: "Watch accessibility: insulin on board with unit"
                                    )))
                            } else {
                                Text(isWatchStateDated || isSessionUnreachable ? "--" : state.iob ?? "--")
                                    .foregroundStyle(isWatchStateDated ? Color.secondary : Color.white)
                                    .frame(alignment: .leading)
                                    .minimumScaleFactor(0.5)
                            }
                        }.font(.caption2)
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        VStack {
                            Image(systemName: "fork.knife")
                                .foregroundStyle(Color.orange)

                            if let loan, loanActive {
                                Text(loan.mainValues(now: Date()).cob)
                                    .accessibilityLabel(Text(String(
                                        localized: "Carbs on board, \(loan.mainValues(now: Date()).cob)",
                                        comment: "Watch accessibility: carbs on board with unit"
                                    )))
                            } else {
                                Text(isWatchStateDated || isSessionUnreachable ? "--" : state.cob ?? "--")
                                    .foregroundStyle(isWatchStateDated || isSessionUnreachable ? Color.secondary : Color.white)
                                    .frame(alignment: .trailing)
                                    .minimumScaleFactor(0.5)
                            }
                        }.font(.caption2)
                    }

                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            showingOverrideSheet = true
                        } label: {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .foregroundStyle(Color.primary, isOverrideActive ? Color.primary : Color.purple)
                        }
                        .tint(isOverrideActive ? Color.purple : nil)
                        .disabled(loanActive ? loanBlocksTreatments : isWatchStateDated || isSessionUnreachable)
                        .accessibilityLabel(Text(String(
                            localized: "Overrides",
                            comment: "Watch accessibility: overrides button"
                        )))

                        // while the watch's pump or the phone delivers a bolus, the button stops it (icon switches to a stop square)
                        Button {
                            if loan?.bolusInProgress != nil {
                                Task { await loanActions.cancelBolus() }
                            } else if state.phoneBolusProgress != nil {
                                state.sendCancelBolusRequest()
                            } else {
                                showingTreatmentMenuSheet = true
                            }
                        } label: {
                            Image(systemName: isBolusRunning ? "square.fill" : "plus")
                                .foregroundStyle(Color.bgDarkerDarkBlue)
                        }
                        .controlSize(.large)
                        .buttonStyle(WatchOSButtonStyle(deviceType: state.deviceType))
                        .overlay {
                            // the running bolus fills a ring around the button, instead of a separate page
                            if let window = loan?.bolusInProgress {
                                BolusProgressRing(window: window)
                            } else if let progress = state.phoneBolusProgress {
                                BolusProgressRing(window: nil, progress: progress)
                            }
                        }
                        .disabled(
                            !isBolusRunning &&
                                (loanActive ? loanBlocksTreatments : isWatchStateDated || isSessionUnreachable)
                        )
                        .accessibilityLabel(Text(
                            isBolusRunning
                                ? String(localized: "Cancel bolus", comment: "Watch accessibility: cancel the running bolus")
                                : String(localized: "Add treatment", comment: "Watch accessibility: add treatment button")
                        ))

                        Button {
                            showingTempTargetSheet = true
                        } label: {
                            Image(systemName: "target")
                                .foregroundStyle(isTempTargetActive ? Color.primary : Color.loopGreen.opacity(0.75))
                        }
                        .tint(isTempTargetActive ? Color.loopGreen.opacity(0.75) : nil)
                        .disabled(loanActive ? loanBlocksTreatments : isWatchStateDated || isSessionUnreachable)
                        .accessibilityLabel(Text(String(
                            localized: "Temp targets",
                            comment: "Watch accessibility: temp targets button"
                        )))
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
                if let loan, loanActive {
                    LoanAdjustmentSheet(
                        kind: .override,
                        adjustment: loan.override,
                        stop: loanActions.stopOverride,
                        presets: loan.isInControl ? loan.overridePresets : [],
                        start: loanActions.startOverride
                    )
                } else {
                    OverridePresetsView(
                        state: state,
                        overridePresets: state.overridePresets
                    ) {
                        showingOverrideSheet = false
                        navigationPath.append(NavigationDestinations.acknowledgmentPending)
                    }
                }
            }
            .sheet(isPresented: $showingTempTargetSheet) {
                if let loan, loanActive {
                    LoanAdjustmentSheet(
                        kind: .tempTarget,
                        adjustment: loan.tempTarget,
                        stop: loanActions.stopTempTarget,
                        presets: loan.isInControl ? loan.tempTargetPresets : [],
                        start: loanActions.startTempTarget
                    )
                } else {
                    TempTargetPresetsView(
                        state: state,
                        tempTargetPresets: state.tempTargetPresets
                    ) {
                        showingTempTargetSheet = false
                        navigationPath.append(NavigationDestinations.acknowledgmentPending)
                    }
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
            .navigationDestination(for: LoanBolusRequest.self) { request in
                LoanBolusProgressView(navigationPath: $navigationPath, request: request, actions: loanActions)
            }
            .navigationDestination(for: LoanCarbsSaved.self) { saved in
                LoanCarbsSavedView(navigationPath: $navigationPath, saved: saved)
            }
            .onChange(of: navigationPath) { _, newPath in
                if newPath.isEmpty {
                    // Reset conditional view navigation when returning to root view
                    continueToBolus = false
                    // Back on the main screen, so no entry is in progress
                    state.clearEntry()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                // the ages tick every 30 s, and not at all while the app is in the background
                if newPhase == .active { now = Date() }
                // An entry left for more than 2 min (wrist down, app in the background) is
                // cleared and the input screens are closed, so a stale amount can't be confirmed
                if newPhase == .active, state.expireStaleEntry() {
                    navigationPath = NavigationPath()
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
        .onReceive(Self.ticker) { now = $0 }
    }

    #if DEBUG
        /// Screens the harness shows on their own; nil for the main and status pages.
        private func fixtureScreen(_ fixture: TrioOnWatchFixture) -> AnyView? {
            let status = fixture.status
            switch fixture.screen {
            case .main,
                 .status:
                return nil
            case let .start(facts):
                return AnyView(StartTrioOnWatchView(now: Date(), loadFacts: { facts }, onStart: {}))
            case let .handOff(kind):
                return AnyView(HandOffView(kind: kind, onClose: {}))
            case .endConfirmation:
                return AnyView(NavigationStack {
                    TrioOnWatchStatusView(
                        status: status,
                        now: Date(),
                        actions: TrioOnWatchActions(),
                        presentsEndConfirmation: true
                    )
                })
            case let .bolus(units, carbsSaved):
                return AnyView(LoanBolusProgressView(
                    navigationPath: .constant(NavigationPath()),
                    request: LoanBolusRequest(units: units, withCarbs: carbsSaved, requestedAt: Date()),
                    actions: TrioOnWatchActions()
                ))
            case .doses:
                return AnyView(NavigationStack { RecentDosesView(doses: status.recentDoses) })
            case .carbsSaved:
                return AnyView(LoanCarbsSavedView(navigationPath: .constant(NavigationPath()), saved: LoanCarbsSaved(grams: 30)))
            case .adjustment:
                return AnyView(LoanAdjustmentSheet(
                    kind: .override,
                    adjustment: status.override,
                    stop: { true },
                    presets: status.overridePresets
                ))
            }
        }
    #endif

    private func updateRotation(for trend: String?) {
        rotationDegrees = GlucoseTrendView.degrees(for: trend)
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

        continueToBolus = true
        var path = NavigationPath()
        path.append(NavigationDestinations.carbsInput)
        navigationPath = path
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
/// From Kristin Kandschur's feature/untethered-plus.
struct ChartScrubEnd: ViewModifier {
    @Binding var isScrubbing: Bool
    @Binding var scrubSteps: Double
    let currentPage: Int
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

/// The running bolus as a ring around the treatment button that fills as it is delivered, by the clock, as the pump
/// counts a bolus done (ported from feat/watch-loop-5/5's BolusProgressRing). Hit testing off, so the button works.
struct BolusProgressRing: View {
    let window: DateInterval?
    /// The phone's reported progress, used instead of the clock.
    var progress: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let progress = self.progress ?? window
                .map { min(1, max(0, context.date.timeIntervalSince($0.start) / max($0.duration, 1))) } ?? 0
            ZStack {
                Circle().stroke(Color.tabBar.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.tabBar, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
            }
            .padding(-4)
        }
        .allowsHitTesting(false)
    }
}
