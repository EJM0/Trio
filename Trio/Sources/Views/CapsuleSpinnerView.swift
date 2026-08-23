import SwiftUI

/// A capsule border whose dashed gap travels around the perimeter while `isActive`,
/// crossfading to a solid border when it stops. Drop it on any pill-shaped view with
/// `.capsuleSpinner(isActive:color:)` - it needs nothing from its content.
///
/// Reduce Motion is honoured here: the border simply stays solid and no spin is ever
/// started. Content that used the spin to convey a state has to say so in its own way,
/// reading `\.accessibilityReduceMotion` itself.
///
/// The sweep is started by the dashed border's own `onAppear`, at the very start of the
/// fade-in, so the gap is already travelling while the border becomes visible instead of
/// appearing as a stalled gap that only then begins to move. It cannot be started any
/// earlier than the insertion: an animation installed on a view that is not in the tree yet
/// never takes, and since a sweep parked at 1.0 is a full lap of dash phase -
/// pixel-identical to one parked at 0.0 - that failure looks exactly like a border that
/// simply never spins.
///
/// Neither the spin nor the crossfade is ever started with `withAnimation`: every animation
/// here is attached to a view with `.animation(_:value:)`. That keeps them scoped twice
/// over - they can only be triggered by the one value they name, and they die with the view
/// they hang on. A `withAnimation` would instead put them in the update's transaction,
/// which every view re-rendered in the same pass can inherit, and which in the case of a
/// `repeatForever` never ends at all.
struct CapsuleSpinnerBorder: ViewModifier {
    let isActive: Bool
    let color: Color
    var activeLineWidth: CGFloat = 2.25
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
                            // the border itself says when it exists, so the sweep is never
                            // installed on a view that isn't in the tree yet
                            .onAppear(perform: startSweep)
                    } else {
                        Capsule()
                            .stroke(
                                color.opacity(0.4),
                                style: StrokeStyle(lineWidth: idleLineWidth, lineCap: .round)
                            )
                            .transition(.opacity)
                    }
                }
                // Scoped to this overlay and to `isSpinning` alone. A `withAnimation` here
                // would put the crossfade in the update's transaction instead, where any
                // view re-rendered in the same pass - the pill's own label, which swaps at
                // exactly this moment - could inherit it.
                .animation(.easeInOut(duration: crossfadeDuration), value: isSpinning)
            )
            // Re-runs on every flip, cancelling the previous run, so a stale fade-out can
            // never clobber a re-activation and no half-finished spin is left behind.
            .task(id: shouldSpin) {
                if shouldSpin {
                    startSpinning()
                } else {
                    await stopSpinning()
                }
            }
    }

    private func startSpinning() {
        // Reset the sweep instantly - `spinAnimation` is nil, so the border ignores it -
        // then insert the dashed border. The overlay's own `.animation(_:value:)` fades it
        // in, and its `onAppear` starts the sweep from there.
        spinAnimation = nil
        spinProgress = 0.0

        isSpinning = true
    }

    /// Called by the dashed border as it is inserted, at the very start of the fade-in, so
    /// the gap is already travelling while the border becomes visible. Running in a later
    /// update than the reset above is also what keeps SwiftUI from collapsing
    /// 1.0 -> 0.0 -> 1.0 into no change at all.
    private func startSweep() {
        spinAnimation = .linear(duration: spinDuration).repeatForever(autoreverses: false)
        spinProgress = 1.0
    }

    private func stopSpinning() async {
        // 1. Fade out the spinning border
        isSpinning = false

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
