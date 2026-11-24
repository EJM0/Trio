import Charts
import CoreData
import LoopKitUI
import SwiftUI
import Swinject
import UIKit

extension Treatments {
    struct RootView: BaseView {
        enum FocusedField {
            case carbs
            case fat
            case protein
            case bolus
        }

        @FocusState private var focusedField: FocusedField?
        /// While the note is being written it takes the whole input card.
        @FocusState private var isNoteFocused: Bool
        /// Follows `isNoteFocused` inside an animation: a focus change alone would snap the list row's height.
        @State private var noteExpanded = false
        @State private var showTimeWheel = false

        let resolver: Resolver
        /// Set by the `.treatmentWithScanner` route (the Siri shortcut). Which tab opens is
        /// decided here, not by the caller, because it depends on the feature settings.
        var opensMealManagerOnAppear: Bool = false

        @State var state = StateModel()

        @State private var showPresetSheet = false
        @State private var watchHasPump = false
        @State private var autofocus: Bool = true
        @State private var calculatorDetent = PresentationDetent.large
        @State private var debounce: DispatchWorkItem?
        @State private var showFatProteinOrderBanner = false

        // Meal search state lives on MealManager.StateModel, which this screen shares with the
        // Meal Manager sheet -- it used to be duplicated here as a second, independent copy.
        @FocusState private var isSearchFocused: Bool
        @State private var isKeyboardVisible = false
        /// Height of the treatment button area, warning panel included, so the list can scroll clear of it.
        @State private var treatmentButtonAreaHeight: CGFloat = TreatmentCardMetrics.height

        private enum Config {
            static let dividerHeight: CGFloat = 2
            static let spacing: CGFloat = 3
        }

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private var formatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumIntegerDigits = 2
            formatter.maximumFractionDigits = 3
            return formatter
        }

        private var bolusProgressFormatter: NumberFormatter {
            let fractionDigits: Int = switch state.settingsManager.preferences.bolusIncrement {
            case 0.1: 1
            case 0.025: 3
            default: 2
            }

            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimum = 0
            formatter.maximumFractionDigits = fractionDigits
            formatter.minimumFractionDigits = fractionDigits
            formatter.allowsFloats = true
            formatter.roundingIncrement = Double(state.settingsManager.preferences.bolusIncrement) as NSNumber
            return formatter
        }

        private var mealFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumIntegerDigits = 3
            formatter.maximumFractionDigits = 0
            return formatter
        }

        private var fractionDigits: Int {
            if state.units == .mmolL {
                return 1
            } else {
                return 0
            }
        }

        @ViewBuilder private func scannedNutrientDeltaText(value: Decimal, onTint: Bool = false) -> some View {
            Text("+ \(Double(truncating: value as NSNumber), specifier: "%.1f")g")
                .font(.caption)
                .foregroundStyle(onTint ? Color.white : Color.blue)
                .monospacedDigit()
                .lineLimit(1)
        }

        /// Handles macro input (carb, fat, protein) in a debounced fashion.
        ///
        /// The Bolus field uses this too, with `followingAcceptedRecommendation: false`: its edits
        /// change the forecast the chart draws, but must not rewrite the amount being typed.
        func handleDebouncedInput(followingAcceptedRecommendation: Bool = true) {
            debounce?.cancel()
            debounce = DispatchWorkItem { [self] in
                Task { @MainActor in
                    state.refreshInsulinRecommendation(
                        updatingForecasts: true,
                        followsAcceptedAmount: followingAcceptedRecommendation
                    )
                }
            }
            if let debounce = debounce {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: debounce)
            }
        }

        /// Macro colours clear of the chart's: insulin and IOB are blue, the ZT forecast purple. Carbs keep COB's orange.
        private static let carbsColor = Color.orange
        private static let fatColor = Color(red: 0.86, green: 0.62, blue: 0.10) // amber
        private static let proteinColor = Color(red: 0.86, green: 0.33, blue: 0.45) // rose

        /// A carb, fat or protein tile: title, entered amount, and the amount the scanned items add. Focused, it fills
        /// with the macro's colour, as a picked amount does in the quick-pick menu; holding an amount, it keeps a rim
        /// in that colour.
        @ViewBuilder private func macroTile(
            _ title: LocalizedStringKey,
            text: Binding<Decimal>,
            field: FocusedField,
            scanned: Decimal,
            color: Color
        ) -> some View {
            let active = focusedField == field
            let hasAmount = text.wrappedValue > 0 || scanned > 0
            let secondary = active ? Color.white.opacity(0.85) : Color.secondary
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) {
                    Text(title).lineLimit(1).allowsTightening(true).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    if scanned > 0 { scannedNutrientDeltaText(value: scanned, onTint: active) }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    TextFieldWithToolBar(
                        text: text,
                        placeholder: "0",
                        textColor: active ? .white : .primary,
                        textAlignment: .leading,
                        keyboardType: .numberPad,
                        numberFormatter: mealFormatter,
                        showArrows: true,
                        previousTextField: { focusedField = previousField(from: field) },
                        nextTextField: { focusedField = nextField(from: field) }
                    )
                    .font(.title2.weight(.semibold))
                    .focused($focusedField, equals: field)
                    .onChange(of: text.wrappedValue) { handleDebouncedInput() }
                    Text(String(localized: "g", comment: "Units for carbs")).font(.footnote.weight(.semibold))
                        .foregroundStyle(secondary)
                }
            }
            // the selected tile's rim is a lighter shade of its fill, so the selection stands out
            .treatmentTile(tint: active ? color : nil, rim: active || hasAmount ? color : nil, lightRim: active)
            .animation(.easeInOut(duration: 0.15), value: active)
            .animation(.easeInOut(duration: 0.15), value: hasAmount)
            .contentShape(Rectangle())
            .onTapGesture { focusedField = field }
        }

        /// Meal search: saved presets, plus OpenFoodFacts when the barcode scanner is enabled.
        ///
        /// The two settings are independent. `displayPresets` governs local meal presets and
        /// `mealManagerScannerEnabled` governs the barcode scanner and OpenFoodFacts, so either
        /// one on is enough to show this section, and turning the scanner off no longer takes
        /// offline preset search down with it.
        private var showsFoodSearch: Bool { mealManager.displayPresets || mealManager.isScannerEnabled }

        @ViewBuilder var foodSearch: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    MealManager.MealSearchBar(state: mealManager, isFocused: $isSearchFocused, background: Color.chart)

                    if mealManager.isScannerEnabled {
                        Button {
                            openMealManager(at: .scanner)
                        } label: {
                            Image(systemName: "barcode.viewfinder")
                                .font(.title3)
                                .foregroundStyle(.blue)
                                .frame(width: 40, height: 40)
                                .background(Color.chart, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Open Barcode Scanner"))
                    }
                }

                if !mealManager.searchQuery.isEmpty {
                    MealManager.SearchResults(state: mealManager, layout: .stack) { item in
                        addSearchResultToMeal(item)
                    }
                }
            }
        }

        /// The meal list (scanned items and presets), with the number of items in the meal.
        private var mealListButton: some View {
            Button {
                openMealManager(at: .scanned)
            } label: {
                Image(systemName: "list.bullet")
                    .overlay(alignment: .topTrailing) {
                        if !mealManager.scannedProducts.isEmpty {
                            Text("\(mealManager.scannedProducts.count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Circle().fill(Color.red))
                                .offset(x: 10, y: -10)
                        }
                    }
            }
        }

        /// Determines the next field to focus on based on the current focused field.
        private func nextField(from current: FocusedField) -> FocusedField? {
            // If fat/protein fields are hidden, skip them in navigation
            let showFPU = state.useFPUconversion

            switch current {
            case .fat:
                return .protein
            case .protein:
                return .bolus
            case .carbs:
                return showFPU ? .fat : .bolus
            case .bolus:
                return .carbs
            }
        }

        /// Determines the previous field to focus on based on the current focused field.
        private func previousField(from current: FocusedField) -> FocusedField? {
            let showFPU = state.useFPUconversion

            switch current {
            case .fat:
                return .carbs
            case .protein:
                return .fat
            case .carbs:
                return .bolus
            case .bolus:
                return showFPU ? .protein : .carbs
            }
        }

        @ViewBuilder var inputsView: some View {
            VStack(spacing: 8) {
                // while the note is written, the other tiles step aside and the note takes the card
                if !noteExpanded {
                    HStack(spacing: 8) {
                        macroTile("Carbs", text: $state.carbs, field: .carbs, scanned: state.scannedCarbs, color: Self.carbsColor)
                        if state.useFPUconversion {
                            macroTile(
                                "Fat",
                                text: $state.fat,
                                field: .fat,
                                scanned: state.effectiveScannedFat,
                                color: Self.fatColor
                            )
                            macroTile(
                                "Protein",
                                text: $state.protein,
                                field: .protein,
                                scanned: state.effectiveScannedProtein,
                                color: Self.proteinColor
                            )
                        }
                    }
                    .transition(.opacity)

                    if state.useFPUconversion, showFatProteinOrderBanner {
                        HStack {
                            Image(systemName: "arrow.left.arrow.right")
                            Text("The order of Fat and Protein inputs has changed.").font(.callout)
                            Spacer()
                            Button {
                                PropertyPersistentFlags.shared.hasSeenFatProteinOrderChange = true
                                withAnimation { showFatProteinOrderBanner = false }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Dismiss"))
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                        .transition(.opacity)
                    }
                }

                HStack(spacing: 8) {
                    if !noteExpanded { timeTile.transition(.opacity) }
                    noteTile
                }
            }
            .padding(.vertical, 4)
            .onChange(of: isNoteFocused) { _, focused in
                withAnimation(Self.resize) { noteExpanded = focused }
            }
        }

        private static let resize = Animation.spring(response: 0.35, dampingFraction: 0.85)

        /// A time other than the screen's opening time, as the forecast and the popup tell a backdated entry.
        private var isCustomTime: Bool { abs(state.date.timeIntervalSince(state.defaultDate)) > 1.0 }

        /// "Now" or the set time; a tap opens the system time wheel in a small popover. A set time can go back to now.
        private var timeTile: some View {
            HStack(spacing: 6) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                // its own popover rather than the compact picker's: a tap outside then only closes the wheel (the time
                // is set as it turns) and doesn't fall through to the note
                Button {
                    showTimeWheel = true
                } label: {
                    Group {
                        if isCustomTime {
                            Text(state.date, style: .time).foregroundStyle(.blue)
                        } else {
                            Text("Now")
                        }
                    }
                    .frame(height: Self.rowTileHeight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Time"))
                .popover(isPresented: $showTimeWheel) {
                    DatePicker("Time", selection: $state.date, displayedComponents: [.hourAndMinute])
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .padding(.horizontal, 12)
                        .presentationCompactAdaptation(.popover)
                }
                if isCustomTime {
                    Button {
                        state.date = state.defaultDate
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Now"))
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: Self.rowTileHeight)
            .treatmentTile(fills: false)
            // Trigger simulation when date changes to update forecasts for backdated carbs.
            // `updateForecasts()` updates the `simulatedDetermination` of type `Determination?`
            // on the main thread, so its cob value feeds the bolus calc manager.
            .onChange(of: state.date) { _, _ in
                state.refreshInsulinRecommendation(updatingForecasts: true)
            }
            .animation(.snappy, value: isCustomTime)
        }

        private static let noteMaxLength = 25

        /// Content height of the time and note tiles, so the two line up.
        private static let rowTileHeight: CGFloat = 28

        private var noteTile: some View {
            HStack(alignment: noteExpanded ? .firstTextBaseline : .center) {
                Image(systemName: "pencil").foregroundStyle(.secondary)
                TextField(String(localized: "Note..."), text: $state.note, axis: .vertical)
                    .lineLimit(noteExpanded ? 8 : 1)
                    .focused($isNoteFocused)
                    .onChange(of: state.note) { _, note in
                        if note.count > Self.noteMaxLength { state.note = String(note.prefix(Self.noteMaxLength)) }
                    }
                    .toolbar {
                        if isNoteFocused {
                            ToolbarItemGroup(placement: .keyboard) {
                                Button { state.note = "" } label: { Image(systemName: "trash") }
                                    .accessibilityLabel(Text("Clear"))
                                Spacer()
                                Button { isNoteFocused = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                                    .accessibilityLabel(Text("Dismiss keyboard"))
                            }
                        }
                    }
            }
            .font(.subheadline)
            .frame(
                minHeight: noteExpanded ? 180 : Self.rowTileHeight,
                alignment: noteExpanded ? .topLeading : .leading
            )
            .treatmentTile()
            .contentShape(Rectangle())
            .onTapGesture { isNoteFocused = true }
        }

        private enum BolusVariant: Hashable {
            case normal
            case reduced
            case superBolus
        }

        /// Reduced and super bolus exclude each other; every change recalculates the recommendation.
        private var bolusVariant: Binding<BolusVariant> {
            Binding(
                get: { state.useSuperBolus ? .superBolus : state.useFattyMealCorrectionFactor ? .reduced : .normal },
                set: { variant in
                    state.useFattyMealCorrectionFactor = variant == .reduced
                    state.useSuperBolus = variant == .superBolus
                    state.refreshInsulinRecommendation()
                }
            )
        }

        private var hasBolusVariants: Bool { state.fattyMeals || state.sweetMeals }

        private var recommendationInfoButton: some View {
            Button {
                state.showInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .foregroundStyle(.blue)
            .buttonStyle(.plain)
            .accessibilityLabel(Text("About the recommendation"))
        }

        private var formattedRecommendation: String {
            formatter.string(from: Double(state.insulinCalculated) as NSNumber) ?? ""
        }

        @ViewBuilder var optionsView: some View {
            VStack(spacing: 10) {
                if hasBolusVariants {
                    HStack(spacing: 8) {
                        recommendationInfoButton.font(.title3)
                        Picker("", selection: bolusVariant) {
                            Text("Normal").tag(BolusVariant.normal)
                            if state.fattyMeals { Text("Reduced").tag(BolusVariant.reduced) }
                            if state.sweetMeals { Text("Super Bolus").tag(BolusVariant.superBolus) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("Recommendation")
                            // without the bolus variants there is no selector row to sit in
                            if !hasBolusVariants { recommendationInfoButton }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                        Button {
                            state.amount = state.insulinCalculated
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(formattedRecommendation).font(.title2.weight(.semibold)).foregroundStyle(.primary)
                                    // a long amount shrinks to stay on one line next to "use"
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                    .contentTransition(.numericText())
                                    .animation(.snappy, value: state.insulinCalculated)
                                Text(String(localized: "U", comment: "Units for bolus amount"))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 6)
                                Text(String(localized: "use", comment: "Copies the recommended bolus into the bolus field"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.blue)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(state.insulinCalculated == 0 || state.amount == state.insulinCalculated)
                        .accessibilityLabel(Text(
                            "Use recommended bolus, " + formattedRecommendation
                                + " " + String(localized: "units", comment: "Insulin units, spoken")
                        ))
                        .accessibilityHint(Text("Copies the recommended amount into the bolus field"))
                    }
                    .treatmentTile(dashed: true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bolus").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            TextFieldWithToolBar(
                                text: $state.amount,
                                placeholder: "0",
                                textColor: colorScheme == .dark ? .white : .blue,
                                textAlignment: .leading,
                                maxLength: 5,
                                numberFormatter: formatter,
                                showArrows: true,
                                previousTextField: { focusedField = previousField(from: .bolus) },
                                nextTextField: { focusedField = nextField(from: .bolus) }
                            )
                            .font(.title2.weight(.semibold))
                            .focused($focusedField, equals: .bolus)
                            .onChange(of: state.amount) {
                                // Redraws the forecast for the entered dose. Debounced and cancellable so
                                // typing a bolus doesn't queue up an oref simulation per keystroke.
                                handleDebouncedInput(followingAcceptedRecommendation: false)
                            }
                            Text(String(localized: "U", comment: "Units for bolus amount")).font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .treatmentTile()
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .bolus }
                }

                Toggle("External Insulin", isOn: $state.externalInsulin)
            }
            .padding(.vertical, 4)
        }

        /// The screen's cards. A scroll view rather than a `List`: a list snaps a row's height when it changes with
        /// the keyboard (the note opening), where a stack animates it.
        @ViewBuilder func listView() -> some View {
            ScrollView {
                VStack(spacing: sectionSpacing) {
                    // the phone's forecast and recommendation are stale while the watch doses (G-M9)
                    if watchHasPump {
                        // the screen's only content, so it sits in the middle like an empty state
                        TrioOnWatchBlockedNote(message: TrioOnWatchBlockedNote.treatments)
                            .containerRelativeFrame(.vertical)
                    } else {
                        // no card of its own: the field is already a box
                        if showsFoodSearch { foodSearch }
                        ForecastChart(state: state).treatmentCard()
                        inputsView.treatmentCard()
                        optionsView.treatmentCard()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
        }

        var body: some View {
            ZStack(alignment: .center) {
                listView()
                    .blur(radius: state.showInfo || state.isAwaitingDeterminationResult ? 3 : 0)
                    .safeAreaPadding(.bottom, treatmentButtonAreaHeight)
                if state.isAwaitingDeterminationResult {
                    CustomProgressView(text: progressText.displayName)
                }
                // nothing to send while the watch has the pump: no dead button under the note
                if !isKeyboardVisible, !watchHasPump {
                    treatmentButton
                        .padding(.horizontal, 16)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                            treatmentButtonAreaHeight = height
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea(.keyboard)
                }
                // while the time wheel is open a tap anywhere only closes it: no field starts editing, no button acts
                if showTimeWheel {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { showTimeWheel = false }
                }
            }
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
            .navigationTitle("Treatments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        state.hideModal()
                    } label: {
                        Text("Close")
                    }
                }
                if showsFoodSearch, !watchHasPump {
                    ToolbarItem(placement: .topBarTrailing) { mealListButton }
                }
            })
            .onReceive(Foundation.NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(Foundation.NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            // When this screen is already up, the shortcut cannot come in via the modal router --
            // it de-duplicates on screen id, so re-sending the same screen is a no-op. Handle the
            // notification here instead and just present the sheet.
            .onReceive(Foundation.NotificationCenter.default.publisher(for: .openBarcode)) { _ in
                openMealManager(at: shortcutTab)
            }
            .onAppear {
                // This screen owns the MealManager state model and reads its feature gates before
                // the sheet is ever opened, so it has to do the resolver hand-off that
                // MealManager.RootView.configureView() would otherwise do. Clearing isInitial
                // keeps that call a no-op, so subscribe() is not run twice.
                if mealManager.isInitial {
                    mealManager.resolver = resolver
                    mealManager.isInitial = false
                }

                watchHasPump = resolver.resolve(WatchLoanGate.self)?.phoneMayCommandPump == false
                #if DEBUG
                    if TrioOnWatchPhoneFixture.showsBlockedNotes { watchHasPump = true }
                #endif
                configureView {
                    state.isActive = true
                    Task { @MainActor in
                        state.refreshInsulinRecommendation()
                    }
                    if PropertyPersistentFlags.shared.hasSeenFatProteinOrderChange != true {
                        showFatProteinOrderBanner = true
                    }
                    if opensMealManagerOnAppear {
                        openMealManager(at: shortcutTab)
                    }
                }
            }
            .onDisappear {
                state.isActive = false
                state.addButtonPressed = false

                // Stop scale connection
                mealManager.stopScaleStream()

                // Cancel all Combine subscriptions and unregister State from broadcaster
                state.cleanupTreatmentState()
            }
            .sheet(isPresented: $state.showInfo) {
                PopupView(state: state)
            }
            .alert("Error while processing Treatment", isPresented: $state.showDeterminationFailureAlert)
            {
                Button("OK", role: .cancel) {
                    state.hideModal()
                }
            } message: {
                Text("\(state.determinationFailureMessage)")
            }
            .sheet(isPresented: $showMealManager, onDismiss: {
                // Here rather than on Done, so a swipe-down closes the scale link too.
                mealManager.stopScaleStream()
                mealManager.cancelEditing()
                mealManager.isEditorPresentedAsSheet = false
            }) {
                NavigationStack {
                    // No `onAddTreatments:` here any more. It was wired through the root view
                    // and the state model but never called from anywhere; the live path is the
                    // `onChange(of:)` on `scannedProducts` below.
                    MealManager.RootView(
                        resolver: resolver,
                        state: mealManager,
                        onDismiss: { showMealManager = false }
                    )
                    .environment(appState)
                }
            }
            // Observed here rather than inside the sheet builder: items can also be added from
            // the inline search results, when no sheet is presented.
            .onChange(of: mealManager.scannedProducts) {
                syncScannedAmounts()
            }
        }

        /// Owned here, not by the sheet: the Treatments screen reads `scannedProducts` to keep
        /// its macro totals in step, so the model has to outlive each presentation of the sheet.
        @StateObject private var mealManager = MealManager.StateModel()
        @State private var showMealManager = false

        /// Opens the Meal Manager sheet on a specific tab.
        func openMealManager(at tab: MealManager.ListTab) {
            mealManager.selectedTab = tab
            showMealManager = true
        }

        /// The tab the "Open Barcode Scanner" shortcut should land on: the scanner when it is
        /// enabled, otherwise the saved meal presets, which are the only way in that is left.
        private var shortcutTab: MealManager.ListTab {
            mealManager.isScannerEnabled ? .scanner : .presets
        }

        /// Adds a search result to the meal and clears the search.
        private func addSearchResultToMeal(_ item: FoodItem) {
            var mutableItem = item
            mutableItem.amount = item.servingQuantity ?? 100 // Default to serving or 100g
            mealManager.scannedProducts.append(mutableItem)

            mealManager.clearSearch()
            isSearchFocused = false
            // scannedProducts is observed in `body`, which drives syncScannedAmounts().
        }

        private func syncScannedAmounts() {
            let items = mealManager.scannedProducts
            state.scannedCarbs = Decimal(items.reduce(0) { $0 + $1.carbs })
            state.scannedProtein = Decimal(items.reduce(0) { $0 + $1.protein })
            state.scannedFat = Decimal(items.reduce(0) { $0 + $1.fat })

            // Trigger a recalculation immediately (sheet may make view inactive, so force it).
            // Scanned carbs are carbs, so this goes through the same path as typed macros and
            // follows an already accepted recommendation.
            debug(
                .bolus,
                "syncScannedAmounts: carbs=\(state.carbs) scannedCarbs=\(state.scannedCarbs) totalCarbs=\(state.carbs + state.scannedCarbs)"
            )
            Task { @MainActor in
                state.refreshInsulinRecommendation(updatingForecasts: true, forceForecasts: true)
            }
        }

        var progressText: ProgressText {
            switch (state.amount > 0, (state.carbs + state.scannedCarbs) > 0) {
            case (true, true):
                return .updatingIOBandCOB
            case (false, true):
                return .updatingCOB
            case (true, false):
                return .updatingIOB
            default:
                return .updatingTreatments
            }
        }

        @State private var showConfirmDialogForBolusing = false

        private var bolusWarning: (shouldConfirm: Bool, warningMessage: String, color: Color) {
            let isGlucoseVeryLow = state.currentBG < 54

            // Only warn when enacting a bolus via pump
            guard !state.externalInsulin, state.amount > 0 else {
                return (false, "", .primary)
            }

            let warningMessage = LowGlucoseBolusWarning.message(currentBG: state.currentBG, minPredBG: state.minPredBG) ?? ""

            let warningColor: Color =
                isGlucoseVeryLow ? .red : colorScheme == .dark ? .orange : .accentColor

            let shouldConfirm = LowGlucoseBolusWarning.shouldConfirm(
                confirmBolus: state.confirmBolus,
                currentBG: state.currentBG,
                minPredBG: state.minPredBG
            )

            return (shouldConfirm, warningMessage, warningColor)
        }

        var treatmentButton: some View {
            let shouldDisplayBolusProgress = bolusInProgressForEntry

            var treatmentButtonBackground = Color(.systemBlue)
            if limitExceeded {
                treatmentButtonBackground = Color(.systemRed)
            } else if disableTaskButton {
                treatmentButtonBackground = Color(.systemGray)
            }

            return Section {
                if shouldDisplayBolusProgress {
                    bolusInProgressView
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                } else {
                    ZStack(alignment: .bottom) {
                        if !bolusWarning.warningMessage.isEmpty {
                            bolusWarningPanel
                                .transition(.move(edge: .bottom))
                        }
                        enactTreatmentButton(background: treatmentButtonBackground)
                    }
                    // Same width and corners as `bolusInProgressView`. The clip makes the warning panel
                    // slide out from behind the button instead of rising from below it.
                    .padding(.horizontal, TreatmentCardMetrics.horizontalInset)
                    .clipShape(RoundedRectangle(cornerRadius: TreatmentCardMetrics.cornerRadius))
                    .animation(.easeInOut(duration: 0.25), value: bolusWarning.warningMessage)
                }
            }
        }

        /// Sits behind the treatment button, same width and corners, and shows the bolus warning in the part
        /// that sticks out above it.
        private var bolusWarningPanel: some View {
            VStack(spacing: 0) {
                Text(bolusWarning.warningMessage)
                    .font(.subheadline)
                    .foregroundStyle(bolusWarning.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                // Covered by the button.
                Color.clear.frame(height: TreatmentCardMetrics.height)
            }
            // The default list row background, as the warning row in the list used to have.
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: TreatmentCardMetrics.cornerRadius)
            )
        }

        private func enactTreatmentButton(background: Color) -> some View {
            Button {
                if bolusWarning.shouldConfirm {
                    showConfirmDialogForBolusing = true
                } else {
                    state.invokeTreatmentsTask()
                }
            } label: {
                HStack {
                    taskButtonLabel
                }
                .font(.headline)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: TreatmentCardMetrics.height)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: TreatmentCardMetrics.cornerRadius))
            }
            .disabled(disableTaskButton)
            .glassActionSheet(
                Text(bolusWarning.warningMessage + " Bolus \(state.amount.description) U?"),
                isPresented: $showConfirmDialogForBolusing,
                actions: [
                    GlassSheetAction(
                        verbatim: bolusWarning.warningMessage
                            .isEmpty ? String(localized: "Enact Bolus") :
                            String(localized: "Ignore Warning and Enact Bolus"),
                        role: bolusWarning.warningMessage.isEmpty ? nil : .destructive
                    ) {
                        state.invokeTreatmentsTask()
                    }
                ]
            )
        }

        /// Card-style in-progress visualizer matching Home's `bolusView` look:
        /// insulin-tinted background, cross.vial.fill icon, "Bolusing" + "X of Y U" text,
        /// xmark.app cancel, gradient progress bar overlaid at the bottom.
        @ViewBuilder private var bolusInProgressView: some View {
            let progress = state.bolusProgress ?? 0
            let bolusTotal = state.lastPumpBolus?.bolus?.amount as Decimal?
            let bolusFraction = (bolusTotal ?? 0) * progress
            let bolusString: String = {
                guard let bolusTotal = bolusTotal else { return String(localized: "Bolus In Progress...") }
                return (bolusProgressFormatter.string(from: bolusFraction as NSNumber) ?? "0")
                    + String(localized: " of ", comment: "Bolus string partial message: 'x U of y U' in home view")
                    + (Formatter.decimalFormatterWithThreeFractionDigits.string(from: bolusTotal as NSNumber) ?? "0")
                    + String(localized: " U", comment: "Insulin unit")
            }()
            let bolusLabel = state.bolusStatus == .inProgress ? String(localized: "Bolusing") : String(localized: "Initiating…")

            ZStack {
                // background card
                RoundedRectangle(cornerRadius: TreatmentCardMetrics.cornerRadius)
                    .fill(
                        colorScheme == .dark
                            ? Color(red: 0.03921568627, green: 0.133333333, blue: 0.2156862745)
                            : Color.insulin.opacity(0.2)
                    )
                    .frame(height: TreatmentCardMetrics.height)
                    .shadow(
                        color: colorScheme == .dark
                            ? Color(red: 0.02745098039, green: 0.1098039216, blue: 0.1411764706)
                            : Color.black.opacity(0.33),
                        radius: 3
                    )

                // bolus content
                HStack {
                    Image(systemName: "cross.vial.fill")
                        .font(.system(size: 25))

                    Spacer()

                    VStack {
                        Text(bolusLabel)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(bolusString)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 5)

                    Spacer()

                    if state.bolusStatus == .inProgress {
                        Button { state.cancelBolus() } label: {
                            Image(systemName: "xmark.app")
                                .font(.system(size: 25))
                        }.tint(Color.tabBar)
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Cancel bolus")
                    } else if state.bolusStatus == .initiating {
                        ProgressView()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.trailing, 8)
            }
            .padding(.horizontal, TreatmentCardMetrics.horizontalInset)
            .overlay(alignment: .bottom) {
                BolusProgressBar(progress: progress)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: TreatmentCardMetrics.cornerRadius))
        }

        private var taskButtonLabel: some View {
            if pumpBolusLimitExceeded {
                return Text("Max Bolus of \(state.maxBolus.description) U Exceeded")
            } else if externalBolusLimitExceeded {
                return Text("Max External Bolus of \(state.maxExternal.description) U Exceeded")
            } else if carbLimitExceeded {
                return Text("Max Carbs of \(state.maxCarbs.description) g Exceeded")
            } else if fatLimitExceeded {
                return Text("Max Fat of \(state.maxFat.description) g Exceeded")
            } else if proteinLimitExceeded {
                return Text("Max Protein of \(state.maxProtein.description) g Exceeded")
            }

            let hasInsulin = state.amount > 0
            let hasCarbs = state.carbs > 0 || state.scannedCarbs > 0
            let hasFatOrProtein =
                state.fat > 0 || state.effectiveScannedFat > 0 || state.protein > 0 || state.effectiveScannedProtein > 0
            let bolusString =
                state.externalInsulin
                    ? String(localized: "External Insulin") : String(localized: "Enact Bolus")

            // Note: when a pump bolus is in progress, the row is rendered by `bolusInProgressView`
            // (Home-style card), so this label's in-progress branch is intentionally absent.

            switch (hasInsulin, hasCarbs, hasFatOrProtein) {
            case (true, true, true):
                return Text("Log Meal and \(bolusString)")
            case (true, true, false):
                return Text("Log Carbs and \(bolusString)")
            case (true, false, true):
                return Text("Log FPU and \(bolusString)")
            case (true, false, false):
                return Text(state.externalInsulin ? String(localized: "Log External Insulin") : String(localized: "Enact Bolus"))
            case (false, true, true):
                return Text("Log Meal")
            case (false, true, false):
                return Text("Log Carbs")
            case (false, false, true):
                return Text("Log FPU")
            default:
                return Text("Continue Without Treatment")
            }
        }

        private var pumpBolusLimitExceeded: Bool {
            !state.externalInsulin && state.amount > state.maxBolus
        }

        private var externalBolusLimitExceeded: Bool {
            state.externalInsulin && state.amount > state.maxExternal
        }

        private var carbLimitExceeded: Bool {
            (state.carbs + state.scannedCarbs) > state.maxCarbs
        }

        private var fatLimitExceeded: Bool {
            (state.fat + state.effectiveScannedFat) > state.maxFat
        }

        private var proteinLimitExceeded: Bool {
            (state.protein + state.effectiveScannedProtein) > state.maxProtein
        }

        private var limitExceeded: Bool {
            pumpBolusLimitExceeded || externalBolusLimitExceeded || carbLimitExceeded || fatLimitExceeded
                || proteinLimitExceeded
        }

        private var bolusInProgressForEntry: Bool {
            // .initiating covers pumps that take a few seconds before reporting progress
            (state.bolusProgress != nil || state.bolusStatus == .initiating) &&
                state.amount > 0 && !state.externalInsulin
        }

        private var disableTaskButton: Bool {
            watchHasPump || bolusInProgressForEntry || state.addButtonPressed || limitExceeded
        }
    }

    struct DividerDouble: View {
        var body: some View {
            VStack(spacing: 2) {
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(.gray.opacity(0.65))
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(.gray.opacity(0.65))
            }
            .frame(height: 4)
            .padding(.vertical)
        }
    }

    struct DividerCustom: View {
        var body: some View {
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.gray.opacity(0.65))
                .padding(.vertical)
        }
    }
}

/// The rounded tile the treatment inputs sit in; a dashed outline marks a value to take over.
private struct TreatmentTile: ViewModifier {
    var dashed: Bool
    /// False sizes the tile to its content instead of sharing the row's width.
    var fills: Bool
    /// Fills the tile with this colour instead of the neutral one.
    var tint: Color?
    /// Outlines the tile in this colour.
    var rim: Color?
    /// Lightens the rim (white over it: `Color.mix` needs iOS 18).
    var lightRim: Bool

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: fills ? .infinity : nil, alignment: .leading)
            .background {
                if !dashed { RoundedRectangle(cornerRadius: 12).fill(tint ?? Color.secondary.opacity(0.12)) }
            }
            .overlay {
                if dashed {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else if let rim {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(rim, lineWidth: lightRim ? 2.5 : 2)
                    if lightRim {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.5), lineWidth: 2.5)
                    }
                }
            }
    }
}

private extension View {
    /// One of the screen's cards, in the colour the list's sections had.
    func treatmentCard() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color.chart, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    func treatmentTile(
        dashed: Bool = false,
        fills: Bool = true,
        tint: Color? = nil,
        rim: Color? = nil,
        lightRim: Bool = false
    ) -> some View {
        modifier(TreatmentTile(dashed: dashed, fills: fills, tint: tint, rim: rim, lightRim: lightRim))
    }
}

/// Shared by the treatment button, the bolus warning panel behind it and the bolus progress card, so the three line up.
private enum TreatmentCardMetrics {
    static let height: CGFloat = 56
    static let cornerRadius: CGFloat = 15
    static let horizontalInset: CGFloat = 10
}
