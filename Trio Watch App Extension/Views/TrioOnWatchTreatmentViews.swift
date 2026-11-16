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
struct LoanBolusRequest: Hashable {
    var units: Decimal
    var withCarbs: Bool
    var requestedAt: Date
}

/// Carbs saved on the watch, for the navigation stack.
struct LoanCarbsSaved: Hashable {
    var grams: Int
}

/// W7: what the pump is doing with this bolus. Failed, cancelled and unconfirmed results stay until OK (G-4).
struct LoanBolusProgressView: View {
    @Binding var navigationPath: NavigationPath
    let request: LoanBolusRequest
    let actions: TrioOnWatchActions

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
                        Image(systemName: "xmark.app")
                    }
                    .tint(.loopRed)
                    .accessibilityLabel(Text(String(
                        localized: "Cancel bolus",
                        comment: "Watch accessibility: cancel bolus button"
                    )))
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
        navigationPath.removeLast(navigationPath.count)
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

/// W8 result: carbs stay on the watch until they reach the phone, so "saved", not "logged".
struct LoanCarbsSavedView: View {
    @Binding var navigationPath: NavigationPath
    let saved: LoanCarbsSaved

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(Color.loopGreen)
                .accessibilityHidden(true)
            Text(String(localized: "Carbs saved on your watch.", comment: "Watch carbs saved while in control"))
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden)
        .task {
            WKInterfaceDevice.current().play(.success)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { navigationPath.removeLast(navigationPath.count) }
        }
    }
}

/// W9 while in control: the running override or temp target, with cancel only (V2-25).
struct LoanAdjustmentSheet: View {
    enum Kind {
        case override
        case tempTarget
    }

    let kind: Kind
    let adjustment: TrioOnWatchStatus.Adjustment?
    let cancel: () async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let adjustment {
                let name = adjustment.name ?? (
                    kind == .override
                        ? String(localized: "Override", comment: "Fallback override name")
                        : String(localized: "Temp target", comment: "Fallback temp target name")
                )
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

                Button(
                    kind == .override
                        ? String(localized: "Cancel Override", comment: "Watch button")
                        : String(localized: "Cancel Temp Target", comment: "Watch button")
                )
                    {
                        Task { await cancel() }
                        dismiss()
                    }
                    .tint(.loopRed)
            } else {
                Text(
                    kind == .override
                        ? String(localized: "No override is running.", comment: "Watch: nothing running")
                        : String(localized: "No temp target is running.", comment: "Watch: nothing running")
                )
                .font(.footnote)
            }
            Text(String(
                localized: "You can't start or change overrides or temp targets while your watch is in control.",
                comment: "Watch: overrides and temp targets are phone-only during Trio on Watch"
            ))
                .font(.footnote)
                .foregroundStyle(.secondary)
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
