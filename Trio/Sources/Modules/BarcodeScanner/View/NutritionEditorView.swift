import SwiftUI
import UIKit

// MARK: - Nutrition Editor View

extension BarcodeScanner {
    struct NutritionEditorView: View {
        @ObservedObject var state: StateModel
        @FocusState private var focusedField: RootView.NutritionField?
        @Binding var isEditingFromList: Bool
        var onDismissList: () -> Void

        var customSaveButtonTitle: String? = nil
        var onSave: (() -> Void)? = nil

        @Environment(AppState.self) var appState
        @Environment(\.colorScheme) var colorScheme

        @State private var shouldPresentPhotoPicker = false
        @State private var shouldPresentCamera = false

        var body: some View {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let product = state.currentScannedItem {
                            // Product header
                            HStack(alignment: .top, spacing: 12) {
                                if onSave != nil {
                                    // Custom editable image for presets
                                    Menu {
                                        Button {
                                            shouldPresentCamera = true
                                        } label: {
                                            Label("Take Picture", systemImage: "camera")
                                        }
                                        Button {
                                            shouldPresentPhotoPicker = true
                                        } label: {
                                            Label("Choose Photo", systemImage: "photo.on.rectangle")
                                        }
                                        if case .image = product.imageSource {
                                            Button(role: .destructive) {
                                                state.currentScannedItem?.imageSource = .none
                                            } label: {
                                                Label("Remove Photo", systemImage: "trash")
                                            }
                                        }
                                    } label: {
                                        ZStack {
                                            switch product.imageSource {
                                            case let .url(url):
                                                AsyncImage(url: url) { phase in
                                                    if let image = phase.image {
                                                        image.resizable().scaledToFill()
                                                    } else {
                                                        productPlaceholder
                                                    }
                                                }
                                            case let .image(uiImage):
                                                Image(uiImage: uiImage)
                                                    .resizable()
                                                    .scaledToFill()
                                            case .none:
                                                productPlaceholder
                                            }
                                        }
                                        .frame(width: 70, height: 70)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.blue, lineWidth: 2)
                                                .opacity(0.3)
                                        )
                                        .overlay(
                                            Image(systemName: "pencil.circle.fill")
                                                .foregroundStyle(.white, .blue)
                                                .frame(
                                                    maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing
                                                )
                                                .offset(x: 6, y: 6)
                                        )
                                    }
                                } else {
                                    // Read-only image for scanned products
                                    switch product.imageSource {
                                    case let .url(url):
                                        AsyncImage(url: url) { phase in
                                            switch phase {
                                            case let .success(image):
                                                image
                                                    .resizable()
                                                    .scaledToFill()
                                            case .failure:
                                                productPlaceholder
                                            default:
                                                ProgressView()
                                            }
                                        }
                                        .frame(width: 70, height: 70)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))

                                    case let .image(uiImage):
                                        Image(uiImage: uiImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 70, height: 70)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))

                                    case .none:
                                        productPlaceholder
                                            .frame(width: 70, height: 70)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    if onSave != nil {
                                        TextField(
                                            "Product Name",
                                            text: Binding(
                                                get: { state.currentScannedItem?.name ?? "" },
                                                set: { state.currentScannedItem?.name = $0 }
                                            )
                                        )
                                        .font(.headline)
                                        .textFieldStyle(.roundedBorder)
                                    } else {
                                        Text(product.name)
                                            .font(.headline)
                                            .lineLimit(2)
                                    }

                                    if let brand = product.brand {
                                        Text(brand)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let quantity = product.quantity {
                                        Text(quantity)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }

                            Text("Nutrition (per 100g)")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)

                            // Editable nutrition rows for product
                            VStack(spacing: 0) {
                                NutritionTextField(
                                    label: String(localized: "Carbohydrates"),
                                    value: Binding(
                                        get: { state.currentScannedItem?.nutriments.carbohydratesPer100g ?? 0 },
                                        set: {
                                            state.updateProductNutriment(keyPath: \.carbohydratesPer100g, value: $0)
                                        }
                                    ),
                                    unit: "g",
                                    field: .carbs,
                                    focusedField: $focusedField
                                )
                                if !state.settingsManager.settings.barcodeScannerOnlyCarbs {
                                    Divider().padding(.leading)

                                    NutritionTextField(
                                        label: String(localized: "Fat"),
                                        value: Binding(
                                            get: { state.currentScannedItem?.nutriments.fatPer100g ?? 0 },
                                            set: { state.updateProductNutriment(keyPath: \.fatPer100g, value: $0) }
                                        ),
                                        unit: "g",
                                        field: .fat,
                                        focusedField: $focusedField
                                    )

                                    Divider().padding(.leading)

                                    NutritionTextField(
                                        label: String(localized: "Protein"),
                                        value: Binding(
                                            get: { state.currentScannedItem?.nutriments.proteinPer100g ?? 0 },
                                            set: { state.updateProductNutriment(keyPath: \.proteinPer100g, value: $0) }
                                        ),
                                        unit: "g",
                                        field: .protein,
                                        focusedField: $focusedField
                                    )
                                }
                            }
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                            // Amount input section
                            amountInputSection
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)

                // Action buttons at bottom
                VStack(spacing: 12) {
                    // Add & Continue button
                    Button {
                        dismissKeyboard()
                        if let onSave = onSave {
                            onSave()
                        } else {
                            if state.currentScannedItem != nil {
                                state.addProductToList()
                            }

                            if isEditingFromList {
                                isEditingFromList = false
                                onDismissList()
                            }
                        }
                    } label: {
                        Label(
                            customSaveButtonTitle
                                ?? (
                                    state.isEditingFromList
                                        ? String(localized: "Update") : String(localized: "Add to List")
                                ),
                            systemImage: "plus.circle.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.insulin)

                    Button {
                        dismissKeyboard()
                        state.cancelEditing()

                        if isEditingFromList {
                            isEditingFromList = false
                            onDismissList()
                        }
                    } label: {
                        Text("Cancel")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
                .padding(.top, 8)
            }
            .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
            .onChange(of: focusedField) { _, newValue in
                // Pause scanner and hide scanner view when numpad is opened
                if newValue != nil {
                    state.isScanning = false
                    state.isKeyboardVisible = true
                } else {
                    state.isKeyboardVisible = false
                }
            }
            .sheet(isPresented: $shouldPresentPhotoPicker) {
                PhotoPicker(
                    image: Binding(
                        get: {
                            if case let .image(img) = state.currentScannedItem?.imageSource {
                                return img
                            }
                            return nil
                        },
                        set: { (newImage: UIImage?) in
                            if let img = newImage {
                                state.currentScannedItem?.imageSource = .image(img)
                            }
                        }
                    )
                )
            }
            .fullScreenCover(isPresented: $shouldPresentCamera) {
                CameraView(
                    image: Binding(
                        get: {
                            if case let .image(img) = state.currentScannedItem?.imageSource {
                                return img
                            }
                            return nil
                        },
                        set: { (newImage: UIImage?) in
                            if let img = newImage {
                                state.currentScannedItem?.imageSource = .image(img)
                            }
                        }
                    )
                )
                .ignoresSafeArea()
            }
        }

        // MARK: - Helper Views

        private var amountInputSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Amount you're eating")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                AmountTextField(
                    amount: $state.editingAmount,
                    isMl: $state.editingIsMl,
                    field: .amount,
                    focusedField: $focusedField
                )

                if state.editingIsMl {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            let options: [(String, Double, String)] = [
                                ("0.25l", 250, "l"),
                                ("0.33l", 333, "l"),
                                ("0.5l", 500, "l"),
                                ("1l", 1000, "l")
                            ]
                            ForEach(options, id: \.0) { label, value, unit in
                                let isSelected = state.editingAmount == value
                                Button {
                                    state.selectQuickPortion(amount: value, unit: unit)
                                } label: {
                                    Text(label)
                                        .font(.subheadline.weight(isSelected ? .bold : .medium))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(
                                            isSelected ? Color.blue : Color.secondary.opacity(0.15)
                                        )
                                        .foregroundColor(isSelected ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Show calculated nutrition based on amount
                if state.editingAmount > 0 {
                    if let product = state.currentScannedItem {
                        let carbsTotal =
                            (product.nutriments.carbohydratesPer100g ?? 0) * state.editingAmount / 100
                        let kcalTotal = (product.nutriments.energyKcalPer100g ?? 0) * state.editingAmount / 100
                        nutritionSummary(carbs: carbsTotal, kcal: kcalTotal)
                    }
                }
            }
        }

        private func nutritionSummary(carbs: Double, kcal _: Double) -> some View {
            HStack(spacing: 16) {
                Text("total \(carbs, specifier: "%.1f") g of carbs")
                    .foregroundStyle(.blue)
            }
            .font(.caption)
            .padding(.top, 4)
        }

        private var productPlaceholder: some View {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.2))
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                )
        }

        // MARK: - Helper Functions

        private func dismissKeyboard() {
            focusedField = nil
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
            )
        }
    }
}
