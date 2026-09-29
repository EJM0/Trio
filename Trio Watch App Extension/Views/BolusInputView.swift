import Foundation
import SwiftUI
import WatchKit

// MARK: - Bolus Input View

struct BolusInputView: View {
    @Binding var navigationPath: NavigationPath
    @State private var bolusAmount = 0.0

    let state: WatchState

    @FocusState private var isCrownFocused: Bool
    /// Set once the first recommendation arrived (or timed out); later recalculations then keep the layout.
    @State private var hasLoadedRecommendation = false

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
        let adjustedBolusAmount = roundedDown(bolusAmount)
        let recommendedAmount = min(effectiveBolusLimit, Double(truncating: NSDecimalNumber(decimal: state.recommendedBolus)))
        let isLimitReached = bolusAmount > 0.0 && bolusAmount >= effectiveBolusLimit
        // A first recommendation fills the whole screen; later ones (option toggles) keep the layout.
        let isRecalculating = state.showBolusCalculationProgress && hasLoadedRecommendation
        // As on the phone, the recommendation pill grays out once its amount is the one entered, or when it is zero.
        let isRecommendationTaken = recommendedAmount <= 0 || abs(adjustedBolusAmount - recommendedAmount) < bolusIncrement / 2

        // In the "Meal & Bolus" flow the user can dial insulin down to zero (or the
        // recommendation itself is zero). In that case there is nothing to bolus, so
        // offer a plain "Log Carbs" action instead of a dead-end disabled button.
        let isCarbsOnly = state.carbsAmount > 0 && adjustedBolusAmount <= 0
        let actionButtonLabel = isCarbsOnly
            ? String(localized: "No Bolus, Log Carbs", comment: "Button Label to Log Carbs on Watch")
            : String(localized: "Enact Bolus")

        VStack {
            if state.showBolusCalculationProgress && !hasLoadedRecommendation {
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
                        // The current carb amount; the icon and color say what it is, so it needs no title.
                        Label("\(state.carbsAmount) g", systemImage: "fork.knife")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.orange)
                    }

                    Spacer()

                    HStack {
                        // "-" Button
                        Button(action: {
                            bolusAmount = max(0, bolusAmount - bolusIncrement)
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3)
                                .tint(Color.insulin)
                        }
                        .buttonStyle(.borderless)
                        .disabled(bolusAmount <= 0)

                        Spacer()

                        Text(verbatim: "\(formattedAmount(adjustedBolusAmount)) \(insulinUnit)")
                            .fontWeight(.bold)
                            .font(.system(.title2, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(isLimitReached ? .loopRed : .primary)
                            .focusable(true)
                            .focused($isCrownFocused)
                            .digitalCrownRotation(
                                $bolusAmount,
                                from: 0,
                                through: effectiveBolusLimit,
                                by: bolusIncrement,
                                sensitivity: .medium,
                                isContinuous: false,
                                isHapticFeedbackEnabled: true
                            )

                        Spacer()

                        // "+" Button
                        Button(action: {
                            bolusAmount = min(effectiveBolusLimit, bolusAmount + bolusIncrement)
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .tint(Color.insulin)
                        }
                        .buttonStyle(.borderless)
                        .disabled(bolusAmount >= effectiveBolusLimit)
                    }.padding(.horizontal)

                    recommendationPill(
                        amount: recommendedAmount,
                        isTaken: isRecommendationTaken,
                        isRecalculating: isRecalculating,
                        isLimitReached: isLimitReached
                    )
                    .padding(.top, 2)

                    if state.isReducedBolusAvailable || state.isSuperBolusAvailable {
                        bolusOptions
                            .padding(.top, 4)
                    }

                    Spacer()

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
                }
            }
        }
        .background(trioBackgroundColor)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OnBoardToolbarBadge(systemImage: "syringe.fill", value: state.iob, unit: insulinUnit, color: .insulin, state: state)
            }
        }
        .onAppear {
            // As on the phone, the amount starts at 0 and the recommendation is only offered in the pill; the user
            // takes it (normal, reduced or super) by tapping it. Only ask for one when no amount is set yet, e.g. not
            // when coming back from the confirmation screen.
            if bolusAmount == 0 {
                state.requestBolusRecommendation()
            }
        }
        .onChange(of: state.showBolusCalculationProgress) { _, isCalculating in
            if !isCalculating { hasLoadedRecommendation = true }
        }
    }

    // MARK: - Amounts

    private var insulinUnit: String { String(localized: "U", comment: "Insulin unit") }

    /// Rounds down to the pump's bolus increment. The epsilon keeps floating point from flooring an exact step one
    /// increment down (0.3 / 0.1 = 2.999…).
    private func roundedDown(_ amount: Double) -> Double {
        let increment = Double(truncating: state.bolusIncrement as NSNumber)
        guard increment > 0 else { return amount }
        return floor(amount / increment + 1e-9) * increment
    }

    /// Shows as many decimals as the bolus increment has (0.1 → 6.7, 0.05 → 6.65), at least one.
    private func formattedAmount(_ amount: Double) -> String {
        let increment = NSDecimalNumber(decimal: state.bolusIncrement).stringValue
        let decimals = increment.split(separator: ".").dropFirst().first?.count ?? 0
        return String(format: "%.\(min(max(decimals, 1), 3))f", amount)
    }

    // MARK: - Recommendation

    /// Tapping the recommendation takes it as the amount, as on the phone's Treatments view. While a new one is being
    /// calculated it shows a spinner in place of the number; at the bolus limit it shows the limit warning instead,
    /// so neither moves the layout.
    private func recommendationPill(
        amount: Double,
        isTaken: Bool,
        isRecalculating: Bool,
        isLimitReached: Bool
    ) -> some View {
        let isInactive = isTaken || isRecalculating || isLimitReached
        let foreground: Color = isLimitReached ? .loopRed : isInactive ? .secondary : .insulin
        let background: Color = isLimitReached ? Color.loopRed.opacity(0.2) :
            isInactive ? Color.secondary.opacity(0.2) : Color.insulin.opacity(0.25)

        return Button {
            bolusAmount = amount
            WKInterfaceDevice.current().play(.click)
        } label: {
            HStack(spacing: 4) {
                if isLimitReached {
                    Text("Bolus Limit Reached!")
                } else {
                    Text(String(localized: "Recommended:", comment: "Recommended bolus on Watch"))
                    if isRecalculating {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Text(verbatim: "\(formattedAmount(amount)) \(insulinUnit)")
                            .monospacedDigit()
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .background(background, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isInactive)
        .animation(.easeInOut(duration: 0.2), value: isInactive)
    }

    // MARK: - Reduced and super bolus

    /// The phone's "Reduced Bolus" and "Super Bolus" options, offered when enabled in its settings. Mutually
    /// exclusive; each change asks the phone for a new recommendation, which the pill then offers.
    private var bolusOptions: some View {
        HStack(spacing: 6) {
            if state.isReducedBolusAvailable {
                bolusOptionButton(
                    String(localized: "Reduced", comment: "Short bolus option label on the watch bolus screen"),
                    systemImage: "arrow.down",
                    accessibilityName: String(localized: "Reduced Bolus"),
                    isOn: state.useReducedBolus
                ) {
                    state.useReducedBolus.toggle()
                    if state.useReducedBolus { state.useSuperBolus = false }
                    state.requestBolusRecommendation()
                }
            }
            if state.isSuperBolusAvailable {
                bolusOptionButton(
                    String(localized: "Super", comment: "Short bolus option label on the watch bolus screen"),
                    systemImage: "bolt.fill",
                    accessibilityName: String(localized: "Super Bolus"),
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

    private func bolusOptionButton(
        _ title: String,
        systemImage: String,
        accessibilityName: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
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
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
