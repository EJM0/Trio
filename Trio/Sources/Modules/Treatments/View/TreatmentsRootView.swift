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

        let resolver: Resolver
        var openWithScanner: Bool = false

        @State var state = StateModel()

        @State private var showPresetSheet = false
        @State private var autofocus: Bool = true
        @State private var calculatorDetent = PresentationDetent.large
        @State private var pushed: Bool = false
        @State private var debounce: DispatchWorkItem?
        @State private var showFatProteinOrderBanner = false

        // Food search state
        @State private var treatmentSearchQuery = ""
        @State private var treatmentSearchResults: [BarcodeScanner.FoodItem] = []
        @State private var isTreatmentSearching = false
        @State private var treatmentSearchError: String?
        @State private var treatmentSearchHasMoreResults = false
        @State private var isLoadingMoreTreatmentSearchResults = false
        @State private var currentTreatmentSearchPage = 1
        @FocusState private var isSearchFocused: Bool
        @State private var isKeyboardVisible = false

        private let foodSearchClient = BarcodeScanner.OpenFoodFactsClient()
        private let treatmentSearchPageSize = 4

        private enum Config {
            static let dividerHeight: CGFloat = 2
            static let spacing: CGFloat = 3
        }

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        @FetchRequest(
            entity: MealPresetStored.entity(),
            sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
        ) var presets: FetchedResults<MealPresetStored>

        private var matchingPresets: [MealPresetStored] {
            if treatmentSearchQuery.isEmpty { return [] }
            return presets.filter {
                ($0.dish ?? "").localizedCaseInsensitiveContains(treatmentSearchQuery)
            }
        }

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

        private var gluoseFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            if state.units == .mmolL {
                formatter.maximumIntegerDigits = 2
                formatter.maximumFractionDigits = 1
            } else {
                formatter.maximumIntegerDigits = 3
                formatter.maximumFractionDigits = 0
            }
            return formatter
        }

        private var fractionDigits: Int {
            if state.units == .mmolL {
                return 1
            } else {
                return 0
            }
        }

        private let scannedDeltaOverlayWidth: CGFloat = 52

        @ViewBuilder private func scannedNutrientDeltaText(value: Decimal) -> some View {
            Text("+ \(Double(truncating: value as NSNumber), specifier: "%.1f")g")
                .font(.caption)
                .foregroundStyle(.blue)
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

        @ViewBuilder private func proteinAndFat() -> some View {
            HStack {
                VStack {
                    HStack {
                        Text("Fat")
                        TextFieldWithToolBar(
                            text: $state.fat,
                            placeholder: "0",
                            keyboardType: .numberPad,
                            numberFormatter: mealFormatter,
                            showArrows: true,
                            previousTextField: { focusedField = previousField(from: .fat) },
                            nextTextField: { focusedField = nextField(from: .fat) },
                            unitsText: String(localized: "g", comment: "Units for carbs")
                        )
                        .focused($focusedField, equals: .fat)
                        .onChange(of: state.fat) {
                            handleDebouncedInput()
                        }
                        .padding(
                            .trailing,
                            state.effectiveScannedFat > 0 ? scannedDeltaOverlayWidth : 0
                        )
                        .overlay(alignment: .trailing) {
                            if state.effectiveScannedFat > 0 {
                                scannedNutrientDeltaText(value: state.effectiveScannedFat)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }

                Divider().foregroundStyle(.primary).fontWeight(.bold).frame(width: 10)

                VStack {
                    HStack {
                        Text("Protein")
                            .fixedSize(horizontal: true, vertical: false)
                        TextFieldWithToolBar(
                            text: $state.protein,
                            placeholder: "0",
                            keyboardType: .numberPad,
                            numberFormatter: mealFormatter,
                            showArrows: true,
                            previousTextField: { focusedField = previousField(from: .protein) },
                            nextTextField: { focusedField = nextField(from: .protein) },
                            unitsText: String(localized: "g", comment: "Units for carbs")
                        )
                        .focused($focusedField, equals: .protein)
                        .onChange(of: state.protein) {
                            handleDebouncedInput()
                        }
                        .padding(
                            .trailing,
                            state.effectiveScannedProtein > 0 ? scannedDeltaOverlayWidth : 0
                        )
                        .overlay(alignment: .trailing) {
                            if state.effectiveScannedProtein > 0 {
                                scannedNutrientDeltaText(value: state.effectiveScannedProtein)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
        }

        @ViewBuilder var foodSearch: some View {
            // Food Search & Quick Actions
            if state.settings != nil && state.settings.settings.barcodeScannerEnabled {
                // Combined search bar with action buttons
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        // Scanner button
                        Button {
                            configureAndShowScanner(showList: false)
                        } label: {
                            Image(systemName: "barcode.viewfinder")
                                .font(.title2)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)

                        // Search field
                        BarcodeScanner.ProductSearchField(
                            searchText: $treatmentSearchQuery,
                            isFocused: $isSearchFocused,
                            onSubmit: {
                                performTreatmentFoodSearch()
                            },
                            onClear: {
                                treatmentSearchQuery = ""
                                treatmentSearchResults = []
                                treatmentSearchError = nil
                                treatmentSearchHasMoreResults = false
                                isLoadingMoreTreatmentSearchResults = false
                                currentTreatmentSearchPage = 1
                            },
                            onChange: {
                                treatmentSearchResults = []
                                treatmentSearchError = nil
                                treatmentSearchHasMoreResults = false
                                isLoadingMoreTreatmentSearchResults = false
                                currentTreatmentSearchPage = 1
                            }
                        )

                        // List button
                        Button {
                            configureAndShowScanner(showList: true)
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "list.bullet")
                                    .font(.title2)
                                    .foregroundStyle(.blue)

                                if !scannerState.scannedProducts.isEmpty {
                                    Text("\(scannerState.scannedProducts.count)")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(4)
                                        .background(Circle().fill(Color.red))
                                        .offset(x: 8, y: -8)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    // Search results and Spinner
                    if !treatmentSearchQuery.isEmpty {
                        let results = matchingPresets
                        ForEach(results) { preset in
                            Button {
                                withAnimation {
                                    var imageSource: BarcodeScanner.FoodItem.ImageSource = .none
                                    if let data = preset.imageData, let image = UIImage(data: data) {
                                        imageSource = .image(image)
                                    }

                                    let item = BarcodeScanner.FoodItem(
                                        barcode: nil,
                                        name: preset.dish ?? "Preset",
                                        brand: "Preset",
                                        imageSource: imageSource,
                                        servingQuantity: preset.amount,
                                        servingQuantityUnit: preset.isMl ? "ml" : "g",
                                        nutriments: .init(
                                            basis: preset.isMl ? .per100ml : .per100g,
                                            carbohydratesPer100g: (preset.carbs as NSDecimalNumber?)?.doubleValue,
                                            fatPer100g: (preset.fat as NSDecimalNumber?)?.doubleValue,
                                            proteinPer100g: (preset.protein as NSDecimalNumber?)?.doubleValue
                                        ),
                                        amount: preset.amount,
                                        isMlInput: preset.isMl,
                                        isManualEntry: true
                                    )
                                    addSearchResultToMeal(item)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    if let data = preset.imageData, let uiImage = UIImage(data: data) {
                                        Image(uiImage: uiImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 44, height: 44)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    } else {
                                        Image(systemName: "fork.knife")
                                            .font(.title2)
                                            .frame(width: 44, height: 44)
                                            .background(Color.gray.opacity(0.1))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .foregroundStyle(.secondary)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preset.dish ?? "Unknown")
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        HStack {
                                            Text("Preset")
                                                .font(.caption2)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 2)
                                                .background(Color.blue.opacity(0.1))
                                                .foregroundStyle(.blue)
                                                .cornerRadius(4)

                                            if let c = preset.carbs {
                                                Text(String(format: "%.0fg carbs", (c as NSDecimalNumber).doubleValue))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.blue)
                                        .font(.title3)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider().opacity(0.3)
                        }
                    }

                    if isTreatmentSearching {
                        HStack {
                            Spacer()
                            ProgressView()
                                .padding(.vertical, 8)
                            Spacer()
                        }
                    } else if let error = treatmentSearchError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if !treatmentSearchResults.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(treatmentSearchResults) { item in
                                BarcodeScanner.FoodSearchResultRow(item: item) {
                                    addSearchResultToMeal(item)
                                }
                                if item.id != treatmentSearchResults.last?.id {
                                    Divider().opacity(0.3)
                                }
                            }

                            if treatmentSearchHasMoreResults {
                                Button {
                                    loadMoreTreatmentSearchResults()
                                } label: {
                                    HStack {
                                        if isLoadingMoreTreatmentSearchResults {
                                            ProgressView()
                                                .scaleEffect(0.9)
                                        } else {
                                            Text("Show 4 more results")
                                                .font(.caption.weight(.medium))
                                            Image(systemName: "chevron.down")
                                                .font(.caption)
                                        }
                                    }
                                    .foregroundStyle(.blue)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                .disabled(isLoadingMoreTreatmentSearchResults)
                            }
                        }
                    }
                }
            }
        }

        @ViewBuilder private func carbsTextField() -> some View {
            HStack {
                Text("Carbs")
                Spacer()
                TextFieldWithToolBar(
                    text: $state.carbs,
                    placeholder: "0",
                    keyboardType: .numberPad,
                    numberFormatter: mealFormatter,
                    showArrows: true,
                    previousTextField: { focusedField = previousField(from: .carbs) },
                    nextTextField: { focusedField = nextField(from: .carbs) },
                    unitsText: String(localized: "g", comment: "Units for carbs")
                )
                .focused($focusedField, equals: .carbs)
                .onChange(of: state.carbs) {
                    handleDebouncedInput()
                }
                .padding(.trailing, state.scannedCarbs > 0 ? scannedDeltaOverlayWidth : 0)
                .overlay(alignment: .trailing) {
                    if state.scannedCarbs > 0 {
                        scannedNutrientDeltaText(value: state.scannedCarbs)
                            .allowsHitTesting(false)
                    }
                }
            }
        }

        /// Determines the next field to focus on based on the current focused field.
        ///
        /// This function handles the tab order navigation between input fields,
        /// taking into account whether fat/protein fields are visible based on user settings.
        ///
        /// - Parameter current: The currently focused field
        /// - Returns: The next field that should receive focus, or nil if there is no next field
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
        ///
        /// This function handles the reverse tab order navigation between input fields,
        /// taking into account whether fat/protein fields are visible based on user settings.
        ///
        /// - Parameter current: The currently focused field
        /// - Returns: The previous field that should receive focus, or nil if there is no previous field
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
            VStack {
                Spacer()
                carbsTextField()

                Divider()

                if state.useFPUconversion {
                    proteinAndFat()

                    if showFatProteinOrderBanner {
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
                        }
                        .listRowBackground(Color.orange.opacity(0.75))
                        .transition(.opacity)
                    }

                    Divider()
                }

                // Time
                HStack {
                    Image(systemName: "clock")

                    Spacer()
                    if !pushed {
                        Button {
                            pushed = true
                        } label: {
                            Text("Now")
                        }.buttonStyle(.borderless).foregroundColor(.secondary)
                            .padding(.trailing, 5)
                    } else {
                        Button {
                            pushed = false
                            state.date = Date()
                        } label: {
                            Text("Reset")
                        }.buttonStyle(.borderless).foregroundColor(.secondary)
                            .padding(.trailing, 5)
                        Button {
                            state.date = state.date.addingTimeInterval(-15.minutes.timeInterval)
                        } label: {
                            Image(systemName: "minus.circle")
                        }.tint(.blue).buttonStyle(.borderless)

                        DatePicker(
                            "Time",
                            selection: $state.date,
                            displayedComponents: [.hourAndMinute]
                        ).controlSize(.mini)
                            .labelsHidden()
                            .onChange(of: state.date) { _, _ in
                                // Trigger simulation when date changes to update forecasts for backdated carbs.
                                // `updateForecasts()` updates the `simulatedDetermination` of type `Determination?`
                                // on the main thread, so its cob value feeds the bolus calc manager.
                                state.refreshInsulinRecommendation(updatingForecasts: true)
                            }
                        Button {
                            state.date = state.date.addingTimeInterval(15.minutes.timeInterval)
                        } label: {
                            Image(systemName: "plus.circle")
                        }.tint(.blue).buttonStyle(.borderless)
                    }
                }

                Divider()

                // Notes
                HStack {
                    Image(systemName: "square.and.pencil")
                    TextFieldWithToolBarString(
                        text: $state.note,
                        placeholder: String(localized: "Note..."),
                        maxLength: 25
                    )
                }
                Spacer()
            }
            .background(Rectangle().fill(Color.chart))
        }

        @ViewBuilder var optionsView: some View {
            VStack {
                if state.fattyMeals || state.sweetMeals {
                    Spacer()
                    HStack(spacing: 10) {
                        if state.fattyMeals {
                            Toggle(isOn: $state.useFattyMealCorrectionFactor) {
                                Text("Reduced Bolus")
                            }
                            .toggleStyle(RadioButtonToggleStyle())
                            .font(.footnote)
                            .onChange(of: state.useFattyMealCorrectionFactor) {
                                // Clear the mutually exclusive option first so the recalculation
                                // below sees a consistent pair of flags. Deselecting recalculates
                                // as well — the option no longer applying changes the result too.
                                if state.useFattyMealCorrectionFactor {
                                    state.useSuperBolus = false
                                }
                                state.refreshInsulinRecommendation()
                            }
                        }
                        if state.sweetMeals {
                            Toggle(isOn: $state.useSuperBolus) {
                                Text("Super Bolus")
                            }
                            .toggleStyle(RadioButtonToggleStyle())
                            .font(.footnote)
                            .onChange(of: state.useSuperBolus) {
                                if state.useSuperBolus {
                                    state.useFattyMealCorrectionFactor = false
                                }
                                state.refreshInsulinRecommendation()
                            }
                        }
                    }
                    Divider()
                }

                Spacer()

                HStack {
                    HStack {
                        Text("Recommendation")
                        Button(
                            action: {
                                state.showInfo.toggle()
                            },
                            label: {
                                Image(systemName: "info.circle")
                            }
                        )
                        .foregroundStyle(.blue)
                        .buttonStyle(PlainButtonStyle())
                    }
                    Spacer()
                    Button {
                        state.amount = state.insulinCalculated
                    } label: {
                        HStack {
                            Text(
                                formatter
                                    .string(from: Double(state.insulinCalculated) as NSNumber) ?? ""
                            )

                            Text(
                                String(
                                    localized:
                                    " U",
                                    comment: "Unit in number of units delivered (keep the space character!)"
                                )
                            ).foregroundColor(.secondary)
                        }
                    }
                    .disabled(state.insulinCalculated == 0 || state.amount == state.insulinCalculated)
                    .buttonStyle(.bordered).padding(.trailing, -10)
                }

                Divider()
                Spacer()

                HStack {
                    Text("Bolus")
                    Spacer()
                    TextFieldWithToolBar(
                        text: $state.amount,
                        placeholder: "0",
                        textColor: colorScheme == .dark ? .white : .blue,
                        maxLength: 5,
                        numberFormatter: formatter,
                        showArrows: true,
                        previousTextField: { focusedField = previousField(from: .bolus) },
                        nextTextField: { focusedField = nextField(from: .bolus) },
                        unitsText: String(localized: "U", comment: "Units for bolus amount")
                    ).focused($focusedField, equals: .bolus)
                        .onChange(of: state.amount) {
                            // Redraws the forecast for the entered dose. Debounced and cancellable so
                            // typing a bolus doesn't queue up an oref simulation per keystroke.
                            handleDebouncedInput(followingAcceptedRecommendation: false)
                        }
                }

                Divider()
                Spacer()

                HStack {
                    Text("External Insulin")
                    Spacer()
                    Toggle("", isOn: $state.externalInsulin).toggleStyle(CheckboxToggleStyle())
                }

                Spacer()
            }
        }

        @ViewBuilder func listView() -> some View {
            List {
                Section {
                    foodSearch
                }.listRowBackground(Color.chart)

                if !bolusWarning.warningMessage.isEmpty {
                    Text(bolusWarning.warningMessage)
                        .textCase(nil)
                        .font(.subheadline)
                        .foregroundColor(bolusWarning.color)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Section {
                    ForecastChart(state: state)
                }.listRowBackground(Color.chart)

                Section {
                    inputsView
                }.listRowBackground(Color.chart)

                Section {
                    optionsView
                }.listRowBackground(Color.chart)
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(sectionSpacing)
            .contentMargins(.top, 0, for: .scrollContent)
        }

        var body: some View {
            ZStack(alignment: .center) {
                listView()
                    .blur(radius: state.showInfo || state.isAwaitingDeterminationResult ? 3 : 0)
                    .safeAreaPadding(.bottom, 50)
                if state.isAwaitingDeterminationResult {
                    CustomProgressView(text: progressText.displayName)
                }
                if !isKeyboardVisible {
                    treatmentButton
                        .padding(.horizontal, 16)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea(.keyboard)
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
            })
            .onReceive(Foundation.NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(Foundation.NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            .onAppear {
                configureView {
                    state.isActive = true
                    Task { @MainActor in
                        state.refreshInsulinRecommendation()
                    }
                    if PropertyPersistentFlags.shared.hasSeenFatProteinOrderChange != true {
                        showFatProteinOrderBanner = true
                    }
                    // Auto-open scanner if requested
                    if openWithScanner {
                        configureAndShowScanner(showList: false)
                    }
                }
            }
            .onDisappear {
                state.isActive = false
                state.addButtonPressed = false

                // Stop scale connection
                scannerState.stopScaleStream()

                // Cancel all Combine subscriptions and unregister State from broadcaster
                state.cleanupTreatmentState()
            }
            .sheet(isPresented: $state.showInfo) {
                PopupView(state: state)
            }
            .sheet(
                isPresented: $showPresetSheet,
                onDismiss: {
                    showPresetSheet = false
                }
            ) {
                PresetListView(scannerState: scannerState) { preset in
                    state.carbs += preset.carbs?.decimalValue ?? 0
                    state.fat += preset.fat?.decimalValue ?? 0
                    state.protein += preset.protein?.decimalValue ?? 0
                }
            }
            .alert("Error while processing Treatment", isPresented: $state.showDeterminationFailureAlert)
            {
                Button("OK", role: .cancel) {
                    state.hideModal()
                }
            } message: {
                Text("\(state.determinationFailureMessage)")
            }
            .sheet(isPresented: $showBarcodeScanner, onDismiss: {
                scannerState.cancelEditing()
                scannerState.isEditingFromList = false
            }) {
                NavigationStack {
                    BarcodeScanner.RootView(
                        resolver: resolver,
                        state: scannerState,
                        showListInitially: initialShowList,
                        onAddTreatments: { carbs, fat, protein, note in
                            // Directly merge scanned amounts into Treatments state
                            Task { @MainActor in
                                state.addScannedAmounts(carbs: carbs, fat: fat, protein: protein, note: note)
                                // Scanned carbs are carbs: force forecasts and recalc the recommendation
                                state.refreshInsulinRecommendation(updatingForecasts: true, forceForecasts: true)
                            }
                        },
                        onDismiss: { showBarcodeScanner = false }
                    )
                    .environment(appState)
                }
                .onChange(of: scannerState.scannedProducts) {
                    syncScannedAmounts()
                }
            }
        }

        @StateObject private var scannerState = BarcodeScanner.StateModel()
        @State private var showBarcodeScanner = false
        @State private var initialShowList = false

        func configureAndShowScanner(showList: Bool) {
            scannerState.showListView = showList
            showBarcodeScanner = true
            initialShowList = showList
        }

        /// Adds a search result to the scanned products and updates calculations
        private func addSearchResultToMeal(_ item: BarcodeScanner.FoodItem) {
            // Add to scanner state's scanned products with default amount
            var mutableItem = item
            mutableItem.amount = item.servingQuantity ?? 100 // Default to serving or 100g
            scannerState.scannedProducts.append(mutableItem)

            // Clear search
            treatmentSearchQuery = ""
            treatmentSearchResults = []
            treatmentSearchError = nil
            treatmentSearchHasMoreResults = false
            isLoadingMoreTreatmentSearchResults = false
            currentTreatmentSearchPage = 1

            // Sync amounts and recalculate
            syncScannedAmounts()
            isSearchFocused = false
        }

        private func performTreatmentFoodSearch() {
            treatmentSearchError = nil
            treatmentSearchResults = []
            treatmentSearchHasMoreResults = false
            currentTreatmentSearchPage = 1
            isLoadingMoreTreatmentSearchResults = false

            let query = treatmentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                isTreatmentSearching = false
                return
            }

            isTreatmentSearching = true

            Task { @MainActor in
                do {
                    let firstPageResults = try await foodSearchClient.searchProducts(
                        query: query,
                        page: 1,
                        pageSize: treatmentSearchPageSize
                    )
                    treatmentSearchResults = firstPageResults
                    treatmentSearchHasMoreResults = firstPageResults.count == treatmentSearchPageSize
                } catch {
                    treatmentSearchError = error.localizedDescription
                    treatmentSearchResults = []
                    treatmentSearchHasMoreResults = false
                }
                isTreatmentSearching = false
            }
        }

        private func loadMoreTreatmentSearchResults() {
            guard !isTreatmentSearching,
                  !isLoadingMoreTreatmentSearchResults,
                  treatmentSearchHasMoreResults
            else {
                return
            }

            let query = treatmentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                treatmentSearchHasMoreResults = false
                return
            }

            isLoadingMoreTreatmentSearchResults = true
            treatmentSearchError = nil

            let nextPage = currentTreatmentSearchPage + 1

            Task { @MainActor in
                defer { isLoadingMoreTreatmentSearchResults = false }

                do {
                    let nextPageResults = try await foodSearchClient.searchProducts(
                        query: query,
                        page: nextPage,
                        pageSize: treatmentSearchPageSize
                    )

                    if nextPageResults.isEmpty {
                        treatmentSearchHasMoreResults = false
                        return
                    }

                    treatmentSearchResults.append(contentsOf: nextPageResults)
                    currentTreatmentSearchPage = nextPage
                    treatmentSearchHasMoreResults = nextPageResults.count == treatmentSearchPageSize
                } catch {
                    treatmentSearchError = error.localizedDescription
                }
            }
        }

        private func syncScannedAmounts() {
            let totalCarbs = scannerState.scannedProducts.reduce(into: 0.0) { result, item in
                let carbsPer100 = item.nutriments.carbohydratesPer100g ?? 0
                let amount = item.amount.isFinite ? item.amount : 0
                result += (carbsPer100 * amount) / 100.0
            }
            let totalProtein = scannerState.scannedProducts.reduce(into: 0.0) { result, item in
                let protPer100 = item.nutriments.proteinPer100g ?? 0
                let amount = item.amount.isFinite ? item.amount : 0
                result += (protPer100 * amount) / 100.0
            }
            let totalFat = scannerState.scannedProducts.reduce(into: 0.0) { result, item in
                let fatPer100 = item.nutriments.fatPer100g ?? 0
                let amount = item.amount.isFinite ? item.amount : 0
                result += (fatPer100 * amount) / 100.0
            }

            state.scannedCarbs = Decimal(totalCarbs)
            state.scannedProtein = Decimal(totalProtein)
            state.scannedFat = Decimal(totalFat)

            // Trigger a recalculation immediately (sheet may make view inactive, so force it).
            // Scanned carbs are carbs, so this goes through the same path as typed macros and
            // follows an already accepted recommendation.
            debug(
                .bolusState,
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
            let isForecastVeryLow = state.minPredBG < 54

            // Only warn when enacting a bolus via pump
            guard !state.externalInsulin, state.amount > 0 else {
                return (false, "", .primary)
            }

            let warningMessage =
                isGlucoseVeryLow
                    ? String(localized: "Glucose is very low.")
                    : isForecastVeryLow ? String(localized: "Glucose forecast is very low.") : ""

            let warningColor: Color =
                isGlucoseVeryLow ? .red : colorScheme == .dark ? .orange : .accentColor

            let shouldConfirm = state.confirmBolus && (isGlucoseVeryLow || isForecastVeryLow)

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
                        .frame(height: 50)
                        .background(treatmentButtonBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                    }
                    .disabled(disableTaskButton)
                    .shadow(radius: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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
            }
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
                RoundedRectangle(cornerRadius: 15)
                    .fill(
                        colorScheme == .dark
                            ? Color(red: 0.03921568627, green: 0.133333333, blue: 0.2156862745)
                            : Color.insulin.opacity(0.2)
                    )
                    .frame(height: 56)
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
            .padding(.horizontal, 10)
            .overlay(alignment: .bottom) {
                BolusProgressBar(progress: progress)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15))
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
            bolusInProgressForEntry || state.addButtonPressed || limitExceeded
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
