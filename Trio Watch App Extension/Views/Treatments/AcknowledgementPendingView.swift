import SwiftUI
import WatchKit

struct AcknowledgementPendingView: View {
    @Binding var navigationPath: NavigationPath
    let state: WatchState
    @Binding var shouldNavigateToRoot: Bool

    var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var statusIcon: some View {
        switch state.acknowledgementStatus {
        case .pending:
            return Image(systemName: "progress.indicator").foregroundStyle(Color.secondary)
        case .success:
            return Image(systemName: "checkmark.circle").foregroundStyle(Color.loopGreen)
        case .failure:
            return Image(systemName: "xmark").foregroundStyle(Color.loopRed)
        }
    }

    var body: some View {
        Group {
            if let pendingBolusOverride = state.pendingBolusOverride {
                BolusOverrideConfirmationView(
                    navigationPath: $navigationPath,
                    state: state,
                    pendingBolusOverride: pendingBolusOverride
                )
            } else {
                VStack {
                    if state.isMealBolusCombo {
                        ProgressView()
                        Text(state.mealBolusStep.rawValue).multilineTextAlignment(.center)
                    } else if state.showAcknowledgmentBanner {
                        statusIcon.padding()
                        Text(state.acknowledgmentMessage).multilineTextAlignment(.center)
                            .foregroundStyle(state.acknowledgementStatus == .failure ? Color.loopRed : Color.primary)
                    } else if state.showCommsAnimation {
                        ProgressView()
                        Text("Processing…")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden)
        .background(trioBackgroundColor)
        // WatchState times out a missing answer by showing a banner (beginAwaitingAcknowledgment), so every
        // request ends here. A timer in this view never started: the flag is already true when the view appears.
        .onChange(of: state.showAcknowledgmentBanner) { _, newValue in
            if !newValue {
                // Navigate back to the root when acknowledgment banner disappears
                navigationPath.removeLast(navigationPath.count)
            }
        }
        .onDisappear {
            state.shouldNavigateToRoot = true
            state.pendingBolusOverride = nil
        }
    }
}

/// Shown when the phone blocked a bolus on a safety check the user may bolus through, as on the main bolus screen.
/// The user confirms with the digital crown again, always at the slower step, before the bolus is sent back.
private struct BolusOverrideConfirmationView: View {
    @Binding var navigationPath: NavigationPath
    let state: WatchState
    let pendingBolusOverride: PendingBolusOverride

    @State private var confirmationProgress: Double = 0
    @FocusState private var isCrownFocused: Bool

    var body: some View {
        let bolusAmount = Double(truncating: pendingBolusOverride.amount as NSNumber)

        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)

            Text(pendingBolusOverride.reason)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)

            HStack {
                Text("Bolus")
                Spacer()
                Text(String(format: "%.2f \(String(localized: "U", comment: "Insulin unit"))", bolusAmount))
                    .bold()
                    .foregroundStyle(Color.insulin)
            }.padding(.horizontal)

            ProgressView(value: confirmationProgress, total: 1.0)
                .tint(confirmationProgress >= 1.0 ? .orange : .gray)
                .padding(.horizontal)

            Text("To bolus anyway, dial crown.").font(.footnote)

            Button("Cancel") {
                state.pendingBolusOverride = nil
                navigationPath.removeLast(navigationPath.count)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable(true)
        .focused($isCrownFocused)
        .digitalCrownRotation(
            $confirmationProgress,
            from: 0.0,
            through: 1.0,
            by: 0.05,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onAppear {
            isCrownFocused = true
            WKInterfaceDevice.current().play(.notification)
        }
        .onChange(of: confirmationProgress) { _, newValue in
            if newValue >= 1.0 {
                WKInterfaceDevice.current().play(.success)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    state.sendBolusRequest(pendingBolusOverride.amount, confirming: pendingBolusOverride)
                }
            } else if newValue > 0 {
                WKInterfaceDevice.current().play(.click)
            }
        }
    }
}
