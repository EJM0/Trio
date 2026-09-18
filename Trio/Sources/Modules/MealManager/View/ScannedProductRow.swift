import SwiftUI

// MARK: - Scanned Product Row

extension MealManager {
    struct ScannedProductRow: View {
        let item: FoodItem
        var state: StateModel
        var focusedItemID: FocusState<UUID?>.Binding
        var isScaleConnected: Bool

        @State private var amount: Double = 0
        @State private var isMlInput: Bool = false
        @State private var showQuickSelector: Bool = false

        // Built once: this was a computed property, so the body made a fresh one every render.
        private static let formatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
            return formatter
        }()

        /// The portion stepper only means anything when the product tells us what one portion
        /// is. Without it the stepper used to step by 100g and label that "1x Portion".
        private var portionSize: Double? {
            guard let quantity = item.servingQuantity, quantity > 0 else { return nil }
            return quantity
        }

        var body: some View {
            let isFocused = focusedItemID.wrappedValue == item.id
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    productImage
                        .contentShape(Rectangle())
                        .onTapGesture(perform: togglePortions)

                    VStack(alignment: .leading, spacing: 6) {
                        // The item itself opens the portion stepper. The tap deliberately stops
                        // short of the amount field and the unit picker below/beside it -- a
                        // gesture over the whole row swallowed taps meant for those.
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)

                                if portionSize != nil {
                                    Image(systemName: "chevron.down")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .rotationEffect(.degrees(showQuickSelector ? 180 : 0))
                                }
                            }

                            if let brand = item.brand {
                                Text(brand)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: togglePortions)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(portionSize == nil ? [] : .isButton)
                        .accessibilityHint(
                            portionSize == nil ? "" : String(localized: "Shows the portion stepper")
                        )

                        KeyboardToolbarTextField(
                            value: $amount,
                            formatter: Self.formatter,
                            configuration: .init(
                                keyboardType: .decimalPad,
                                textAlignment: .left,
                                placeholder: "0",
                                font: .systemFont(ofSize: 17, weight: .bold)
                            ),
                            onFocusContext: { isEntering in
                                if isEntering {
                                    focusedItemID.wrappedValue = item.id
                                } else if isFocused {
                                    focusedItemID.wrappedValue = nil
                                }
                            },
                            externalFocus: isFocused
                        )
                        .frame(width: 70)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onChange(of: amount) { _, newValue in
                            state.updateScannedProductAmount(item, amount: newValue, isMlInput: isMlInput)
                        }
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        // Show scale button if connected
                        if isScaleConnected {
                            Button {
                                state.fetchScaleWeight { weight in
                                    let validWeight = max(0, weight)
                                    updateAmount(validWeight)
                                }
                            } label: {
                                Image(systemName: "arrow.down.circle.fill")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 24, height: 24)
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "Use scale reading"))
                        }

                        Picker(String(localized: "Unit"), selection: $isMlInput) {
                            Text("g").tag(false)
                            Text("ml").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 85)
                        .onChange(of: isMlInput) { _, newValue in
                            state.updateScannedProductAmount(item, amount: amount, isMlInput: newValue)
                        }
                    }
                }

                if showQuickSelector {
                    multiplierWheel
                        .padding(.top, 12)
                        // Fade only. The default insertion slides the wheel in from the row's
                        // edge, and a `List` row clips it mid-flight while its own height is
                        // still animating, which is what made this look broken.
                        .transition(.opacity)
                }
            }
            .onAppear {
                updateFromItem()
            }
            .onChange(of: item.amount) { _, _ in
                updateFromItem()
            }
            .onChange(of: item.isMlInput) { _, _ in
                updateFromItem()
            }
        }

        /// Only items that carry a serving size have portions to step through; for anything
        /// else the tap is a no-op rather than a stepper that invents a 100g "portion".
        private func togglePortions() {
            guard portionSize != nil else { return }
            withAnimation(.snappy(duration: 0.2)) { showQuickSelector.toggle() }
        }

        private func updateFromItem() {
            amount = item.amount
            isMlInput = item.isMlInput
        }

        private func updateAmount(_ amount: Double) {
            guard amount.isFinite else { return }
            self.amount = amount
            state.updateScannedProductAmount(item, amount: amount, isMlInput: isMlInput)
        }

        private func stepMultiplier(by value: Int) {
            guard let base = portionSize else { return }
            let next = max(1, Int(round(item.amount / base)) + value)
            updateAmount(base * Double(next))
        }

        @ViewBuilder private var multiplierWheel: some View {
            if let base = portionSize {
                let current = max(1, Int(round(item.amount / base)))

                HStack(spacing: 12) {
                    Button {
                        stepMultiplier(by: -1)
                    } label: {
                        Image(systemName: "minus")
                            .font(.title2.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "One portion fewer"))
                    .disabled(current <= 1)

                    VStack(spacing: 2) {
                        Text("\(current)x")
                            .font(.title2.weight(.bold))
                        // Says what a portion actually is, instead of asserting that one
                        // exists: "1x / 30 g each" rather than a bare "1x PORTION".
                        Text(
                            "\(Self.formatter.string(from: NSNumber(value: base)) ?? "") \(isMlInput ? "ml" : "g") each"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                    .frame(width: 110, height: 60)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityElement(children: .combine)

                    Button {
                        stepMultiplier(by: 1)
                    } label: {
                        Image(systemName: "plus")
                            .font(.title2.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "One portion more"))
                }
                .padding(.horizontal)
            }
        }

        @ViewBuilder private var productImage: some View {
            switch item.imageSource {
            case let .image(uiImage):
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: MealManager.Layout.thumbnail, height: MealManager.Layout.thumbnail)
                    .clipShape(RoundedRectangle(cornerRadius: MealManager.Layout.cornerRadius))

            case let .url(url):
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    default:
                        ProgressView()
                    }
                }
                .frame(width: MealManager.Layout.thumbnail, height: MealManager.Layout.thumbnail)
                .clipShape(RoundedRectangle(cornerRadius: MealManager.Layout.cornerRadius))

            case .none:
                placeholder
                    .frame(width: MealManager.Layout.thumbnail, height: MealManager.Layout.thumbnail)
            }
        }

        private var placeholder: some View {
            RoundedRectangle(cornerRadius: MealManager.Layout.cornerRadius)
                .fill(Color.secondary.opacity(0.2))
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                )
        }
    }
}
