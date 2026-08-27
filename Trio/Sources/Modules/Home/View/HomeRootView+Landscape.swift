import Foundation
import SwiftUI

// MARK: - Landscape: the chart, and nothing else

/// The strip the display cutout carves out of one horizontal edge — and which edge that is.
///
/// Only one of the two edges has hardware in it. iOS still insets *both* in landscape, and
/// insets them equally, so that content stays centred on the display: the inset widths alone
/// therefore cannot say where the pill physically is, and trusting them puts a frost over the
/// far edge, where it covers the y-axis labels and guards nothing. The side comes from the
/// interface orientation instead, and the far edge is reported as zero — the chart runs flush
/// to it, and only the real cutout is frosted.
///
/// Read off the window, not off a `GeometryProxy`: the landscape container ignores the safe
/// area, and a proxy inside an ignored region reports zeroes — which is exactly the number
/// the frost must not be given, since zero means "draw nothing".
///
/// Left and right rather than leading and trailing: this describes a hole in the glass, and
/// the hole does not move when the reading order does.
struct HousingInsets: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0

    @MainActor static var current: HousingInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        else { return HousingInsets() }

        let insets = window.safeAreaInsets
        switch scene.interfaceOrientation {
        // Verified on device, and deliberately the opposite of what the naming suggests:
        // `UIInterfaceOrientation` is documented in terms of where the home button ends up,
        // which reads as "landscapeLeft means the device's top edge points left" — it does
        // not. `UIInterfaceOrientation` and `UIDeviceOrientation` are mirror images of each
        // other, and this is the interface one. Do not "fix" these two cases back.
        case .landscapeLeft:
            return HousingInsets(left: 0, right: insets.right)
        case .landscapeRight:
            return HousingInsets(left: insets.left, right: 0)
        default:
            return HousingInsets()
        }
    }
}

/// Keeps a `HousingInsets` value current across rotations.
///
/// A 180-degree landscape flip moves the pill to the opposite edge without changing a single
/// dimension SwiftUI can observe — same size, same size class, same inset widths — so nothing
/// in the view tree invalidates on its own and the frost stays on the edge the phone *used*
/// to have hardware on. The device-orientation notification is the only signal that fires for
/// it, and it has to be switched on explicitly.
struct HousingInsetsReader: ViewModifier {
    @Binding var insets: HousingInsets

    func body(content: Content) -> some View {
        content
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                insets = .current
            }
            .onDisappear { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
            .onReceive(
                Foundation.NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
            ) { _ in
                Task { @MainActor in
                    insets = .current
                    // The device turns before the interface follows, so the first read can
                    // still describe the orientation being left. Settle again once the
                    // rotation has landed; the value is Equatable, so an unchanged re-read
                    // costs nothing.
                    try? await Task.sleep(for: .milliseconds(350))
                    insets = .current
                }
            }
    }
}

extension Home.RootView {
    /// The Home screen held sideways.
    ///
    /// The dashboard's fixed zones cannot be paid for in a ~390 pt tall viewport — header
    /// (172) + meal slot (44) + bottom zone (150) alone overrun it before the chart gets a
    /// single point — and nothing in them is worth two thirds of a screen the user
    /// deliberately turned in order to see *more chart*. So landscape drops all of it: the
    /// chart takes the whole viewport, the tab bar and the treatment button step aside
    /// (`isLandscapeChart` in `HomeRootView`), and the scrub readout, which portrait parks in
    /// the meal slot, floats back over the chart as a card in the top-right corner.
    ///
    /// Width is the full display, not the safe area: stopping the plot at the sensor housing
    /// would trade a strip of chart for a bar of empty background on one side only, which
    /// reads as a rendering fault rather than as a margin. The chart runs under the housing
    /// bare, the way Maps runs the map under the island — nothing is drawn over that strip.
    /// What the cutout does get is room: everything pinned to its edge, and the pan limit
    /// itself, is inset by its width, so no reading or label is ever stuck behind it
    /// (`HousingInsets`, and `leadingInset` / `trailingInset` on the chart).
    @ViewBuilder func landscapeChart(geo: GeometryProxy, housing: HousingInsets) -> some View {
        ZStack(alignment: .topTrailing) {
            MainChartView(
                geo: geo,
                chartHeight: geo.size.height,
                units: state.units,
                highGlucose: state.highGlucose,
                lowGlucose: state.lowGlucose,
                currentGlucoseTarget: state.currentGlucoseTarget,
                glucoseColorScheme: state.glucoseColorScheme,
                displayXgridLines: state.displayXgridLines,
                displayYgridLines: state.displayYgridLines,
                showGlucoseEpisodes: state.showGlucoseEpisodes,
                thresholdLines: state.thresholdLines,
                // let the outermost readings be panned back out from behind the housing —
                // and, on the trailing side, push the pinned y-axis labels clear of it
                leadingInset: housing.left,
                trailingInset: housing.right,
                state: state,
                selection: $chartSelection
            )

            landscapeSelectionPopover
                // Innermost, so it reaches the card's own text and nothing else: the card is
                // the only reading matter here, and the stack around it is pinned to LTR for
                // the chart's sake. The paddings below stay in that LTR frame.
                .environment(\.layoutDirection, layoutDirection)
                .padding(.top, 10)
                // The chart may run under the housing; the card may not. Turned the other way
                // round the pill sits on this side, and a readout hiding behind it is the one
                // thing on screen that has to be readable at a glance.
                .padding(.trailing, 14 + housing.right)
                // the card sits in the middle of the scrubbing hand's travel; it must never
                // swallow a touch meant for the chart underneath
                .allowsHitTesting(false)
        }
        // The chart plots time left-to-right and the housing is a physical cutout, so both
        // the plot and the frost are positioned in screen terms, not in reading order.
        .environment(\.layoutDirection, .leftToRight)
        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        // The meal slot owns this in portrait; sideways there is no meal slot, so the decay
        // that keeps the readout from flickering across data holes — and the fade the card
        // arrives and leaves with (`ChartSelectionLookup.readoutFade`) — runs here instead.
        .task(id: chartSelection) { await updateChartReadout() }
    }

    /// The scrub readout, in the corner the chart's own content reaches last. Renders from
    /// `chartReadoutDate` rather than `chartSelection` directly, exactly as the meal slot
    /// does, so a hole in either series can't flicker it (see `updateChartReadout`).
    @ViewBuilder private var landscapeSelectionPopover: some View {
        if let readoutDate = chartReadoutDate,
           let selectedGlucose = ChartSelectionLookup.glucose(at: readoutDate, in: state.glucoseFromPersistence)
        {
            SelectionPopoverView(
                selectedGlucose: selectedGlucose,
                determination: chartReadoutDeterminationDate.flatMap {
                    ChartSelectionLookup.determination(at: $0, in: state.enactedAndNonEnactedDeterminations)
                },
                units: state.units,
                highGlucose: state.highGlucose,
                lowGlucose: state.lowGlucose,
                currentGlucoseTarget: state.currentGlucoseTarget,
                glucoseColorScheme: state.glucoseColorScheme,
                isSmoothingEnabled: state.settingsManager.settings.smoothGlucose
            )
            .transition(.opacity)
        }
    }
}
