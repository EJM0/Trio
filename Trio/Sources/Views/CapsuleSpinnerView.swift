import SwiftUI

/// A reusable animated spinner capsule component that overlays any content.
struct CapsuleSpinnerView<Content: View>: View {
    @Environment(\.colorScheme) var colorScheme

    let isLooping: Bool
    let color: Color
    let minAnimationDuration: TimeInterval
    let content: (Bool) -> Content

    @State private var showSpinner: Bool = false
    @State private var dashPhase: CGFloat = 0.0
    @State private var perimeter: CGFloat = 200
    @State private var contentSize: CGSize = .zero
    @State private var stopAnimationTask: Task<Void, Never>? = nil

    // Tracks when the spin cycle started to enforce the minimum duration
    @State private var animationStartTime: Date? = nil

    // Initializer 1: With content state closure (passes a Bool indicating if it's spinning)
    init(
        isLooping: Bool,
        color: Color,
        minAnimationDuration: TimeInterval = 2,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.isLooping = isLooping
        self.color = color
        self.minAnimationDuration = minAnimationDuration
        self.content = content
    }

    // Initializer 2: Without content state closure
    init(
        isLooping: Bool,
        color: Color,
        minAnimationDuration: TimeInterval = 2,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isLooping = isLooping
        self.color = color
        self.minAnimationDuration = minAnimationDuration
        self.content = { _ in content() }
    }

    var body: some View {
        ZStack {
            // INVISIBLE MEASUREMENT LAYER
            content(showSpinner)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .hidden()
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                contentSize = geo.size
                                updatePerimeter(size: geo.size)
                            }
                            .onChange(of: geo.size) { _, newSize in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    contentSize = newSize
                                    updatePerimeter(size: newSize)
                                }
                            }
                    }
                )

            // VISIBLE ANIMATED LAYER
            content(showSpinner)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .frame(
                    width: contentSize.width == 0 ? nil : contentSize.width,
                    height: contentSize.height == 0 ? nil : contentSize.height
                )
                .overlay(
                    ZStack {
                        // 1. SPINNING CAPSULE LAYER (Maintains full linear speed during fade)
                        Capsule()
                            .stroke(color.opacity(0.4), style: StrokeStyle(
                                lineWidth: 2.5,
                                lineCap: .round,
                                dash: [perimeter * 0.7, perimeter * 0.3],
                                dashPhase: dashPhase
                            ))
                            .opacity(showSpinner ? 1 : 0)

                        // 2. STATIC CAPSULE LAYER
                        Capsule()
                            .stroke(color.opacity(0.4), style: StrokeStyle(
                                lineWidth: 2,
                                lineCap: .round,
                                dash: [perimeter + 10, 0]
                            ))
                            .opacity(showSpinner ? 0 : 1)
                    }
                    .animation(.easeInOut(duration: 0.3), value: showSpinner)
                )
        }
        .onAppear {
            updateAnimating(isLooping)
        }
        .onChange(of: isLooping) { _, newValue in
            updateAnimating(newValue)
        }
    }

    private func updatePerimeter(size: CGSize) {
        let w = size.width
        let h = size.height

        if w >= h {
            perimeter = (2 * (w - h) + .pi * h).rounded()
        } else {
            perimeter = (2 * (h - w) + .pi * w).rounded()
        }
    }

    private func updateAnimating(_ newValue: Bool) {
        stopAnimationTask?.cancel()

        if newValue {
            animationStartTime = Date()

            // Instantly sync layout geometry without an inherited transition
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.dashPhase = 0.0
            }

            // Fire up infinite constant rotation loop
            withAnimation(.linear(duration: 1.333).repeatForever(autoreverses: false)) {
                self.dashPhase = -self.perimeter
            }

            // Fade the spinner layer into view
            showSpinner = true
        } else {
            stopAnimationTask = Task {
                let elapsed = Date().timeIntervalSince(animationStartTime ?? Date())
                let remainingTime = max(0, minAnimationDuration - elapsed)

                // 1. Wait out the remaining timeline requirement
                if remainingTime > 0 {
                    try? await Task.sleep(for: .seconds(remainingTime))
                }
                guard !Task.isCancelled else { return }

                // 2. Start the cross-fade opacity change (takes 0.3s)
                await MainActor.run {
                    showSpinner = false
                }

                // 3. Wait exactly 0.3 seconds for the fade-out transaction to clear the screen
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled else { return }

                // 4. Reset the dash phase layout engine state once it's completely out of sight
                await MainActor.run {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        self.dashPhase = 0.0
                    }
                }
            }
        }
    }
}
