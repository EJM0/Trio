import SwiftUI
import Swinject

extension Color {
    /// The Watch Loop wherever it shows: a bright cyan on the dark background, deeper on the light one.
    static let watchLoop = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x33 / 255, green: 0xE3 / 255, blue: 0xFF / 255, alpha: 1)
            : UIColor(red: 0x00 / 255, green: 0x9C / 255, blue: 0xBD / 255, alpha: 1)
    })
}

extension Resolver {
    var watchLoop: BaseWatchLoopPhoneManager? { resolve(WatchLoopPhoneManager.self) as? BaseWatchLoopPhoneManager }
}

/// `content`, or the Watch Loop banner while the watch has the pod. A tap offers taking it back.
struct WatchLoopBannerSlot<Content: View, Banner: View>: View {
    @ObservedObject var manager: BaseWatchLoopPhoneManager
    @ViewBuilder let content: () -> Content
    let banner: (_ title: String, _ subtitle: String, _ action: @escaping () -> Void) -> Banner
    @State private var confirmTakeBack = false

    var body: some View {
        if manager.isWatchInCharge {
            banner(String(localized: "Watch Loop on Apple Watch"), subtitle) { confirmTakeBack = true }
                .watchLoopTakeBackDialog(isPresented: $confirmTakeBack, manager: manager)
        } else {
            content()
        }
    }

    private var subtitle: String {
        guard let status = manager.state.liveStatus, let last = status.lastLoopAt else {
            return String(localized: "The iPhone doesn't dose. Enter carbs and boluses on the watch.")
        }
        let minutes = max(0, Int(Date().timeIntervalSince(last) / 60))
        return String(localized: "Last loop on the watch \(minutes) min ago. Tap to take the pod back.")
    }
}

/// The settings the watch doses with came with the grant; a change here would never reach it. Locked until the
/// hand-back, as LoopKit/Loop#2545 locks Settings during a loan.
struct WatchLoopSettingsGate<Content: View>: View {
    @ObservedObject var manager: BaseWatchLoopPhoneManager
    @ViewBuilder let content: () -> Content

    var body: some View {
        if manager.isWatchInCharge {
            WatchLoopLockedView(
                manager: manager,
                title: String(localized: "Locked While the Watch Loops"),
                message: String(localized: "The watch doses with these settings. Take the pod back to change them.")
            )
        } else {
            content()
        }
    }
}

/// Carbs, boluses and adjustments are entered on the watch while it has the pod.
struct WatchLoopTreatmentGate<Content: View>: View {
    @ObservedObject var manager: BaseWatchLoopPhoneManager
    @ViewBuilder let content: () -> Content

    var body: some View {
        if manager.isWatchInCharge {
            WatchLoopLockedView(
                manager: manager,
                title: String(localized: "Apple Watch Is Looping"),
                message: String(localized: "Enter carbs and boluses on the watch. They come back to the iPhone with its records.")
            )
        } else {
            content()
        }
    }
}

private struct WatchLoopLockedView: View {
    @ObservedObject var manager: BaseWatchLoopPhoneManager
    let title: String
    let message: String
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmTakeBack = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.watchLoop)
                .frame(width: 76, height: 76)
                .background(Circle().fill(Color.watchLoop.opacity(0.18)))
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(title).font(.title3).fontWeight(.semibold)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)
            Button { confirmTakeBack = true } label: {
                Label("Take Back the Pod", systemImage: "iphone")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.bordered)
            .tint(.watchLoop)
            Spacer()
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea())
        .watchLoopTakeBackDialog(isPresented: $confirmTakeBack, manager: manager)
    }
}

/// The home screen while the watch has the pod: a halo behind the glucose bubble, as Trio's rings glow
/// (Kristin Kandschur, 3010a9a15). The header's background, so it is centred on the bubble and scrolls with it.
struct WatchLoopHomeGlow: View {
    @ObservedObject var manager: BaseWatchLoopPhoneManager

    /// The bubble is 130 pt drawn at 0.9 (`CurrentGlucoseView`), its edge 58 pt out: the halo is full there and gone
    /// within the header (`HomeLayout.headerHeight`).
    private static let radius: CGFloat = 90

    private static let glow = Gradient(stops: [
        .init(color: Color.watchLoop.opacity(0.3), location: 0),
        .init(color: Color.watchLoop.opacity(0.3), location: 0.62),
        .init(color: Color.watchLoop.opacity(0.12), location: 0.8),
        .init(color: Color.watchLoop.opacity(0), location: 1)
    ])

    var body: some View {
        RadialGradient(gradient: Self.glow, center: .center, startRadius: 0, endRadius: Self.radius)
            .frame(width: Self.radius * 2, height: Self.radius * 2)
            .opacity(manager.isWatchInCharge ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(.easeInOut(duration: 0.4), value: manager.isWatchInCharge)
    }
}

/// The pod tile while the watch has the pod: a tap offers taking it back.
struct WatchLoopTakeBackOnPump: ViewModifier {
    @Binding var isPresented: Bool
    let manager: BaseWatchLoopPhoneManager?

    func body(content: Content) -> some View {
        if let manager {
            content.watchLoopTakeBackDialog(isPresented: $isPresented, manager: manager)
        } else {
            content
        }
    }
}

extension View {
    /// "Take back the pod?": the phone reaches for it and tells the watch to stop.
    func watchLoopTakeBackDialog(isPresented: Binding<Bool>, manager: BaseWatchLoopPhoneManager) -> some View {
        modifier(WatchLoopTakeBack(isPresented: isPresented, manager: manager))
    }
}

private struct WatchLoopTakeBack: ViewModifier {
    @Binding var isPresented: Bool
    let manager: BaseWatchLoopPhoneManager
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Take the pod back?", isPresented: $isPresented, titleVisibility: .visible) {
                Button("Take Back") { Task { failure = await manager.takeBack() } }
            } message: {
                Text(
                    "The iPhone reaches for the pod and tells the watch to stop. Insulin the watch's records don't explain yet is counted as a bolus now."
                )
            }
            .alert("Couldn't Reach the Pod", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }
}
