import Charts
import SwiftUI
import WatchKit

struct TrioMainWatchView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = WatchState.shared

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

    /// Ticks so staleness shows without new data.
    @State private var now = Date()
    private static let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// The bubble goes stale by reading age.
    private var isReadingDated: Bool {
        guard let newestReading = state.glucoseValues.last?.date else { return isWatchStateDated }
        return now.timeIntervalSince(newestReading) > 6 * 60
    }

    var isWatchStateDated: Bool {
        // If `lastWatchStateUpdate` is nil, treat as "dated"
        guard let lastUpdateTimestamp = state.lastWatchStateUpdate else { return true }
        // Return true if last update older than 5 min, so 1 loop cycle
        return now.timeIntervalSince1970 - lastUpdateTimestamp > 5 * 60
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
        return NavigationStack(path: $navigationPath) {
            TabView(selection: $currentPage) {
                // Page 1: Current glucose trend in "BG bobble"
                ZStack {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        GlucoseTrendView(
                            state: state,
                            rotationDegrees: rotationDegrees,
                            isWatchStateDated: isReadingDated || isSessionUnreachable,
                            loan: loan,
                            now: context.date,
                            onControlLineTap: { currentPage = 3 }
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
                    glucoseValues: state.glucoseValues
                )
                .tag(1)

                // Page 3: Alarm snooze
                AlarmSnoozeView(state: state)
                    .tag(2)

                // Page 4: Trio on Watch
                if let loan {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        TrioOnWatchStatusView(status: loan, now: context.date, actions: loanActions, scrollTo: debugScrollTo)
                    }
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
                // the status page has its own actions; the main page's bar would cover them
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

                        Button {
                            showingTreatmentMenuSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(Color.bgDarkerDarkBlue)
                        }
                        .controlSize(.large)
                        .buttonStyle(WatchOSButtonStyle(deviceType: state.deviceType))
                        .disabled(loanActive ? loanBlocksTreatments : isWatchStateDated || isSessionUnreachable)
                        .accessibilityLabel(Text(String(
                            localized: "Add treatment",
                            comment: "Watch accessibility: add treatment button"
                        )))

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
                    LoanAdjustmentSheet(kind: .override, adjustment: loan.override, stop: loanActions.stopOverride)
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
                    LoanAdjustmentSheet(kind: .tempTarget, adjustment: loan.tempTarget, stop: loanActions.stopTempTarget)
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
                if newPhase == .active { now = Date() }
                // An entry left for more than 2 min (wrist down, app in the background) is
                // cleared and the input screens are closed, so a stale amount can't be confirmed
                if newPhase == .active, state.expireStaleEntry() {
                    navigationPath = NavigationPath()
                }
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
                return AnyView(LoanAdjustmentSheet(kind: .override, adjustment: status.override, stop: { true }))
            }
        }
    #endif

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
