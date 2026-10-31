import SwiftUI
import WatchConnectivity

extension Color {
    /// The Watch Loop, as on the phone.
    static let watchLoop = Color(red: 0x33 / 255, green: 0xE3 / 255, blue: 0xFF / 255)
}

/// The Watch Loop page: what the watch is doing and the ways to end it; otherwise the place to start it.
struct WatchLoopView: View {
    let session: WatchLoopSession
    @State private var confirmStart = false
    @State private var confirmEnd = false
    @State private var confirmDeactivate = false
    @State private var confirmDiscard = false
    @State private var podFailure: String?
    @State private var isEndingPod = false
    @State private var confirmStartWithoutPhone = false

    private var phase: WatchLoopWatchState.Phase { session.state.phase }
    private var unsynced: Int { session.state.pending.count }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                VStack(spacing: 10) {
                    header(now: context.date)
                    if let note = session.note {
                        card(tint: .watchLoop) { Text(note).font(.footnote) }
                    }
                    if phase == .active, let error = session.state.lastError {
                        card(tint: .orange) {
                            Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote)
                        }
                    }
                    if phase == .active { tiles }
                    if phase == .active {
                        // remote commands come through the phone's push: without it online they wait or run out
                        note(
                            "Remote boluses and meals (LoopFollow, Nightscout) reach the watch only through your iPhone, while it is online. The watch refuses commands sent more than 10 minutes ago."
                        )
                    }
                    if phase == .active || unsynced > 0 { historyButton }
                    actions
                }
                .padding(.horizontal, 4)
            }
        }
        .confirmationDialog(
            "Start from your iPhone's copy of \(copyAgeMinutes) min ago? Only if the iPhone is off or out of reach: it stops dosing once it hears from the watch.",
            isPresented: $confirmStartWithoutPhone
        ) {
            Button("Start Without iPhone") { Task { await session.startWithoutPhone() } }
        }
        .confirmationDialog("Loop on the watch? Your iPhone stops dosing until you end it.", isPresented: $confirmStart) {
            Button("Start Watch Loop") { session.start() }
        }
        .confirmationDialog("Hand the pod back to your iPhone?", isPresented: $confirmEnd) {
            Button("Hand Back") { Task { await session.end() } }
        }
        .confirmationDialog(
            "Deactivate the pod? It stops delivering insulin. Remove it, then pair a new pod on your iPhone.",
            isPresented: $confirmDeactivate
        ) {
            Button("Deactivate Pod", role: .destructive) { endPod(discard: false) }
        }
        .confirmationDialog(
            "Discard the pod without reaching it? It may keep beeping until you remove it.",
            isPresented: $confirmDiscard
        ) {
            Button("Discard Pod", role: .destructive) { endPod(discard: true) }
        }
    }

    private var copyAgeMinutes: Int {
        Int(Date().timeIntervalSince(session.state.standing?.issuedAt ?? Date()) / 60)
    }

    private func endPod(discard: Bool) {
        isEndingPod = true
        podFailure = nil
        Task {
            podFailure = await session.endPod(discard: discard)
            isEndingPod = false
        }
    }

    // MARK: - Header

    private func header(now: Date) -> some View {
        let look = look(now: now)
        return HStack(spacing: 10) {
            Image(systemName: look.symbol)
                .font(.title3)
                .foregroundStyle(look.tint)
                .frame(width: 38, height: 38)
                .background(look.tint.opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(look.title).font(.headline)
                Text(look.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func look(now: Date) -> (symbol: String, tint: Color, title: LocalizedStringKey, subtitle: LocalizedStringKey) {
        switch phase {
        case .active:
            guard let last = session.state.lastLoopAt else {
                return ("applewatch", .watchLoop, "Watch Loop", "Looping on the watch")
            }
            let minutes = max(0, Int(now.timeIntervalSince(last) / 60))
            return ("applewatch", .watchLoop, "Watch Loop", "Last loop \(minutes) min ago")
        case .requested:
            return ("applewatch.radiowaves.left.and.right", .yellow, "Starting…", "Taking over the pod")
        case .handingBack:
            return ("arrow.uturn.backward.circle", .blue, "Handing Back…", "Waiting for your iPhone to take the pod")
        case .idle:
            if unsynced > 0 {
                return ("arrow.triangle.2.circlepath", .blue, "Syncing History", "\(unsynced) entries on the way to your iPhone")
            }
            return ("applewatch.slash", .secondary, "iPhone in Charge", "The watch can take over the pod")
        }
    }

    // MARK: - Figures

    /// The loop mode on the left, tapped to change it, and the basal running on the right.
    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            NavigationLink { WatchLoopModeView(session: session) } label: {
                tile(
                    "Loop Mode",
                    systemImage: session.state.closedLoop ? "arrow.triangle.2.circlepath" : "hand.raised",
                    tint: .watchLoop,
                    value: session.state.closedLoop ? String(localized: "Closed") : String(localized: "Open")
                )
            }
            .buttonStyle(.plain)
            tile(
                "Basal",
                systemImage: "chart.bar.fill",
                tint: .blue,
                value: session.state.lastDetermination?.rate.map {
                    String(format: "%.2f U/h", NSDecimalNumber(decimal: $0).doubleValue)
                }
            )
        }
    }

    /// The watch's history on its own screen; the second row counts the records still to sync.
    private var historyButton: some View {
        NavigationLink { WatchLoopHistoryView(session: session) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Label("History", systemImage: "list.bullet")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text("to sync:").foregroundStyle(.secondary)
                    Text("\(unsynced)")
                }
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func tile(_ label: LocalizedStringKey, systemImage: String, tint: Color, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(value ?? "--")
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    @ViewBuilder private var actions: some View {
        if session.isBusy || isEndingPod {
            HStack(spacing: 8) {
                ProgressView().frame(width: 20)
                Text(isEndingPod ? "Ending the pod…" : phase == .handingBack ? "Handing back…" : "Starting…")
                    .font(.footnote)
            }
            .padding(.top, 4)
        } else {
            switch phase {
            case .idle:
                Button { confirmStart = true } label: {
                    Label("Start Watch Loop", systemImage: "applewatch")
                }
                .buttonStyle(.borderedProminent)
                .tint(.watchLoop)
                if session.offersStartWithoutPhone, session.usableStandingCopy != nil {
                    Button { confirmStartWithoutPhone = true } label: {
                        Label("Start Without iPhone", systemImage: "iphone.slash")
                    }
                    .tint(.watchLoop)
                } else if !WatchState.shared.isReachable {
                    note("Starts with your iPhone nearby.")
                }
                if WatchState.shared.watchLoopFallback, WatchState.shared.watchLoopWithoutPhone {
                    Label(
                        session.usableStandingCopy != nil
                            ? "Fallback Loop ready: starts by itself if your iPhone stops looping"
                            : "Fallback Loop can't start: no recent copy from your iPhone",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            case .active:
                Button { confirmEnd = true } label: {
                    Label("Hand Back", systemImage: "iphone")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                if let podFailure {
                    card(tint: .orange) {
                        Label(podFailure, systemImage: "exclamationmark.triangle.fill").font(.footnote)
                    }
                    Button(role: .destructive) { confirmDiscard = true } label: {
                        Label("Discard Pod", systemImage: "trash")
                    }
                    .tint(.red)
                } else {
                    Button(role: .destructive) { confirmDeactivate = true } label: {
                        Label("Deactivate Pod", systemImage: "xmark.circle")
                    }
                    .tint(.orange)
                }
            case .handingBack,
                 .requested:
                EmptyView()
            }
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private func card<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Closed loop: the watch enacts; open: it only determines, as the phone's open loop.
private struct WatchLoopModeView: View {
    let session: WatchLoopSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                option(closed: true, "Closed Loop", "arrow.triangle.2.circlepath", "The watch adjusts basal and gives SMBs.")
                option(closed: false, "Open Loop", "hand.raised", "The watch determines but doses nothing by itself.")
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Loop Mode")
    }

    private func option(closed: Bool, _ title: LocalizedStringKey, _ symbol: String, _ hint: LocalizedStringKey) -> some View {
        Button {
            session.setClosedLoop(closed)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Label(title, systemImage: symbol)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.watchLoop)
                    Spacer(minLength: 0)
                    if session.state.closedLoop == closed {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.watchLoop)
                    }
                }
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// Glucose, carbs and insulin of the session; a carb entry is deleted by swiping it (as Loop's carb list).
struct WatchLoopHistoryView: View {
    let session: WatchLoopSession
    @State private var kind = Kind.carbs

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

    private var since: Date { Date().addingTimeInterval(-6 * 60 * 60) }

    var body: some View {
        List {
            switch kind {
            case .glucose: glucoseRows
            case .carbs: carbRows
            case .insulin: insulinRows
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                ForEach(Kind.allCases, id: \.self) { kind in
                    Button { self.kind = kind } label: {
                        Image(systemName: kind.symbol)
                            .foregroundStyle(self.kind == kind ? Color.primary : kind.color)
                    }
                    .tint(self.kind == kind ? kind.color : nil)
                }
            }
        }
    }

    @ViewBuilder private var glucoseRows: some View {
        let mmol = session.state.grant?.units == .mmolL
        let readings = session.state.allGlucose.filter { $0.dateString >= since }
        if readings.isEmpty { Text("No glucose").foregroundStyle(.secondary) }
        ForEach(readings, id: \.id) { reading in
            let value = reading.sgv ?? reading.glucose ?? 0
            row(reading.dateString, Text(verbatim: mmol ? Decimal(value).asMmolL.description : "\(value)"))
        }
    }

    @ViewBuilder private var carbRows: some View {
        let entries = session.state.allCarbs.filter { ($0.actualDate ?? $0.createdAt) >= since && !($0.isFPU ?? false) }
            .sorted { ($0.actualDate ?? $0.createdAt) > ($1.actualDate ?? $1.createdAt) }
        if entries.isEmpty { Text("No carbs").foregroundStyle(.secondary) }
        ForEach(entries, id: \.self) { entry in
            row(
                entry.actualDate ?? entry.createdAt,
                Text("\(entry.carbs.formatted(.number.precision(.fractionLength(0)))) g").foregroundStyle(.orange)
            )
            .swipeActions {
                if session.state.phase == .active {
                    Button("Delete", role: .destructive) { session.deleteCarbs(entry) }
                }
            }
        }
    }

    @ViewBuilder private var insulinRows: some View {
        let events = session.state.pumpHistory
            .filter { [.bolus, .smb, .tempBasal, .pumpSuspend, .pumpResume].contains($0.type) && $0.timestamp >= since }
        if events.isEmpty { Text("No insulin").foregroundStyle(.secondary) }
        ForEach(events, id: \.id) { event in
            row(event.timestamp, Text(describe(event)).foregroundStyle(.blue))
        }
    }

    private func row(_ date: Date, _ value: Text) -> some View {
        HStack {
            Text(date, style: .time).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            value
        }
    }

    private func describe(_ event: PumpHistoryEvent) -> String {
        switch event.type {
        case .bolus,
             .smb:
            let units = String(format: "%.2f U", NSDecimalNumber(decimal: event.amount ?? 0).doubleValue)
            return (event.isSMB ?? false) ? "SMB " + units : String(localized: "Bolus") + " " + units
        case .tempBasal:
            return String(format: "Temp %.2f U/h", NSDecimalNumber(decimal: event.amount ?? 0).doubleValue)
        case .pumpSuspend: return String(localized: "Suspended")
        case .pumpResume: return String(localized: "Resumed")
        default: return event.type.rawValue
        }
    }
}

/// The phone's Loop Status sheet, from the watch's own loop: how recent it is and oref's reasoning.
struct WatchLoopStatusView: View {
    let session: WatchLoopSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current Loop Status").font(.headline)
                    let status = status(now: context.date)
                    Text(status.title)
                        .font(.footnote.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(Color.white)
                        .background(status.color, in: Capsule())
                    if let error = session.state.lastError {
                        Text(error).font(.caption2).foregroundStyle(.red)
                    }
                    if let determination = session.state.lastDetermination {
                        values(determination)
                        Text("Current Algorithm Reasoning").font(.footnote.bold()).padding(.top, 6)
                        Text(determination.reasonConclusion.prefix(1).uppercased() + determination.reasonConclusion.dropFirst())
                            .font(.caption2)
                    } else {
                        Text("No recent oref algorithm determination.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
        }
    }

    private func values(_ determination: Determination) -> some View {
        let format: (Decimal?, String) -> String = { value, unit in
            value
                .map {
                    "\(NSDecimalNumber(decimal: $0).doubleValue.formatted(.number.precision(.fractionLength(0 ... 2)))) \(unit)" }
                ?? "--"
        }
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow { Text("IOB").foregroundStyle(.secondary)
                Text(format(determination.iob, "U")) }
            GridRow { Text("COB").foregroundStyle(.secondary)
                Text(format(determination.cob, "g")) }
            GridRow { Text("Temp").foregroundStyle(.secondary)
                Text(format(determination.rate, "U/h")) }
            GridRow { Text("SMB").foregroundStyle(.secondary)
                Text(format(determination.units, "U")) }
        }
        .font(.caption2)
    }

    /// As the phone's sheet: within 5 minutes green, within 10 yellow, then red.
    private func status(now: Date) -> (title: String, color: Color) {
        guard let last = session.state.lastLoopAt else { return (String(localized: "Not looping."), .gray) }
        let age = now.timeIntervalSince(last)
        let color: Color = age <= 5 * 60 ? .green : age <= 10 * 60 ? .yellow : .red
        let time = last.formatted(date: .omitted, time: .shortened)
        return (
            session.state.closedLoop ? String(localized: "Enacted at \(time)") : String(localized: "Determined at \(time)"),
            color
        )
    }
}
