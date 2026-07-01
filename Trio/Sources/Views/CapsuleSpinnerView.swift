import SwiftUI

struct CapsuleSpinnerView<Content: View>: View {
    let isLooping: Bool
    let color: Color
    let minAnimationDuration: TimeInterval
    let content: (Bool) -> Content

    private let crossfadeDuration: TimeInterval = 0.2

    @State private var showSpinner: Bool = false // drives opacity crossfade
    @State private var isSpinning: Bool = false // drives actual CA rotation
    @State private var contentSize: CGSize = .zero
    @State private var stopAnimationTask: Task<Void, Never>? = nil
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
            content(showSpinner)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .hidden()
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { contentSize = geo.size }
                            .onChange(of: geo.size) { _, newSize in
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    contentSize = newSize
                                }
                            }
                    }
                )

            content(showSpinner)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .frame(
                    width: contentSize.width == 0 ? nil : contentSize.width,
                    height: contentSize.height == 0 ? nil : contentSize.height
                )
                .overlay(
                    ZStack {
                        // Keeps physically rotating as long as `isSpinning` is true,
                        // regardless of whether it's visible yet.
                        CoreAnimationSpinnerBorder(color: UIColor(color), isSpinning: isSpinning)
                            .opacity(showSpinner ? 1 : 0)

                        Capsule()
                            .stroke(color.opacity(0.4), lineWidth: isSpinning ? 2.5 : 2)
                            .opacity(showSpinner ? 0 : 1)
                    }
                    .animation(.easeInOut(duration: crossfadeDuration), value: showSpinner)
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
            isSpinning = true
            showSpinner = true
        } else {
            stopAnimationTask = Task {
                let elapsed = Date().timeIntervalSince(animationStartTime ?? Date())
                let remainingTime = max(0, minAnimationDuration - elapsed)

                if remainingTime > 0 {
                    try? await Task.sleep(for: .seconds(remainingTime))
                }
                guard !Task.isCancelled else { return }

                // Start the crossfade — spinner is still rotating underneath.
                await MainActor.run {
                    showSpinner = false
                }

                // Wait for the fade to finish covering it before actually
                // halting the rotation, so the stop is never visible.
                try? await Task.sleep(for: .seconds(crossfadeDuration + 0.3))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    isSpinning = false
                }
            }
        }
    }
}
