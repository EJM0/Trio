import SwiftUI

/// The watch's recorded history over the last 6 hours while it holds the pump: glucose, carbs and insulin,
/// switched by the bottom toolbar. Swipe a meal to edit or delete it, a reading to delete it; the phone follows.
/// Ported from feat/watch-loop-5/5's WatchLoopHistoryView.
struct TrioOnWatchHistoryView: View {
    /// Reloaded on appear and whenever the tab changes, so a new reading or dose shows without leaving the page.
    @State private var history = TrioOnWatchHistory(glucose: [], carbs: [], insulin: [], units: .mgdL)
    @State private var kind = Kind.glucose
    @State private var deleting: Deletion?
    @State private var editing: CarbsEntry?

    enum Deletion {
        case carbs(CarbsEntry)
        case glucose(BloodGlucose)
    }

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
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete", comment: "Watch history: confirm deleting an entry"), role: .destructive) {
                guard let deletion = deleting else { return }
                Task {
                    switch deletion {
                    case let .carbs(entry): await WatchLoanRuntime.host?.deleteCarbs(entry)
                    case let .glucose(reading): await WatchLoanRuntime.host?.deleteGlucose(reading)
                    }
                    history = load()
                }
            }
            Button(String(localized: "Cancel", comment: "Watch history: keep the entry"), role: .cancel) {}
        }
        .sheet(item: $editing) { entry in
            CarbEditView(entry: entry) { grams, date in
                editing = nil
                Task {
                    await WatchLoanRuntime.host?.editCarbs(entry, grams: grams, at: date)
                    history = load()
                }
            }
        }
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
            .swipeActions {
                deleteButton { deleting = .glucose(reading) }
            }
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
            .swipeActions {
                deleteButton { deleting = .carbs(entry) }
                Button { editing = entry } label: {
                    Label(String(localized: "Edit", comment: "Watch history: edit a meal"), systemImage: "pencil")
                }
                .tint(.orange)
            }
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

    private func deleteButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(String(localized: "Delete", comment: "Watch history: delete an entry"), systemImage: "trash")
        }
        .tint(.red)
    }

    private var deletionTitle: String {
        switch deleting {
        case .glucose: return String(
                localized: "Delete this reading?",
                comment: "Watch history: confirm deleting a glucose reading"
            )
        default: return String(localized: "Delete this meal?", comment: "Watch history: confirm deleting a meal")
        }
    }

    private func row(_ date: Date, _ value: Text) -> some View {
        HStack {
            Text(date, style: .time).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            value
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10).fill(Color.trioCard)
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

/// A meal's carbs and time. The crown turns the grams, as on the carbs entry; no ScrollView, which took the crown, and
/// no DatePicker, which can't present from this sheet: the time moves in 5-minute steps.
private struct CarbEditView: View {
    let entry: CarbsEntry
    let save: (Decimal, Date) -> Void
    @State private var grams: Double
    @State private var date: Date
    @FocusState private var crownFocused: Bool

    private var maxGrams: Double { max(1, NSDecimalNumber(decimal: WatchState.shared.maxCarbs).doubleValue) }

    init(entry: CarbsEntry, save: @escaping (Decimal, Date) -> Void) {
        self.entry = entry
        self.save = save
        _grams = State(initialValue: NSDecimalNumber(decimal: entry.carbs).doubleValue)
        _date = State(initialValue: entry.actualDate ?? entry.createdAt)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                stepButton("minus.circle.fill") { grams = max(1, grams - 5) }
                Spacer()
                Text("\(Int(grams)) g")
                    .font(.system(.title2, design: .rounded).bold())
                    .foregroundStyle(.orange)
                    .focusable(true)
                    .focused($crownFocused)
                    .digitalCrownRotation(
                        $grams,
                        from: 1,
                        through: maxGrams,
                        by: 1,
                        sensitivity: .medium,
                        isContinuous: false,
                        isHapticFeedbackEnabled: true
                    )
                Spacer()
                stepButton("plus.circle.fill") { grams = min(maxGrams, grams + 5) }
            }
            HStack {
                stepButton("minus.circle.fill") { date = date.addingTimeInterval(-5 * 60) }
                Spacer()
                Text(date, style: .time).font(.system(.title3, design: .rounded)).monospacedDigit()
                Spacer()
                stepButton("plus.circle.fill") { date = date.addingTimeInterval(5 * 60) }
            }
            Button(String(localized: "Save", comment: "Watch history: save the edited meal")) {
                save(Decimal(Int(grams)), date)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
        .padding(.horizontal)
        .onAppear { crownFocused = true }
        .navigationTitle(String(localized: "Edit Meal", comment: "Watch history: edit meal title"))
    }

    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.orange)
        }
        .buttonStyle(.borderless)
    }
}
