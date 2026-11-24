import SwiftUI
import UIKit

/// P1: replaces the loop ring while the phone isn't in control. Symbol, word and age; colour only adds to them.
struct TrioOnWatchPill: View {
    let pill: TrioOnWatchPhoneStatus.Pill
    /// `LoopView`'s ring size, so the symbol sits where the ring does.
    @ScaledMetric(relativeTo: .callout) private var symbolSize: CGFloat = 18

    var body: some View {
        // the age must not be cut at large text (G-M11)
        HStack(alignment: .center) {
            Image(systemName: pill.symbol)
                .resizable()
                .scaledToFit()
                .frame(width: symbolSize, height: symbolSize)
            Text(pill.text).lineLimit(1).minimumScaleFactor(0.6)
        }
        // the loop pill's look: same type, insets and capsule
        .font(.callout).fontWeight(.bold).fontDesign(.rounded)
        .foregroundColor(pill.tint)
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .capsuleSpinner(isActive: false, color: pill.tint)
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

/// P4: why an action is off while Apple Watch is in control, in the look of the Home banners: tinted glass panel,
/// symbol badge, title and detail.
struct TrioOnWatchBlockedNote: View {
    var title = String(localized: "Apple Watch Is in Control", comment: "Home banner title")
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "applewatch")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.insulin)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.insulin.opacity(0.18)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline).fontWeight(.semibold)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(tint: .insulin)
        .accessibilityElement(children: .combine)
        // in a list it is its own panel, not a row on the list's background
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    /// The pump's own screens while it is handed over: the gate's reason, centred.
    static func pumpScreen(_ refusal: String) -> some View {
        TrioOnWatchBlockedNote(
            title: String(localized: "Pump Settings Unavailable", comment: "Pump screen while the pump is on Apple Watch"),
            message: refusal
        )
        .padding()
        .frame(maxHeight: .infinity)
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
                                localized: "Only do this if no other device should control this patch. If another device still runs it, stop Trio there first: with a patch, that device may not notice right away.",
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

    /// Home, in global coordinates; the overlay sets it.
    var screenFrame: CGRect = .zero

    var isActive: Bool { step != .idle }
    var ringCenter: CGPoint { CGPoint(x: ringFrame.midX + translation.width, y: ringFrame.midY + translation.height) }
    /// The watch's screen to drop on, as the overlay draws it: its case, resting on Home's bottom edge.
    var targetFrame: CGRect {
        guard !screenFrame.isEmpty else { return .zero }
        let scale = Self.watchScale(width: screenFrame.width)
        let center = Self.watchCenter(in: screenFrame)
        let width = TrioOnWatchStyle.caseWidth * scale
        let height = TrioOnWatchStyle.caseHeight * scale
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    var isOverTarget: Bool { targetFrame.contains(ringCenter) }

    /// The watch while the glucose is held: two thirds of Home's width.
    static func watchScale(width: CGFloat) -> CGFloat {
        min(width * 0.68 / TrioOnWatchStyle.caseWidth, 1.8)
    }

    /// The watch while the glucose is held: its case resting on Home's bottom edge, the lower band below it.
    static func watchCenter(in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.maxY - TrioOnWatchStyle.caseHeight * watchScale(width: frame.width) / 2)
    }

    static let pollInterval: UInt64 = 500_000_000

    func reset() {
        step = .idle
        translation = .zero
        isConfirming = false
    }

    /// What the watch's own Start screen discloses; this Start doesn't show it.
    static func confirmationText(patch: Bool) -> String {
        [
            patch ? String(
                localized: "Check that your patch and sensor don't end soon.",
                comment: "Drag-to-watch Start confirmation"
            ) : String(
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

/// Over all of Home while the glucose is held: the lifted glucose and a large watch peeking up from the screen's bottom
/// edge to drop it on; once dropped, that watch shrinks to its normal size in the middle while the hand-off goes on.
struct TrioOnWatchStartOverlay<Ring: View>: View {
    @Bindable var drag: TrioOnWatchStartDrag
    let model: TrioOnWatchPhoneModel
    @ViewBuilder let ring: () -> Ring
    /// Opens the Trio on Watch screen, where control is taken back.
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let size = geo.size
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.3))
                // one watch through both steps, so the drop animates it from the edge to the middle
                if drag.isActive {
                    TrioOnWatchWatch(highlighted: isOver) { watchFace }
                        .scaleEffect(watchScale(size))
                        .opacity(isDragging && !watchReachable ? 0.4 : 1)
                        .position(watchCenter(size))
                        .animation(.easeOut(duration: 0.15), value: isOver)
                }
                switch drag.step {
                case .dragging:
                    dragging(size: size, origin: origin)
                case let .handOff(stage):
                    handOff(stage)
                        .padding(.horizontal, 32)
                        .frame(maxWidth: 380)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, handOffWatchY(size) + TrioOnWatchStyle.watchHeight / 2 + 18)
                        .transition(.opacity)
                case .idle:
                    EmptyView()
                }
            }
            .onAppear { drag.screenFrame = geo.frame(in: .global) }
            .onChange(of: geo.size) { drag.screenFrame = geo.frame(in: .global) }
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
    private var isDragging: Bool { drag.step == .dragging }
    private var isOver: Bool { isDragging && drag.isOverTarget && watchReachable }

    /// While dragging, large (the drop target); after the drop, its normal size.
    private func watchScale(_ size: CGSize) -> CGFloat {
        guard isDragging else { return 1 }
        let large = TrioOnWatchStartDrag.watchScale(width: size.width)
        return isOver ? large * 1.04 : large
    }

    /// While dragging, on the bottom edge; after the drop, in the middle.
    private func watchCenter(_ size: CGSize) -> CGPoint {
        guard isDragging else { return CGPoint(x: size.width / 2, y: handOffWatchY(size)) }
        return TrioOnWatchStartDrag.watchCenter(in: CGRect(origin: .zero, size: size))
    }

    private func handOffWatchY(_ size: CGSize) -> CGFloat { size.height * 0.36 }

    @ViewBuilder private var watchFace: some View {
        if case let .handOff(stage) = drag.step {
            face(stage)
        }
    }

    /// The hint above the watch and the lifted glucose.
    @ViewBuilder private func dragging(size: CGSize, origin: CGPoint) -> some View {
        let ringAt = CGPoint(x: drag.ringCenter.x - origin.x, y: drag.ringCenter.y - origin.y)
        let watchTop = watchCenter(size).y - TrioOnWatchStyle.watchHeight * watchScale(size) / 2

        Text(targetText(over: isOver))
            .font(.callout.weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 260)
            .position(x: size.width / 2, y: watchTop - 32)

        ring()
            .scaleEffect(isOver ? 0.8 : 1.05)
            .shadow(color: TrioOnWatchStyle.glow.opacity(isOver ? 0.9 : 0.5), radius: isOver ? 26 : 16)
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

    /// Under the watch during the hand-off: how it goes, and what can be done.
    @ViewBuilder private func handOff(_ stage: TrioOnWatchPhoneStart.Stage) -> some View {
        VStack(spacing: 18) {
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
    }

    /// The watch's face during the hand-off: a spinner, then the glucose once the watch has the pump.
    @ViewBuilder private func face(_ stage: TrioOnWatchPhoneStart.Stage) -> some View {
        switch stage {
        case .handingOver,
             .stillWaiting:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        case .done:
            ring()
                .scaleEffect(0.8)
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        case .failed:
            Image(systemName: "xmark")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Color.loopRed)
        }
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

enum TrioOnWatchStyle {
    static let glow = Color(red: 0.62, green: 0.42, blue: 0.98)
    static let gradient = LinearGradient(
        colors: [Color(red: 0.72, green: 0.34, blue: 1), Color(red: 0.26, green: 0.73, blue: 0.91)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// The watch from band end to band end.
    static let watchHeight: CGFloat = 270
    static let caseWidth: CGFloat = 168
    static let caseHeight: CGFloat = 196
}

/// A watch drawn on Home: the band, and the case showing `face`.
struct TrioOnWatchWatch<Face: View>: View {
    var highlighted = false
    @ViewBuilder let face: () -> Face

    var body: some View {
        ZStack {
            // the band
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.gray.opacity(0.22))
                .frame(width: 112, height: TrioOnWatchStyle.watchHeight)
            // the case is its own shape: modifiers on an empty face would draw nothing
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 42, style: .continuous)
                        .strokeBorder(TrioOnWatchStyle.gradient, lineWidth: highlighted ? 6 : 4)
                )
                .overlay { face().foregroundStyle(.white) }
                .frame(width: TrioOnWatchStyle.caseWidth, height: TrioOnWatchStyle.caseHeight)
                .shadow(color: TrioOnWatchStyle.glow.opacity(highlighted ? 0.9 : 0.55), radius: highlighted ? 30 : 22)
        }
        // one layer, so a faded watch doesn't show its band through the case
        .compositingGroup()
        .accessibilityHidden(true)
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
