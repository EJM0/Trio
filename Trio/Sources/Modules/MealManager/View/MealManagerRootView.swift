import CodeScanner
import SwiftUI
import Swinject

private func localizedScanFailureMessage(for error: ScanError) -> String {
    switch error {
    case .badInput:
        return String(localized: "The camera could not be accessed.")
    case .badOutput:
        return String(localized: "This device can't read barcodes with the camera.")
    case .permissionDenied:
        return String(
            localized: "Camera permissions were denied. Enable them in Settings to continue."
        )
    case let .initError(underlying):
        return (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
    }
}

// MARK: - Root View

extension MealManager {
    struct RootView: BaseView {
        let resolver: Resolver
        var onAddTreatments: ((Decimal, Decimal, Decimal, String) -> Void)?

        @ObservedObject var state: StateModel
        @State private var isEditingFromList = false
        @State private var showEditorCard = false

        @FocusState private var focusedItemID: UUID?
        @FocusState private var isSearchFocused: Bool

        init(
            resolver: Resolver,
            state: StateModel,
            onAddTreatments: ((Decimal, Decimal, Decimal, String) -> Void)? = nil,
            onDismiss: (() -> Void)? = nil
        ) {
            self.resolver = resolver
            _state = ObservedObject(wrappedValue: state)
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

        /// Tabs follow the feature gates: no Scanner tab without the barcode scanner, no Presets
        /// tab without meal presets. The current meal is always reachable.
        private var availableTabs: [ListTab] {
            ListTab.allCases.filter { tab in
                switch tab {
                case .scanner: return state.isScannerEnabled
                case .scanned: return true
                case .presets: return state.displayPresets
                }
            }
        }

        private var torchToggleButton: some View {
            Button {
                state.isTorchOn.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: state.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.title2)
                    Text(String(localized: "Flash"))
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .safeAreaPadding(.bottom, 8)
            .accessibilityLabel(String(localized: "Flash"))
        }

        var body: some View {
            VStack(spacing: 0) {
                if availableTabs.count > 1, !state.showEditorView || state.selectedTab != .scanner {
                    Picker("Mode", selection: $state.selectedTab) {
                        ForEach(availableTabs, id: \.self) { tab in
                            Text(LocalizedStringKey(tab.rawValue)).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top)
                    .padding(.bottom, 0)
                }

                ZStack {
                    switch state.selectedTab {
                    case .scanner:
                        scannerViewContent
                    case .scanned:
                        mainListView
                    case .presets:
                        presetListView
                    }
                }
            }
            .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
            .navigationTitle(LocalizedStringKey(navigationTitle))
            .onAppear {
                // A disabled feature must not leave the sheet showing an empty tab.
                if !availableTabs.contains(state.selectedTab) {
                    state.selectedTab = availableTabs.first ?? .scanned
                }
            }
            .onChange(of: state.selectedTab) { _, newValue in
                // The torch belongs to the scanner tab only.
                if newValue != .scanner {
                    state.isTorchOn = false
                }
            }
            .onDisappear {
                // Ensure the torch state resets if the entire RootView is dismissed
                state.isTorchOn = false
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .topBarLeading) {
                    Button(
                        action: {
                            state.performDismissal()
                        },
                        label: {
                            Text("Close")
                        }
                    )
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
            }
        }

        // MARK: - Scanner View Content

        private var scannerViewContent: some View {
            Group {
                if state.showEditorView {
                    // Show full editor view when product/nutrition data is available
                    NutritionEditorView(
                        state: state,
                        isEditingFromList: $isEditingFromList,
                        onDismissList: { state.selectedTab = .scanned }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    GeometryReader { geo in
                        ScrollView {
                            ZStack {
                                if state.isFetchingProduct {
                                    // Loading state
                                    loadingView
                                        .transition(.opacity)
                                } else {
                                    // Scanner view
                                    fullScreenCameraView
                                        .transition(.move(edge: .leading).combined(with: .opacity))
                                }

                                // Error overlay (always visible if there's an error)
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

        // MARK: - Full Screen Camera View

        private var fullScreenCameraView: some View {
            VStack {
                ZStack {
                    switch state.cameraStatus {
                    case .authorized:
                        CodeScannerView(
                            codeTypes: [.ean13, .ean8, .upce, .code128, .code39],
                            scanMode: .continuous,
                            requiresPhotoOutput: false,
                            isTorchOn: state.isTorchOn,
                            isPaused: !state.isScanning,
                            completion: { result in
                                switch result {
                                case let .success(scan):
                                    state.didDetect(barcode: scan.string)
                                case let .failure(error):
                                    state.reportScannerIssue(localizedScanFailureMessage(for: error))
                                }
                            }
                        )

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
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if state.cameraStatus == .authorized {
                    torchToggleButton
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
            MealPresetListView(
                scannerState: state,
                onSelect: { preset in
                    withAnimation {
                        state.scannedProducts.append(FoodItem(preset: preset))
                        state.selectedTab = .scanned
                    }
                },
                shouldDismissOnSelect: false
            )
        }

        private var mainListView: some View {
            ZStack(alignment: .leading) {
                List {
                    // Search Section
                    Section {
                        MealManager.MealSearchBar(state: state, isFocused: $isSearchFocused)
                            .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 10, trailing: 0))

                        if !state.searchQuery.isEmpty {
                            MealManager.SearchResults(state: state, layout: .list) { item in
                                var mutableItem = item
                                mutableItem.amount = item.servingQuantity ?? 100
                                state.scannedProducts.append(mutableItem)
                                state.clearSearch()
                                isSearchFocused = false
                            }
                        }

                        if state.scannedProducts.isEmpty, state.searchResults.isEmpty, !state.isSearching {
                            emptyListView
                                .listRowSeparator(.hidden)
                        }

                        if !state.scannedProducts.isEmpty {
                            listHeader
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 20, trailing: 0))
                        }
                    }
                    .listRowBackground(Color.clear)

                    if !state.scannedProducts.isEmpty {
                        Section {
                            ForEach(state.scannedProducts) { item in
                                ScannedProductRow(
                                    item: item,
                                    state: state,
                                    focusedItemID: $focusedItemID,
                                    isScaleConnected: state.liveScaleWeight != nil
                                )
                                .listRowInsets(EdgeInsets())
                                .padding(15)
                                .contextMenu {
                                    actionButtonsForScannedProduct(for: item)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    actionButtonsForScannedProduct(for: item)
                                }
                            }
                        }
                        .listRowBackground(Color.chart)
                    }
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(0)
                .contentMargins(.top, 0, for: .scrollContent)
                .scrollContentBackground(.hidden)
            }
        }

        // MARK: - Scanned Product Actions

        func actionButtonsForScannedProduct(for product: FoodItem) -> some View {
            Group {
                Button(role: .destructive) {
                    withAnimation {
                        state.removeScannedProduct(product)
                    }
                } label: {
                    Label("Delete", systemImage: "trash.fill")
                }
                .tint(.red)

                Button {
                    state.editScannedProduct(product)
                    isEditingFromList = true
                    state.isEditingFromList = true
                    showEditorCard = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.blue)
            }
        }

        private var emptyListView: some View {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: state.isScannerEnabled ? "barcode.viewfinder" : "fork.knife")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text(String(localized: "No items yet"))
                    .font(.title3.weight(.medium))
                Text(
                    state.isScannerEnabled
                        ? String(localized: "Scan barcodes or search to add items.")
                        : String(localized: "Search your meal presets to add items.")
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

                // Without the scanner there is no Scanner tab to send anyone to.
                if state.isScannerEnabled {
                    Button {
                        state.selectedTab = .scanner
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
                }
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
            return HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "\(state.scannedProducts.count) Item\(state.scannedProducts.count == 1 ? "" : "s")"
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
    }
}
