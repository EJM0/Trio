import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit

// MARK: - StateModel

extension MealManager {
    final class StateModel: BaseStateModel<Provider> {
        deinit {
            stopScaleStream()
        }

        // MARK: - Properties

        @Published var cameraStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(
            for: .video
        )
        @Published var isScanning = true
        @Published var isKeyboardVisible = false
        @Published var currentScannedItem: FoodItem?
        @Published var isFetchingProduct = false
        @Published var errorMessage: String?
        @Published var scannedProducts: [FoodItem] = []

        /// True while the nutrition editor is presented as a sheet (from the meal list or the
        /// preset list) rather than inline on the scanner tab. A sheet has to be dismissed
        /// explicitly; the inline editor just disappears when `currentScannedItem` clears.
        /// This used to be two flags -- this one plus a local `@State` in the root view -- that
        /// every call site set and cleared in pairs and read as `a || b`.
        @Published var isEditorPresentedAsSheet: Bool = false

        @Published var scaleBatteryLevel: Int?
        @Published var liveScaleWeight: Double?

        // External control
        @Published var selectedTab: ListTab = .scanner
        @Published var isTorchOn = false
        var onDismiss: (() -> Void)?

        // Editor amount input
        @Published var editingAmount: Double = 0
        @Published var editingIsMl: Bool = false

        // Feature gates. `isScannerEnabled` controls the barcode scanner and OpenFoodFacts;
        // `displayPresets` controls local meal presets. They are independent: either one on
        // is enough to show the meal search UI.
        @Published var isScannerEnabled = false
        @Published var displayPresets = true

        // Search State
        @Published var searchQuery = ""
        @Published var searchResults: [FoodItem] = []
        @Published var isSearching = false
        @Published var searchError: String?
        @Published var hasMoreSearchResults = false
        @Published var isLoadingMoreSearchResults = false
        @Published var isUploadingNutritionCorrection = false
        @Published var nutritionUploadStatusMessage: String?

        // Scale polling. Not private: used from MealManagerStateModel+Scale.swift, and Swift
        // does not allow stored properties in extensions.
        var scaleCheckTimer: Timer?
        var isCheckingScaleConnection = false
        private var originalScannedNutriments: FoodItem.Nutriments?

        // MARK: - Private Properties

        private var lastScanTime: Date?
        private var lastScannedBarcode: String?
        private var lastScanWasSuccessful: Bool = false
        private let scanCooldownSeconds: TimeInterval = 1.0
        // Used from MealManagerStateModel+Search.swift. Four made "Show 4 more results" the
        // most-tapped control on the screen.
        let searchPageSize = 10
        var currentSearchPage = 1

        // MARK: - Lifecycle

        override func subscribe() {
            subscribeSetting(\.mealManagerScannerEnabled, on: $isScannerEnabled) { isScannerEnabled = $0 }
            subscribeSetting(\.displayPresets, on: $displayPresets) { displayPresets = $0 }
        }

        func handleAppear() {
            Task {
                await provider.openFoodFacts.setCredentials(
                    username: settingsManager.settings.openFoodFactsUsername,
                    password: settingsManager.settings.openFoodFactsPassword
                )
            }

            refreshCameraStatus()
            startScalePolling()

            switch cameraStatus {
            case .notDetermined:
                requestCameraAccess()
            case .authorized:
                isScanning = true
            default:
                isScanning = false
                errorMessage = String(localized: "Camera access is required to scan barcodes.")
            }
        }

        // MARK: - Camera Access

        func refreshCameraStatus() {
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        }

        private func requestCameraAccess() {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    self.refreshCameraStatus()
                    if granted {
                        self.errorMessage = nil
                        self.isScanning = true
                    } else {
                        self.isScanning = false
                        self.showTemporaryError(
                            String(
                                localized: "Camera permissions were denied. Enable them in Settings to continue."
                            ),
                            resumeScanning: false
                        )
                    }
                }
            }
        }

        func openAppSettings() {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }

        // MARK: - Barcode Scanning

        func reportScannerIssue(_ message: String) {
            showTemporaryError(message)
            isScanning = false
        }

        func scanAgain(resetResults: Bool = false) {
            guard cameraStatus == .authorized else { return }
            if resetResults {
                currentScannedItem = nil
                errorMessage = nil
                scannedProducts.removeAll()
                lastScanTime = nil
                lastScannedBarcode = nil
                lastScanWasSuccessful = false
            }
            isScanning = true
        }

        func didDetect(barcode: String) {
            Task { @MainActor in
                // Prevent rapid scanning - require cooldown between scans
                if let lastScan = lastScanTime, Date().timeIntervalSince(lastScan) < scanCooldownSeconds {
                    return
                }

                // Prevent rescanning the same barcode (valid or invalid)
                guard barcode != lastScannedBarcode else { return }

                lastScannedBarcode = barcode
                lastScanTime = Date()
                fetchProduct(for: barcode)
            }
        }

        private func fetchProduct(for barcode: String) {
            isFetchingProduct = true
            errorMessage = nil

            Task { @MainActor in
                do {
                    var fetchedProduct = try await provider.openFoodFacts.fetchProduct(barcode: barcode)
                    self.setupEditingAmount(for: fetchedProduct)
                    self.originalScannedNutriments = fetchedProduct.nutriments

                    // Pre-fill amount in the item for display, though editingAmount controls input
                    fetchedProduct.amount = self.editingAmount
                    fetchedProduct.isMlInput = self.editingIsMl

                    self.currentScannedItem = fetchedProduct
                    self.lastScanWasSuccessful = true
                    self.isFetchingProduct = false
                    self.triggerSuccessHaptic()
                } catch {
                    guard !Task.isCancelled else { return }
                    self.currentScannedItem = nil
                    self.lastScanWasSuccessful = false
                    self.isFetchingProduct = false
                    self.lastScannedBarcode = nil
                    self.lastScanTime = nil
                    self.showTemporaryError(
                        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                }
            }
        }

        /// Shows a transient error message that auto-clears after a short delay
        private func showTemporaryError(
            _ message: String,
            duration: TimeInterval = 3,
            resumeScanning: Bool = true
        ) {
            errorMessage = message
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(duration))
                // Only clear if no new error was set in the meantime
                if self.errorMessage == message {
                    self.errorMessage = nil
                    if resumeScanning,
                       self.cameraStatus == .authorized,
                       self.currentScannedItem == nil,
                       !self.isFetchingProduct
                    {
                        self.isScanning = true
                    }
                }
            }
        }

        private func triggerSuccessHaptic() {
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        }

        // MARK: - Product Management

        func removeScannedProduct(_ item: FoodItem) {
            scannedProducts.removeAll { $0.id == item.id }
        }

        func updateScannedProductAmount(_ item: FoodItem, amount: Double, isMlInput: Bool) {
            if let index = scannedProducts.firstIndex(where: { $0.id == item.id }) {
                scannedProducts[index].amount = amount
                scannedProducts[index].isMlInput = isMlInput
            }
        }

        func editScannedProduct(_ item: FoodItem) {
            // Set as current item for editing
            currentScannedItem = item
            originalScannedNutriments = item.nutriments
            nutritionUploadStatusMessage = nil

            // Set up editing state
            editingAmount = item.amount
            editingIsMl = item.isMlInput

            // Stop scanning while editing
            isScanning = false
        }

        /// Updates a nutriment value for the currently displayed product
        func updateProductNutriment(
            keyPath: WritableKeyPath<FoodItem.Nutriments, Double?>,
            value: Double?
        ) {
            currentScannedItem?.nutriments[keyPath: keyPath] = value
            nutritionUploadStatusMessage = nil
        }

        /// Adds the currently displayed product (with edited nutriments) to the list
        func addProductToList() {
            guard var item = currentScannedItem else { return }

            // Update with latest user edits
            item.amount = editingAmount
            item.isMlInput = editingIsMl

            item.nutriments = nutrimentsHonoringOnlyCarbs(item.nutriments)

            if let index = scannedProducts.firstIndex(where: { $0.id == item.id }) {
                scannedProducts[index] = item
            } else {
                scannedProducts.append(item)
            }

            // Turn off torch *before* clearing the scanned item. clearScannedProduct() clears
            // currentScannedItem synchronously, which flips showEditorView to false and briefly
            // re-mounts the live camera view (with whatever isTorchOn was) for one runloop tick,
            // before the deferred tab flip below switches the tab away and resets it.
            // That gap is what causes the visible torch flash.
            isTorchOn = false

            // Clear the editor and resume scanning
            clearScannedProduct()

            // MARK: - FIX: Defer the expensive tab switch to the next runloop iteration

            // This prevents the UI from hanging when transitioning from scanner to list view
            DispatchQueue.main.async {
                self.selectedTab = .scanned
            }
        }

        /// Sets up editing state when a product is loaded
        func setupEditingAmount(for product: FoodItem) {
            // Determine initial amount and unit from serving info
            editingAmount = product.servingQuantity ?? 100
            if let servingUnit = product.servingQuantityUnit?.lowercased() {
                editingIsMl =
                    servingUnit.contains("ml") || servingUnit == "l" || servingUnit.contains("fl oz")
            } else {
                editingIsMl = product.defaultPortionIsMl
            }
        }

        /// A quick-portion chip is a shortcut for the amount field and nothing more.
        ///
        /// It used to write the tapped value into `currentScannedItem.servingQuantity` and clear
        /// it again on deselect, so tapping a chip destroyed the serving size OpenFoodFacts had
        /// returned -- which is also what the portion stepper in the meal list measures against.
        func selectQuickPortion(amount: Double) {
            editingAmount = (editingAmount == amount) ? 100 : amount
        }

        /// Drops macros the user cannot see. `mealManagerOnlyCarbs` hides the fat and protein
        /// fields, so whatever is left in them is stale and must not reach storage. Applied on
        /// every way out of the editor -- adding to the meal and saving a preset both go
        /// through here, which the preset path previously did not.
        func nutrimentsHonoringOnlyCarbs(_ nutriments: FoodItem.Nutriments) -> FoodItem.Nutriments {
            guard settingsManager.settings.mealManagerOnlyCarbs else { return nutriments }
            var result = nutriments
            result.fatPer100g = 0
            result.proteinPer100g = 0
            return result
        }

        /// Keeps the nutriment basis in step with the unit the user is typing in.
        ///
        /// The basis is the unit the *values* are given in; `editingIsMl` is the unit of the
        /// portion. For a hand-entered item or a preset they are the same thing, because the
        /// user supplies both. For a scanned product the basis comes from OpenFoodFacts and the
        /// portion picker must not rewrite it -- the editor used to label the whole block
        /// "per 100ml" purely because the portion picker said ml, without converting anything.
        func syncNutrimentBasisToInputUnit() {
            guard currentScannedItem?.barcode == nil else { return }
            currentScannedItem?.nutriments.basis = editingIsMl ? .per100ml : .per100g
        }

        /// Clears the currently displayed product from the overlay
        func clearScannedProduct() {
            currentScannedItem = nil
            originalScannedNutriments = nil
            lastScannedBarcode = nil
            lastScanWasSuccessful = false
            errorMessage = nil
            nutritionUploadStatusMessage = nil
            isScanning = true
        }

        /// The carbohydrates every item currently in the meal adds up to, in grams.
        var totalCarbs: Double {
            scannedProducts.reduce(0) { $0 + $1.carbs }
        }

        /// Whether to show the editor view (product available)
        var showEditorView: Bool {
            currentScannedItem != nil
        }

        /// Cancels the current editing session and returns to scanner
        func cancelEditing() {
            // Clear all editing state (product was not added to list yet)
            currentScannedItem = nil
            originalScannedNutriments = nil
            lastScannedBarcode = nil
            lastScanWasSuccessful = false
            errorMessage = nil
            editingAmount = 0
            editingIsMl = false
            nutritionUploadStatusMessage = nil
            isScanning = true
        }

        var hasOpenFoodFactsCredentialsConfigured: Bool {
            let username = settingsManager.settings.openFoodFactsUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            let password = settingsManager.settings.openFoodFactsPassword
            return !username.isEmpty && !password.isEmpty
        }

        var isCurrentItemMealPreset: Bool {
            currentScannedItem?.isManualEntry == true
        }

        var isCurrentItemScannedObject: Bool {
            guard let item = currentScannedItem else {
                return false
            }

            let hasBarcode = !(item.barcode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            return hasBarcode
        }

        var hasNutrimentAdjustmentsFromOriginal: Bool {
            guard let current = currentScannedItem?.nutriments,
                  let original = originalScannedNutriments
            else {
                return false
            }

            let epsilon = 0.0001
            let carbsChanged = abs((current.carbohydratesPer100g ?? 0) - (original.carbohydratesPer100g ?? 0)) > epsilon
            let fatChanged = abs((current.fatPer100g ?? 0) - (original.fatPer100g ?? 0)) > epsilon
            let proteinChanged = abs((current.proteinPer100g ?? 0) - (original.proteinPer100g ?? 0)) > epsilon
            return carbsChanged || fatChanged || proteinChanged
        }

        var shouldShowOpenFoodFactsUploadButton: Bool {
            isCurrentItemScannedObject
                && hasNutrimentAdjustmentsFromOriginal
                && hasOpenFoodFactsCredentialsConfigured
        }

        @MainActor func uploadCurrentItemNutritionCorrection() async {
            guard let currentItem = currentScannedItem,
                  let original = originalScannedNutriments,
                  shouldShowOpenFoodFactsUploadButton,
                  !isUploadingNutritionCorrection
            else {
                return
            }

            isUploadingNutritionCorrection = true
            nutritionUploadStatusMessage = nil

            defer {
                isUploadingNutritionCorrection = false
            }

            do {
                let success = try await provider.openFoodFacts.uploadNutritionCorrection(for: currentItem, comparedTo: original)
                if success {
                    originalScannedNutriments = currentItem.nutriments
                    nutritionUploadStatusMessage = String(localized: "Uploaded to OpenFoodFacts")
                } else {
                    nutritionUploadStatusMessage = String(localized: "Upload to OpenFoodFacts failed")
                }
            } catch {
                nutritionUploadStatusMessage = error.localizedDescription
            }
        }

        /// Performs the dismissal of the barcode scanner module
        func performDismissal() {
            stopScaleStream()
            if let onDismiss = onDismiss {
                onDismiss()
            } else {
                hideModal()
            }
        }
    }
}
