import SwiftUI

/// A reusable off-main-thread animated spinner capsule component that overlays any content.
struct CapsuleSpinnerView<Content: View>: View {
    let isLooping: Bool
    let color: Color
    let minAnimationDuration: TimeInterval
    let content: (Bool) -> Content

    @State private var showSpinner: Bool = false
    @State private var contentSize: CGSize = .zero
    @State private var stopAnimationTask: Task<Void, Never>? = nil
    @State private var resizeTask: Task<Void, Never>? = nil // <--- Debounce task tracker
    @State private var animationStartTime: Date? = nil

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
                            .onAppear { contentSize = geo.size }
                            .onChange(of: geo.size) { _, newSize in
                                // Resizes immediately without any asynchronous delay
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    contentSize = newSize
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
                        // 1. HARDWARE-ACCELERATED SPINNING CAPSULE LAYER
                        CoreAnimationSpinnerBorder(color: UIColor(color), isSpinning: showSpinner)
                            .opacity(showSpinner ? 1 : 0)

                        // 2. STATIC CAPSULE LAYER
                        Capsule()
                            .stroke(color.opacity(0.4), lineWidth: 2)
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

    private func updateAnimating(_ newValue: Bool) {
        stopAnimationTask?.cancel()

        if newValue {
            animationStartTime = Date()
            showSpinner = true
        } else {
            stopAnimationTask = Task {
                let elapsed = Date().timeIntervalSince(animationStartTime ?? Date())
                let remainingTime = max(0, minAnimationDuration - elapsed)

                if remainingTime > 0 {
                    try? await Task.sleep(for: .seconds(remainingTime))
                }
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    showSpinner = false
                }
            }
        }
    }
}
