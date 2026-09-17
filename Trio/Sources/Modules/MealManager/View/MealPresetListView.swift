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
    @State private var isEditing = false
    @State private var editingPreset: MealPresetStored?

    var body: some View {
        List {
            ForEach(presets) { preset in
                HStack(spacing: 0) {
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
                                    .frame(width: 58, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.blue.opacity(0.1))
                                        .frame(width: 58, height: 58)
                                    Image(systemName: "fork.knife")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 24, height: 24)
                                        .foregroundStyle(.blue)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(preset.dish ?? "Unknown")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text("\(format(preset.carbs))g carbs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            deletePreset(preset)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)

                        Button {
                            startEditPreset(preset)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }

                    // Edit button outside the main tap area, but visually aligned if needed
                    // For now, removing the separate edit button from the row visual flow
                    // and relying on swipe actions or a trailing button if desired.
                    // But to match the list style, we keep the edit button separate or integrated.
                    // Based on "ScannedProductRow", it seems the action happens on the row itself.
                }
                .listRowBackground(Color.chart)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deletePreset(preset)
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
            // onDelete removed from here as it is now in swipeActions
        }
        .listStyle(.insetGrouped)
        .listRowSpacing(10)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .padding(.top, 15)
        // .navigationTitle not needed as it's handled by parent view
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    startNewPreset()
                } label: {
                    Image(systemName: "plus")
                }
            }
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
                    isEditingFromList: $isEditing,
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
        isEditing = false
        // Ensure we clear the scanner state so it doesn't think we are still editing
        scannerState.cancelEditing()
    }

    private func startNewPreset() {
        editingPreset = nil
        isEditing = false
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
        isEditing = true

        // This used to hardcode a per-100g basis, so editing a millilitre-based preset silently
        // reinterpreted its nutriments as grams. FoodItem(preset:) follows `isMl`.
        scannerState.currentScannedItem = FoodItem(preset: preset)
        scannerState.editingAmount = preset.amount
        scannerState.editingIsMl = preset.isMl
        showEditor = true
    }

    private func saveCurrentItemAsPreset() {
        guard let item = scannerState.currentScannedItem, !item.name.isEmpty else { return }

        let preset = editingPreset ?? MealPresetStored(context: moc)
        preset.dish = item.name
        preset.carbs = NSDecimalNumber(value: item.nutriments.carbohydratesPer100g ?? 0)
        preset.fat = NSDecimalNumber(value: item.nutriments.fatPer100g ?? 0)
        preset.protein = NSDecimalNumber(value: item.nutriments.proteinPer100g ?? 0)
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

    private func format(_ number: NSDecimalNumber?) -> String {
        guard let number = number else { return "0" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter.string(from: number) ?? "0"
    }
}
