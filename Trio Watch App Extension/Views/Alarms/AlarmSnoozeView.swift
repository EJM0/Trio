import SwiftUI

struct AlarmSnoozeView: View {
    let state: WatchState

    @State private var showingSnoozeOptions = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            // measure from now, so calculation is not based off stale tick date
            // cf. https://github.com/nightscout/Trio/issues/1381
            let now = max(context.date, Date())
            // while Trio on Watch reads the sensor, the watch's own alarms are what this page snoozes
            let watchSnooze = TrioOnWatchSource.snoozedUntil
            let snoozeUntil = watchSnooze ?? state.snoozeUntilDate
            let isSnoozed = snoozeUntil > now
            let remainingMinutes = max(Int(ceil(snoozeUntil.timeIntervalSince(now) / 60)), 0)

            VStack {
                Button {
                    showingSnoozeOptions = true
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: isSnoozed ? "bell.slash.fill" : "bell.fill")
                            .font(.title2)
                        if isSnoozed {
                            Text("\(remainingMinutes) m")
                                .font(.headline).fontWeight(.bold).fontDesign(.rounded)
                        }
                    }
                    .foregroundStyle(isSnoozed ? Color.secondary : Color.primary)
                    .frame(width: 80, height: 80)
                    .overlay(
                        Circle()
                            .stroke(Color.primary.opacity(0.4), lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                Text(
                    isSnoozed
                        ? String(
                            format: String(localized: "Snoozed until %@"),
                            snoozeUntil.formatted(date: .omitted, time: .shortened)
                        )
                        : String(localized: "Alarms active")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                if watchSnooze != nil {
                    Text(String(localized: "Alarms on this watch", comment: "Watch snooze page while Trio on Watch runs"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(
                watchSnooze != nil ? String(localized: "Alarms on this watch") :
                    String(localized: "Alarms")
            ))
            .accessibilityValue(Text(
                isSnoozed
                    ? String(
                        format: String(localized: "snoozed, %d minutes remaining", comment: "Accessibility: alarm snooze"),
                        remainingMinutes
                    )
                    : String(localized: "active", comment: "Accessibility: alarms active")
            ))
            .accessibilityHint(Text(String(localized: "Opens snooze options", comment: "Accessibility hint")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showingSnoozeOptions = true }
        }
        .sheet(isPresented: $showingSnoozeOptions) {
            AlarmSnoozeOptionsView(state: state) {
                showingSnoozeOptions = false
            }
        }
    }
}

struct AlarmSnoozeOptionsView: View {
    let state: WatchState
    var onDismiss: () -> Void

    var body: some View {
        NavigationView {
            List {
                if (TrioOnWatchSource.snoozedUntil ?? state.snoozeUntilDate) > Date() {
                    Button {
                        snooze(minutes: 0)
                        onDismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "alarm.waves.left.and.right.fill")
                            Text("End Snooze")
                        }
                    }
                    .foregroundColor(.white)
                    .listRowBackground(
                        Color.loopRed
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    )
                }

                ForEach(NotificationResponseAction.allCases, id: \.self) { action in
                    Button(action.localizedTitle) {
                        snooze(minutes: action.minutes)
                        onDismiss()
                    }
                }
            }
            .navigationTitle("Snooze Alerts")
        }
    }

    /// The watch's own alarms while Trio on Watch reads the sensor (G-M8); the iPhone's otherwise.
    private func snooze(minutes: Int) {
        if let host = WatchLoanRuntime.host, host.ownsGlucoseAlarms {
            host.snoozeAlarms(minutes: minutes)
        } else {
            state.sendSnoozeRequest(minutes: minutes)
        }
    }
}
