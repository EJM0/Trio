import SwiftUI
import WatchKit

/// The host while it holds the pump and the watch's own first reading has arrived; nil otherwise.
@MainActor enum LoanTreatments {
    static var host: WatchLoanHost? {
        guard let host = WatchLoanRuntime.host, host.isInControl else { return nil }
        return host
    }

    /// Rounded down to the pump's increment, as the input screen shows it.
    static func units(_ amount: Double, increment: Decimal) -> Decimal {
        guard increment > 0 else { return 0 }
        var steps = Decimal(amount) / increment + Decimal(string: "0.000001")!
        var whole = Decimal()
        NSDecimalRound(&whole, &steps, 0, .down)
        return whole * increment
    }
}

/// A bolus sent while the watch holds the pump, for the navigation stack.
struct LoanBolusRequest: Hashable, Identifiable {
    var units: Decimal
    var withCarbs: Bool
    var requestedAt: Date
    var id: Date { requestedAt }
}

/// Carbs saved on the watch, for the navigation stack.
struct LoanCarbsSaved: Hashable {
    var grams: Int
    var requestedAt = Date()
}

/// W7: what the pump is doing with this bolus. Failed, cancelled and unconfirmed results stay until OK (G-4).
struct LoanBolusProgressView: View {
    @Binding var navigationPath: NavigationPath
    let request: LoanBolusRequest
    let actions: TrioOnWatchActions
    /// When shown as a cover (bolus failed), closing dismisses the cover instead of popping the stack.
    var onClose: (() -> Void)?

    @State private var showingDoses = false

    var body: some View {
        let status = TrioOnWatchSource.status ?? TrioOnWatchStatus()
        let carbsSaved = request.withCarbs && TrioOnWatchSource.carbsSaved(since: request.requestedAt)
        let view = status.bolusView(units: request.units, carbsSaved: carbsSaved)
        ScrollView {
            VStack(spacing: 8) {
                if let symbol = view.symbol {
                    Image(systemName: symbol).font(.title2).foregroundStyle(view.tint)
                        .accessibilityHidden(true)
                } else {
                    ProgressView()
                }
                Text(view.title).font(.headline)
                Text(view.detail).font(.footnote).multilineTextAlignment(.center)

                if view.showsCancel {
                    Button {
                        Task { await actions.cancelBolus() }
                    } label: {
                        Label(
                            String(localized: "Cancel Bolus", comment: "Watch button to cancel a running bolus"),
                            systemImage: "xmark.app"
                        )
                    }
                    .tint(.loopRed)
                }
                if view.showsRecentDoses {
                    Button(String(localized: "Recent Doses", comment: "Watch button to the recent doses list")) {
                        showingDoses = true
                    }
                }
                if view.needsAcknowledgement {
                    Button(String(localized: "OK", comment: "Dismiss button")) { close() }
                }
            }
            .padding()
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden)
        .sheet(isPresented: $showingDoses) {
            RecentDosesView(doses: status.recentDoses)
        }
        .task(id: view) {
            if view.needsAcknowledgement {
                WKInterfaceDevice.current().play(.failure)
            } else if view.isFinished {
                WKInterfaceDevice.current().play(.success)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { close() }
            }
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            navigationPath.removeLast(navigationPath.count)
        }
    }
}

/// The small list the unconfirmed-bolus screen links to. No retry from here.
struct RecentDosesView: View {
    let doses: [TrioOnWatchStatus.Dose]

    var body: some View {
        List {
            if doses.isEmpty {
                Text(String(localized: "No boluses in the last 6 hours.", comment: "Watch recent doses, empty"))
                    .font(.footnote)
            }
            ForEach(doses, id: \.date) { dose in
                let kind = dose.isAutomatic
                    ? String(localized: "SMB", comment: "Watch recent doses: automatic bolus")
                    : String(localized: "Bolus", comment: "Watch recent doses: manual bolus")
                let state = dose.isUnconfirmed
                    ? String(localized: "not confirmed", comment: "Watch recent doses: dose the pump hasn't confirmed")
                    : nil
                VStack(alignment: .leading) {
                    Text("\(kind) \(TrioOnWatchRules.insulin(dose.units))").font(.footnote.weight(.semibold))
                    Text([dose.date.formatted(date: .omitted, time: .shortened), state].compactMap { $0 }.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(dose.isUnconfirmed ? Color.orange : Color.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle(String(localized: "Recent Doses", comment: "Watch recent doses title"))
    }
}

/// W8 result: carbs stay on the watch until they reach the phone, so "saved", not "logged". Shown once the save is
/// on disk (G-M14).
struct LoanCarbsSavedView: View {
    @Binding var navigationPath: NavigationPath
    let saved: LoanCarbsSaved

    @State private var outcome: Bool?

    var body: some View {
        VStack(spacing: 8) {
            switch outcome {
            case nil:
                ProgressView()
                Text(String(localized: "Saving carbs…", comment: "Watch: carbs being saved while in control"))
            case true?:
                Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(Color.loopGreen)
                    .accessibilityHidden(true)
                Text(String(localized: "Carbs saved on your watch.", comment: "Watch carbs saved while in control"))
            case false?:
                Image(systemName: "xmark").font(.title2).foregroundStyle(Color.loopRed)
                    .accessibilityHidden(true)
                Text(String(localized: "Carbs not saved. Enter them again.", comment: "Watch: carbs couldn't be saved"))
                Button(String(localized: "OK", comment: "Dismiss button")) { navigationPath.removeLast(navigationPath.count) }
            }
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden)
        .task {
            for _ in 0 ..< 20 where !TrioOnWatchSource.carbsSaved(since: saved.requestedAt) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            outcome = TrioOnWatchSource.carbsSaved(since: saved.requestedAt)
            WKInterfaceDevice.current().play(outcome == true ? .success : .failure)
            guard outcome == true else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { navigationPath.removeLast(navigationPath.count) }
        }
    }
}

/// W9 while in control: the loan's override or temp target presets. Tapping one starts it (G-M5); the running one
/// can be stopped. Starting and stopping use the watch's own record store, synced back to the phone at the loan's end.
struct LoanAdjustmentSheet: View {
    enum Kind {
        case override
        case tempTarget
    }

    let kind: Kind
    let adjustment: TrioOnWatchStatus.Adjustment?
    /// The presets the loan can start, with their running state (from the grant).
    var presets: [TrioOnWatchStatus.Preset] = []
    let stop: () async -> Bool
    /// Starts the named preset during the loan.
    var start: (String) async -> Void = { _ in }

    @State private var pendingStop: String?
    @State private var result: ActionResult?

    private var fallbackName: String {
        kind == .override
            ? String(localized: "Override", comment: "Fallback override name")
            : String(localized: "Temp target", comment: "Fallback temp target name")
    }

    var body: some View {
        List {
            if let adjustment {
                runningSection(adjustment)
            }

            Section {
                if presets.isEmpty {
                    Text(
                        kind == .override
                            ? String(localized: "No override presets.", comment: "Watch: no override presets to start")
                            : String(localized: "No temp target presets.", comment: "Watch: no temp target presets to start")
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(presets) { preset in
                        Button {
                            Task { await start(preset.name) }
                        } label: {
                            HStack {
                                Text(preset.name).font(.caption)
                                if preset.isRunning {
                                    Spacer()
                                    Text(String(localized: "running", comment: "Watch: preset currently running"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(preset.isRunning)
                    }
                }
            } header: {
                Text(
                    kind == .override
                        ? String(localized: "Start an Override", comment: "Watch section header")
                        : String(localized: "Start a Temp Target", comment: "Watch section header")
                )
            } footer: {
                Text(String(
                    localized: "Creating or editing presets needs your iPhone.",
                    comment: "Watch: presets can be started, not created, on the watch"
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            kind == .override
                ? String(localized: "Override to Stop")
                : String(localized: "Temp Target to Stop"),
            isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Stop"), role: .destructive) {
                Task {
                    result = await stop()
                        ? .success(
                            kind == .override
                                ? String(localized: "Override stopped.", comment: "Watch: override stopped")
                                : String(localized: "Temp target stopped.", comment: "Watch: temp target stopped")
                        )
                        : .failure(String(
                            localized: "Trio on Watch couldn't save. Nothing was changed.",
                            comment: "Watch: stopping an override or temp target failed"
                        ))
                    pendingStop = nil
                }
            }
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) { pendingStop = nil }
        } message: {
            Text(kind == .override
                ? "Stop the Override \"\(pendingStop ?? fallbackName)\"?"
                : "Stop the Temp Target \"\(pendingStop ?? fallbackName)\"?")
        }
        .fullScreenCover(item: $result) { shown in
            ActionResultView(result: shown) { result = nil }
        }
    }

    @ViewBuilder private func runningSection(_ adjustment: TrioOnWatchStatus.Adjustment) -> some View {
        let name = adjustment.name ?? fallbackName
        Section {
            VStack(alignment: .leading) {
                Text(name).font(.headline)
                Text(adjustment.endsAt.map {
                    String(
                        localized: "Runs until \($0.formatted(date: .omitted, time: .shortened))",
                        comment: "Watch: end time of the running override or temp target"
                    )
                } ?? String(localized: "No end time", comment: "Watch: override without an end"))
                    .font(.footnote)
            }
            .accessibilityElement(children: .combine)

            Button(kind == .override ? String(localized: "Stop Override") : String(localized: "Stop Temp Target")) {
                pendingStop = name
            }
            .tint(.loopRed)
        } header: {
            Text(String(localized: "Running", comment: "Watch section header for the running adjustment"))
        }
    }
}

/// W1: who is in control and how fresh the loop is, as symbol plus word plus age. Opens the status page.
struct ControlLineView: View {
    let line: TrioOnWatchStatus.ControlLine
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(line.text)
            } icon: {
                Image(systemName: line.symbol)
            }
            .font(.footnote)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(line.tier == .unknown ? Color.primary : line.tier.color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(line.accessibilityLabel))
        .accessibilityHint(Text(String(localized: "Opens Trio on Watch status", comment: "Watch accessibility hint")))
    }
}
