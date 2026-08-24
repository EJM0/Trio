import SwiftUI

/// Shared chrome for the Home panels: real Liquid Glass on iOS 26,
/// material approximation below.
enum GlassChrome {
    /// system-glass panel rounding (not the design patch's 17pt)
    static let panelCornerRadius: CGFloat = 26

    static var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
    }

    /// Stand-in for glass/material when Reduce Transparency is on: no blur, so
    /// nothing behind the panel bleeds through.
    static let opaqueFill = Color(.secondarySystemGroupedBackground)
}

/// Glass panel background with optional tint; pre-26 falls back to
/// ultraThinMaterial + tint fill + stroke, matching the compat-mode look.
struct GlassPanelBackground: ViewModifier {
    var tint: Color?
    var tintOpacity: Double = 0.12
    var strokeOpacity: Double = 0.35
    var strokeWidth: CGFloat = 1

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Opaque when Reduce Transparency is on, blurred material otherwise.
    private var baseFill: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(GlassChrome.opaqueFill) : AnyShapeStyle(.ultraThinMaterial)
    }

    func body(content: Content) -> some View {
        // Reduce Transparency skips the glass path entirely; it cannot be made opaque.
        if !reduceTransparency, #available(iOS 26.0, *) {
            content
                .glassEffect(
                    tint.map { Glass.regular.tint($0.opacity(tintOpacity)) } ?? .regular,
                    in: .rect(cornerRadius: GlassChrome.panelCornerRadius, style: .continuous)
                )
                // faint rim keeps tinted panels legible on busy backgrounds
                .overlay(GlassChrome.panelShape.strokeBorder(
                    (tint ?? Color.primary).opacity(strokeOpacity * 0.6),
                    lineWidth: strokeWidth
                ))
        } else {
            content
                .background(
                    GlassChrome.panelShape
                        .fill(baseFill)
                        .overlay(GlassChrome.panelShape.fill((tint ?? .clear).opacity(tintOpacity)))
                        .overlay(GlassChrome.panelShape.strokeBorder(
                            (tint ?? Color.primary).opacity(strokeOpacity),
                            lineWidth: strokeWidth
                        ))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.10), radius: 3, y: 1)
                )
        }
    }
}

/// Circular control overlaid on the glucose chart. The legend/info button and the
/// return-to-now button are the same component so they stack as one visual family;
/// only the glyph and the action differ.
struct ChartOverlayButton: View {
    let systemImage: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var isLight: Bool { colorScheme == .light }

    /// The light chart background washes the button out, so there the glyph is spelled out
    /// 10% darker than `.secondary` (~60% ink) and the rim gets the same uplift. Dark mode
    /// keeps the untouched `.secondary` glyph and 0.12 rim.
    private var glyphStyle: AnyShapeStyle {
        isLight ? AnyShapeStyle(Color.primary.opacity(0.66)) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(glyphStyle)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(isLight ? 0.132 : 0.12), lineWidth: 1))
        }
        .contentShape(Circle())
    }
}

extension View {
    func glassPanel(
        tint: Color? = nil,
        tintOpacity: Double = 0.12,
        strokeOpacity: Double = 0.35,
        strokeWidth: CGFloat = 1
    ) -> some View {
        modifier(GlassPanelBackground(
            tint: tint,
            tintOpacity: tintOpacity,
            strokeOpacity: strokeOpacity,
            strokeWidth: strokeWidth
        ))
    }
}
