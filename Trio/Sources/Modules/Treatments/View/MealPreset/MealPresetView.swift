import CoreData
import Foundation
import SwiftUI
import UIKit

struct MealPresetView: View {
    @Bindable var state: Treatments.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    @Environment(\.managedObjectContext) var moc
    @Environment(AppState.self) var appState

    @State private var showAlert = false
    @State private var dish: String = ""
    @State private var showAddNewPresetSheet = false

    @State private var presetCarbs: Decimal = 0
    @State private var presetFat: Decimal = 0
    @State private var presetProtein: Decimal = 0

    @State private var carbs: Decimal = 0
    @State private var fat: Decimal = 0
    @State private var protein: Decimal = 0

    @FetchRequest(
        entity: MealPresetStored.entity(),
        sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
    ) var carbPresets: FetchedResults<MealPresetStored>

    private var mealFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }

    private var color: LinearGradient {
        colorScheme == .dark
            ? LinearGradient(
                gradient: Gradient(colors: [
                    Color.bgDarkBlue,
                    Color.bgDarkerDarkBlue
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            : LinearGradient(
                gradient: Gradient(colors: [Color.gray.opacity(0.1)]),
                startPoint: .top,
                endPoint: .bottom
            )
    }

    var body: some View {
        NavigationStack {
            Form {
                mealPresets
                dishInfos()
                addPresetToTreatmentsButton
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
            .navigationTitle("Meal Presets")
            .navigationBarTitleDisplayMode(.automatic)
            .toolbar(content: {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Close")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        showAddNewPresetSheet.toggle()
                    }, label: {
                        HStack {
                            Text("New Preset")
                            Image(systemName: "plus")
                        }
                    })
                }
            })
            .sheet(isPresented: $showAddNewPresetSheet) {
                AddMealPresetView(
                    dish: $dish,
                    presetCarbs: $presetCarbs,
                    presetFat: $presetFat,
                    presetProtein: $presetProtein,
                    displayFatAndProtein: $state.useFPUconversion,
                    onSave: savePreset,
                    onCancel: {
                        showAddNewPresetSheet.toggle()
                        resetNewPresetForm()
                    }
                )
            }
            .onDisappear {
                resetValues()
            }
        }
    }

    private var mealPresets: some View {
        Section {
            HStack {
                if state.selection != nil {
                    minusButton
                }
                Picker("Preset", selection: $state.selection) {
                    Text("Saved Food").tag(nil as MealPresetStored?)
                    ForEach(carbPresets, id: \.self) { (preset: MealPresetStored) in
                        Text(preset.dish ?? "").tag(preset as MealPresetStored?)
                    }
                }
                .onChange(of: state.selection) {
                    carbs += ((state.selection?.carbs ?? 0) as NSDecimalNumber) as Decimal
                    if state.useFPUconversion {
                        fat += ((state.selection?.fat ?? 0) as NSDecimalNumber) as Decimal
                        protein += ((state.selection?.protein ?? 0) as NSDecimalNumber) as Decimal
                    }

                    state.addPresetToNewMeal()
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .center)
                if state.selection != nil {
                    plusButton
                }
            }

            HStack {
                Spacer()

                Button("Delete Preset") {
                    showAlert.toggle()
                }
                .disabled(state.selection == nil)
                .tint(.orange)
                .buttonStyle(.borderless)
                .alert(
                    "Delete preset '\(state.selection?.dish ?? "")'?",
                    isPresented: $showAlert,
                    actions: {
                        Button("No", role: .cancel) {}
                        Button("Yes", role: .destructive) {
                            if let selection = state.selection {
                                let previousSelection = state.selection
                                let count = state.summation.filter { $0 == selection.dish }.count
                                state.summation.removeAll { $0 == selection.dish }
                                carbs -= (((selection.carbs ?? 0) as NSDecimalNumber) as Decimal) * Decimal(count)
                                fat -= (((selection.fat ?? 0) as NSDecimalNumber) as Decimal) * Decimal(count)
                                protein -=
                                    (((selection.protein ?? 0) as NSDecimalNumber) as Decimal) * Decimal(count)
                                state.deletePreset()
                                state.selection = previousSelection
                            }
                        }
                    }
                )

                Spacer()
            }
        }.listRowBackground(Color.chart)
    }

    private var addPresetToTreatmentsButton: some View {
        Button {
            state.carbs += carbs
            state.fat += fat
            state.protein += protein

            dismiss()
        } label: {
            Text("Add to Treatments")
                .font(.headline)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .disabled(noPresetChosen)
        .listRowBackground(noPresetChosen ? Color(.systemGray3) : Color(.systemBlue))
        .shadow(radius: 3)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var noPresetChosen: Bool {
        state.selection == nil || state.summation.isEmpty
    }

    @ViewBuilder private func dishInfos() -> some View {
        if !state.summation.isEmpty {
            let presetSummary = generatePresetSummary()

            Section(header: Text("Summary")) {
                presetSummary
                    .lineLimit(nil) // In case the text is too long, allow it to wrap to the next line

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .trailing)
                    ], spacing: 0
                ) {
                    Group {
                        Text("Carbs: ")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 2) {
                            Text("\(carbs as NSNumber, formatter: mealFormatter)")
                                .font(.footnote)
                            Text(" g")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if state.useFPUconversion {
                        Group {
                            Text("Protein: ")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 2) {
                                Text("\(protein as NSNumber, formatter: mealFormatter)")
                                    .font(.footnote)
                                Text(" g")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Group {
                            Text("Fat: ")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 2) {
                                Text("\(fat as NSNumber, formatter: mealFormatter)")
                                    .font(.footnote)
                                Text(" g")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.listRowBackground(Color.chart)
        }
    }

    private func generatePresetSummary() -> some View {
        var counts = [String: Int]()

        for preset in state.summation {
            counts[preset, default: 0] += 1
        }

        return VStack(alignment: .leading) {
            ForEach(counts.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                if value > 0 {
                    HStack {
                        Text("\(value) x")
                            .foregroundColor(.blue)
                        Text(key)
                    }
                }
            }
        }
    }

    private func resetValues() {
        state.selection = nil
        state.summation.removeAll()
    }

    private func resetNewPresetForm() {
        dish = ""
        presetCarbs = 0
        presetFat = 0
        presetProtein = 0
    }

    private var minusButton: some View {
        Button {
            if carbs != 0 {
                carbs -= (((state.selection?.carbs ?? 0) as NSDecimalNumber) as Decimal)
            } else {
                carbs = 0
            }

            if state.useFPUconversion {
                if fat != 0,
                   (fat - (((state.selection?.fat ?? 0) as NSDecimalNumber) as Decimal) as Decimal) >= 0
                {
                    fat -= (((state.selection?.fat ?? 0) as NSDecimalNumber) as Decimal)
                } else {
                    fat = 0
                }

                if protein != 0,
                   (protein - (((state.selection?.protein ?? 0) as NSDecimalNumber) as Decimal) as Decimal)
                   >= 0
                {
                    protein -= (((state.selection?.protein ?? 0) as NSDecimalNumber) as Decimal)
                } else {
                    protein = 0
                }
            }

            state.removePresetFromNewMeal()
            if carbs == 0, fat == 0, protein == 0 { state.summation = [] }
        } label: {
            Image(systemName: "minus.circle.fill")
                .font(.title3)
        }
        .disabled(
            state
                .selection == nil
                || (
                    !state.summation
                        .contains(state.selection?.dish ?? "") && (state.selection?.dish ?? "") != ""
                )
        )
        .buttonStyle(.borderless)
        .tint(.blue)
    }

    private var plusButton: some View {
        Button {
            carbs += ((state.selection?.carbs ?? 0) as NSDecimalNumber) as Decimal
            if state.useFPUconversion {
                fat += ((state.selection?.fat ?? 0) as NSDecimalNumber) as Decimal
                protein += ((state.selection?.protein ?? 0) as NSDecimalNumber) as Decimal
            }

            state.addPresetToNewMeal()
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
        }
        .disabled(state.selection == nil)
        .buttonStyle(.borderless)
        .tint(.blue)
    }

    private func savePreset() {
        if dish != "" {
            let preset = MealPresetStored(context: moc)
            preset.dish = dish
            preset.carbs = presetCarbs as NSDecimalNumber
            if state.useFPUconversion {
                preset.fat = presetFat as NSDecimalNumber
                preset.protein = presetProtein as NSDecimalNumber
            }

            do {
                guard moc.hasChanges else { return }
                try moc.save()
                showAddNewPresetSheet.toggle()
            } catch let error as NSError {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) Failed to save Meal Preset with error: \(error.userInfo)"
                )
            }
        }
    }
}

struct PresetListView: View {
    @Environment(\.managedObjectContext) var moc
    @Environment(\.dismiss) var dismiss
    @Environment(AppState.self) var appState

    @ObservedObject var scannerState: BarcodeScanner.StateModel

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
                BarcodeScanner.NutritionEditorView(
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
        let newItem = BarcodeScanner.FoodItem(
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

        var imageSource: BarcodeScanner.FoodItem.ImageSource = .none
        if let data = preset.imageData, let img = UIImage(data: data) {
            imageSource = .image(img)
        }

        let item = BarcodeScanner.FoodItem(
            id: UUID(),
            name: preset.dish ?? "",
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
        scannerState.currentScannedItem = item
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
            print("Error saving preset: \(error)")
        }
    }

    private func deletePreset(_ preset: MealPresetStored) {
        withAnimation {
            moc.delete(preset)
            do {
                try moc.save()
            } catch {
                print("Error deleting preset: \(error)")
            }
        }
    }

    private func deleteOffsets(offsets: IndexSet) {
        withAnimation {
            offsets.map { presets[$0] }.forEach(moc.delete)
            do {
                try moc.save()
            } catch {
                print("Error deleting preset: \(error)")
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
