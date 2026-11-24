import SwiftUI
import UIKit

// MARK: - Device pickers

/// Presents the "Add CGM" / "Add Pump" pickers for the home screen.
///
/// Both selections are applied in `onDismiss` rather than inline: the home view already stacks several sheets,
/// and presenting the device setup sheet while the picker is still dismissing gets dropped by SwiftUI.
private struct DevicePickersModifier: ViewModifier {
    @Binding var showPumpSelection: Bool
    @Binding var showCGMSelection: Bool
    @Binding var pendingPump: PumpCatalogEntry?
    @Binding var pendingCGM: CGMCatalogEntry?
    let state: Home.StateModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showPumpSelection, onDismiss: {
                if let entry = pendingPump {
                    pendingPump = nil
                    state.addPump(entry)
                }
            }) {
                DevicePickerView(
                    title: String(localized: "Add Pump", comment: "The title of the pump chooser in settings"),
                    entries: DeviceCatalog.pumps
                ) { entry in
                    pendingPump = entry
                    showPumpSelection = false
                }
            }
            .sheet(isPresented: $showCGMSelection, onDismiss: {
                if let entry = pendingCGM {
                    pendingCGM = nil
                    state.addCGM(cgm: CGMModel(entry))
                }
            }) {
                DevicePickerView(
                    title: String(localized: "Add CGM", comment: "The title of the CGM chooser in settings"),
                    entries: DeviceCatalog.cgms
                ) { entry in
                    pendingCGM = entry
                    showCGMSelection = false
                }
            }
    }
}

extension View {
    func devicePickers(
        showPumpSelection: Binding<Bool>,
        showCGMSelection: Binding<Bool>,
        pendingPump: Binding<PumpCatalogEntry?>,
        pendingCGM: Binding<CGMCatalogEntry?>,
        state: Home.StateModel
    ) -> some View {
        modifier(DevicePickersModifier(
            showPumpSelection: showPumpSelection,
            showCGMSelection: showCGMSelection,
            pendingPump: pendingPump,
            pendingCGM: pendingCGM,
            state: state
        ))
    }
}

// MARK: - Zone B: header (pump panel / glucose bobble / loop status)

extension Home.RootView {
    /// The glucose bobble alone; also what is lifted when it is dragged onto the watch.
    var glucoseRing: some View {
        CurrentGlucoseView(
            timerDate: state.timerDate,
            units: state.units,
            alarm: state.alarm,
            lowGlucose: state.lowGlucose,
            highGlucose: state.highGlucose,
            cgmAvailable: state.cgmAvailable,
            currentGlucoseTarget: state.currentGlucoseTarget,
            glucoseColorScheme: state.glucoseColorScheme,
            glucose: state.latestTwoGlucoseValues,
            cgmProgress: state.cgmProgressHighlight,
            cgmStatus: state.cgmDisplayState,
            cgmSensorExpiresAt: state.cgmSensorExpiresAt,
            cgmWarmupEndsAt: state.cgmWarmupEndsAt
        )
    }

    var glucoseView: some View {
        glucoseRing
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { watchStartDrag.ringFrame = $0 }
            .onTapGesture {
                if !state.cgmAvailable {
                    showCGMSelection.toggle()
                } else {
                    state.shouldDisplayCGMSetupSheet.toggle()
                }
            }
            .gesture(glucoseHoldGesture)
            .onChange(of: glucoseTouched) { _, touched in
                guard !touched else { return }
                // after the gesture's own end has run: a hold still marked started was cancelled, not ended
                DispatchQueue.main.async {
                    guard watchStartDrag.holdStarted else { return }
                    watchStartDrag.holdStarted = false
                    if watchStartDrag.step == .dragging, !watchStartDrag.isConfirming {
                        withAnimation(.spring(duration: 0.3)) { watchStartDrag.reset() }
                    }
                }
            }
            .accessibilityAction {
                if !state.cgmAvailable {
                    showCGMSelection.toggle()
                } else {
                    state.shouldDisplayCGMSetupSheet.toggle()
                }
            }
            .accessibilityAction(named: Text("Snooze alerts")) {
                showSnoozeSheet = true
            }
            .accessibilityAction(named: Text(String(
                localized: "Start Trio on Watch",
                comment: "Accessibility action on the glucose: the drag-to-watch Start without dragging"
            ))) {
                guard trioOnWatch.status.offersDragToStart else { return }
                watchStartDrag.isConfirming = true
            }
    }

    /// Hold the glucose and drag it onto the watch to start Trio on Watch. Alerts are snoozed from the bell.
    var glucoseHoldGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($glucoseTouched) { _, touched, _ in touched = true }
            .onChanged { value in
                guard case let .second(true, drag) = value else { return }
                if !watchStartDrag.holdStarted {
                    watchStartDrag.holdStarted = true
                    guard trioOnWatch.status.offersDragToStart, !watchStartDrag.isActive else { return }
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    withAnimation(.easeOut(duration: 0.2)) { watchStartDrag.step = .dragging }
                }
                guard watchStartDrag.step == .dragging, let drag else { return }
                let wasOver = watchStartDrag.isOverTarget
                watchStartDrag.translation = drag.translation
                if watchStartDrag.isOverTarget != wasOver { UISelectionFeedbackGenerator().selectionChanged() }
            }
            .onEnded { _ in
                watchStartDrag.holdStarted = false
                guard watchStartDrag.step == .dragging else { return }
                if watchStartDrag.isOverTarget, trioOnWatch.status.watchReachable {
                    watchStartDrag.isConfirming = true
                } else {
                    withAnimation(.spring(duration: 0.3)) { watchStartDrag.reset() }
                }
            }
    }

    /// The reading on the watch card of the drag-to-watch Start.
    var watchCardReading: TrioOnWatchFaceCard.Reading? {
        guard let latest = state.latestTwoGlucoseValues.first else { return nil }
        let value = Int(latest.glucose)
        let delta = state.latestTwoGlucoseValues.dropFirst().first.map {
            Decimal(value - Int($0.glucose)).formattedDelta(for: state.units)
        } ?? ""
        return TrioOnWatchFaceCard.Reading(value: value.formatted(for: state.units), delta: delta, date: latest.date)
    }

    var pumpView: some View {
        Group {
            if trioOnWatch.status.replacesLoopRing {
                // this phone's pod readings stop at the hand-off (G-M9)
                TrioOnWatchPumpPlaceholder()
            } else {
                PumpView(
                    reservoir: state.reservoir,
                    name: state.pumpName,
                    expiresAtDate: state.pumpExpiresAtDate,
                    activatedAtDate: state.pumpActivatedAtDate,
                    timerDate: state.timerDate,
                    pumpStatusHighlightMessage: state.pumpStatusHighlightMessage,
                    battery: state.batteryFromPersistence
                )
            }
        }
        .onTapGesture {
            if trioOnWatch.status.replacesLoopRing {
                // the kit's screens offer commands the gate refuses while the watch has the pump
                showTrioOnWatch = true
            } else if state.pumpDisplayState == nil {
                // shows user confirmation dialog with pump model choices, then proceeds to setup
                showPumpSelection.toggle()
            } else {
                // sends user to pump settings
                state.shouldDisplayPumpSetupSheet.toggle()
            }
        }
        // group reservoir/battery/pod into one button so VO reads it as a single control
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(
            state.pumpDisplayState == nil
                ? String(localized: "Opens pump setup", comment: "Accessibility hint")
                : String(localized: "Opens pump settings", comment: "Accessibility hint")
        ))
        .accessibilityAction {
            if trioOnWatch.status.replacesLoopRing {
                showTrioOnWatch = true
            } else if state.pumpDisplayState == nil {
                showPumpSelection.toggle()
            } else {
                state.shouldDisplayPumpSetupSheet.toggle()
            }
        }
    }

    @ViewBuilder func rightHeaderPanel() -> some View {
        VStack(alignment: .center, spacing: 20) {
            if trioOnWatch.status.replacesLoopRing {
                TrioOnWatchPill(pill: trioOnWatch.status.pill(now: state.timerDate))
                    .onTapGesture { showTrioOnWatch = true }
                    .accessibilityAction { showTrioOnWatch = true }
            } else {
                /// Loop view at bottomLeading
                LoopView(
                    dosingMode: state.dosingMode,
                    timerDate: state.timerDate,
                    isLooping: state.isLooping,
                    lastLoopDate: state.lastLoopDate,
                    manualTempBasal: state.manualTempBasal,
                    lastGlucoseDate: state.lastGlucoseDate,
                    lastPumpCommsDate: state.lastPumpCommsDate,
                    hasDeviceIssue: state.hasDeviceIssue,
                    determination: state.determinationsFromPersistence
                )
                .onTapGesture {
                    state.isLoopStatusPresented = true
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text(String(localized: "Opens loop status", comment: "Accessibility hint")))
                .accessibilityAction { state.isLoopStatusPresented = true }
            }
            /// eventualBG string at bottomTrailing

            // the phone's last own forecast says nothing while the watch doses
            if !trioOnWatch.status.replacesLoopRing,
               let eventualBG = state.enactedAndNonEnactedDeterminations.first?.eventualBG
            {
                let eventualGlucose = eventualBG as Decimal
                HStack {
                    Image(systemName: "arrow.right.circle")
                        .font(.callout)
                        .fontWeight(.bold)

                    Text(eventualGlucose.formatted(for: state.units))
                        .font(.callout)
                        .fontWeight(.bold)
                        .fontDesign(.rounded)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Eventual glucose"))
                .accessibilityValue(Text(
                    eventualGlucose.formatted(for: state.units)
                        + " " + state.units.spokenValue
                ))
            } else {
                HStack {
                    Image(systemName: "arrow.right.circle")
                        .font(.callout).fontWeight(.bold)
                    Text("--")
                        .font(.callout).fontWeight(.bold).fontDesign(.rounded)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Eventual glucose"))
                .accessibilityValue(Text(verbatim: "--"))
            }
        }
    }
}
