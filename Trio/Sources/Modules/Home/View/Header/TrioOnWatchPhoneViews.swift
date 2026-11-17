import SwiftUI

/// P1: replaces the loop ring while the phone isn't in control. Symbol, word and age; colour only adds to them.
struct TrioOnWatchPill: View {
    let pill: TrioOnWatchPhoneStatus.Pill

    var body: some View {
        // at large text the glyph carries "Watch"; the age must not be cut (G-M11)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                Image(systemName: pill.symbol)
                Text(pill.text).lineLimit(1)
            }
            HStack(spacing: 4) {
                Image(systemName: pill.symbol)
                Text(pill.compactText).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(pill.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().strokeBorder(pill.tint, lineWidth: 1.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(pill.accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(String(localized: "Opens Trio on Watch details", comment: "Accessibility hint")))
    }
}

/// The pump panel while Apple Watch has the pump: this phone's own pod readings stopped at the hand-off.
struct TrioOnWatchPumpPlaceholder: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "applewatch")
                .font(.title3)
                .foregroundStyle(Color.insulin)
                .accessibilityHidden(true)
            Text(String(localized: "On Apple Watch", comment: "Home pump panel while Apple Watch has the pump"))
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(localized: "Pump is on Apple Watch", comment: "Accessibility: Home pump panel")))
    }
}

/// P4: why an action is off while Apple Watch is in control.
struct TrioOnWatchBlockedNote: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "applewatch")
                .accessibilityHidden(true)
            Text(String(
                localized: "Apple Watch is in control. \(message)",
                comment: "Note on a phone screen whose actions are off during Trio on Watch; the value says which"
            ))
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    static var treatments: String {
        String(localized: "Bolus and carbs are entered on your watch.", comment: "Blocked note on Treatments")
    }

    static var adjustments: String {
        String(
            localized: "Overrides and temp targets can't be changed until you end Trio on Watch. You can cancel them on your watch.",
            comment: "Blocked note on Adjustments"
        )
    }

    static var settings: String {
        String(
            localized: "Pump settings can't be changed until you end Trio on Watch, and other changes reach your watch only after you end it.",
            comment: "Blocked note on the Settings root"
        )
    }
}

/// P2 with P3: the state, what this iPhone won't do now, and Take Back or "Use the pod on this iPhone".
struct TrioOnWatchSheet: View {
    let model: TrioOnWatchPhoneModel
    /// Screenshot harness only.
    var presents: TrioOnWatchPhoneFixtureDialog?

    @Environment(\.dismiss) private var dismiss
    @State private var showingTakeBack = false
    @State private var showingUsePod = false

    var body: some View {
        let status = model.status
        let banner = status.banner(now: Date())
        NavigationStack {
            List {
                Section {
                    Label {
                        Text(banner.title).font(.headline)
                    } icon: {
                        Image(systemName: banner.symbol).foregroundStyle(banner.tint)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    if let detail = status.sheetDetail {
                        Text(detail)
                    }
                    if status.phase != .podRefused {
                        Text(status.lastUpdate.map {
                            String(
                                localized: "Last update from Apple Watch: \($0.formatted(date: .omitted, time: .shortened)) (\($0.formattedTimeAgo()) ago)",
                                comment: "Trio on Watch sheet: time and age of the last record batch"
                            )
                        } ?? String(localized: "No update from Apple Watch yet.", comment: "Trio on Watch sheet"))
                            .foregroundStyle(.secondary)
                    }
                }

                if status.replacesLoopRing, status.phase != .takingBack, status.phase != .takingBackStuck {
                    Section {
                        ForEach(Self.blockedActions, id: \.self) { line in
                            Label(line, systemImage: "nosign").accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text(String(
                            localized: "This iPhone won't, until Trio on Watch ends",
                            comment: "Trio on Watch sheet section"
                        ))
                    } footer: {
                        Text(String(
                            localized: "Your iPhone keeps showing glucose and sounding glucose alarms. Insulin and carbs on this iPhone include only what Apple Watch has sent so far. To suspend insulin, use Trio on your watch.",
                            comment: "Trio on Watch sheet footer"
                        ))
                    }
                }

                if status.phase == .takingBackStuck || status.phase == .unreadable || status.phase == .noUpdates {
                    Section {
                        Text(String(
                            localized: "Your pump keeps running the last temp basal until it ends (at most 2 hours), then your scheduled basal.",
                            comment: "Trio on Watch sheet: what the pump does while nothing loops"
                        ))
                    }
                }

                if status.offersTakeBack {
                    Section {
                        if status.watchReachable, status.phase != .startUnconfirmed, status.phase != .starting {
                            Text(String(
                                localized: "End Trio on Watch on your watch to bring everything back.",
                                comment: "Trio on Watch sheet: the safer way while the watch is reachable"
                            ))
                        }
                        Button(String(localized: "Take Back Pump", comment: "Trio on Watch sheet button")) {
                            showingTakeBack = true
                        }
                        .confirmationDialog(
                            String(localized: "Take Back Pump", comment: "Take Back confirmation title"),
                            isPresented: $showingTakeBack,
                            titleVisibility: .visible
                        ) {
                            let context = status.takeBackContext
                            Button(
                                TrioOnWatchPhoneStatus.takeBackButton(context),
                                role: context == .watchReachable ? .destructive : nil
                            ) {
                                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                                Task { await model.takeBack() }
                            }
                            Button(String(localized: "Cancel"), role: .cancel) {}
                        } message: {
                            Text(TrioOnWatchPhoneStatus.takeBackMessage(status.takeBackContext))
                        }
                    }
                }

                if status.offersUsePod {
                    Section {
                        Button(String(localized: "Use the Pod on This iPhone", comment: "Trio on Watch sheet button")) {
                            showingUsePod = true
                        }
                        .confirmationDialog(
                            String(localized: "Use the Pod on This iPhone?", comment: "Confirmation title"),
                            isPresented: $showingUsePod,
                            titleVisibility: .visible
                        ) {
                            Button(String(localized: "Use the Pod on This iPhone", comment: "Confirmation button")) {
                                Task { await model.usePodOnThisPhone() }
                            }
                            Button(String(localized: "Cancel"), role: .cancel) {}
                        } message: {
                            Text(String(
                                localized: "Only do this if no other device should control this pod. If another device still runs it, it stops when it next reaches your pod.",
                                comment: "Use the pod on this iPhone confirmation message"
                            ))
                        }
                    } footer: {
                        Text(String(
                            localized: "Another device used your pod, so this iPhone stopped sending it commands.",
                            comment: "Trio on Watch sheet footer for a refused pod"
                        ))
                    }
                }
            }
            .navigationTitle(String(localized: "Trio on Watch", comment: "Trio on Watch sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .onAppear {
                switch presents {
                case .takeBack: showingTakeBack = true
                case .usePod: showingUsePod = true
                case nil: break
                }
            }
        }
    }

    static var blockedActions: [String] {
        [
            String(localized: "Give insulin or change basal", comment: "Trio on Watch sheet: blocked on iPhone"),
            String(localized: "Log carbs", comment: "Trio on Watch sheet: blocked on iPhone"),
            String(
                localized: "Change pump settings, overrides or temp targets",
                comment: "Trio on Watch sheet: blocked on iPhone"
            ),
            String(
                localized: "Run remote commands or upload loop status to Nightscout",
                comment: "Trio on Watch sheet: blocked on iPhone"
            )
        ]
    }
}

enum TrioOnWatchPhoneFixtureDialog {
    case takeBack
    case usePod
}

#if DEBUG
    /// Screenshot harness: `-TrioOnWatchPhoneScreen <name>` shows a fixed status, and optionally opens the sheet or a
    /// dialog. UI only; the coordinator and the pump are never touched. Debug builds only.
    struct TrioOnWatchPhoneFixture {
        var status: TrioOnWatchPhoneStatus
        var opensSheet = false
        var dialog: TrioOnWatchPhoneFixtureDialog?
        /// "treatments", "adjustments" or "settings": the screen to open, showing its blocked note.
        var opens: String?

        /// Screens with a blocked note show it while the harness runs.
        static var showsBlockedNotes: Bool { current != nil }

        static let current: TrioOnWatchPhoneFixture? = {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-TrioOnWatchPhoneScreen"), index + 1 < arguments.count else { return nil }
            return named(arguments[index + 1], now: Date())
        }()

        static func named(_ name: String, now: Date) -> TrioOnWatchPhoneFixture? {
            var status = TrioOnWatchPhoneStatus(lastUpdate: now.addingTimeInterval(-3 * 60), watchReachable: false)
            let parts = name.split(separator: "+").map(String.init)
            switch parts.first {
            case "starting": status.phase = .starting
            case "start-unconfirmed": status.phase = .startUnconfirmed
            case "in-control": status.phase = .inControl
            case "in-control-reachable":
                status.phase = .inControl
                status.watchReachable = true
            case "no-updates":
                status.phase = .noUpdates
                status.lastUpdate = now.addingTimeInterval(-34 * 60)
            case "taking-back": status.phase = .takingBack
            case "taking-back-stuck": status.phase = .takingBackStuck
            case "pod-refused":
                status.phase = .podRefused
                status.podRefusesSessions = true
            case "unreadable": status.phase = .unreadable
            default: return nil
            }
            var fixture = TrioOnWatchPhoneFixture(status: status)
            fixture.opensSheet = parts.contains("sheet") || parts.contains("takeback") || parts.contains("usepod")
            fixture.dialog = parts.contains("takeback") ? .takeBack : parts.contains("usepod") ? .usePod : nil
            fixture.opens = parts.first { ["treatments", "adjustments", "settings"].contains($0) }
            return fixture
        }
    }
#endif
