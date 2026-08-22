import SwiftUI

struct BolusProgressBar: View {
    let progress: Decimal

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 15)
                .frame(height: 6)
                .foregroundColor(.clear)
                .background(
                    Color.tabBar
                        .mask(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 15)
                                .frame(width: geo.size.width * CGFloat(progress))
                                .animation(.easeInOut(duration: 0.25), value: progress)
                        }
                )
        }
        .frame(height: 6)
    }
}

/// Progress drawn as a shade instead of a bar: the glass unit fills from its leading edge
/// as the value advances - the delivered part of a bolus, the remaining part of an
/// adjustment. The fill fades toward its moving edge so it reads as a wash over the glass
/// rather than a second, thicker bar.
///
/// Sized by its container, so it goes under the panel's content and gets clipped by the
/// caller: the whole panel shape for a single shade, the shared container when two of them
/// split a panel.
struct PanelProgressShade: View {
    let progress: Double
    let tint: Color

    init(progress: Double, tint: Color) {
        self.progress = progress
        self.tint = tint
    }

    init(progress: Decimal, tint: Color) {
        self.init(progress: Double(progress), tint: tint)
    }

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(progress, 0), 1)
            LinearGradient(
                colors: [tint.opacity(0.34), tint.opacity(0.12)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * fraction)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .animation(.easeInOut(duration: 0.25), value: progress)
    }
}
