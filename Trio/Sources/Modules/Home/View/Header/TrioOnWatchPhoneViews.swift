import SwiftUI
import UIKit

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
                            Text(TrioOnWatchPhoneStatus.takeBackMessage(status.takeBackContext, patch: status.pumpIsPatch))
                        }
                    }
                }

                if status.offersUsePod {
                    Section {
                        Button(
                            status
                                .pumpIsPatch ?
                                String(localized: "Use the Patch on This iPhone", comment: "Trio on Watch sheet button") :
                                String(localized: "Use the Pod on This iPhone", comment: "Trio on Watch sheet button")
                        ) {
                            showingUsePod = true
                        }
                        .confirmationDialog(
                            status.pumpIsPatch ? String(
                                localized: "Use the Patch on This iPhone?",
                                comment: "Confirmation title"
                            ) : String(localized: "Use the Pod on This iPhone?", comment: "Confirmation title"),
                            isPresented: $showingUsePod,
                            titleVisibility: .visible
                        ) {
                            Button(
                                status
                                    .pumpIsPatch ? String(
                                        localized: "Use the Patch on This iPhone",
                                        comment: "Confirmation button"
                                    ) :
                                    String(localized: "Use the Pod on This iPhone", comment: "Confirmation button")
                            ) {
                                Task { await model.usePodOnThisPhone() }
                            }
                            Button(String(localized: "Cancel"), role: .cancel) {}
                        } message: {
                            Text(status.pumpIsPatch ? String(
                                localized: "Only do this if no other device should control this patch. If another device still runs it, it stops when it next reaches your patch.",
                                comment: "Use the patch on this iPhone confirmation message"
                            ) : String(
                                localized: "Only do this if no other device should control this pod. If another device still runs it, it stops when it next reaches your pod.",
                                comment: "Use the pod on this iPhone confirmation message"
                            ))
                        }
                    } footer: {
                        Text(status.refusedFooter)
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
            var status = TrioOnWatchPhoneStatus(
                lastUpdate: now.addingTimeInterval(-3 * 60),
                lastLoop: now.addingTimeInterval(-3 * 60),
                watchReachable: false
            )
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
                status.lastLoop = now.addingTimeInterval(-36 * 60)
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

// MARK: - Drag the glucose onto the watch

/// Starting Trio on Watch from Home: hold the glucose, drag it onto the watch, then the hand-off.
@MainActor @Observable final class TrioOnWatchStartDrag {
    enum Step: Equatable {
        case idle
        case dragging
        case handOff(TrioOnWatchPhoneStart.Stage)
    }

    var step: Step = .idle
    /// The glucose on Home, in global coordinates.
    var ringFrame: CGRect = .zero
    var translation: CGSize = .zero
    /// The long press finished: the rest of this touch belongs to it.
    var holdStarted = false
    /// Dropped on the watch: the user confirms, with what changes, before the watch is asked.
    var isConfirming = false

    var isActive: Bool { step != .idle }
    var ringCenter: CGPoint { CGPoint(x: ringFrame.midX + translation.width, y: ringFrame.midY + translation.height) }
    /// The watch to drop on: under the glucose, a thumb's drag away.
    var targetCenter: CGPoint { CGPoint(x: ringFrame.midX, y: ringFrame.maxY + Self.targetDistance) }
    var isOverTarget: Bool { hypot(ringCenter.x - targetCenter.x, ringCenter.y - targetCenter.y) < Self.dropRadius }
    /// Let go about where it was picked up: the long press it always was, snooze.
    var isNearStart: Bool { hypot(translation.width, translation.height) < Self.snoozeRadius }

    static let targetDistance: CGFloat = 190
    static let dropRadius: CGFloat = 60
    static let snoozeRadius: CGFloat = 24
    static let pollInterval: UInt64 = 500_000_000

    func reset() {
        step = .idle
        translation = .zero
        isConfirming = false
    }

    /// What the watch's own Start screen discloses; this Start doesn't show it.
    static var confirmationText: String {
        [
            String(
                localized: "Check that your pod and sensor don't end soon.",
                comment: "Drag-to-watch Start confirmation"
            ),
            String(
                localized: "On your watch, Trio's alarms may only tap your wrist when Silent Mode or a Focus is on. Keep your watch on and notifications allowed.",
                comment: "Watch Start disclosure about alarms (G-6b)"
            ),
            String(
                localized: "Nightscout updates and remote commands pause until you end Trio on Watch.",
                comment: "Watch Start disclosure for caregivers (G-8, V2-26)"
            )
        ].joined(separator: "\n\n")
    }

    /// Dropped on the watch: ask it to start, then follow the phone's loan state until the watch has the pump.
    func handOff(model: TrioOnWatchPhoneModel) async {
        let droppedAt = Date()
        withAnimation(.spring(duration: 0.45)) { step = .handOff(.handingOver) }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let answer = await model.startFromPhone()
        while case .handOff = step {
            await model.refresh()
            let stage = TrioOnWatchPhoneStart.stage(
                answer: answer,
                phase: model.status.phase,
                elapsed: Date().timeIntervalSince(droppedAt),
                patch: model.status.pumpIsPatch
            )
            if step != .handOff(stage) {
                withAnimation(.spring(duration: 0.45)) { step = .handOff(stage) }
                switch stage {
                case .done: UINotificationFeedbackGenerator().notificationOccurred(.success)
                case .failed: UINotificationFeedbackGenerator().notificationOccurred(.error)
                case .handingOver,
                     .stillWaiting: break
                }
            }
            switch stage {
            case .done,
                 .failed: return
            case .handingOver,
                 .stillWaiting:
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }
}

/// Over all of Home while the glucose is held: the lifted glucose and the watch to drop it on, then the hand-off card.
struct TrioOnWatchStartOverlay<Ring: View>: View {
    @Bindable var drag: TrioOnWatchStartDrag
    let model: TrioOnWatchPhoneModel
    let reading: TrioOnWatchFaceCard.Reading?
    @ViewBuilder let ring: () -> Ring
    /// Opens the Trio on Watch screen, where control is taken back.
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.3))
                switch drag.step {
                case .dragging:
                    dragging(origin: origin)
                case let .handOff(stage):
                    handOff(stage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                case .idle:
                    EmptyView()
                }
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .task(id: drag.step == .dragging) {
            // the watch app opening or closing turns the drop target on and off while the glucose is held
            while drag.step == .dragging, !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var watchReachable: Bool { model.status.watchReachable }

    @ViewBuilder private func dragging(origin: CGPoint) -> some View {
        let over = drag.isOverTarget && watchReachable
        let target = CGPoint(x: drag.targetCenter.x - origin.x, y: drag.targetCenter.y - origin.y)
        let ringAt = CGPoint(x: drag.ringCenter.x - origin.x, y: drag.ringCenter.y - origin.y)

        if drag.isNearStart {
            Text(String(localized: "Let go to snooze alerts", comment: "Hint while the glucose is held on Home"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .position(x: drag.ringFrame.midX - origin.x, y: drag.ringFrame.minY - origin.y - 14)
        }

        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(over ? 0.18 : 0.08))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(TrioOnWatchFaceCard.gradient, lineWidth: over ? 3 : 1.5)
            Image(systemName: "applewatch")
                .font(.system(size: 30, weight: .medium))
        }
        .frame(width: 68, height: 68)
        .scaleEffect(over ? 1.25 : 1)
        .shadow(color: TrioOnWatchFaceCard.glow.opacity(over ? 0.9 : 0.3), radius: over ? 22 : 8)
        .opacity(watchReachable ? 1 : 0.4)
        .position(target)
        .accessibilityHidden(true)

        Text(targetText(over: over))
            .font(.callout.weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 260)
            .position(x: target.x, y: target.y + 66)

        ring()
            .scaleEffect(over ? 0.8 : 1.05)
            .shadow(color: TrioOnWatchFaceCard.glow.opacity(over ? 0.9 : 0.5), radius: over ? 26 : 16)
            .position(ringAt)
            .animation(.interactiveSpring(duration: 0.2), value: drag.translation)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func targetText(over: Bool) -> String {
        if !watchReachable {
            return String(
                localized: "Open Trio on your watch to start it from here",
                comment: "Drag-to-watch Start: the watch app isn't open"
            )
        }
        return over
            ? String(localized: "Release to start Trio on Watch", comment: "Drag-to-watch Start: over the watch")
            : String(localized: "Drag onto the watch", comment: "Drag-to-watch Start: the hint under the watch")
    }

    @ViewBuilder private func handOff(_ stage: TrioOnWatchPhoneStart.Stage) -> some View {
        VStack(spacing: 18) {
            TrioOnWatchFaceCard(reading: reading, stage: stage)
            VStack(spacing: 8) {
                Text(title(stage))
                    .font(.title3.weight(.semibold))
                Text(detail(stage))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)

            switch stage {
            case .done:
                Button(String(localized: "Done", comment: "Drag-to-watch Start: close after the watch took over")) {
                    close()
                }
                .buttonStyle(.borderedProminent)
                .tint(.insulin)
                Button(String(localized: "End Trio on Watch", comment: "Drag-to-watch Start: open the screen to take back")) {
                    close()
                    onEnd()
                }
                .font(.subheadline)
            case .failed:
                Button(String(localized: "OK", comment: "Dismiss button")) { close() }
                    .buttonStyle(.borderedProminent)
                    .tint(.insulin)
            case .handingOver,
                 .stillWaiting:
                // the hand-off goes on; Home's banner follows it
                Button(String(localized: "Hide", comment: "Drag-to-watch Start: hide the card while the hand-off goes on")) {
                    close()
                }
                .font(.subheadline)
            }
        }
        .padding(32)
        .frame(maxWidth: 380)
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.25)) { drag.reset() }
    }

    private func title(_ stage: TrioOnWatchPhoneStart.Stage) -> String {
        switch stage {
        case .handingOver:
            return String(localized: "Handing over to your watch…", comment: "Drag-to-watch Start: in progress")
        case .stillWaiting:
            return String(localized: "Waiting for your watch", comment: "Drag-to-watch Start: no confirmation yet")
        case .done:
            return String(localized: "Your watch is in control", comment: "Drag-to-watch Start: done")
        case .failed:
            return String(localized: "Trio on Watch didn't start", comment: "Drag-to-watch Start: failed")
        }
    }

    private func detail(_ stage: TrioOnWatchPhoneStart.Stage) -> String {
        let patch = model.status.pumpIsPatch
        switch stage {
        case .handingOver:
            return String(localized: "Keep your iPhone and watch close.", comment: "Drag-to-watch Start: in progress")
        case .stillWaiting:
            return String(
                localized: "Your watch hasn't confirmed it has your pump. Check Trio on your watch.",
                comment: "Drag-to-watch Start: no confirmation yet"
            )
        case .done:
            return patch ? String(
                localized: "It has your patch now and loops with its own sensor readings, the first within 5 minutes.",
                comment: "Drag-to-watch Start: done"
            ) : String(
                localized: "It has your pod now and loops with its own sensor readings, the first within 5 minutes.",
                comment: "Drag-to-watch Start: done"
            )
        case let .failed(text):
            return text
        }
    }
}

/// The watch the glucose was dropped on: the reading, then how the hand-off is going.
struct TrioOnWatchFaceCard: View {
    struct Reading: Equatable {
        var value: String
        var delta: String
        var date: Date?
    }

    let reading: Reading?
    let stage: TrioOnWatchPhoneStart.Stage

    static let glow = Color(red: 0.62, green: 0.42, blue: 0.98)
    static let gradient = LinearGradient(
        colors: [Color(red: 0.72, green: 0.34, blue: 1), Color(red: 0.26, green: 0.73, blue: 0.91)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            // the band
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.gray.opacity(0.22))
                .frame(width: 112, height: 270)
            VStack(spacing: 4) {
                if let date = reading?.date {
                    Text(date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(reading?.value ?? "--")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let delta = reading?.delta, !delta.isEmpty {
                    Text(delta)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                badge
                    .padding(.top, 6)
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(width: 168, height: 196)
            .background(RoundedRectangle(cornerRadius: 42, style: .continuous).fill(Color.black))
            .overlay(RoundedRectangle(cornerRadius: 42, style: .continuous).strokeBorder(Self.gradient, lineWidth: 4))
            .shadow(color: Self.glow.opacity(0.55), radius: 22)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var badge: some View {
        switch stage {
        case .handingOver,
             .stillWaiting:
            ProgressView()
                .tint(.white)
        case .done:
            Label(
                String(localized: "Trio on Watch", comment: "Badge on the watch card once the watch took over"),
                systemImage: "checkmark"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.loopGreen)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.loopGreen.opacity(0.2)))
        case .failed:
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.loopRed)
        }
    }
}

extension TrioOnWatchPhoneStatus {
    /// Why this iPhone sends the pump nothing while it is home.
    var refusedFooter: String {
        switch (podReleasedAtHome, pumpIsPatch) {
        case (true, true):
            return String(
                localized: "Your patch was handed off and not taken back, so this iPhone isn't sending it commands.",
                comment: "Trio on Watch sheet footer for a patch released at home"
            )
        case (true, false):
            return String(
                localized: "Your pod was handed off and not taken back, so this iPhone isn't sending it commands.",
                comment: "Trio on Watch sheet footer for a pod released at home"
            )
        case (false, true):
            return String(
                localized: "Another device used your patch, so this iPhone stopped sending it commands.",
                comment: "Trio on Watch sheet footer for a refused patch"
            )
        case (false, false):
            return String(
                localized: "Another device used your pod, so this iPhone stopped sending it commands.",
                comment: "Trio on Watch sheet footer for a refused pod"
            )
        }
    }
}
