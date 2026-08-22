import SwiftUI

/// A reusable animated spinner capsule component that overlays any content.
///
/// With Reduce Motion on, the spinning dashed border never appears: the capsule keeps its
/// plain static border and the content is handed `reduceMotionActive` so it can spell the
/// looping state out instead of animating it.
struct CapsuleSpinnerView<Content: View>: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    let isLooping: Bool
    let color: Color
    let content: (Bool, Bool) -> Content

    @State private var isAnimating: Bool = false
    @State private var spinProgress: CGFloat = 0.0
    @State private var spinAnimation: Animation? = nil
    @State private var spinStartDate: Date? = nil
    @State private var startAnimationTask: Task<Void, Never>? = nil
    @State private var stopAnimationTask: Task<Void, Never>? = nil

    // OPTION 1: Initializer WITH the animating and reduce-motion arguments
    init(
        isLooping: Bool,
        color: Color,
        @ViewBuilder content: @escaping (_ isAnimating: Bool, _ reduceMotionActive: Bool) -> Content
    ) {
        self.isLooping = isLooping
        self.color = color
        self.content = content
    }

    // OPTION 2: Initializer WITH the animating argument only
    init(
        isLooping: Bool,
        color: Color,
        @ViewBuilder content: @escaping (_ isAnimating: Bool) -> Content
    ) {
        self.isLooping = isLooping
        self.color = color
        self.content = { isAnimating, _ in content(isAnimating) }
    }

    // OPTION 3: Initializer WITHOUT the animating argument
    init(
        isLooping: Bool,
        color: Color,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isLooping = isLooping
        self.color = color
        self.content = { _, _ in content() }
    }

    var body: some View {
        content(isAnimating, reduceMotion)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .overlay(
                Group {
                    // Reduce Motion keeps the plain border; the content carries the looping state
                    if isAnimating, !reduceMotion {
                        DashedCapsuleBorder(progress: spinProgress)
                            .stroke(color.opacity(0.4), style: StrokeStyle(lineWidth: 2.05, lineCap: .round))
                            .animation(spinAnimation, value: spinProgress)
                            .transition(.opacity)
                    } else {
                        Capsule()
                            .stroke(color.opacity(0.4), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .transition(.opacity)
                    }
                }
            )
            .onAppear {
                updateAnimating(isLooping)
            }
            .onChange(of: isLooping) { _, newValue in
                updateAnimating(newValue)
            }
            .onChange(of: reduceMotion) { _, motionReduced in
                if motionReduced {
                    // drop the in-flight spin so the border can't freeze mid-dash
                    spinAnimation = nil
                    spinProgress = 0.0
                } else if isAnimating, startAnimationTask == nil {
                    guard !reduceMotion else { return }

                    spinAnimation = .linear(duration: 1.333).repeatForever(autoreverses: false)
                    spinProgress = 1.0
                }
            }
    }
    
    private func updateAnimating(_ newValue: Bool) {
        if newValue {
            stopAnimationTask?.cancel()
            stopAnimationTask = nil

            guard startAnimationTask == nil else { return }

            spinStartDate = Date()

            startAnimationTask = Task { @MainActor in
                // 1. Reset progress instantly — `spinAnimation` is nil, so the border
                //    ignores whatever animation the fade-in below puts in the transaction
                self.spinAnimation = nil
                self.spinProgress = 0.0

                // 2. Fade in the spinning capsule
                withAnimation(.easeInOut(duration: 0.3)) {
                    isAnimating = true
                }

                // 3. Wait for transition. Also keeps the reset and the spin target in
                //    separate updates, so SwiftUI can't collapse 1.0 -> 0.0 -> 1.0 into
                //    no change at all
                try? await Task.sleep(for: .seconds(0.3))

                // 4. Drive the normalized 0.0 -> 1.0 spin loop
                startSpin()

                startAnimationTask = nil
            }
        } else {
            stopAnimationTask?.cancel()

            stopAnimationTask = Task { @MainActor in
                while startAnimationTask != nil {
                    try? await Task.sleep(for: .milliseconds(20))
                    guard !Task.isCancelled else { return }
                }

                let elapsed = spinStartDate.map { Date().timeIntervalSince($0) } ?? 0
                let minimumSpinTime: TimeInterval = 2.0
                let remaining = max(0, minimumSpinTime - elapsed)

                if remaining > 0 {
                    try? await Task.sleep(for: .seconds(remaining))
                    guard !Task.isCancelled else { return }
                }

                // 1. Fade out spinning capsule
                withAnimation(.easeInOut(duration: 0.3)) {
                    isAnimating = false
                }

                // 2. Wait for the transition
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled else { return }

                // 3. Reset animation state
                self.spinAnimation = nil
                self.spinProgress = 0.0

                spinStartDate = nil
            }
        }
    }
}

// MARK: - Custom Self-Measuring Animatable Shape

private struct DashedCapsuleBorder: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let perimeter: CGFloat = w >= h
            ? (2 * (w - h) + .pi * h).rounded()
            : (2 * (h - w) + .pi * w).rounded()

        let dashLength = perimeter * 0.7
        let gapLength = perimeter * 0.3
        let dashPhase = -progress * perimeter

        // ONLY apply dash styling here, NOT the line width
        var style = StrokeStyle(lineCap: .round)
        style.dash = [dashLength, gapLength]
        style.dashPhase = dashPhase

        return Capsule().path(in: rect).strokedPath(style)
    }
}
