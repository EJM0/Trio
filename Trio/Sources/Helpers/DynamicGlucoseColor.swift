import Foundation
import SwiftUI

// Helper function to decide how to pick the glucose color
public func getDynamicGlucoseColor(
    glucoseValue: Decimal,
    highGlucoseColorValue: Decimal,
    lowGlucoseColorValue: Decimal,
    targetGlucose: Decimal,
    glucoseColorScheme: GlucoseColorScheme
) -> Color {
    // Only use calculateHueBasedGlucoseColor if the setting is enabled in preferences
    if glucoseColorScheme == .dynamicColor {
        return calculateHueBasedGlucoseColor(
            glucoseValue: glucoseValue,
            highGlucose: highGlucoseColorValue,
            lowGlucose: lowGlucoseColorValue,
            targetGlucose: targetGlucose
        )
    }
    // Otherwise, use the static colors
    else {
        if glucoseValue >= highGlucoseColorValue {
            return Color.staticHigh
        } else if glucoseValue <= lowGlucoseColorValue {
            return Color.staticLow
        } else {
            return Color.staticInRange
        }
    }
}

/// The three hues the whole glucose palette is built on: the ends of the dynamic ramp and the
/// green it passes through at target.
///
/// Named rather than written inline because the static bands below are the *same* three hues at
/// a fixed saturation and brightness, and `shadedStaticGlucoseColor` needs to reach one of them
/// directly to build a shade of a band.
public enum GlucoseHue {
    public static let red: CGFloat = 0.0 / 360.0 // 0 degrees
    public static let green: CGFloat = 120.0 / 360.0 // 120 degrees
    public static let purple: CGFloat = 270.0 / 360.0 // 270 degrees
}

// Dynamic color - Define the hue values for the key points
// We'll shift color gradually one glucose point at a time
// We'll shift through the rainbow colors of ROY-G-BIV from low to high
// Start at red for lowGlucose, green for targetGlucose, and violet for highGlucose
public func calculateHueBasedGlucoseColor(
    glucoseValue: Decimal,
    highGlucose: Decimal,
    lowGlucose: Decimal,
    targetGlucose: Decimal
) -> Color {
    let redHue = GlucoseHue.red
    let greenHue = GlucoseHue.green
    let purpleHue = GlucoseHue.purple

    // Calculate the hue based on the bgLevel
    var hue: CGFloat
    if glucoseValue <= lowGlucose {
        hue = redHue
    } else if glucoseValue >= highGlucose {
        hue = purpleHue
    } else if glucoseValue <= targetGlucose {
        // Interpolate between red and green
        let ratio = CGFloat(truncating: (glucoseValue - lowGlucose) / (targetGlucose - lowGlucose) as NSNumber)

        hue = redHue + ratio * (greenHue - redHue)
    } else {
        // Interpolate between green and purple
        let ratio = CGFloat(truncating: (glucoseValue - targetGlucose) / (highGlucose - targetGlucose) as NSNumber)
        hue = greenHue + ratio * (purpleHue - greenHue)
    }
    // Return the color with full saturation and brightness
    let color = Color(hue: hue, saturation: 0.6, brightness: 0.9)
    return color
}

/// One shade of a static band: the band's own hue, deepened by how far past the band's threshold
/// a reading sits.
///
/// The static scheme has exactly one color per band, so anything drawing a *range* of readings in
/// it — `GlucoseEpisodesOverlay`'s span bar — comes out flat and says nothing about the shape of
/// the excursion. Ramping saturation and brightness while holding the hue gives that shape back
/// without introducing the hues the user opted out of by not choosing the dynamic scheme.
///
/// - Parameters:
///   - glucoseValue: The reading, in mg/dL.
///   - threshold: Where the band begins, in mg/dL — the palest end of the ramp.
///   - extreme: Where the ramp reaches full depth, in mg/dL. Beyond it the shade is clamped, so
///     a 400 and a 300 look alike rather than the scale being stretched by one outlier.
///   - hue: The band's hue — `GlucoseHue.red` for a low, `GlucoseHue.purple` for a high. Passed
///     rather than inferred from the two bounds, which cannot tell the bands apart once a user's
///     high threshold sits above the high band's own extreme.
public func shadedStaticGlucoseColor(
    glucoseValue: Decimal,
    threshold: Decimal,
    extreme: Decimal,
    hue: CGFloat
) -> Color {
    let span = abs(Double(truncating: (extreme - threshold) as NSNumber))
    let distance = abs(Double(truncating: (glucoseValue - threshold) as NSNumber))
    // A zero span means the two ends coincide — nothing to ramp through, so sit at the deep end
    // rather than dividing by it.
    let depth = span > 0 ? min(distance / span, 1) : 1

    return Color(
        hue: hue,
        saturation: 0.35 + 0.45 * depth,
        brightness: 0.98 - 0.26 * depth
    )
}

// Discrete band colors sampled from the dynamic gradient above
public extension Color {
    static let dynamicRed = Color(hue: GlucoseHue.red, saturation: 0.6, brightness: 0.9)
    static let dynamicOrange = Color(hue: 30.0 / 360.0, saturation: 0.6, brightness: 0.9)
    static let dynamicGreen = Color(hue: GlucoseHue.green, saturation: 0.6, brightness: 0.9)
    static let dynamicTeal = Color(hue: 165.0 / 360.0, saturation: 0.6, brightness: 0.9)
    static let dynamicBlue = Color(hue: 200.0 / 360.0, saturation: 0.6, brightness: 0.9)
    static let dynamicIndigo = Color(hue: 235.0 / 360.0, saturation: 0.6, brightness: 0.9)
    static let dynamicPurple = Color(hue: GlucoseHue.purple, saturation: 0.6, brightness: 0.9)

    // Colors used when the Static Glucose Color Scheme is selected
    static let staticLow = Color.dynamicRed
    static let staticInRange = Color.dynamicGreen
    static let staticHigh = Color.dynamicPurple
}
