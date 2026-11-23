import SwiftUI
import WatchKit

/// The host calls behind the Trio on Watch screens. Fixtures leave them empty.
struct TrioOnWatchActions {
    var start: () async -> Void = {}
    var startWithoutPhone: () async -> Void = {}
    var end: () async -> Void = {}
    var acknowledgeStop: () async -> Void = {}
    var startFacts: () async -> WatchLoanStartFacts? = { nil }
    /// True once the pump confirmed it.
    var suspend: () async -> Bool = { true }
    var resume: () async -> Bool = { true }
    /// True once the stop was saved.
    var stopOverride: () async -> Bool = { true }
    var stopTempTarget: () async -> Bool = { true }
    /// Starts an override or temp target from a grant preset during the loan.
    var startOverride: (String) async -> Void = { _ in }
    var startTempTarget: (String) async -> Void = { _ in }
    var cancelBolus: () async -> Void = {}
    /// Acknowledges the pod alert with this notification id.
    var acknowledgePodAlert: (String) async -> Void = { _ in }
    /// Reads the pod while the status page is open, for its alerts.
    var readPod: () async -> Void = {}
    /// True once the faulted pod was deactivated.
    var deactivatePod: () async -> Bool = { true }
    /// The phone answered a live query; End is tried, not blocked on a flag.
    var phoneAnswers: () async -> Bool = { true }
    /// Forgets the last notice, so an old refusal doesn't show as the next hand-off's outcome.
    var clearNotice: () -> Void = {}

    @MainActor static var live: TrioOnWatchActions {
        guard let host = WatchLoanRuntime.host else { return TrioOnWatchActions() }
        return TrioOnWatchActions(
            start: { await host.startTapped() },
            startWithoutPhone: { await host.startWithoutPhone() },
            end: { await host.endTapped() },
            acknowledgeStop: { await host.stopAcknowledged() },
            startFacts: { await host.startFacts() },
            suspend: { await host.suspendInsulinConfirmed() },
            resume: { await host.resumeInsulinConfirmed() },
            stopOverride: { await host.stopAdjustmentConfirmed(override: true) },
            stopTempTarget: { await host.stopAdjustmentConfirmed(override: false) },
            startOverride: { await host.startOverride(presetName: $0) },
            startTempTarget: { await host.startTempTarget(presetName: $0) },
            cancelBolus: { await host.cancelBolus() },
            acknowledgePodAlert: { await host.acknowledgePodAlert(notificationID: $0) },
            readPod: { await host.readPodForStatusPage() },
            deactivatePod: { await host.deactivateFaultedPod() },
            phoneAnswers: { await host.phoneAnswers() },
            clearNotice: { host.lastAlert = nil }
        )
    }
}

/// Where the screens read the loan from: the host, or a screenshot fixture in debug builds.
@MainActor enum TrioOnWatchSource {
    static var status: TrioOnWatchStatus? {
        #if DEBUG
            if let fixture = TrioOnWatchFixture.current { return fixture.status }
        #endif
        guard let host = WatchLoanRuntime.host else { return nil }
        // the setting hides the page; a loan that still runs keeps it, so it can be ended here
        if !WatchState.shared.trioOnWatchEnabled, case .idle = host.state { return nil }
        return host.uiStatus()
    }

    static var actions: TrioOnWatchActions {
        #if DEBUG
            if TrioOnWatchFixture.current != nil { return TrioOnWatchActions() }
        #endif
        return .live
    }

    static var snoozedUntil: Date? {
        #if DEBUG
            if TrioOnWatchFixture.current != nil { return nil }
        #endif
        guard let host = WatchLoanRuntime.host, host.ownsGlucoseAlarms else { return nil }
        return host.snoozedUntil
    }

    static func carbsSaved(since date: Date) -> Bool {
        #if DEBUG
            if TrioOnWatchFixture.current != nil {
                if case let .bolus(_, carbsSaved) = TrioOnWatchFixture.current?.screen { return carbsSaved }
                if case .carbsSaved = TrioOnWatchFixture.current?.screen { return true }
            }
        #endif
        return WatchLoanRuntime.host?.carbsSaved(since: date) == true
    }

    /// The watch's recorded history over the last 6 hours for the history screen; empty without a host.
    static func history(since date: Date) -> TrioOnWatchHistory {
        WatchLoanRuntime.host?.history(since: date)
            ?? TrioOnWatchHistory(glucose: [], carbs: [], insulin: [], units: .mgdL)
    }
}

enum HandOffKind: Equatable {
    case start
    case end
}

enum HandOffStage: Equatable {
    case working(title: String, detail: String)
    case succeeded(String)
    case failed(String)

    static func stage(
        _ kind: HandOffKind,
        status: TrioOnWatchStatus,
        askingPhone: Bool = false,
        phoneSilent: Bool = false
    ) -> HandOffStage {
        if phoneSilent {
            return .failed(String(
                localized: "Your iPhone didn't answer. Unlock it or open Trio, then try again. Your watch stays in control until then.",
                comment: "Watch End refused: the phone didn't answer"
            ))
        }
        if askingPhone {
            return .working(
                title: String(localized: "Waking your iPhone…", comment: "Watch End: waiting for the phone to answer"),
                detail: String(
                    localized: "Keep your iPhone close. If it's locked, unlock it.",
                    comment: "Watch End: waiting for the phone to answer"
                )
            )
        }
        if let alert = status.lastAlert, let text = TrioOnWatchStatus.outcomeText(alert) {
            return .failed(text)
        }
        if case let .stopped(reason) = status.phase {
            return .failed(TrioOnWatchStatus.stopReason(reason))
        }
        switch (kind, status.phase) {
        case (.start, .inControl):
            return .succeeded(String(localized: "Your watch is in control.", comment: "Watch Start succeeded"))
        case (.start, .waitingForReading):
            return .working(
                title: String(
                    localized: "Waiting for your watch's first sensor reading…",
                    comment: "Watch Start, before the first reading"
                ),
                detail: TrioOnWatchStatus.notGivingInsulinYet + " " + String(
                    localized: "Keep Trio open. Your watch takes over once it gets a reading.",
                    comment: "Watch Start, before the first reading (V3-8)"
                )
            )
        case (.start, _):
            return .working(
                title: String(localized: "Starting Trio on Watch…", comment: "Watch Start in progress"),
                detail: String(localized: "Keep your iPhone close.", comment: "Watch hand-off in progress")
            )
        case (.end, .phone):
            return .succeeded(String(localized: "Your iPhone is in control.", comment: "Watch End succeeded"))
        case (.end, _):
            return .working(
                title: String(localized: "Ending Trio on Watch…", comment: "Watch End in progress"),
                detail: String(localized: "Keep your iPhone close.", comment: "Watch hand-off in progress")
            )
        }
    }
}

/// W2: the one place for who is in control, the pump and sensor, and Start or End.
struct TrioOnWatchStatusView: View {
    let status: TrioOnWatchStatus
    let now: Date
    let actions: TrioOnWatchActions
    /// Screenshot harness only.
    var presentsEndConfirmation = false
    var scrollTo: String?

    @State private var showingStart = false
    @State private var showingStartWithoutPhone = false
    @State private var showingEndConfirmation = false
    @State private var showingSuspendConfirmation = false
    @State private var showingCancelBolusConfirmation = false
    @State private var showingDeactivatePod = false
    @State private var handOff: HandOffKind?
    @State private var endPhoneSilent = false
    @State private var endAskingPhone = false
    @State private var result: ActionResult?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    let header = status.header
                    Label {
                        Text(header.title).font(.headline)
                    } icon: {
                        if let symbol = header.symbol {
                            Image(systemName: symbol).foregroundStyle(header.tint)
                        }
                    }
                    .foregroundStyle(header.tint)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)

                    if status.phase == .starting || status.phase == .ending {
                        ProgressView()
                    }
                }
                .trioRow()

                ForEach(status.podAlerts) { alert in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(alert.title, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.orange)
                        Text(alert.body).font(.footnote)
                        // a faulted pod takes no acknowledgement: it alarms until deactivated
                        if !status.podFaulted {
                            Button(String(localized: "Acknowledge", comment: "Watch: acknowledge a pod alert")) {
                                Task { await actions.acknowledgePodAlert(alert.id) }
                            }
                            .tint(.orange)
                        }
                    }
                    .trioRow()
                }

                if status.canDeactivatePod {
                    Button(role: .destructive) {
                        showingDeactivatePod = true
                    } label: {
                        Label(
                            String(localized: "Deactivate Pod", comment: "Watch: deactivate the faulted pod"),
                            systemImage: "xmark.octagon"
                        )
                    }
                    .tint(.loopRed)
                    .trioRow()
                }

                ForEach(status.rows(now: now)) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(row.title, systemImage: row.symbol)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(row.tint)
                        ForEach(row.lines, id: \.self) { line in
                            Text(line).font(.footnote)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.accessibilityLabel)
                    .trioRow()
                }

                if status.isLoanActive {
                    historyLink
                        .trioRow()
                }

                if status.isInControl, status.bolusInProgress != nil {
                    cancelBolusControl
                }

                if status.isInControl {
                    insulinControls
                }

                Section {
                    primaryButton.id("actions")
                } footer: {
                    Text(status.footer())
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }

                if status.primaryAction == .start, let copyMadeAt = status.copyMadeAt {
                    Section {
                        Button(String(localized: "Start Without iPhone", comment: "Watch: start from the phone's copy")) {
                            showingStartWithoutPhone = true
                        }
                    } footer: {
                        Text(String(
                            localized: "From your iPhone's settings of \(copyMadeAt.formatted(date: .omitted, time: .shortened)).",
                            comment: "Watch: when the copy for a start without the iPhone was made"
                        ))
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .onAppear {
                if presentsEndConfirmation { showingEndConfirmation = true }
                if let scrollTo { proxy.scrollTo(scrollTo, anchor: .top) }
            }
            .task { await actions.readPod() }
        }
        .navigationTitle(String(localized: "Trio on Watch", comment: "Watch status page title"))
        .sheet(isPresented: $showingStart) {
            StartTrioOnWatchView(now: now, loadFacts: actions.startFacts) {
                showingStart = false
                endPhoneSilent = false
                actions.clearNotice()
                handOff = .start
                Task { await actions.start() }
            }
        }
        .fullScreenCover(item: Binding(
            get: { handOff.map(HandOffItem.init) },
            set: { handOff = $0?.kind }
        )) { item in
            HandOffView(kind: item.kind, askingPhone: endAskingPhone, phoneSilent: endPhoneSilent) {
                handOff = nil
                actions.clearNotice()
            }
        }
        .confirmationDialog(
            String(localized: "Start Without iPhone?", comment: "Watch: confirm the start from the phone's copy"),
            isPresented: $showingStartWithoutPhone,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Start", comment: "Watch: confirm the start without the iPhone")) {
                actions.clearNotice()
                handOff = .start
                Task { await actions.startWithoutPhone() }
            }
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {}
        } message: {
            Text(String(
                localized: "Your watch takes the pod with your iPhone's last settings. It first counts any insulin the iPhone gave since then. When your iPhone is back, the watch keeps the pod until you end.",
                comment: "Watch: start without the iPhone confirmation message"
            ))
        }
        .fullScreenCover(item: $result) { result in
            ActionResultView(result: result) { self.result = nil }
        }
        .confirmationDialog(
            String(localized: "Deactivate your pod?", comment: "Watch: confirm deactivating the faulted pod"),
            isPresented: $showingDeactivatePod,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Deactivate", comment: "Watch: confirm deactivating the pod"), role: .destructive) {
                Task {
                    result = await actions.deactivatePod()
                        ? .success(String(
                            localized: "Pod deactivated. Pair a new pod on your iPhone.",
                            comment: "Watch: faulted pod deactivated"
                        ))
                        : .failure(String(
                            localized: "Your pod didn't answer. Keep your watch close to it and try again.",
                            comment: "Watch: deactivating the pod failed"
                        ))
                }
            }
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {}
        } message: {
            Text(String(
                localized: "Your pod has stopped and alarms until it is deactivated. Remove it afterwards and pair a new pod on your iPhone.",
                comment: "Watch: deactivate faulted pod confirmation message"
            ))
        }
        .confirmationDialog(
            String(localized: "End Trio on Watch?", comment: "Watch End confirmation title"),
            isPresented: $showingEndConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "End", comment: "Watch End confirmation button")) {
                // tried: the phone must answer before the watch lets go (G-15)
                endPhoneSilent = false
                actions.clearNotice()
                handOff = .end
                endAskingPhone = true
                Task {
                    let answered = await actions.phoneAnswers()
                    endAskingPhone = false
                    if answered {
                        await actions.end()
                    } else {
                        endPhoneSilent = true
                    }
                }
            }
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {}
        } message: {
            Text(String(localized: "Your iPhone takes back your pump and sensor.", comment: "Watch End confirmation message"))
        }
    }

    @ViewBuilder private var historyLink: some View {
        NavigationLink {
            TrioOnWatchHistoryView()
        } label: {
            Label(
                String(localized: "History", comment: "Watch: link to the recorded history"),
                systemImage: "list.bullet"
            )
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch status.primaryAction {
        case .start:
            Button(String(localized: "Start Trio on Watch", comment: "Watch Start button")) {
                showingStart = true
            }
            .tint(.insulin)
        case .end:
            Button(String(localized: "End Trio on Watch", comment: "Watch End button")) {
                showingEndConfirmation = true
            }
        case .acknowledgeStop:
            Button(String(localized: "Done", comment: "Watch: dismiss the stopped state")) {
                Task { await actions.acknowledgeStop() }
            }
            .accessibilityHint(Text(String(
                localized: "Ends Trio on Watch on this watch and stops its glucose alarms",
                comment: "Watch accessibility hint for Done when stopped"
            )))
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var cancelBolusControl: some View {
        Section {
            Button(role: .destructive) {
                showingCancelBolusConfirmation = true
            } label: {
                Label(
                    String(localized: "Cancel Bolus", comment: "Watch button to cancel a running bolus"),
                    systemImage: "xmark.app"
                )
            }
            .tint(.loopRed)
            .confirmationDialog(
                String(localized: "Cancel the running bolus?", comment: "Watch cancel-bolus confirmation title"),
                isPresented: $showingCancelBolusConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Cancel Bolus", comment: "Watch cancel-bolus confirm button"), role: .destructive) {
                    Task { await actions.cancelBolus() }
                }
                Button(String(localized: "Keep Delivering", comment: "Watch: dismiss the cancel-bolus dialog"), role: .cancel) {}
            } message: {
                Text(String(
                    localized: "Your pump stops this bolus. Insulin already delivered still counts.",
                    comment: "Watch cancel-bolus confirmation message"
                ))
            }
        }
        .trioRow()
    }

    @ViewBuilder private var insulinControls: some View {
        Section {
            if status.insulinSuspended {
                Button(String(localized: "Resume Insulin", comment: "Watch resume insulin button")) {
                    Task {
                        result = await actions.resume()
                            ? .success(String(localized: "Insulin resumed.", comment: "Watch: resume confirmed by the pump"))
                            : .failure(String(
                                localized: "Your pump didn't confirm. Insulin may still be suspended.",
                                comment: "Watch: resume not confirmed"
                            ))
                    }
                }
                .tint(.insulin)
            } else {
                Button(String(localized: "Suspend Insulin", comment: "Watch suspend insulin button")) {
                    showingSuspendConfirmation = true
                }
                .confirmationDialog(
                    String(localized: "Suspend insulin?", comment: "Watch suspend confirmation title"),
                    isPresented: $showingSuspendConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Suspend", comment: "Watch suspend confirmation button"), role: .destructive) {
                        Task {
                            result = await actions.suspend()
                                ? .success(String(
                                    localized: "Insulin suspended. Trio reminds you every 30 minutes, for up to 4 hours.",
                                    comment: "Watch: suspend confirmed by the pump"
                                ))
                                : .failure(String(
                                    localized: "Your pump didn't confirm. Insulin may not be suspended.",
                                    comment: "Watch: suspend not confirmed"
                                ))
                        }
                    }
                    Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {}
                } message: {
                    Text(String(
                        localized: "Your pump stops all insulin, including basal, until you resume. Trio doesn't loop while insulin is suspended.",
                        comment: "Watch suspend confirmation message"
                    ))
                }
            }
        }
    }
}

private struct HandOffItem: Identifiable {
    let kind: HandOffKind
    var id: String { kind == .start ? "start" : "end" }
}

/// W3: consent with the facts that matter, before the phone releases the pump.
struct StartTrioOnWatchView: View {
    let now: Date
    let loadFacts: () async -> WatchLoanStartFacts?
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var facts: [TrioOnWatchStatus.Fact]?

    var body: some View {
        List {
            Text(String(localized: "Start Trio on Watch?", comment: "Watch Start sheet title"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if let facts {
                ForEach(facts) { fact in
                    Text(fact.text)
                        .font(.footnote)
                        .foregroundStyle(fact.isWarning ? Color.orange : Color.primary)
                }
            } else {
                HStack {
                    ProgressView()
                    Text(String(localized: "Asking your iPhone…", comment: "Watch Start sheet while loading facts"))
                        .font(.footnote)
                }
                .accessibilityElement(children: .combine)
            }

            Button(String(localized: "Start", comment: "Watch Start sheet confirm button"), action: onStart)
                .tint(.insulin)
                .disabled(facts == nil)
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) { dismiss() }
        }
        .task {
            facts = TrioOnWatchStatus.startFacts(await loadFacts(), now: now)
        }
    }
}

/// W4: a hand-off in progress, then its result. Success closes after 2 s; a failure stays until OK (G-4).
struct HandOffView: View {
    let kind: HandOffKind
    var askingPhone = false
    var phoneSilent = false
    let onClose: () -> Void

    var body: some View {
        let stage = HandOffStage.stage(
            kind,
            status: TrioOnWatchSource.status ?? TrioOnWatchStatus(),
            askingPhone: askingPhone,
            phoneSilent: phoneSilent
        )
        ScrollView {
            VStack(spacing: 8) {
                switch stage {
                case let .working(title, detail):
                    ProgressView()
                    Text(title).font(.headline).multilineTextAlignment(.center)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                case let .succeeded(text):
                    Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(Color.loopGreen)
                        .accessibilityHidden(true)
                    Text(text).font(.headline).multilineTextAlignment(.center)
                case let .failed(text):
                    Image(systemName: "xmark").font(.title2).foregroundStyle(Color.loopRed)
                        .accessibilityHidden(true)
                    Text(text).font(.footnote).multilineTextAlignment(.center)
                    Button(String(localized: "OK", comment: "Dismiss button"), action: onClose)
                }
            }
            .padding()
            .accessibilityElement(children: .combine)
        }
        .toolbar(.hidden)
        .task(id: stage) {
            switch stage {
            case .succeeded:
                WKInterfaceDevice.current().play(kind == .start ? .start : .stop)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { onClose() }
            case .failed:
                WKInterfaceDevice.current().play(.failure)
            case .working:
                break
            }
        }
    }
}

/// The outcome of a pump or adjustment action. Success closes after 2 s; a failure stays until OK (G-4).
enum ActionResult: Identifiable, Equatable {
    case success(String)
    case failure(String)

    var id: String {
        switch self {
        case let .failure(text),
             let .success(text): return text
        }
    }
}

struct ActionResultView: View {
    let result: ActionResult
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                switch result {
                case let .success(text):
                    Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(Color.loopGreen)
                        .accessibilityHidden(true)
                    Text(text).multilineTextAlignment(.center)
                case let .failure(text):
                    Image(systemName: "xmark").font(.title2).foregroundStyle(Color.loopRed)
                        .accessibilityHidden(true)
                    Text(text).font(.footnote).multilineTextAlignment(.center)
                    Button(String(localized: "OK", comment: "Dismiss button"), action: onClose)
                }
            }
            .padding()
            .accessibilityElement(children: .combine)
        }
        .toolbar(.hidden)
        .task {
            if case .success = result {
                WKInterfaceDevice.current().play(.success)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { onClose() }
            } else {
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }
}

private extension View {
    /// A Trio-styled list row: a solid dark card (matching the Suspend/Resume buttons) with horizontal insets, so the
    /// rows sit inset on the Trio gradient instead of edge to edge. A fixed dark color, so it never flips to the
    /// light (white) appearance of `Color.chart`.
    func trioRow() -> some View {
        listRowBackground(RoundedRectangle(cornerRadius: 10).fill(Color.trioCard))
            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
    }
}

extension Color {
    /// The dark card behind watch list rows; the dark value of the Chart color, fixed so it never renders white.
    static let trioCard = Color(red: 0.13, green: 0.13, blue: 0.18)
}
