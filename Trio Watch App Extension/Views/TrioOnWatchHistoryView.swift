import SwiftUI

/// The watch's recorded history over the last 6 hours while it holds the pump: glucose, carbs and insulin,
/// switched by the bottom toolbar. Read-only; ported from feat/watch-loop-5/5's WatchLoopHistoryView.
struct TrioOnWatchHistoryView: View {
    /// Reloaded on appear and whenever the tab changes, so a new reading or dose shows without leaving the page.
    @State private var history = TrioOnWatchHistory(glucose: [], carbs: [], insulin: [], units: .mgdL)
    @State private var kind = Kind.glucose

    /// Live from the loan host; overridden in previews and the screenshot harness.
    var load: () -> TrioOnWatchHistory = {
        TrioOnWatchSource.history(since: Date().addingTimeInterval(-6 * 60 * 60))
    }

    enum Kind: CaseIterable {
        case glucose
        case carbs
        case insulin

        var symbol: String {
            switch self {
            case .glucose: return "drop.fill"
            case .carbs: return "fork.knife"
            case .insulin: return "syringe.fill"
            }
        }

        var color: Color {
            switch self {
            case .glucose: return .green
            case .carbs: return .orange
            case .insulin: return .blue
            }
        }
    }

    var body: some View {
        List {
            switch kind {
            case .glucose: glucoseRows
            case .carbs: carbRows
            case .insulin: insulinRows
            }
        }
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationTitle(String(localized: "History", comment: "Watch history screen title"))
        .onAppear { history = load() }
        .onChange(of: kind) { _, _ in history = load() }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                ForEach(Kind.allCases, id: \.self) { tab in
                    Button { kind = tab } label: {
                        Image(systemName: tab.symbol)
                            .foregroundStyle(kind == tab ? Color.primary : tab.color)
                    }
                    .tint(kind == tab ? tab.color : nil)
                    .accessibilityLabel(accessibilityLabel(for: tab))
                }
            }
        }
    }

    @ViewBuilder private var glucoseRows: some View {
        let mmol = history.units == .mmolL
        if history.glucose.isEmpty {
            Text(String(localized: "No glucose", comment: "Watch history: no glucose readings")).foregroundStyle(.secondary)
        }
        ForEach(history.glucose, id: \.id) { reading in
            let value = reading.glucose ?? reading.sgv ?? 0
            let shown = Text(verbatim: mmol ? Decimal(value).asMmolL.description : "\(value)")
            // a meter's BG is marked: it isn't a sensor reading
            row(
                reading.dateString,
                reading.mbg != nil ? Text(Image(systemName: "drop.circle")) + Text(verbatim: " ") + shown : shown
            )
        }
    }

    @ViewBuilder private var carbRows: some View {
        if history.carbs.isEmpty {
            Text(String(localized: "No carbs", comment: "Watch history: no carb entries")).foregroundStyle(.secondary)
        }
        ForEach(history.carbs, id: \.self) { entry in
            row(
                entry.actualDate ?? entry.createdAt,
                Text("\(entry.carbs.formatted(.number.precision(.fractionLength(0)))) g").foregroundStyle(.orange)
            )
        }
    }

    @ViewBuilder private var insulinRows: some View {
        if history.insulin.isEmpty {
            Text(String(localized: "No insulin", comment: "Watch history: no insulin events")).foregroundStyle(.secondary)
        }
        ForEach(history.insulin, id: \.id) { event in
            row(event.timestamp, Text(describe(event)).foregroundStyle(.blue))
        }
    }

    private func row(_ date: Date, _ value: Text) -> some View {
        HStack {
            Text(date, style: .time).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            value
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10).fill(Color.chart)
        )
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
    }

    private func describe(_ event: PumpHistoryEvent) -> String {
        switch event.type {
        case .bolus,
             .smb:
            let units = String(format: "%.2f U", NSDecimalNumber(decimal: event.amount ?? 0).doubleValue)
            return (event.isSMB ?? false) ? "SMB " + units : String(localized: "Bolus") + " " + units
        case .tempBasal:
            return String(format: "Temp %.2f U/h", NSDecimalNumber(decimal: event.rate ?? 0).doubleValue)
        case .pumpSuspend: return String(localized: "Suspended")
        case .pumpResume: return String(localized: "Resumed")
        default: return event.type.rawValue
        }
    }

    private func accessibilityLabel(for tab: Kind) -> Text {
        switch tab {
        case .glucose: return Text(String(localized: "Glucose", comment: "Watch history tab"))
        case .carbs: return Text(String(localized: "Carbs", comment: "Watch history tab"))
        case .insulin: return Text(String(localized: "Insulin", comment: "Watch history tab"))
        }
    }
}
