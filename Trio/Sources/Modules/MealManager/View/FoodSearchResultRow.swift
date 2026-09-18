import SwiftUI

extension MealManager {
    /// A compact row view for displaying food search results
    struct FoodSearchResultRow: View {
        let item: FoodItem
        /// Saved meal presets render their origin as a chip and their carbs as a plain total,
        /// which is how they have always been shown; remote results keep the per-100g form.
        var isPreset: Bool = false
        let onAdd: () -> Void

        var body: some View {
            Button(action: onAdd) {
                HStack(spacing: 12) {
                    // Product image
                    productImage
                        .frame(
                            width: MealManager.Layout.thumbnailCompact,
                            height: MealManager.Layout.thumbnailCompact
                        )
                        .clipShape(RoundedRectangle(cornerRadius: MealManager.Layout.cornerRadiusCompact))

                    // Product info
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            if let brand = item.brand {
                                if isPreset {
                                    Text(brand)
                                        .font(.caption2)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.1))
                                        .foregroundStyle(.blue)
                                        .cornerRadius(4)
                                } else {
                                    Text(brand)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            if isPreset {
                                // A preset stores its carbs per 100 g/ml *and* the portion it
                                // was saved at, so this used to print a per-100 figure with no
                                // qualifier: a 250 g preset at 10 g/100 g read "10g carbs" and
                                // then added 25 g. `item.carbs` is the portion total, which is
                                // what tapping the row actually adds.
                                Text("\(portionDescription) · \(item.carbs, specifier: "%.1f")g carbs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let carbs = item.nutriments.carbohydratesPer100g {
                                Text("\(carbs, specifier: "%.1f")g carbs/100g")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                        }
                    }

                    Spacer()

                    // Add button indicator
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Add \(item.name)"))
        }

        /// The amount a preset adds when tapped, e.g. "250 g".
        private var portionDescription: String {
            let unit = item.isMlInput ? "ml" : "g"
            return "\(item.amount.formatted(.number.precision(.fractionLength(0 ... 1)))) \(unit)"
        }

        @ViewBuilder private var productImage: some View {
            switch item.imageSource {
            case let .url(url):
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        imagePlaceholder
                    default:
                        ProgressView()
                            .frame(
                                width: MealManager.Layout.thumbnailCompact,
                                height: MealManager.Layout.thumbnailCompact
                            )
                    }
                }

            case let .image(uiImage):
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()

            case .none:
                imagePlaceholder
            }
        }

        private var imagePlaceholder: some View {
            RoundedRectangle(cornerRadius: MealManager.Layout.cornerRadiusCompact)
                .fill(Color.secondary.opacity(0.2))
                .overlay(
                    Image(systemName: "fork.knife")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                )
        }
    }
}
