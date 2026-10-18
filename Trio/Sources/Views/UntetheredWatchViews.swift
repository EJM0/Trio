import SwiftUI

extension UntetheredPhoneManager {
    /// Checking the devices, handing over, handing back or reading the pump after its return.
    var isBusy: Bool {
        if isCheckingDevices { return true }
        switch state.session.phase {
        case .ending,
             .preparing,
             .starting: return true
        case .active,
             .idle: return state.pumpReturnPending
        }
    }
}

extension UntetheredPhoneManager {
    /// While the pump comes back: reaching it, then waiting for the watch's last records and the audit.
    var pumpReturnTitle: String {
        pumpReturnAnswered ? String(localized: "Checking the watch's records…") : String(localized: "Reaching the pump…")
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
                    .foregroundStyle(manager.isWatchInCharge ? Color.untethered : Color.secondary)
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
/// own panel style; a tap offers ending untethered mode or taking the pump back, so the banner only shows it is
/// tappable while there is something to offer. `content` gets the last session's audit finding, so it updates
/// with it.
struct UntetheredBannerSlot<Content: View, Banner: View>: View {
    @ObservedObject var manager: UntetheredPhoneManager
    @ViewBuilder let content: (_ auditFinding: String?) -> Content
    let banner: (_ title: String, _ subtitle: String, _ isTappable: Bool, _ action: @escaping () -> Void) -> Banner
    @State private var showActions = false
    @State private var confirmForce = false

    var body: some View {
        if manager.isWatchInCharge || manager.state.pumpReturnPending {
            banner(
                manager.state.pumpReturnPending
                    ? manager.pumpReturnTitle
                    : String(localized: "Untethered on Apple Watch"),
                manager.state.pumpReturnPending
                    ? manager.state.lastError
                    ?? String(localized: "Checking what the watch delivered before the phone doses again.")
                    : String(localized: "The phone doesn't dose. Bolus and carbs are entered on the watch."),
                manager.isWatchInCharge,
                { showActions = manager.isWatchInCharge }
            )
            .confirmationDialog("Untethered Watch Mode", isPresented: $showActions, titleVisibility: .visible) {
                Button("End Untethered Mode") { Task { await manager.end() } }
                Button("Take Back the Pump Now", role: .destructive) { confirmForce = true }
            }
            .untetheredForceDialog(isPresented: $confirmForce, manager: manager)
        } else {
            content(manager.state.auditFinding)
        }
    }
}

/// The home screen's pump while the watch has it: the watch's own figures while they are recent, otherwise what is
/// going on, never the connection error of the phone's own pump manager, which handed the pod over.
struct UntetheredPumpGate<Content: View>: View {
    enum Display {
        /// The phone has the pump: its own figures and messages.
        case phone
        case watch(UntetheredPumpStatus)
        /// The watch has the pump, and nothing recent came from it.
        case away
    }

    @ObservedObject var manager: UntetheredPhoneManager
    let now: Date
    @ViewBuilder let content: (Display) -> Content

    /// Three of the watch's loops: older figures may no longer be what the pod does.
    static var recent: TimeInterval { 15 * 60 }

    var body: some View {
        if !manager.isWatchInCharge {
            content(.phone)
        } else if let status = manager.state.watchPump, now.timeIntervalSince(status.date) < Self.recent {
            content(.watch(status))
        } else {
            content(.away)
        }
    }
}

/// Bolus and carbs are entered on the watch while it has the pump: in their place, what is going on and the ways
/// back, in the app's own background and glass panels.
struct UntetheredTreatmentGate<Content: View>: View {
    @ObservedObject var manager: UntetheredPhoneManager
    @ViewBuilder let content: () -> Content
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEnd = false
    @State private var confirmForce = false

    var body: some View {
        if manager.isWatchInCharge || manager.state.pumpReturnPending {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.untethered)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(Color.untethered.opacity(0.18)))
                    .shadow(color: Color.untethered.opacity(0.35), radius: 16)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(
                        manager.state.pumpReturnPending ? manager
                            .pumpReturnTitle : String(localized: "The Apple Watch is looping")
                    )
                    .font(.title3).fontWeight(.semibold)
                    Text(
                        manager.state.pumpReturnPending
                            ? manager.pumpReturnAnswered
                            ? String(localized: "The phone doses again once it has checked the watch's records.")
                            : String(localized: "The phone doses again once it has read the pump.")
                            :
                            String(
                                localized: "Enter carbs and boluses on the watch. They come back to the phone with the watch's history."
                            )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)

                if manager.isWatchInCharge {
                    VStack(spacing: 10) {
                        gateButton("End Untethered Mode", systemImage: "iphone", tint: .untethered) { confirmEnd = true }
                        gateButton("Take Back the Pump Now", systemImage: "exclamationmark.triangle", tint: .red) {
                            confirmForce = true
                        }
                    }
                }
                Spacer()
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
            .navigationTitle("Treatments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
            }
            .confirmationDialog("End untethered mode?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End") { Task { await manager.end() } }
            } message: {
                Text("The watch hands the pump back as soon as it is reachable.")
            }
            .untetheredForceDialog(isPresented: $confirmForce, manager: manager)
        } else {
            content()
        }
    }

    private func gateButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tint.opacity(0.18)))
                Text(title).font(.subheadline).fontWeight(.semibold).foregroundStyle(.primary)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .glassPanel(tint: tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension Color {
    /// Untethered watch mode, wherever it shows: a bright cyan on the dark background, deeper on the light one.
    static let untethered = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x33 / 255, green: 0xE3 / 255, blue: 0xFF / 255, alpha: 1)
            : UIColor(red: 0x00 / 255, green: 0x9C / 255, blue: 0xBD / 255, alpha: 1)
    })
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
