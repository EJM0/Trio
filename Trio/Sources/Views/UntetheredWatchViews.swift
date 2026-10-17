import SwiftUI

extension UntetheredPhoneManager {
    /// Handing over, handing back or reading the pump after its return.
    var isBusy: Bool {
        switch state.session.phase {
        case .ending,
             .preparing,
             .starting: return true
        case .active,
             .idle: return state.pumpReturnPending
        }
    }
}

/// The toggle in Settings › Apple Watch. It only stays on once the watch has taken the pump.
struct UntetheredSettingsSection: View {
    @ObservedObject var manager: UntetheredPhoneManager
    @State private var confirmEnd = false
    @State private var confirmForce = false

    var body: some View {
        Section(
            header: Text("Untethered Watch Mode"),
            footer: Text(
                "The watch runs the loop with its own connection to the pump and the CGM while the phone is away. While it does, the phone shows glucose but doesn't dose."
            )
        ) {
            HStack {
                Text("Untethered Watch Mode")
                Spacer()
                if manager.isBusy {
                    ProgressView()
                } else {
                    Toggle("", isOn: Binding(
                        get: { manager.isWatchInCharge },
                        set: { on in
                            if on {
                                Task { await manager.start() }
                            } else {
                                confirmEnd = true
                            }
                        }
                    ))
                        .labelsHidden()
                }
            }

            if let error = manager.state.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            if manager.isWatchInCharge {
                Button("Take Back the Pump Now", role: .destructive) { confirmForce = true }
            }
        }
        .listRowBackground(Color.chart)
        .confirmationDialog("End untethered mode?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End") { Task { await manager.end() } }
        } message: {
            Text("The watch hands the pump back as soon as it is reachable.")
        }
        .untetheredForceDialog(isPresented: $confirmForce, manager: manager)
    }
}

/// Left of the cancel button of an override that offers untethered mode.
struct UntetheredOverrideButton: View {
    @ObservedObject var manager: UntetheredPhoneManager
    let overrideID: String?
    @State private var confirmEnd = false
    @State private var confirmForce = false
    @State private var showError = false

    var body: some View {
        Group {
            if manager.isBusy {
                ProgressView()
            } else {
                Image(systemName: manager.isWatchInCharge ? "applewatch" : "applewatch.slash")
                    .font(.title2)
                    .foregroundStyle(manager.isWatchInCharge ? Color.loopGreen : Color.secondary)
                    .onTapGesture {
                        if manager.isWatchInCharge {
                            confirmEnd = true
                        } else {
                            Task { await manager.start(linkedOverrideID: overrideID) }
                        }
                    }
                    .onLongPressGesture { if manager.isWatchInCharge { confirmForce = true } }
            }
        }
        .frame(minWidth: 30)
        .confirmationDialog("End untethered mode?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End") { Task { await manager.end() } }
            Button("Take Back the Pump Now", role: .destructive) { confirmForce = true }
        }
        .untetheredForceDialog(isPresented: $confirmForce, manager: manager)
        // a refusal can come from the watch long after the tap
        .onChange(of: manager.state.lastError) { _, error in
            showError = error != nil && !manager.isWatchInCharge
        }
        .alert("Untethered Watch Mode", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(manager.state.lastError ?? "")
        }
    }
}

/// `content`, or the untethered notice while the watch has the pump. `banner` draws it in the home screen's
/// own panel style; a tap offers ending untethered mode or taking the pump back.
struct UntetheredBannerSlot<Content: View, Banner: View>: View {
    @ObservedObject var manager: UntetheredPhoneManager
    @ViewBuilder let content: () -> Content
    let banner: (_ title: String, _ subtitle: String, _ action: @escaping () -> Void) -> Banner
    @State private var showActions = false
    @State private var confirmForce = false

    var body: some View {
        if manager.isWatchInCharge || manager.state.pumpReturnPending {
            banner(
                manager.state.pumpReturnPending
                    ? String(localized: "Reaching the pump…")
                    : String(localized: "Untethered on Apple Watch"),
                manager.state.pumpReturnPending
                    ? manager.state.lastError
                    ?? String(localized: "Checking what the watch delivered before the phone doses again.")
                    : String(localized: "The phone doesn't dose. Bolus and carbs are entered on the watch."),
                { showActions = manager.isWatchInCharge }
            )
            .confirmationDialog("Untethered Watch Mode", isPresented: $showActions, titleVisibility: .visible) {
                Button("End Untethered Mode") { Task { await manager.end() } }
                Button("Take Back the Pump Now", role: .destructive) { confirmForce = true }
            }
            .untetheredForceDialog(isPresented: $confirmForce, manager: manager)
        } else {
            content()
        }
    }
}

/// Bolus and carbs are entered on the watch while it has the pump.
struct UntetheredTreatmentGate<Content: View>: View {
    @ObservedObject var manager: UntetheredPhoneManager
    @ViewBuilder let content: () -> Content

    var body: some View {
        if manager.isWatchInCharge {
            VStack(spacing: 16) {
                Image(systemName: "applewatch.radiowaves.left.and.right").font(.largeTitle)
                Text("The Apple Watch is running the loop").font(.headline)
                Text("Enter carbs and boluses on the watch. They come back to the phone with the watch's history.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                UntetheredBanner(manager: manager)
            }
            .padding()
        } else {
            content()
        }
    }
}

/// Shown on the home screen while the watch has the pump.
struct UntetheredBanner: View {
    @ObservedObject var manager: UntetheredPhoneManager
    @State private var confirmForce = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.state.pumpReturnPending ? "Reaching the pump…" : "Untethered on Apple Watch")
                    .font(.subheadline).bold()
                Text("The phone doesn't dose. Bolus and carbs are entered on the watch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if manager.isWatchInCharge {
                Menu {
                    Button("End Untethered Mode") { Task { await manager.end() } }
                    Button("Take Back the Pump Now", role: .destructive) { confirmForce = true }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
        }
        .padding(10)
        .background(Color.loopGreen.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .untetheredForceDialog(isPresented: $confirmForce, manager: manager)
    }
}

private extension View {
    func untetheredForceDialog(isPresented: Binding<Bool>, manager: UntetheredPhoneManager) -> some View {
        confirmationDialog("Take back the pump?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Take Back", role: .destructive) { Task { await manager.forceTakeBack() } }
        } message: {
            Text(
                "Use this when the watch can't hand the pump back, for example when it is lost or out of battery. The phone takes the pump without waiting for the watch, and counts insulin it has no record of until the watch's history arrives."
            )
        }
    }
}
