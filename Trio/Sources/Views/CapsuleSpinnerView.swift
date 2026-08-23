import SwiftUI

/// A capsule border whose dashed gap travels around the perimeter while `isActive`,
/// crossfading to a solid border when it stops. Drop it on any pill-shaped view with
/// `.capsuleSpinner(isActive:color:)` - it needs nothing from its content.
///
/// Reduce Motion is honoured here: the border simply stays solid and no spin is ever
/// started. Content that used the spin to convey a state has to say so in its own way,
/// reading `\.accessibilityReduceMotion` itself.
///
/// The spin is driven by animating `DashedCapsuleBorder`'s `animatableData` through the
/// shape's own `.animation(_:value:)`, so the repeating animation is scoped to the border
/// view and dies with it. It is deliberately never started with `withAnimation` on a
/// `@State` value, which outlives the view and keeps animating off-screen.
struct CapsuleSpinnerBorder: ViewModifier {
    let isActive: Bool
    let color: Color
    var activeLineWidth: CGFloat = 2.5
    var idleLineWidth: CGFloat = 2
    var spinDuration: Double = 1.333
    var crossfadeDuration: Double = 0.3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isSpinning: Bool = false
    @State private var spinProgress: CGFloat = 0.0
    @State private var spinAnimation: Animation? = nil

    /// Reduce Motion turns every request into "solid border", and flipping the setting
    /// re-runs the task below, so a spin already under way is torn down properly.
    private var shouldSpin: Bool { isActive && !reduceMotion }

    func body(content: Content) -> some View {
        content
            .overlay(
                Group {
                    if isSpinning {
                        DashedCapsuleBorder(progress: spinProgress)
                            .stroke(
                                color.opacity(0.4),
                                style: StrokeStyle(lineWidth: activeLineWidth, lineCap: .round)
                            )
                            .animation(spinAnimation, value: spinProgress)
                            .transition(.opacity)
                    } else {
                        Capsule()
                            .stroke(
                                color.opacity(0.4),
                                style: StrokeStyle(lineWidth: idleLineWidth, lineCap: .round)
                            )
                            .transition(.opacity)
                    }
                }
            )
            // Re-runs on every flip, cancelling the previous run, so a stale fade-out can
            // never clobber a re-activation and no half-finished spin is left behind.
            .task(id: shouldSpin) {
                shouldSpin ? await startSpinning() : await stopSpinning()
            }
    }

    private func startSpinning() async {
        // 1. Reset progress instantly - `spinAnimation` is nil, so the border ignores
        //    whatever animation the fade-in below puts in the transaction
        spinAnimation = nil
        spinProgress = 0.0

        // 2. Fade in the spinning border
        withAnimation(.easeInOut(duration: crossfadeDuration)) {
            isSpinning = true
        }

        // 3. Wait for the crossfade. Also keeps the reset and the spin target in separate
        //    updates, so SwiftUI can't collapse 1.0 -> 0.0 -> 1.0 into no change at all
        try? await Task.sleep(for: .seconds(crossfadeDuration))
        guard !Task.isCancelled else { return }

        // 4. Drive the normalized 0.0 -> 1.0 spin loop
        spinAnimation = .linear(duration: spinDuration).repeatForever(autoreverses: false)
        spinProgress = 1.0
    }

    private func stopSpinning() async {
        // 1. Fade out the spinning border
        withAnimation(.easeInOut(duration: crossfadeDuration)) {
            isSpinning = false
        }

        // 2. Wait for the crossfade
        try? await Task.sleep(for: .seconds(crossfadeDuration))
        guard !Task.isCancelled else { return }

        // 3. Drop the repeating animation once nothing renders it any more
        spinAnimation = nil
        spinProgress = 0.0
    }
}

extension View {
    /// Adds a capsule border that spins while `isActive` and is solid otherwise.
    func capsuleSpinner(isActive: Bool, color: Color) -> some View {
        modifier(CapsuleSpinnerBorder(isActive: isActive, color: color))
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
