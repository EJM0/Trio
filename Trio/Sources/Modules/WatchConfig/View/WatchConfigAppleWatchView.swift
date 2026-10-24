import CoreTransferable
import SwiftUI
import Swinject
import UniformTypeIdentifiers

struct WatchConfigAppleWatchView: BaseView {
    let resolver: Resolver
    @ObservedObject var state: WatchConfig.StateModel

    @State private var shouldDisplayHint: Bool = false
    @State var hintDetent = PresentationDetent.large
    @State var selectedVerboseHint: AnyView?
    @State var hintLabel: String?
    @State private var decimalPlaceholder: Decimal = 0.0
    @State private var booleanPlaceholder: Bool = false

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private func onDelete(offsets: IndexSet) {
        state.devices.remove(atOffsets: offsets)
        state.deleteGarminDevice()
    }

    var body: some View {
        List {
            // what the watch shows
            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.showForecastWatch,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Show Forecast on Watch")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Show Forecast on Watch"),
                miniHint: String(localized: "Draws the predicted glucose into the watch's charts."),
                verboseHint: Text(
                    "When this is on, the watch's glucose charts, the minimal screen's included, continue past now with the predicted glucose, as lines or as a cone as set for the main chart. The charts then span less of the past. While the watch loops untethered, the prediction is its own loop's."
                ),
                headerText: String(localized: "Display")
            )

            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.showGlucoseBubbleWatch,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Show Glucose Bubble on Watch")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Show Glucose Bubble on Watch"),
                miniHint: String(localized: "Adds a watch page with only the large glucose bubble."),
                verboseHint: Text(
                    "When this is on, the watch has a page with only the large glucose bubble, after the first page. When this is off, that page is gone; the first page, with the bubble above the chart, stays."
                ),
                headerText: nil
            )

            // treatments from the wrist
            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.confirmBolusFaster,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Confirm Bolus Faster")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Confirm Bolus Faster"),
                miniHint: String(localized: "Confirming a bolus on the watch takes a much shorter crown turn."),
                verboseHint: Text(
                    "A bolus on the watch is confirmed by turning the Digital Crown until the ring is full. When this is on, each step of the crown fills ten times as much of it, so a short turn confirms. Off, it takes several full turns, which makes a bolus by accident harder."
                ),
                headerText: String(localized: "Treatments")
            )

            // the watch's own link to the G7, with or without untethered mode
            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.watchSensorAlwaysOn,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Watch Reads the Sensor")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Watch Reads the Sensor"),
                miniHint: String(
                    localized: "The watch reads the Dexcom G7 itself, next to the iPhone. Off saves watch battery: the watch then shows the iPhone's glucose only."
                ),
                verboseHint: VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "When this is on, the watch connects to your Dexcom G7 at each reading, in the sensor's slot for a watch, so the iPhone keeps its own. Glucose on the watch and its complications stays current with the iPhone out of reach or its app asleep, and Fallback Loop can tell when the iPhone's readings stop. The connections cost some watch battery."
                    )
                    Text("When this is off, the watch reads the sensor only while it loops untethered. Otherwise:")
                    Text(
                        "• Glucose on the watch and on its complications comes from the iPhone only, and stops while the iPhone is away."
                    )
                    Text(
                        "• The complications update far less often: watchOS redraws them in the background mainly when a Bluetooth connection wakes the app, otherwise about every half hour at most."
                    )
                    Text(
                        "• Untethered mode starts without readings: the watch first has to find the sensor, and pair with a new one."
                    )
                    Text("• Fallback Loop is not available.")
                },
                headerText: String(localized: "Sensor")
            )

            // the watch running the loop: the switch, then what it allows and the session itself
            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.untetheredModeWatch,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Untethered Mode")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Untethered Mode"),
                miniHint: String(
                    localized: "The watch can take over the loop, with its own connection to the pod and the sensor."
                ),
                verboseHint: VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "When this is on, untethered mode can be started here or on the watch's status page. The iPhone then hands the pod over: the watch connects to it and to the sensor itself and runs the loop, with the iPhone's settings, until it hands the pod back. Meanwhile the iPhone shows glucose but doesn't dose. Only the Omnipod DASH and the Dexcom G7 are supported."
                    )
                    Text(
                        "The iPhone keeps sending the watch a copy of its settings and history, so the watch can also start while the iPhone is away (Allow Start Without iPhone)."
                    )
                    Text(
                        "When this is off, neither the iPhone nor the watch starts untethered mode, the watch hides its status page and the iPhone stops sending the copy. A session still running hands back."
                    )
                },
                headerText: String(localized: "Untethered Mode")
            )

            if state.untetheredModeWatch {
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.allowUntetheredStartWithoutPhoneWatch,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Allow Start Without iPhone")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Allow Start Without iPhone"),
                    miniHint: String(localized: "The watch can take over the pod while the iPhone can't be reached."),
                    verboseHint: VStack(alignment: .leading, spacing: 8) {
                        Text(
                            "When this is on, the watch's status page offers Start Without Phone while the iPhone can't be reached. The watch then starts from the last copy of the iPhone's settings and history it was sent, and takes the pod over itself. The iPhone learns of it once it is back, and stops dosing."
                        )
                        Text(
                            "When this is off, untethered mode starts only with the iPhone in reach, and Fallback Loop is not available."
                        )
                    },
                    headerText: nil
                )

                // starts by itself when the iPhone's readings stop; needs the watch's own sensor link
                if state.allowUntetheredStartWithoutPhoneWatch, state.watchSensorAlwaysOn {
                    SettingInputSection(
                        decimalValue: $decimalPlaceholder,
                        booleanValue: $state.fallbackLoopWatch,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: Binding(
                            get: { selectedVerboseHint },
                            set: {
                                selectedVerboseHint = $0.map { AnyView($0) }
                                hintLabel = String(localized: "Fallback Loop")
                            }
                        ),
                        units: state.units,
                        type: .boolean,
                        label: String(localized: "Fallback Loop"),
                        miniHint: String(localized: "The watch takes over the loop by itself when the iPhone stops looping."),
                        verboseHint: VStack(alignment: .leading, spacing: 8) {
                            Text(
                                "When this is on, the watch compares its own sensor readings with the iPhone's. When it has a reading the iPhone hasn't sent and the iPhone's newest is over 10 minutes old, it asks the Trio app on the iPhone directly. If the app doesn't answer within 15 seconds, the watch starts untethered mode from the last copy and takes the pod over."
                            )
                            Text(
                                "Once the iPhone answers again with current glucose, the watch hands the pod back by itself. Only one of them doses at a time: while the watch has the pod, the iPhone doesn't dose."
                            )
                            Text("Needs Watch Reads the Sensor and Allow Start Without iPhone.")
                        },
                        headerText: nil
                    )
                }

                // a workout session that is never saved keeps Trio running through the session
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.untetheredWorkoutWatch,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Extended Untethered Mode")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Extended Untethered Mode"),
                    miniHint: String(
                        localized: "More stable untethered mode: a workout keeps Trio running on the watch, at a clear battery cost."
                    ),
                    verboseHint: VStack(alignment: .leading, spacing: 8) {
                        Text(
                            "When this is on, the watch runs a workout with each untethered session, from the start to the hand-back. watchOS doesn't suspend an app with a running workout, so Trio stays awake between sensor readings: fewer readings and loops are missed, and its own checks keep running."
                        )
                        Text(
                            "The workout is discarded at the end: it doesn't appear in the Fitness app or count toward the activity rings. It collects only the heart rate, for the minimal screen. The first start asks on the watch for permission to use workouts and read the heart rate."
                        )
                        Text("While it runs:")
                        Text(
                            "• The watch shows the workout symbol at the top, and raising the wrist shows Trio instead of the watch face: its minimal screen, or the full app with Minimal Screen off."
                        )
                        Text(
                            "To keep the watch face instead: on the Apple Watch, open Settings → General → Return to Clock → Trio, turn on Custom, choose Always, and turn off Return to App during a session. Trio keeps running and stays awake; tap the workout symbol at the top of the watch face to open it."
                        )
                        .padding(.leading, 12)
                        Text("• The heart rate sensor runs the whole time: the watch battery drains noticeably faster.")
                        Text(
                            "• Ending the workout on the watch stops the keeping awake until the next untethered session. Untethered mode itself goes on."
                        )
                    },
                    headerText: nil
                )

                if state.untetheredWorkoutWatch {
                    Section {
                        Toggle("Minimal Screen", isOn: $state.watchGlanceEnabled)
                        if state.watchGlanceEnabled {
                            NavigationLink("Minimal Screen Layout") {
                                WatchGlanceConfigurationView(layout: $state.watchGlanceLayout)
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                    } footer: {
                        Text(
                            "While the workout runs, watchOS shows Trio instead of the watch face when the wrist comes up. With Minimal Screen on, that is a calm dark screen you arrange here; tap it for the full app. Off, it is the full app at once. The workout and the keeping awake are the same either way."
                        )
                    }
                    .listRowBackground(Color.chart)
                }

                // a wash of the untethered color over the home screen while the watch doses (Kristin Kandschur, 3010a9a15)
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.untetheredTintHomeWatch,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Tint Home Screen While Watch Loops")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Tint Home Screen While Watch Loops"),
                    miniHint: String(localized: "Color the whole home screen while the watch has the pump"),
                    verboseHint: Text(
                        "While the watch runs the loop, the home screen's background takes the untethered color, so you see at a glance that the phone doesn't dose. When this is off, only the bar at the bottom shows it."
                    ),
                    headerText: nil
                )

                UntetheredSettingsSection(manager: resolver.resolve(UntetheredPhoneManager.self)!)
            }

            Section(
                header: Text("Contact Image"),
                content: {
                    VStack {
                        HStack {
                            NavigationLink("Contacts Configuration") {
                                ContactImage.RootView(resolver: resolver)
                            }.foregroundStyle(Color.accentColor)
                        }
                    }
                }
            ).listRowBackground(Color.chart)
        }
        .listSectionSpacing(sectionSpacing)
        .sheet(isPresented: $shouldDisplayHint) {
            SettingInputHintView(
                hintDetent: $hintDetent,
                shouldDisplayHint: $shouldDisplayHint,
                hintLabel: hintLabel ?? "",
                hintText: selectedVerboseHint ?? AnyView(EmptyView()),
                sheetTitle: String(localized: "Help", comment: "Help sheet title")
            )
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.automatic)
        .settingsHighlightScroll()
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
    }
}

/// Arranges Extended Untethered Mode's minimal watch screen, as the Live Activity's widgets are: drag an element onto a
/// slot, tap one to add it, drag it back onto the list or tap its trash to remove it.
struct WatchGlanceConfigurationView: View {
    @Binding var layout: WatchGlanceLayout

    @State private var targetedSlot: Int?
    @State private var isPaletteTargeted = false

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private static let rowHeight: CGFloat = 46
    private static let watchWidth: CGFloat = 230

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                watchPreview

                HStack(alignment: .top) {
                    Image(systemName: "info.circle")
                    Text(
                        "Drag an element onto a slot, or tap it to add it. Drag it back onto the list, or tap its trash, to remove it. Wide elements take two or three slots of their row."
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(.secondary)
                .font(.footnote)

                palette(String(localized: "Middle"), items: WatchGlanceItem.centerItems)
                palette(String(localized: "Elements"), items: WatchGlanceItem.rowItems)

                Button(String(localized: "Reset to Default")) { apply { $0 = .standard } }
                    .padding(.top, 4)
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
        .navigationTitle("Minimal Screen")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - The watch

    private var watchPreview: some View {
        VStack(spacing: 6) {
            row(0)
            slotView(WatchGlanceLayout.center, item: layout.slots[WatchGlanceLayout.center])
                .frame(height: 110)
            row(1)
        }
        .padding(10)
        .frame(width: Self.watchWidth)
        .background(RoundedRectangle(cornerRadius: 36, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 36, style: .continuous).stroke(Color.gray.opacity(0.5), lineWidth: 3))
        .environment(\.colorScheme, .dark)
    }

    private func row(_ index: Int) -> some View {
        let slots = WatchGlanceLayout.rows[index].count
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(layout.row(index), id: \.slot) { element in
                    slotView(element.slot, item: element.item)
                        .padding(2)
                        .frame(width: geometry.size.width * CGFloat(element.item?.width ?? 1) / CGFloat(slots))
                }
            }
        }
        .frame(height: Self.rowHeight)
    }

    @ViewBuilder private func slotView(_ slot: Int, item: WatchGlanceItem?) -> some View {
        let isTargeted = targetedSlot == slot
        Group {
            if let item {
                tile(item, highlighted: isTargeted)
                    .overlay(alignment: .topTrailing) {
                        Button { apply { $0.clear(slot) } } label: {
                            Image(systemName: "trash.circle.fill")
                                .foregroundColor(Color(UIColor.systemGray2))
                                .background(Circle().fill(Color.white))
                                .font(.body)
                        }
                        .offset(x: 6, y: -6)
                        .accessibilityLabel(Text("Remove \(item.label)"))
                    }
                    .draggable(item) { tile(item).frame(width: 70, height: Self.rowHeight) }
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [4]))
                    .foregroundColor(isTargeted ? Color.accentColor : Color.gray)
                    .overlay(Image(systemName: "plus").foregroundColor(.secondary))
                    .accessibilityLabel(Text("Empty slot"))
            }
        }
        .dropDestination(for: WatchGlanceItem.self) { dropped, _ in
            targetedSlot = nil
            guard let item = dropped.first else { return false }
            var placed = false
            apply { placed = $0.place(item, at: slot) }
            return placed
        } isTargeted: { hovering in
            if hovering { targetedSlot = slot } else if targetedSlot == slot { targetedSlot = nil }
        }
    }

    private func tile(_ item: WatchGlanceItem, highlighted: Bool = false) -> some View {
        sample(item)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(highlighted ? Color.accentColor : Color.gray.opacity(0.6), lineWidth: highlighted ? 2 : 1)
            )
    }

    // MARK: - Palette

    private func palette(_ title: String, items: [WatchGlanceItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).foregroundColor(.secondary).font(.footnote)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                ForEach(items, id: \.self) { item in
                    paletteCell(item)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(isPaletteTargeted ? 0.25 : 0.1)))
        .dropDestination(for: WatchGlanceItem.self) { dropped, _ in
            isPaletteTargeted = false
            guard let item = dropped.first, layout.slots.contains(item) else { return false }
            apply { $0.remove(item) }
            return true
        } isTargeted: { isPaletteTargeted = $0 }
    }

    private func paletteCell(_ item: WatchGlanceItem) -> some View {
        let isPlaced = layout.slots.contains(item)
        return VStack(spacing: 4) {
            tile(item)
                .frame(height: Self.rowHeight)
                .environment(\.colorScheme, .dark)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
            Text(item.label + (item.width > 1 ? " (\(item.width)×)" : ""))
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(isPlaced ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !isPlaced { apply { $0.placeInFirstFreeSlot(item) } } }
        .draggable(item) { tile(item).frame(width: 70, height: Self.rowHeight) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(isPlaced ? "Already on the screen" : "Adds this element to the screen"))
    }

    // MARK: - Samples

    @ViewBuilder private func sample(_ item: WatchGlanceItem) -> some View {
        switch item {
        case .glucoseLarge:
            VStack(spacing: 0) {
                Text("123 →").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Color.loopGreen)
                Text("12:05  +3").font(.caption2.weight(.semibold)).foregroundStyle(.gray)
            }
        case .glucoseChart:
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("123 →").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Color.loopGreen)
                    Text("12:05").font(.caption2.weight(.semibold)).foregroundStyle(.gray)
                }
                chartSample
            }
        case .chart:
            chartSample
        default:
            HStack(spacing: 4) {
                ForEach(item.parts, id: \.self) { part in
                    VStack(spacing: 0) {
                        partSample(part).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                        Text(part == .glucose ? "12:05" : part.label.uppercased()).font(.system(size: 7, weight: .medium))
                            .foregroundStyle(.gray)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder private func partSample(_ item: WatchGlanceItem) -> some View {
        switch item {
        case .glucose: Text("123→").foregroundStyle(Color.loopGreen)
        case .loop:
            HStack(spacing: 2) {
                Circle().stroke(Color.loopGreen, lineWidth: 2).frame(width: 9, height: 9)
                Text("2m")
            }
        case .iob: Text("1.25").foregroundStyle(Color.insulin)
        case .cob: Text("24").foregroundStyle(Color.orange)
        case .tempBasal: Text("0.85")
        case .eventualGlucose: Text("108")
        case .heartRate:
            HStack(spacing: 1) {
                Image(systemName: "heart.fill").font(.system(size: 8)).foregroundStyle(Color.red)
                Text("72")
            }
        case .reservoir: Text("86 U")
        case .lastReading: Text("1m")
        case .totalDailyDose: Text("38.4 U")
        case .clock: Text("12:05")
        default: Text("")
        }
    }

    private var chartSample: some View {
        Image(systemName: "chart.dots.scatter")
            .font(.system(size: 26))
            .foregroundStyle(Color.loopGreen, Color.cyan.opacity(0.6))
    }

    // MARK: - Changes

    private func apply(_ change: (inout WatchGlanceLayout) -> Void) {
        var changed = layout
        change(&changed)
        guard changed != layout else { return }
        withAnimation(.easeInOut(duration: 0.2)) { layout = changed }
    }
}

extension WatchGlanceItem: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}
