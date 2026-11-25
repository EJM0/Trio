import PhotosUI
import SwiftUI
import UIKit

#if canImport(ImagePlayground)
    import ImagePlayground
#endif

/// Edits a copy of a `FoodItem` and hands it back on save; Cancel simply drops the copy.
/// Used for meal presets (name and photo editable) and for items already in the meal.
struct FoodItemEditor: View {
    let title: String
    let saveTitle: String
    let isPreset: Bool
    let showsFatAndProtein: Bool
    let onSave: (FoodItem) -> Void

    @State private var draft: FoodItem
    @State private var photoSelection: PhotosPickerItem?
    @State private var showsPhotoPicker = false
    @State private var showsCamera = false
    @State private var showsImagePlayground = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    init(
        item: FoodItem,
        title: String,
        saveTitle: String,
        isPreset: Bool,
        showsFatAndProtein: Bool,
        onSave: @escaping (FoodItem) -> Void
    ) {
        _draft = State(initialValue: item)
        self.title = title
        self.saveTitle = saveTitle
        self.isPreset = isPreset
        self.showsFatAndProtein = showsFatAndProtein
        self.onSave = onSave
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var quickPortions: [(label: String, amount: Decimal)] {
        draft.isMl
            ? [("0.25l", 250), ("0.33l", 333), ("0.5l", 500), ("1l", 1000)]
            : [("50g", 50), ("100g", 100), ("150g", 150), ("200g", 200)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    nutrition
                    portion
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            // Pinned, so saving does not need the keyboard out of the way first.
            .safeAreaInset(edge: .bottom) {
                Button {
                    onSave(draft)
                    dismiss()
                } label: {
                    Label(saveTitle, systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPreset && trimmedName.isEmpty)
                .padding()
            }
            .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
            .photosPicker(isPresented: $showsPhotoPicker, selection: $photoSelection, matching: .images)
            .onChange(of: photoSelection) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        draft.imageData = FoodItem.imageData(from: image)
                    }
                    photoSelection = nil
                }
            }
            .fullScreenCover(isPresented: $showsCamera) {
                CameraPicker { draft.imageData = FoodItem.imageData(from: $0) }
                    .ignoresSafeArea()
            }
            .modifier(
                MealPhotoGenerationSheet(
                    isPresented: $showsImagePlayground,
                    concept: String(localized: "A plate of \(trimmedName), food photography"),
                    onImage: { draft.imageData = FoodItem.imageData(from: $0) }
                )
            )
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if isPreset {
                photoMenu
            } else {
                FoodThumbnail(imageData: draft.imageData, size: 70)
            }

            VStack(alignment: .leading, spacing: 4) {
                if isPreset {
                    TextField(String(localized: "Name"), text: $draft.name)
                        .font(.headline)
                        .textFieldStyle(.roundedBorder)
                    Text("Preset")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(draft.name)
                        .font(.headline)
                        .lineLimit(2)
                }
            }
        }
    }

    private var photoMenu: some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showsCamera = true } label: {
                    Label("Take Picture", systemImage: "camera")
                }
            }
            Button { showsPhotoPicker = true } label: {
                Label("Choose Photo", systemImage: "photo.on.rectangle")
            }
            if MealPhotoGeneration.isAvailable {
                Button { showsImagePlayground = true } label: {
                    Label("Generate Image", systemImage: "apple.image.playground")
                }
                .disabled(trimmedName.isEmpty)
            }
            if draft.imageData != nil {
                Button(role: .destructive) { draft.imageData = nil } label: {
                    Label("Remove Photo", systemImage: "trash")
                }
            }
        } label: {
            FoodThumbnail(imageData: draft.imageData, size: 70)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .blue)
                        .offset(x: 6, y: 6)
                }
        }
        .accessibilityLabel(String(localized: "Edit photo"))
    }

    private var nutrition: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.isMl ? "Nutrition (per 100ml)" : "Nutrition (per 100g)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                macroField(String(localized: "Carbs"), value: $draft.carbsPer100)
                if showsFatAndProtein {
                    Divider().padding(.leading)
                    macroField(String(localized: "Fat"), value: $draft.fatPer100)
                    Divider().padding(.leading)
                    macroField(String(localized: "Protein"), value: $draft.proteinPer100)
                }
            }
            .background(Color.chart, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func macroField(_ label: String, value: Binding<Decimal>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextFieldWithToolBar(
                text: value,
                placeholder: "0",
                numberFormatter: Self.formatter,
                unitsText: String(localized: "g", comment: "Units for carbs")
            )
        }
        .padding()
    }

    private var portion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Amount you're eating")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                TextFieldWithToolBar(
                    text: $draft.amount,
                    placeholder: "0",
                    numberFormatter: Self.formatter,
                    unitsText: draft.unit
                )
                .font(.title2.weight(.semibold))
                .padding()
                .background(Color.chart, in: RoundedRectangle(cornerRadius: 12))

                Picker(String(localized: "Unit"), selection: $draft.isMl) {
                    Text("g").tag(false)
                    Text("ml").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(quickPortions, id: \.amount) { portion in
                        let isSelected = draft.amount == portion.amount
                        Button { draft.amount = portion.amount } label: {
                            Text(portion.label)
                                .font(.subheadline.weight(isSelected ? .bold : .medium))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(isSelected ? Color.blue : Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(isSelected ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }

            Text("Total \(draft.carbs.formatted(.number.precision(.fractionLength(0 ... 1)))) g carbs")
                .font(.footnote)
                .foregroundStyle(.blue)
        }
    }
}

// MARK: - Camera

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Image Playground

/// Image Playground needs iOS 18.1 and Apple Intelligence; elsewhere the menu entry is absent.
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

/// A modifier because `.imagePlaygroundSheet` is iOS 18.1+ and the deployment target is lower.
struct MealPhotoGenerationSheet: ViewModifier {
    @Binding var isPresented: Bool
    let concept: String
    let onImage: (UIImage) -> Void

    func body(content: Content) -> some View {
        #if canImport(ImagePlayground)
            if #available(iOS 18.1, *) {
                content.imagePlaygroundSheet(isPresented: $isPresented, concept: concept) { url in
                    if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                        onImage(image)
                    }
                }
            } else {
                content
            }
        #else
            content
        #endif
    }
}
