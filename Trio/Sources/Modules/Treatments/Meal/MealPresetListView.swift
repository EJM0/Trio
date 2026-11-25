import CoreData
import SwiftUI

/// The Presets tab: tap a preset to add it to the meal; create, edit and delete presets.
struct MealPresetListView: View {
    @Bindable var meal: MealModel
    let showsFatAndProtein: Bool

    @Environment(\.managedObjectContext) private var moc

    @FetchRequest(
        entity: MealPresetStored.entity(),
        sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
    ) private var presets: FetchedResults<MealPresetStored>

    /// The preset in the editor; `preset == nil` is a new one.
    private struct Edit: Identifiable {
        let id = UUID()
        let preset: MealPresetStored?
    }

    @State private var edit: Edit?
    @State private var pendingDeletion: MealPresetStored?

    var body: some View {
        List {
            ForEach(presets) { preset in
                let item = preset.foodItem
                Button {
                    withAnimation {
                        meal.items.append(preset.foodItem)
                        meal.tab = .meal
                    }
                } label: {
                    HStack(spacing: 12) {
                        FoodThumbnail(imageData: item.imageData)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.headline)
                            Text(item.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    editButton(for: preset)
                    deleteButton(for: preset)
                }
                // No full swipe: a preset is saved data, often with a photo.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    deleteButton(for: preset)
                    editButton(for: preset)
                }
            }
            .listRowBackground(Color.chart)
        }
        .listStyle(.insetGrouped)
        .listRowSpacing(10)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .overlay {
            if presets.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No presets yet"), systemImage: "fork.knife")
                } description: {
                    Text("Save a meal you eat often and it will be one tap away.")
                } actions: {
                    Button(String(localized: "New Preset")) { edit = Edit(preset: nil) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { edit = Edit(preset: nil) } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(String(localized: "New Preset"))
            }
        }
        .sheet(item: $edit) { edit in
            FoodItemEditor(
                item: edit.preset?.foodItem ?? FoodItem(),
                title: edit.preset == nil ? String(localized: "New Preset") : String(localized: "Edit Preset"),
                saveTitle: edit.preset == nil ? String(localized: "Save Preset") : String(localized: "Update Preset"),
                isPreset: true,
                showsFatAndProtein: showsFatAndProtein
            ) { item in
                (edit.preset ?? MealPresetStored(context: moc)).update(from: item)
                save()
            }
        }
        .confirmationDialog(
            String(localized: "Delete this preset?"),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { preset in
            Button(String(localized: "Delete"), role: .destructive) {
                moc.delete(preset)
                save()
            }
        } message: { preset in
            Text(preset.dish ?? "")
        }
    }

    private func editButton(for preset: MealPresetStored) -> some View {
        Button { edit = Edit(preset: preset) } label: {
            Label("Edit", systemImage: "pencil")
        }
        .tint(.blue)
    }

    private func deleteButton(for preset: MealPresetStored) -> some View {
        Button(role: .destructive) { pendingDeletion = preset } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func save() {
        do {
            try moc.save()
        } catch {
            warning(.treatments, "Saving meal presets failed", error: error)
        }
    }
}
