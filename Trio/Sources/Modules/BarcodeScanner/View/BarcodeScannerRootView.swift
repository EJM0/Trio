import CoreData
import SwiftUI
import Swinject
import UIKit

// MARK: - Root View

extension BarcodeScanner {
    struct RootView: BaseView {
        let resolver: Resolver
        var showListInitially: Bool = false
        var onAddTreatments: ((Decimal, Decimal, Decimal, String) -> Void)?

        @ObservedObject var state: StateModel
        @State private var isEditingFromList = false
        @State private var showEditorCard = false
        @State private var selectedListTab: ListTab = .scanned
        @FocusState private var focusedItemID: UUID?
        @FocusState private var isSearchFocused: Bool
        @State private var showAllSearchResults = false
        @Environment(\.managedObjectContext) var moc

        @FetchRequest(
            entity: MealPresetStored.entity(),
            sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
        ) var presets: FetchedResults<MealPresetStored>

        private var matchingPresets: [MealPresetStored] {
            if state.searchQuery.isEmpty { return [] }
            return presets.filter { ($0.dish ?? "").localizedCaseInsensitiveContains(state.searchQuery) }
        }

        init(
            resolver: Resolver,
            state: StateModel,
            showListInitially: Bool = false,
            onAddTreatments: ((Decimal, Decimal, Decimal, String) -> Void)? = nil,
            onDismiss: (() -> Void)? = nil
        ) {
            self.resolver = resolver
            _state = ObservedObject(wrappedValue: state)
            self.showListInitially = showListInitially
            self.onAddTreatments = onAddTreatments
            // Wire optional callback into the state so it can call back when user selects "Add to Treatments"
            self.state.onAddTreatments = onAddTreatments
            self.state.onDismiss = onDismiss
        }

        @Environment(AppState.self) var appState
        @Environment(\.colorScheme) var colorScheme

        enum NutritionField: Hashable {
            case name
            case amount
            case calories
            case carbs
            case sugars
            case fat
            case protein
            case fiber
        }

        enum ListTab: String, CaseIterable {
            case scanner = "Scanner"
            case scanned = "Meal"
            case presets = "Presets"
        }

        var body: some View {
            VStack(spacing: 0) {
                if !state.showEditorView || selectedListTab != .scanner {
                    Picker("Mode", selection: $selectedListTab) {
                        ForEach(ListTab.allCases, id: \.self) { tab in
                            Text(LocalizedStringKey(tab.rawValue)).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding()
                }

                ZStack {
                    switch selectedListTab {
                    case .scanner:
                        scannerViewContent
                    case .scanned:
                        scannedItemsList
                    case .presets:
                        presetListView
                    }
                }
            }
            .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
            .navigationTitle(LocalizedStringKey(navigationTitle))
            .onChange(of: state.showListView) {
                if state.showListView {
                    if selectedListTab == .scanner {
                        selectedListTab = .scanned
                    }
                } else {
                    selectedListTab = .scanner
                }
            }
            .onChange(of: selectedListTab) {
                state.showListView = (selectedListTab != .scanner)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .topBarLeading) {
                    if state.showEditorView && selectedListTab == .scanner {
                        Button(
                            action: {
                                state.cancelEditing()
                            },
                            label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                    Text(String(localized: "Back"))
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        )
                        .buttonStyle(BorderlessButtonStyle())
                    } else {
                        Button(
                            action: {
                                state.performDismissal()
                            },
                            label: {
                                Text(String(localized: "Close"))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        )
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }
            })
            .sheet(isPresented: $showEditorCard) {
                NavigationStack {
                    NutritionEditorView(
                        state: state,
                        isEditingFromList: $isEditingFromList,
                        onDismissList: { showEditorCard = false }
                    )
                    .navigationTitle(String(localized: "Edit Item"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(String(localized: "Cancel")) {
                                showEditorCard = false
                                // Robust cleanup: Check either local or state flag
                                if isEditingFromList || state.isEditingFromList {
                                    isEditingFromList = false
                                    state.isEditingFromList = false
                                    state.cancelEditing()
                                }
                            }
                        }
                    }
                }
            }
            .onChange(of: showEditorCard) { _, isPresented in
                // If the sheet is dismissed interactively while editing from list, reset editing state
                if !isPresented {
                    if isEditingFromList || state.isEditingFromList {
                        isEditingFromList = false
                        state.isEditingFromList = false
                        state.cancelEditing()
                    }
                }
            }
            .onAppear {
                configureView()
                state.handleAppear()
                state.showListView = showListInitially
                // Sync tab state with showListInitially
                if showListInitially {
                    selectedListTab = .scanned
                } else {
                    selectedListTab = .scanner
                }
            }
        }

        // MARK: - Scanner View Content

        private var scannerViewContent: some View {
            Group {
                if state.isFetchingProduct {
                    loadingView
                } else if state.showEditorView {
                    NutritionEditorView(
                        state: state,
                        isEditingFromList: $isEditingFromList,
                        onDismissList: {}
                    )
                } else {
                    GeometryReader { geo in
                        ScrollView {
                            ZStack {
                                fullScreenCameraView

                                if let message = state.errorMessage {
                                    VStack {
                                        Spacer()
                                        Label(message, systemImage: "exclamationmark.triangle.fill")
                                            .font(.footnote)
                                            .foregroundStyle(.orange)
                                            .padding(12)
                                            .background(Color.orange.opacity(0.12))
                                            .background(.ultraThinMaterial)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                            .padding(.horizontal)
                                            .padding(.bottom, 100)
                                    }
                                    .allowsHitTesting(false)
                                }
                            }
                            .frame(minHeight: geo.size.height)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
            .onChange(of: focusedItemID) { _, newValue in
                if newValue != nil {
                    state.isKeyboardVisible = true
                    state.isScanning = false
                } else {
                    state.isKeyboardVisible = false
                }
            }
        }

        // MARK: - Loading View

        private var loadingView: some View {
            VStack(spacing: 16) {
                Spacer()
                ProgressView()
                    .scaleEffect(1.5)
                Text(
                    String(localized: "Looking up product…")
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // MARK: - List View Content

        private var navigationTitle: String {
            "Barcode Scanner"
        }

        private var presetListView: some View {
            PresetListView(
                scannerState: state,
                onSelect: { preset in
                    var imageSource: BarcodeScanner.FoodItem.ImageSource = .none
                    if let data = preset.imageData, let img = UIImage(data: data) {
                        imageSource = .image(img)
                    }

                    let item = BarcodeScanner.FoodItem(
                        id: UUID(),
                        name: preset.dish ?? "Unknown",
                        imageSource: imageSource,
                        nutriments: .init(
                            basis: .per100g,
                            carbohydratesPer100g: Double(truncating: preset.carbs ?? 0),
                            sugarsPer100g: nil,
                            fatPer100g: Double(truncating: preset.fat ?? 0),
                            proteinPer100g: Double(truncating: preset.protein ?? 0),
                            fiberPer100g: nil
                        ),
                        amount: 100
                    )
                    withAnimation {
                        state.scannedProducts.append(item)
                        selectedListTab = .scanned
                    }
                },
                shouldDismissOnSelect: false
            )
        }

        private var scannedItemsList: some View {
            ZStack(alignment: .leading) {
                List {
                    // Search Section
                    Section {
                        BarcodeScanner.ProductSearchField(
                            searchText: $state.searchQuery,
                            isFocused: $isSearchFocused,
                            onSubmit: {
                                showAllSearchResults = false
                                state.performFoodSearch()
                            },
                            onClear: {
                                state.searchQuery = ""
                                state.searchResults = []
                                showAllSearchResults = false
                            },
                            onChange: {
                                showAllSearchResults = false
                            }
                        )
                        .padding(.horizontal)
                        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))

                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                        if !state.searchQuery.isEmpty {
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
                                            servingQuantity: 100,
                                            servingQuantityUnit: "g",
                                            nutriments: .init(
                                                basis: .per100g,
                                                carbohydratesPer100g: (preset.carbs as NSDecimalNumber?)?.doubleValue,
                                                fatPer100g: (preset.fat as NSDecimalNumber?)?.doubleValue,
                                                proteinPer100g: (preset.protein as NSDecimalNumber?)?.doubleValue
                                            ),
                                            amount: 100,
                                            isManualEntry: true
                                        )
                                        state.scannedProducts.append(item)
                                        state.searchQuery = ""
                                        state.searchResults = []
                                        isSearchFocused = false
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
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            }

                            if !results.isEmpty && (!state.searchResults.isEmpty || state.isSearching) {
                                Divider()
                                    .padding(.horizontal)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                        }

                        if state.isSearching {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(1.5)
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        } else if let error = state.searchError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } else if !state.searchResults.isEmpty {
                            let displayResults =
                                showAllSearchResults ? state.searchResults : Array(state.searchResults.prefix(5))
                            ForEach(displayResults) { item in
                                BarcodeScanner.FoodSearchResultRow(item: item) {
                                    withAnimation {
                                        var mutableItem = item
                                        mutableItem.amount = item.servingQuantity ?? 100
                                        state.scannedProducts.append(mutableItem)
                                        state.searchQuery = ""
                                        state.searchResults = []
                                        isSearchFocused = false
                                    }
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            }

                            if state.searchResults.count > 5 {
                                Button {
                                    withAnimation {
                                        showAllSearchResults.toggle()
                                    }
                                } label: {
                                    HStack {
                                        Text(
                                            showAllSearchResults
                                                ? "Show less" : "Show \(state.searchResults.count - 5) more results"
                                        )
                                        .font(.caption.weight(.medium))
                                        Image(systemName: showAllSearchResults ? "chevron.up" : "chevron.down")
                                            .font(.caption)
                                    }
                                    .foregroundStyle(.blue)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }

                    if state.scannedProducts.isEmpty, state.searchResults.isEmpty, !state.isSearching {
                        emptyListView
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                    }

                    if !state.scannedProducts.isEmpty {
                        Section {
                            listHeader
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
                        }
                        Section {
                            ForEach(state.scannedProducts) { item in
                                ScannedProductRow(
                                    item: item,
                                    state: state,
                                    focusedItemID: $focusedItemID,
                                    isScaleConnected: state.liveScaleWeight != nil
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation {
                                            state.removeScannedProduct(item)
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        state.editScannedProduct(item)
                                        isEditingFromList = true
                                        state.isEditingFromList = true
                                        showEditorCard = true
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: 30)
                    .frame(maxHeight: .infinity)
            }
        }

        // MARK: - Full Screen Camera View

        private var fullScreenCameraView: some View {
            ZStack {
                switch state.cameraStatus {
                case .authorized:
                    ZStack {
                        ScannerPreviewView(
                            isRunning: Binding(
                                get: { state.isScanning },
                                set: { state.isScanning = $0 }
                            ),
                            onDetected: { state.didDetect(barcode: $0) },
                            onFailure: state.reportScannerIssue
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 120)

                        // Action buttons at bottom
                        VStack {
                            Spacer()
                            cameraActionButtons
                        }
                    }

                case .notDetermined:
                    VStack {
                        Spacer()
                        ProgressView(String(localized: "Requesting camera access…"))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

                default:
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "camera.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.secondary)
                        Label(
                            String(localized: "Enable camera access to start scanning."),
                            systemImage: "lock.shield"
                        )
                        .font(.subheadline)
                        Button(String(localized: "Open Settings"), action: state.openAppSettings)
                            .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.9))
                }
            }
        }

        // MARK: - Camera Action Buttons

        private var cameraActionButtons: some View {
            HStack(spacing: 12) {
                Button {
                    if state.isScanning {
                        state.isScanning = false
                    } else {
                        state.scanAgain(resetResults: false)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.isScanning ? "pause.fill" : "barcode.viewfinder")
                        Text(state.isScanning ? "Pause" : "Scan")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(state.isScanning ? .orange : .insulin)

                if !state.scannedProducts.isEmpty {
                    // "Calculator" button removed as per request for live updates
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }

        // MARK: - List View Content

        private var listViewContent: some View {
            ZStack(alignment: .leading) {
                List {
                    // Search Section
                    Section {
                        BarcodeScanner.ProductSearchField(
                            searchText: $state.searchQuery,
                            isFocused: $isSearchFocused,
                            onSubmit: {
                                showAllSearchResults = false
                                state.performFoodSearch()
                            },
                            onClear: {
                                state.searchQuery = ""
                                state.searchResults = []
                                showAllSearchResults = false
                            },
                            onChange: {
                                showAllSearchResults = false
                            }
                        )
                        .padding(.horizontal)
                        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                        if !state.searchQuery.isEmpty {
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
                                            servingQuantity: 100,
                                            servingQuantityUnit: "g",
                                            nutriments: .init(
                                                basis: .per100g,
                                                carbohydratesPer100g: (preset.carbs as NSDecimalNumber?)?.doubleValue,
                                                fatPer100g: (preset.fat as NSDecimalNumber?)?.doubleValue,
                                                proteinPer100g: (preset.protein as NSDecimalNumber?)?.doubleValue
                                            ),
                                            amount: 100,
                                            isManualEntry: true
                                        )
                                        state.scannedProducts.append(item)
                                        state.searchQuery = ""
                                        state.searchResults = []
                                        isSearchFocused = false
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
                                                .background(Color(.secondarySystemBackground))
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        }
                                        VStack(alignment: .leading) {
                                            Text(preset.dish ?? "Unknown")
                                                .font(.headline)
                                            Text("\(preset.carbs ?? 0)g carbs")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            }
                        }

                        if state.isSearching {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .padding(.vertical, 8)
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        } else if let error = state.searchError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } else if !state.searchResults.isEmpty {
                            let displayResults =
                                showAllSearchResults ? state.searchResults : Array(state.searchResults.prefix(5))
                            ForEach(displayResults) { item in
                                BarcodeScanner.FoodSearchResultRow(item: item) {
                                    withAnimation {
                                        var mutableItem = item
                                        mutableItem.amount = item.servingQuantity ?? 100
                                        state.scannedProducts.append(mutableItem)
                                        state.searchQuery = ""
                                        state.searchResults = []
                                        isSearchFocused = false
                                    }
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            }

                            if state.searchResults.count > 5 {
                                Button {
                                    withAnimation {
                                        showAllSearchResults.toggle()
                                    }
                                } label: {
                                    HStack {
                                        Text(
                                            showAllSearchResults
                                                ? "Show less" : "Show \(state.searchResults.count - 5) more results"
                                        )
                                        .font(.caption.weight(.medium))
                                        Image(systemName: showAllSearchResults ? "chevron.up" : "chevron.down")
                                            .font(.caption)
                                    }
                                    .foregroundStyle(.blue)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }

                    if state.scannedProducts.isEmpty, state.searchResults.isEmpty, !state.isSearching {
                        emptyListView
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                    }

                    if !state.scannedProducts.isEmpty {
                        Section {
                            listHeader
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
                        }

                        Section {
                            ForEach(state.scannedProducts) { item in
                                ScannedProductRow(
                                    item: item,
                                    state: state,
                                    focusedItemID: $focusedItemID,
                                    isScaleConnected: state.liveScaleWeight != nil
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation {
                                            state.removeScannedProduct(item)
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        state.editScannedProduct(item)
                                        isEditingFromList = true
                                        state.isEditingFromList = true
                                        showEditorCard = true
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                // Edge Swipe Overlay: Invisible touch zone on the left edge
                // Captures swipes to go back to scanner, preventing conflict with list row swipes
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: 30)
                    .frame(maxHeight: .infinity)
            }
        }

        private var emptyListView: some View {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "barcode.viewfinder")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text(String(localized: "No items scanned yet"))
                    .font(.title3.weight(.medium))
                Text(String(localized: "Scan barcodes or search to add items."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button {
                    state.showListView = false
                } label: {
                    HStack {
                        Image(systemName: "barcode.viewfinder")
                        Text(String(localized: "Start Scanning"))
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }

        private var listHeader: some View {
            let totalCarbs = state.scannedProducts.reduce(into: 0.0) { result, item in
                let carbsPer100 = item.nutriments.carbohydratesPer100g ?? 0
                let amount = item.amount.isFinite ? item.amount : 0
                result += (carbsPer100 * amount) / 100.0
            }
            let totalCalories = state.scannedProducts.reduce(into: 0.0) { result, item in
                let kcalPer100 = item.nutriments.energyKcalPer100g ?? 0
                let amount = item.amount.isFinite ? item.amount : 0
                result += (kcalPer100 * amount) / 100.0
            }

            return HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "\(state.scannedProducts.count) Item\(state.scannedProducts.count == 1 ? "" : "s") Scanned"
                    )
                    .font(.title2)
                    .bold()

                    HStack(spacing: 16) {
                        Text("total \(totalCarbs, specifier: "%.1f") g of carbs")
                            .foregroundStyle(.blue)
                    }
                    .font(.subheadline)
                }

                Spacer()

                // Scale controls on the right - only if WebSocket connected and receiving data
                if let liveWeight = state.liveScaleWeight {
                    VStack(alignment: .trailing, spacing: 4) {
                        // Live weight display
                        Text(String(format: "%.1f g", liveWeight))
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundColor(.accentColor)

                        HStack(spacing: 8) {
                            Button {
                                state.tareScale()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 18, height: 18)
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)

                            if let battery = state.scaleBatteryLevel {
                                Text("\(battery)%")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(minWidth: 60)
                }
            }
        }

        // MARK: - Helper Functions
    }
}
