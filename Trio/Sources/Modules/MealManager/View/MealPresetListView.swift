import CoreData
import Foundation
import SwiftUI
import UIKit

struct MealPresetListView: View {
    @Environment(\.managedObjectContext) var moc
    @Environment(\.dismiss) var dismiss
    @Environment(AppState.self) var appState

    @ObservedObject var scannerState: MealManager.StateModel

    @FetchRequest(
        entity: MealPresetStored.entity(),
        sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
    ) var presets: FetchedResults<MealPresetStored>

    var onSelect: ((MealPresetStored) -> Void)?
    var shouldDismissOnSelect: Bool = true

    @State private var showEditor = false
    @State private var editingPreset: MealPresetStored?
    @State private var presetPendingDeletion: MealPresetStored?

    var body: some View {
        List {
            ForEach(presets) { preset in
                Button {
                    onSelect?(preset)
                    if shouldDismissOnSelect {
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 12) {
                        if let data = preset.imageData, let uiImage = UIImage(data: data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(
                                    width: MealManager.Layout.thumbnail,
                                    height: MealManager.Layout.thumbnail
                                )
                                .clipShape(RoundedRectangle(cornerRadius: MealManager.Layout.cornerRadius))
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: MealManager.Layout.cornerRadius)
                                    .fill(Color.blue.opacity(0.1))
                                    .frame(
                                        width: MealManager.Layout.thumbnail,
                                        height: MealManager.Layout.thumbnail
                                    )
                                Image(systemName: "fork.knife")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 24, height: 24)
                                    .foregroundStyle(.blue)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(preset.dish ?? String(localized: "Unknown"))
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            // `preset.carbs` is a per-100 g/ml figure, but this row used to
                            // print it bare as "Xg carbs" -- so a 250 g preset at 10 g/100 g
                            // advertised 10 g and added 25 g. Show the portion and its total.
                            Text(presetSummary(preset))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Destructive last in a context menu, outermost in a swipe.
                .contextMenu {
                    Button {
                        startEditPreset(preset)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        presetPendingDeletion = preset
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .listRowBackground(Color.chart)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                // No full swipe: a preset is saved data with a photo attached, and a stray
                // swipe used to delete it outright with no confirmation and no undo.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        presetPendingDeletion = preset
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Button {
                        startEditPreset(preset)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
        .overlay {
            if presets.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No presets yet"), systemImage: "fork.knife")
                } description: {
                    Text(String(localized: "Save a meal you eat often and it will be one tap away."))
                } actions: {
                    Button(String(localized: "New Preset"), action: startNewPreset)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listRowSpacing(10)
        .scrollContentBackground(.hidden)
        // No extra top padding: the meal tab sets a zero top margin, so a 15pt pad here made
        // the content jump every time you switched between the two tabs.
        .contentMargins(.top, 0, for: .scrollContent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: startNewPreset) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(String(localized: "New Preset"))
            }
        }
        .confirmationDialog(
            String(localized: "Delete this preset?"),
            isPresented: Binding(
                get: { presetPendingDeletion != nil },
                set: { if !$0 { presetPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: presetPendingDeletion
        ) { preset in
            Button(String(localized: "Delete"), role: .destructive) {
                deletePreset(preset)
                presetPendingDeletion = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { presetPendingDeletion = nil }
        } message: { preset in
            Text(preset.dish ?? String(localized: "Unknown"))
        }
        .sheet(
            isPresented: $showEditor,
            onDismiss: {
                cleanupEditorState()
            }
        ) {
            NavigationStack {
                MealManager.NutritionEditorView(
                    state: scannerState,
                    onDismissList: { showEditor = false },
                    customSaveButtonTitle: editingPreset == nil ? "Save Preset" : "Update Preset",
                    onSave: {
                        saveCurrentItemAsPreset()
                    }
                )
                .navigationTitle(editingPreset == nil ? "New Preset" : "Edit Preset")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            showEditor = false
                        }
                    }
                }
            }
        }
    }

    private func cleanupEditorState() {
        editingPreset = nil
        // Ensure we clear the scanner state so it doesn't think we are still editing
        scannerState.isEditorPresentedAsSheet = false
        scannerState.cancelEditing()
    }

    private func startNewPreset() {
        editingPreset = nil
        // Both preset paths present the editor as a sheet, so both have to tell it to dismiss
        // itself. Only the edit path used to set this, so Cancel on a *new* preset cleared the
        // form and left the empty sheet sitting there.
        scannerState.isEditorPresentedAsSheet = true
        // Initialize a clean item
        let newItem = FoodItem(
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
        scannerState.currentScannedItem = newItem
        scannerState.editingAmount = 100
        scannerState.editingIsMl = false
        showEditor = true
    }

    private func startEditPreset(_ preset: MealPresetStored) {
        editingPreset = preset
        scannerState.isEditorPresentedAsSheet = true

        // This used to hardcode a per-100g basis, so editing a millilitre-based preset silently
        // reinterpreted its nutriments as grams. FoodItem(preset:) follows `isMl`.
        scannerState.currentScannedItem = FoodItem(preset: preset)
        scannerState.editingAmount = preset.amount
        scannerState.editingIsMl = preset.isMl
        showEditor = true
    }

    private func saveCurrentItemAsPreset() {
        guard let item = scannerState.currentScannedItem, !item.name.isEmpty else { return }

        // The fat and protein fields are hidden when `mealManagerOnlyCarbs` is on, so whatever
        // is left in them is stale. `addProductToList()` already dropped them on the way into a
        // meal; this path used to persist them into the preset regardless.
        let nutriments = scannerState.nutrimentsHonoringOnlyCarbs(item.nutriments)

        let preset = editingPreset ?? MealPresetStored(context: moc)
        preset.dish = item.name
        preset.carbs = NSDecimalNumber(value: nutriments.carbohydratesPer100g ?? 0)
        preset.fat = NSDecimalNumber(value: nutriments.fatPer100g ?? 0)
        preset.protein = NSDecimalNumber(value: nutriments.proteinPer100g ?? 0)
        preset.isMl = scannerState.editingIsMl
        preset.amount = scannerState.editingAmount

        if case let .image(img) = item.imageSource {
            // Resize image to max 512px dimension to save space
            let maxDimension: CGFloat = 512
            var finalImage = img
            if img.size.width > maxDimension || img.size.height > maxDimension {
                let aspectRatio = img.size.width / img.size.height
                var newSize: CGSize
                if img.size.width > img.size.height {
                    newSize = CGSize(width: maxDimension, height: maxDimension / aspectRatio)
                } else {
                    newSize = CGSize(width: maxDimension * aspectRatio, height: maxDimension)
                }
                let renderer = UIGraphicsImageRenderer(size: newSize)
                finalImage = renderer.image { _ in
                    img.draw(in: CGRect(origin: .zero, size: newSize))
                }
            }
            // Compress with lower quality (0.5 instead of 0.8)
            preset.imageData = finalImage.jpegData(compressionQuality: 0.5)
        } else {
            preset.imageData = nil
        }

        do {
            try moc.save()
            showEditor = false
            editingPreset = nil
        } catch {
            debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to save meal preset: \(error)")
        }
    }

    private func deletePreset(_ preset: MealPresetStored) {
        withAnimation {
            moc.delete(preset)
            do {
                try moc.save()
            } catch {
                debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to delete meal preset: \(error)")
            }
        }
    }

    /// "250 g · 25.0 g carbs" -- the portion the preset was saved at and what it actually adds.
    private func presetSummary(_ preset: MealPresetStored) -> String {
        let item = FoodItem(preset: preset)
        let unit = preset.isMl ? String(localized: "ml") : String(localized: "g")
        let amount = preset.amount.formatted(.number.precision(.fractionLength(0 ... 1)))
        let carbs = item.carbs.formatted(.number.precision(.fractionLength(0 ... 1)))
        return "\(amount) \(unit) · \(carbs) \(String(localized: "g carbs"))"
    }
}
