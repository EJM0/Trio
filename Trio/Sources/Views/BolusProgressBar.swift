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

/// Same progress, drawn as a shade instead of a bar: the glass unit behind the bolus
/// panel fills from its leading edge as the dose is delivered. The fill fades toward its
/// moving edge so it reads as a wash over the glass rather than a second, thicker bar.
/// Sized by its container, so it goes in a `.background` under the panel's content.
struct BolusProgressShade: View {
    let progress: Decimal

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(CGFloat(progress), 0), 1)
            LinearGradient(
                colors: [Color.insulin.opacity(0.34), Color.insulin.opacity(0.12)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * fraction)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .clipShape(GlassChrome.panelShape)
        .animation(.easeInOut(duration: 0.25), value: progress)
    }
}
