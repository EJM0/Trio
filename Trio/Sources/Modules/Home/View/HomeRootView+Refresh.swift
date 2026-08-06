import SwiftUI
import UIKit

/// Pull distance via layout frames — iOS 17 fallback only.
struct HomePullOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Pull distance, held outside the root view's `@State` on purpose. Every frame of a pull —
/// and of the spring-back — writes this value; as root-view state each write re-rendered the
/// whole dashboard (chart included), and the resulting main-thread load made the release
/// visibly stick before the scroll view returned. Only `PullToRefreshIndicator` reads it, so
/// only that subtree re-renders now.
@Observable final class HomePullState {
    var offset: CGFloat = 0
}

/// Applies the iOS 17 preference-based offset source. On iOS 18+ the scroll geometry reader
/// below supplies the value instead, so the two never both write per frame.
struct HomeLegacyPullOffsetWriter: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
        } else {
            content.background(
                GeometryReader { g in
                    Color.clear.preference(
                        key: HomePullOffsetKey.self,
                        value: g.frame(in: .named("homeScroll")).minY
                    )
                }
            )
        }
    }
}

/// Streams the pull-down distance from the scroll geometry on iOS 18+.
struct HomePullOffsetReader: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, pull in
                onChange(pull)
            }
        } else {
            content
        }
    }
}

// MARK: - Pull-down-to-force-loop

/// Own view rather than a `@ViewBuilder` on the root view: a builder property is inlined
/// into the root's body, so reading the pull offset there would re-render the dashboard on
/// every frame — the very thing `HomePullState` exists to avoid.
struct PullToRefreshIndicator: View {
    let pullState: HomePullState
    let isForcingLoop: Bool

    /// Only ever visible while pulled: the running loop is shown by the loop icon
    /// spinner, so pulling down again mid-loop just peeks at that status.
    var body: some View {
        let pullOffset = pullState.offset
        if pullOffset > 4 {
            let progress = min(pullOffset / HomeLayout.refreshTriggerDistance, 1)
            HStack(spacing: 8) {
                if isForcingLoop {
                    ProgressView()
                    Text("Forcing loop…")
                } else {
                    Image(systemName: "arrow.down")
                        .rotationEffect(.degrees(progress * 180))
                    Text("Pull down to force loop")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .opacity(progress)
            .frame(height: HomeLayout.refreshIndicatorHeight)
            .frame(maxWidth: .infinity)
        }
    }
}

extension Home.RootView {
    /// Arms once per pull at the threshold; re-arms after the pull settles.
    func handlePullChange(_ offset: CGFloat) {
        // Overscrolling upward is not a pull; clamping keeps the indicator from reacting.
        let pull = max(0, offset)
        pullState.offset = pull
        guard !isForcingLoop else { return }
        if pull >= HomeLayout.refreshTriggerDistance, !isRefreshArmed {
            isRefreshArmed = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            forceLoop()
        } else if pull <= 1, isRefreshArmed {
            isRefreshArmed = false
        }
    }

    /// Triggers the loop heartbeat and holds the indicator while it runs.
    private func forceLoop() {
        withAnimation(.easeInOut(duration: 0.2)) { isForcingLoop = true }
        state.runLoop()
        Task {
            let start = Date()
            while !state.isLooping, Date().timeIntervalSince(start) < 3 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            while state.isLooping, Date().timeIntervalSince(start) < 30 {
                try? await Task.sleep(for: .milliseconds(200))
            }
            // Minimum visible duration.
            let elapsed = Date().timeIntervalSince(start)
            if elapsed < 1 {
                try? await Task.sleep(for: .seconds(1 - elapsed))
            }
            withAnimation(.easeInOut(duration: 0.25)) { isForcingLoop = false }
        }
    }
}
