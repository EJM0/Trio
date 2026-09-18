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

        @ObservedObject var state: StateModel
        @State private var showEditorCard = false

        @FocusState private var focusedItemID: UUID?
        @FocusState private var isSearchFocused: Bool

        init(
            resolver: Resolver,
            state: StateModel,
            onDismiss: (() -> Void)? = nil
        ) {
            self.resolver = resolver
            _state = ObservedObject(wrappedValue: state)
            self.state.onDismiss = onDismiss
        }

        @Environment(AppState.self) var appState
        @Environment(\.colorScheme) var colorScheme

        enum NutritionField: Hashable {
            case name
            case amount
            case carbs
            case fat
            case protein
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
            .tint(state.isTorchOn ? .yellow : .blue)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .safeAreaPadding(.bottom, 8)
            .accessibilityLabel(String(localized: "Flash"))
            .accessibilityAddTraits(state.isTorchOn ? .isSelected : [])
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
                    .padding(.top, Layout.contentTopSpacing)
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
                // The one place the gap under the selector is set, so the three tabs cannot
                // drift apart again. It sits here rather than on the picker so the spacing
                // survives the cases where the picker is not shown at all.
                .padding(.top, Layout.contentTopSpacing)
            }
            .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                configureView()
                state.handleAppear()
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // "Done", not "Close": items land in the meal as they are added, so there
                    // is nothing here left to confirm and nothing that closing discards.
                    Button(String(localized: "Done")) { state.performDismissal() }
                }
            }
            .sheet(isPresented: $showEditorCard) {
                NavigationStack {
                    NutritionEditorView(
                        state: state,
                        onDismissList: { showEditorCard = false }
                    )
                    .navigationTitle(String(localized: "Edit Item"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            // Cleanup lives in the onChange below, which this triggers. Doing it
                            // here as well ran it twice on every tap of this button.
                            Button(String(localized: "Cancel")) { showEditorCard = false }
                        }
                    }
                }
            }
            .onChange(of: showEditorCard) { _, isPresented in
                // Covers both the Cancel button and an interactive swipe-down.
                guard !isPresented, state.isEditorPresentedAsSheet else { return }
                state.isEditorPresentedAsSheet = false
                state.cancelEditing()
            }
        }

        // MARK: - Scanner View Content

        private var scannerViewContent: some View {
            Group {
                if state.showEditorView {
                    // Show full editor view when product/nutrition data is available
                    NutritionEditorView(
                        state: state,
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

        /// The title used to be "Barcode Scanner" on all three tabs, including on installs where
        /// the scanner is switched off and that tab does not exist.
        private var navigationTitle: LocalizedStringKey {
            switch state.selectedTab {
            case .scanner: return "Barcode Scanner"
            case .scanned: return "Meal"
            case .presets: return "Meal Presets"
            }
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
            VStack(spacing: 0) {
                // Both of these are headers for the meal rather than part of it, so they sit
                // above the `List` and share one container, one horizontal inset and one gap
                // down to the rows. The search field was previously the first row of an
                // `.insetGrouped` section, which clipped it to the section's rounded top
                // corners and overrode the shape it asks for.
                VStack(alignment: .leading, spacing: 16) {
                    MealManager.MealSearchBar(state: state, isFocused: $isSearchFocused)

                    if !state.scannedProducts.isEmpty {
                        listHeader
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, Layout.contentTopSpacing)

                List {
                    Section {
                        if !state.searchQuery.isEmpty {
                            MealManager.SearchResults(state: state, layout: .list) { item in
                                var mutableItem = item
                                mutableItem.amount = item.servingQuantity ?? 100
                                state.scannedProducts.append(mutableItem)
                                state.clearSearch()
                                isSearchFocused = false
                            }
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
                                // Destructive last in a context menu, outermost in a swipe:
                                // the platform conventions want opposite orders, and this used
                                // to be one shared builder putting Delete first in both.
                                .contextMenu {
                                    editButton(for: item)
                                    deleteButton(for: item)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    deleteButton(for: item)
                                    editButton(for: item)
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
                // An overlay, not a row. As a row inside the `List` the action button kept
                // being handed the row's full height and filling it, whatever size its label
                // asked for. The presets tab has always drawn its empty state this way.
                .overlay {
                    if showsEmptyState {
                        emptyListView
                    }
                }
            }
        }

        // MARK: - Scanned Product Actions

        private func deleteButton(for product: FoodItem) -> some View {
            Button(role: .destructive) {
                withAnimation { state.removeScannedProduct(product) }
            } label: {
                Label("Delete", systemImage: "trash.fill")
            }
            .tint(.red)
        }

        private func editButton(for product: FoodItem) -> some View {
            Button {
                state.editScannedProduct(product)
                state.isEditorPresentedAsSheet = true
                showEditorCard = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }

        /// Nothing to show: no items in the meal, and no search running that would fill it.
        ///
        /// Presets are matched live by `SearchResults` and never land in `state.searchResults`,
        /// so an active query is enough to stand down -- checking `searchResults` alone let the
        /// empty state sit on top of a list of matching presets.
        private var showsEmptyState: Bool {
            state.scannedProducts.isEmpty
                && state.searchQuery.isEmpty
                && !state.isSearching
                && state.searchError == nil
        }

        private var emptyListView: some View {
            ContentUnavailableView {
                Label(
                    String(localized: "No items yet"),
                    systemImage: state.isScannerEnabled ? "barcode.viewfinder" : "fork.knife"
                )
            } description: {
                Text(
                    state.isScannerEnabled
                        ? String(localized: "Scan barcodes or search to add items.")
                        : String(localized: "Search your meal presets to add items.")
                )
            } actions: {
                // Without the scanner there is no Scanner tab to send anyone to.
                if state.isScannerEnabled {
                    Button(String(localized: "Start Scanning")) {
                        state.selectedTab = .scanner
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }

        private var listHeader: some View {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    // Automatic grammatical agreement: this used to be
                    // `"\(count) Item\(count == 1 ? "" : "s")"`, which no translator could fix.
                    Text("^[\(state.scannedProducts.count) item](inflect: true)")
                        .font(.title2)
                        .bold()

                    Text("Total \(state.totalCarbs, specifier: "%.1f") g carbs")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                }

                Spacer()

                // Scale controls on the right - only if WebSocket connected and receiving data
                if let liveWeight = state.liveScaleWeight {
                    VStack(alignment: .trailing, spacing: 4) {
                        // Live weight display
                        Text(String(format: "%.1f g", liveWeight))
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundColor(.accentColor)
                            .accessibilityLabel(String(localized: "Scale reading"))
                            .accessibilityValue(String(format: "%.1f g", liveWeight))

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
                            .accessibilityLabel(String(localized: "Tare scale"))

                            if let battery = state.scaleBatteryLevel {
                                Label("\(battery)%", systemImage: batteryIcon(for: battery))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel(String(localized: "Scale battery"))
                                    .accessibilityValue("\(battery)%")
                            }
                        }
                    }
                    .frame(minWidth: 60)
                }
            }
        }

        private func batteryIcon(for level: Int) -> String {
            switch level {
            case ..<15: return "battery.0percent"
            case ..<40: return "battery.25percent"
            case ..<75: return "battery.50percent"
            default: return "battery.100percent"
            }
        }
    }
}
