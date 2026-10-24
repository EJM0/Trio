import Foundation
import SwiftUI

extension Binding where Value == Int {
    func doubleBinding() -> Binding<Double> {
        Binding<Double>(
            get: { Double(self.wrappedValue) },
            set: { self.wrappedValue = Int($0) }
        )
    }
}

extension Color {
    static let bgDarkBlue = Color("Background_DarkBlue")
    static let bgDarkerDarkBlue = Color("Background_DarkerDarkBlue")
}

extension String {
    func toColor() -> Color {
        var hexString = trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgb)

        let red = Double((rgb & 0xFF0000) >> 16) / 255.0
        let green = Double((rgb & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgb & 0x0000FF) / 255.0

        return Color(red: red, green: green, blue: blue)
    }
}

/// A treatment screen's toolbar badge: the treatment's icon with its current on-board value (IOB, COB), shown as
/// "--" while the phone's data is older than one loop cycle, as on the main screen.
struct OnBoardToolbarBadge: View {
    let systemImage: String
    let value: String?
    let unit: String
    let color: Color
    let state: WatchState

    private var isDated: Bool {
        guard let lastUpdate = state.lastWatchStateUpdate else { return true }
        return Date().timeIntervalSince1970 - lastUpdate > 5 * 60
    }

    var body: some View {
        let shownValue = isDated ? nil : value.flatMap { $0 == "--" ? nil : $0 }

        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(verbatim: shownValue.map { "\($0) \(unit)" } ?? "--")
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(.white)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(color, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
