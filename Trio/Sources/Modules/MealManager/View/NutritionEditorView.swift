import SwiftUI
import UIKit

#if canImport(ImagePlayground)
    import ImagePlayground
#endif

// MARK: - Nutrition Editor View

extension MealManager {
    struct NutritionEditorView: View {
        @ObservedObject var state: StateModel
        @FocusState private var focusedField: RootView.NutritionField?
        /// Called when the editor is finished and the presenter has to take it away. Only a
        /// sheet needs this; the inline scanner editor disappears on its own once the state
        /// model clears `currentScannedItem`.
        var onDismissList: () -> Void

        var customSaveButtonTitle: String? = nil
        var onSave: (() -> Void)? = nil

        @Environment(AppState.self) var appState
        @Environment(\.colorScheme) var colorScheme

        @State private var shouldPresentPhotoPicker = false
        @State private var shouldPresentCamera = false
        @State private var shouldPresentImagePlayground = false

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
                                        // Only where the device can actually do it: Image
                                        // Playground needs Apple Intelligence, so on everything
                                        // else this entry is simply absent rather than a button
                                        // that explains why it does not work.
                                        if MealPhotoGeneration.isAvailable {
                                            Button {
                                                shouldPresentImagePlayground = true
                                            } label: {
                                                Label("Generate Image", systemImage: "apple.image.playground")
                                            }
                                            .disabled(generationConcept == nil)
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
                                        .clipShape(RoundedRectangle(cornerRadius: MealManager.Layout.cornerRadius))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: MealManager.Layout.cornerRadius)
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
                                        .clipShape(RoundedRectangle(cornerRadius: MealManager.Layout.cornerRadius))

                                    case let .image(uiImage):
                                        Image(uiImage: uiImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 70, height: 70)
                                            .clipShape(RoundedRectangle(cornerRadius: MealManager.Layout.cornerRadius))

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
                                        .focused($focusedField, equals: .name)
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

                            // The basis is a property of the values, not of the portion the
                            // user is eating. Reading `editingIsMl` here relabelled the block
                            // "per 100ml" the moment the portion picker was flipped, over
                            // values that had not changed.
                            Text(
                                product.nutriments.basis == .per100ml
                                    ? "Nutrition (per 100ml)"
                                    : "Nutrition (per 100g)"
                            )
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
                                if !state.settingsManager.settings.mealManagerOnlyCarbs {
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
                            .clipShape(RoundedRectangle(cornerRadius: MealManager.Layout.cornerRadius))

                            // Amount input section
                            amountInputSection
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)

                // Pinned, not hidden behind the keyboard: these used to disappear for as long
                // as a field was focused, so entering an amount and saving it took two gestures.
                VStack(spacing: 12) {
                    if state.shouldShowOpenFoodFactsUploadButton {
                        Menu {
                            Button {
                                dismissKeyboard()
                                Task {
                                    await state.uploadCurrentItemNutritionCorrection()
                                }
                            } label: {
                                Text(String(localized: "tap to confirm"))
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if state.isUploadingNutritionCorrection {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                }

                                Text(String(localized: "Update OpenFoodFactsDB"))
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color(red: 128.0 / 255.0, green: 140.0 / 255.0, blue: 235.0 / 255.0))
                        .disabled(state.isUploadingNutritionCorrection)

                        if let message = state.nutritionUploadStatusMessage, !message.isEmpty {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        dismissKeyboard()
                        if let onSave {
                            onSave()
                        } else {
                            if state.currentScannedItem != nil {
                                state.addProductToList()
                            }
                            dismissIfPresentedAsSheet()
                        }
                    } label: {
                        Label(primaryActionTitle, systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.insulin)
                    .disabled(!canSave)

                    // A sheet already carries a Cancel in its toolbar; only the inline scanner
                    // editor, which has no toolbar of its own, needs one down here.
                    if !state.isEditorPresentedAsSheet {
                        Button {
                            dismissKeyboard()
                            state.cancelEditing()
                        } label: {
                            Text("Cancel")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
                .padding(.top, 8)
            }
            .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
            .onAppear {
                // Preset editor can be opened without a scanner result; ensure we have an editable shell item.
                if onSave != nil, state.currentScannedItem == nil {
                    state.currentScannedItem = FoodItem(
                        id: UUID(),
                        name: "",
                        nutriments: .init(
                            basis: .per100g,
                            carbohydratesPer100g: 0,
                            sugarsPer100g: 0,
                            fatPer100g: 0,
                            proteinPer100g: 0,
                            fiberPer100g: 0
                        ),
                        amount: 100
                    )
                    state.editingAmount = 100
                    state.editingIsMl = false
                }
            }
            // `focusedField` is the single keyboard signal for this screen. It used to be four:
            // this, a local `keyboardIsVisible`, `state.isKeyboardVisible`, and a pair of
            // `keyboardWillShow`/`Hide` observers that raced this handler on the way down. The
            // observers only ever caught anything because the product-name field had no focus
            // binding; it has one now.
            .onChange(of: focusedField) { _, newValue in
                state.isKeyboardVisible = newValue != nil
                if newValue != nil {
                    state.isScanning = false
                }
            }
            .onChange(of: state.editingIsMl) { _, _ in
                state.syncNutrimentBasisToInputUnit()
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
            .modifier(
                MealPhotoGenerationSheet(
                    isPresented: $shouldPresentImagePlayground,
                    concept: generationConcept ?? "",
                    onImage: { state.currentScannedItem?.imageSource = .image($0) }
                )
            )
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

                // Both units get chips. Only millilitres used to, so entering 150 g meant
                // typing it every time while 0.33 l was one tap.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(quickPortions, id: \.1) { label, value in
                            let isSelected = state.editingAmount == value
                            Button {
                                state.selectQuickPortion(amount: value)
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
                            .accessibilityLabel(label)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }

                if let carbs = previewCarbs {
                    Text("Total \(carbs, specifier: "%.1f") g carbs")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .padding(.top, 4)
                }
            }
        }

        private var productPlaceholder: some View {
            RoundedRectangle(cornerRadius: MealManager.Layout.cornerRadius)
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

        private var primaryActionTitle: String {
            if let customSaveButtonTitle {
                return customSaveButtonTitle
            }

            if state.isCurrentItemMealPreset {
                return String(localized: "Update Preset")
            }

            return state.isEditorPresentedAsSheet
                ? String(localized: "Update")
                : String(localized: "Add to List")
        }

        /// What the generator is asked to draw. Nil when the preset has no name yet -- there
        /// is nothing to describe, and an empty concept just opens a blank playground.
        private var generationConcept: String? {
            let name = (state.currentScannedItem?.name ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return String(localized: "A plate of \(name), food photography")
        }

        private var quickPortions: [(String, Double)] {
            state.editingIsMl
                ? [("0.25l", 250), ("0.33l", 333), ("0.5l", 500), ("1l", 1000)]
                : [("50g", 50), ("100g", 100), ("150g", 150), ("200g", 200)]
        }

        /// The carbs this edit would contribute. `editingAmount` is the live field value and is
        /// only written back onto the item on save, so scale a copy rather than repeating the
        /// per-100 arithmetic `FoodItem.carbs` already does.
        private var previewCarbs: Double? {
            guard state.editingAmount > 0, var item = state.currentScannedItem else { return nil }
            item.amount = state.editingAmount
            return item.carbs
        }

        /// A preset needs a name to be findable again; a scanned item always has one.
        private var canSave: Bool {
            guard onSave != nil else { return true }
            return !(state.currentScannedItem?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private func dismissIfPresentedAsSheet() {
            guard state.isEditorPresentedAsSheet else { return }
            state.isEditorPresentedAsSheet = false
            onDismissList()
        }
    }
}

// MARK: - On-device Photo Generation

/// Image Playground, where the device has it.
///
/// Deployment target is below the framework's, so every entry point is behind an availability
/// check; `isAvailable` additionally covers the runtime conditions Apple Intelligence has
/// beyond the OS version -- eligible hardware, the models actually downloaded, and a supported
/// region -- so a supported iPhone that has the feature switched off still gets no menu entry.
enum MealPhotoGeneration {
    static var isAvailable: Bool {
        #if canImport(ImagePlayground)
            if #available(iOS 18.1, *) {
                return ImagePlaygroundViewController.isAvailable
            }
        #endif
        return false
    }
}

/// Presents the Image Playground sheet and hands back the generated image.
///
/// A `ViewModifier` rather than an inline `.imagePlaygroundSheet(...)` because the modifier
/// itself is iOS 18.1+ and cannot be applied inside an `if #available` in a view body without
/// changing the body's type.
struct MealPhotoGenerationSheet: ViewModifier {
    @Binding var isPresented: Bool
    let concept: String
    let onImage: (UIImage) -> Void

    func body(content: Content) -> some View {
        #if canImport(ImagePlayground)
            if #available(iOS 18.1, *) {
                content.imagePlaygroundSheet(isPresented: $isPresented, concept: concept) { url in
                    // The sheet writes the result to a temporary file and hands over the URL.
                    guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                        debug(.default, "\(DebuggingIdentifiers.failed) Could not read generated image at \(url)")
                        return
                    }
                    onImage(image)
                }
            } else {
                content
            }
        #else
            content
        #endif
    }
}
