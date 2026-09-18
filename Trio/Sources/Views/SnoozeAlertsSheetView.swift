import SwiftUI
import Swinject

/// Shared "Snooze All" sheet. Used from Notifications settings and the home
/// glucose long-press. Wraps `TrioAlertManager.applySnooze` directly — no
/// router / module hop.
struct SnoozeAlertsSheetView: View {
    let resolver: Resolver
    @Binding var isPresented: Bool

    @State private var snoozeUntilDate: Date = .distantPast

    // Individual snoozes live in their own stores, not in the global
    // snoozeUntilDate — observed so ending one here updates the list.
    @StateObject private var glucoseStore = GlucoseAlertsStore.shared
    @StateObject private var deviceStore = DeviceAlertsStore.shared

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        NavigationStack {
            List {
                if snoozeUntilDate > Date() {
                    Section {
                        HStack {
                            Image(systemName: "moon.zzz.fill").foregroundStyle(.tint)
                            Text(String(
                                format: String(localized: "Snoozed until %@"),
                                snoozeUntilDate.formatted(date: .omitted, time: .shortened)
                            ))
                                .font(.headline)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            endSnoozeAction
                        }
                        .listRowBackground(Color.chart)
                    } footer: {
                        HStack {
                            Image(systemName: "hand.draw.fill").foregroundStyle(.primary)
                            Text("Swipe left to end snooze.")
                        }
                    }
                }
                if !snoozedAlarms.isEmpty || !snoozedTiers.isEmpty {
                    Section {
                        ForEach(snoozedAlarms) { alarm in
                            snoozeRow(title: alarm.name, until: alarm.snoozedUntil ?? Date()) {
                                var updated = alarm
                                updated.snoozedUntil = nil
                                glucoseStore.update(updated)
                            }
                        }
                        ForEach(snoozedTiers, id: \.tier) { entry in
                            snoozeRow(
                                title: String(
                                    format: String(localized: "%@ device alarms"),
                                    entry.tier.displayName
                                ),
                                until: entry.until
                            ) {
                                deviceStore.snoozeTier(entry.tier, until: .distantPast)
                            }
                        }
                    } header: {
                        Text("Snoozed Alarms")
                    } footer: {
                        HStack {
                            Image(systemName: "hand.draw.fill").foregroundStyle(.primary)
                            Text("Swipe left to end snooze.")
                        }
                    }
                    .listRowBackground(Color.chart)
                }

                Section(footer: Text(
                    "Pick a duration to mute every Trio alarm. Critical alerts (e.g. occlusion, urgent low) still pierce the snooze."
                )) {
                    ForEach(NotificationResponseAction.allCases, id: \.self) { action in
                        Button {
                            applySnooze(action.duration)
                        } label: {
                            HStack {
                                Text(action.localizedTitle).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.gray)
                                    .font(.footnote)
                            }
                        }
                    }
                }.listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
            .navigationTitle("Snooze Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { isPresented = false }
                }
            }
            .onAppear {
                snoozeUntilDate = UserDefaults.standard
                    .object(forKey: "UserNotificationsManager.snoozeUntilDate") as? Date ?? .distantPast
            }
        }
    }

    /// Glucose alarms carry `snoozedUntil` per alarm; device alarms snooze a
    /// whole severity tier. Both are stamped by the banner and notification
    /// snooze actions and were previously only visible in the alarm lists.
    private var snoozedAlarms: [GlucoseAlert] {
        GlucoseAlert.individuallySnoozed(glucoseStore.alerts, globalSnoozeUntil: snoozeUntilDate)
    }

    private var snoozedTiers: [(tier: DeviceAlertSeverity, until: Date)] {
        let now = Date()
        return DeviceAlertSeverity.allCases.compactMap { tier in
            guard let until = deviceStore.tierSnoozes[tier.rawValue], until > now else { return nil }
            return (tier, until)
        }
    }

    private func snoozeRow(title: String, until: Date, endSnooze: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.primary)
            AlarmSnoozeBadge(until: until)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: endSnooze) {
                Label("End Snooze", systemImage: "alarm.waves.left.and.right.fill")
            }
            .tint(.red)
        }
    }

    private var endSnoozeAction: some View {
        Button(role: .destructive) {
            endSnooze()
        } label: {
            Label("End Snooze", systemImage: "alarm.waves.left.and.right.fill")
        }
        .tint(.red)
    }

    private func applySnooze(_ duration: TimeInterval) {
        let trioAlertManager = resolver.resolve(TrioAlertManager.self)
        Task { @MainActor in
            await trioAlertManager?.applySnooze(for: duration)
            snoozeUntilDate = Date().addingTimeInterval(duration)
            isPresented = false
        }
    }

    private func endSnooze() {
        let trioAlertManager = resolver.resolve(TrioAlertManager.self)
        Task { @MainActor in
            await trioAlertManager?.applySnooze(for: 0)
            snoozeUntilDate = Date().addingTimeInterval(0)
        }
    }
}
