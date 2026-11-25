import SwiftUI

/// The meal sheet opened from the Treatments toolbar: the meal being entered, and the saved presets.
struct MealSheet: View {
    @Bindable var meal: MealModel
    let showsFatAndProtein: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker(String(localized: "Mode"), selection: $meal.tab) {
                    Text("Meal").tag(MealModel.Tab.meal)
                    Text("Presets").tag(MealModel.Tab.presets)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                switch meal.tab {
                case .meal:
                    MealListView(meal: meal, showsFatAndProtein: showsFatAndProtein)
                case .presets:
                    MealPresetListView(meal: meal, showsFatAndProtein: showsFatAndProtein)
                }
            }
            .padding(.top)
            .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
            .navigationTitle(meal.tab == .meal ? String(localized: "Meal") : String(localized: "Meal Presets"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // "Done", not "Close": items are in the meal as soon as they are added.
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }
}

/// The Meal tab: search, the items in the meal and their total.
struct MealListView: View {
    @Bindable var meal: MealModel
    let showsFatAndProtein: Bool

    @FocusState private var isSearchFocused: Bool
    @State private var editingItem: FoodItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MealSearchBar(query: $meal.searchQuery, isFocused: $isSearchFocused)
                .padding(10)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)

            if !meal.items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("^[\(meal.items.count) item](inflect: true)")
                        .font(.title2.bold())
                    Text("Total \(meal.carbs.formatted(.number.precision(.fractionLength(0 ... 1)))) g carbs")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal)
            }

            List {
                if !meal.searchQuery.isEmpty {
                    Section {
                        MealSearchResults(query: meal.searchQuery) { item in
                            meal.items.append(item)
                            meal.searchQuery = ""
                            isSearchFocused = false
                        }
                    }
                    .listRowBackground(Color.chart)
                }

                Section {
                    ForEach($meal.items) { $item in
                        MealItemRow(item: $item)
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
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
            .overlay {
                if meal.items.isEmpty, meal.searchQuery.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No items yet"),
                        systemImage: "fork.knife",
                        description: Text("Search your meal presets to add items.")
                    )
                }
            }
        }
        .sheet(item: $editingItem) { item in
            FoodItemEditor(
                item: item,
                title: String(localized: "Edit Item"),
                saveTitle: String(localized: "Update"),
                isPreset: false,
                showsFatAndProtein: showsFatAndProtein
            ) { edited in
                if let index = meal.items.firstIndex(where: { $0.id == edited.id }) {
                    meal.items[index] = edited
                }
            }
        }
    }

    private func editButton(for item: FoodItem) -> some View {
        Button { editingItem = item } label: {
            Label("Edit", systemImage: "pencil")
        }
        .tint(.blue)
    }

    private func deleteButton(for item: FoodItem) -> some View {
        Button(role: .destructive) {
            withAnimation { meal.items.removeAll { $0.id == item.id } }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// One item in the meal: photo, name, carbs, the amount, and a portion stepper for items that
/// know their portion size.
struct MealItemRow: View {
    @Binding var item: FoodItem
    @State private var showsStepper = false

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FoodThumbnail(imageData: item.imageData)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(item.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if item.servingSize != nil {
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(showsStepper ? 180 : 0))
                        }
                    }
                    Text("\(item.carbs.formatted(.number.precision(.fractionLength(0 ... 1)))) g carbs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Only the name toggles the stepper, so taps on the amount field stay with it.
                .contentShape(Rectangle())
                .onTapGesture {
                    guard item.servingSize != nil else { return }
                    withAnimation(.snappy(duration: 0.2)) { showsStepper.toggle() }
                }

                Spacer()

                TextFieldWithToolBar(
                    text: $item.amount,
                    placeholder: "0",
                    numberFormatter: Self.formatter,
                    unitsText: item.unit
                )
                .frame(width: 100)
            }

            if showsStepper, let portion = item.servingSize, portion > 0 {
                stepper(portion: portion)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
    }

    private func stepper(portion: Decimal) -> some View {
        let count = max(1, Int(Double(truncating: (item.amount / portion) as NSNumber).rounded()))
        return HStack(spacing: 12) {
            Button { item.amount = portion * Decimal(count - 1) } label: {
                Image(systemName: "minus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(count <= 1)
            .accessibilityLabel(String(localized: "One portion fewer"))

            VStack(spacing: 2) {
                Text("\(count)x").font(.headline)
                Text("\(portion.formatted(.number.precision(.fractionLength(0 ... 1)))) \(item.unit) each")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110)
            .accessibilityElement(children: .combine)

            Button { item.amount = portion * Decimal(count + 1) } label: {
                Image(systemName: "plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel(String(localized: "One portion more"))
        }
        .font(.title3.weight(.bold))
        .buttonStyle(.bordered)
    }
}
