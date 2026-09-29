import Foundation
import SwiftUI
import WatchKit

// MARK: - Bolus Input View

struct BolusInputView: View {
    @Binding var navigationPath: NavigationPath
    @State private var bolusAmount = 0.0

    let state: WatchState

    @FocusState private var isCrownFocused: Bool

    private var effectiveBolusLimit: Double {
        Double(truncating: state.maxBolus as NSNumber)
    }

    var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        let bolusIncrement = Double(truncating: state.bolusIncrement as NSNumber)
        let adjustedBolusAmount = floor(bolusAmount / bolusIncrement) * bolusIncrement

        // In the "Meal & Bolus" flow the user can dial insulin down to zero (or the
        // recommendation itself is zero). In that case there is nothing to bolus, so
        // offer a plain "Log Carbs" action instead of a dead-end disabled button.
        let isCarbsOnly = state.carbsAmount > 0 && adjustedBolusAmount <= 0
        let actionButtonLabel = isCarbsOnly
            ? String(localized: "No Bolus, Log Carbs", comment: "Button Label to Log Carbs on Watch")
            : String(localized: "Enact Bolus")

        VStack {
            if state.showBolusCalculationProgress {
                ProgressView(String(
                    localized: "Calculating Bolus...",
                    comment: "Progress view text on watch when calculating bolus"
                ))
                Spacer()
            } else {
                if effectiveBolusLimit <= 0 {
                    VStack(spacing: 8) {
                        Text("Bolus limit cannot be fetched from phone!").font(.headline)
                        Text("Check device settings, connect to phone, and try again.").font(.caption)
                    }
                    .scenePadding()
                } else {
                    if state.carbsAmount > 0 {
                        // Display the current carb amount
                        HStack {
                            Text("Carbs:").bold().font(.subheadline).padding(.leading)
                            Text("\(state.carbsAmount) g").font(.subheadline).foregroundStyle(Color.orange)
                            Spacer()
                        }
                    }

                    Spacer()

                    HStack {
                        // "-" Button
                        Button(action: {
                            if bolusAmount > 0 { bolusAmount -= Double(truncating: state.bolusIncrement as NSNumber) }
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3)
                                .tint(Color.insulin)
                        }
                        .buttonStyle(.borderless)
                        .disabled(bolusAmount <= 0)

                        Spacer()

                        Text(String(format: "%.2f \(String(localized: "U", comment: "Insulin unit"))", adjustedBolusAmount))
                            .fontWeight(.bold)
                            .font(.system(.title2, design: .rounded))
                            .foregroundColor(bolusAmount > 0.0 && bolusAmount >= effectiveBolusLimit ? .loopRed : .primary)
                            .focusable(true)
                            .focused($isCrownFocused)
                            .digitalCrownRotation(
                                $bolusAmount,
                                from: 0,
                                through: effectiveBolusLimit,
                                by: Double(truncating: state.bolusIncrement as NSNumber),
                                sensitivity: .medium,
                                isContinuous: false,
                                isHapticFeedbackEnabled: true
                            )

                        Spacer()

                        // "+" Button
                        Button(action: {
                            bolusAmount = min(
                                effectiveBolusLimit,
                                bolusAmount + Double(truncating: state.bolusIncrement as NSNumber)
                            )
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .tint(Color.insulin)
                        }
                        .buttonStyle(.borderless)
                        .disabled(bolusAmount >= effectiveBolusLimit)
                    }.padding(.horizontal)

                    Text("Insulin")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.bottom, state.isReducedBolusAvailable || state.isSuperBolusAvailable ? 4 : nil)

                    if state.isReducedBolusAvailable || state.isSuperBolusAvailable {
                        bolusOptions
                    }

                    Spacer()

                    if bolusAmount > 0.0 && bolusAmount >= effectiveBolusLimit {
                        Text("Bolus Limit Reached!")
                            .font(.footnote)
                            .foregroundColor(.loopRed)
                    }

                    Button(actionButtonLabel) {
                        if isCarbsOnly {
                            state.sendCarbsRequest(state.carbsAmount)
                            state.carbsAmount = 0 // reset carbs in state
                            navigationPath.append(NavigationDestinations.acknowledgmentPending)
                        } else {
                            state.bolusAmount = min(bolusAmount, effectiveBolusLimit)
                            navigationPath.append(NavigationDestinations.bolusConfirm)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.insulin)
                    .disabled(!isCarbsOnly && (!(bolusAmount > 0.0) || bolusAmount > effectiveBolusLimit))

                    Text(String(
                        format: "\(String(localized: "Recommended:", comment: "Recommended bolus on Watch")) %.1f \(String(localized: "U", comment: "Insulin unit"))",
                        NSDecimalNumber(decimal: state.recommendedBolus).doubleValue
                    ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(trioBackgroundColor)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: "syringe.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .padding()
                    .background(Color.insulin)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
        }
        .onAppear {
            // Set initial bolus amount to recommended value
            // Only do this if user has not updated amount previously, e.g., when navigating to next and then back to this view
            if bolusAmount == 0 {
                state.requestBolusRecommendation()
                bolusAmount = Double(truncating: NSDecimalNumber(decimal: state.recommendedBolus))
            }
        }
        // Add onChange to update bolus amount when recommendation changes
        .onChange(of: state.recommendedBolus) { oldValue, newValue in
            // Only update if user hasn't modified the value OR if recommendation hasn't changed
            if bolusAmount == 0 || oldValue != newValue {
                bolusAmount = Double(truncating: NSDecimalNumber(decimal: newValue))
            }
        }
    }

    // MARK: - Reduced and super bolus

    /// The phone's "Reduced Bolus" and "Super Bolus" options, offered when enabled in its settings. Mutually
    /// exclusive; each change asks the phone for a new recommendation, which then replaces the amount.
    private var bolusOptions: some View {
        HStack(spacing: 6) {
            if state.isReducedBolusAvailable {
                bolusOptionButton(
                    String(localized: "Reduced Bolus"),
                    isOn: state.useReducedBolus
                ) {
                    state.useReducedBolus.toggle()
                    if state.useReducedBolus { state.useSuperBolus = false }
                    state.requestBolusRecommendation()
                }
            }
            if state.isSuperBolusAvailable {
                bolusOptionButton(
                    String(localized: "Super Bolus"),
                    isOn: state.useSuperBolus
                ) {
                    state.useSuperBolus.toggle()
                    if state.useSuperBolus { state.useReducedBolus = false }
                    state.requestBolusRecommendation()
                }
            }
        }
        .padding(.horizontal)
    }

    private func bolusOptionButton(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .background(isOn ? Color.insulin : Color.secondary.opacity(0.25), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
