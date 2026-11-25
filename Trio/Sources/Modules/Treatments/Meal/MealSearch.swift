import CoreData
import SwiftUI

/// The meal search field, used on the Treatments screen and in the meal sheet.
struct MealSearchBar: View {
    @Binding var query: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(String(localized: "Search foods..."), text: $query)
                .focused(isFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)

            if !query.isEmpty {
                Button {
                    query = ""
                    isFocused.wrappedValue = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear search"))
            }
        }
    }
}

/// Saved meal presets whose name matches `query`, as list rows. Tapping one hands back a new
/// `FoodItem` for it.
struct MealSearchResults: View {
    let query: String
    let onSelect: (FoodItem) -> Void

    @FetchRequest(
        entity: MealPresetStored.entity(),
        sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
    ) private var presets: FetchedResults<MealPresetStored>

    private var matches: [MealPresetStored] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return presets.filter { ($0.dish ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ForEach(matches) { preset in
            let item = preset.foodItem
            Button { onSelect(preset.foodItem) } label: {
                HStack(spacing: 12) {
                    FoodThumbnail(imageData: item.imageData, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(item.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Add \(item.name)"))
        }

        if matches.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("No matching presets")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// A food's photo, or a fork-and-knife placeholder.
struct FoodThumbnail: View {
    let imageData: Data?
    var size: CGFloat = 56

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.2)
                    .overlay(
                        Image(systemName: "fork.knife")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 4.5, style: .continuous))
    }
}

extension FoodItem {
    /// "333 ml · 33.3 g carbs": the portion and what it adds.
    var summary: String {
        let amount = amount.formatted(.number.precision(.fractionLength(0 ... 1)))
        let carbs = carbs.formatted(.number.precision(.fractionLength(0 ... 1)))
        return "\(amount) \(unit) · \(carbs) \(String(localized: "g carbs"))"
    }
}
