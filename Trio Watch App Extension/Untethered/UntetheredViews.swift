import SwiftUI

/// The landing page while untethered: what the watch is doing, and the ways to stop it. Otherwise the
/// place to start it from the wrist.
struct UntetheredStatusView: View {
    let manager: UntetheredWatchManager
    @State private var confirmEnd = false
    @State private var confirmStop = false

    private var data: UntetheredWatchData { manager.data }
    private var phase: UntetheredSession.Phase { data.session.phase }
    private var unsynced: Int { data.pending.values.reduce(0) { $0 + $1.count } }
    private var isPhoneReachable: Bool { WatchState.shared.isReachable }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                VStack(spacing: 10) {
                    header(now: context.date)
                    if let error = data.lastError ?? (manager.isActive ? data.lastLoopError : nil) {
                        card(tint: .orange) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                        }
                    }
                    if manager.isActive { tiles }
                    alerts(now: context.date)
                    actions
                }
                .padding(.horizontal, 4)
            }
        }
        .confirmationDialog("Hand the pump back to the phone?", isPresented: $confirmEnd) {
            Button("Hand Back") { manager.end() }
        }
        .confirmationDialog(
            "Stop now? The watch lets go of the pump at once, cancels the temp basal and stops looping until the phone takes over.",
            isPresented: $confirmStop
        ) {
            Button("Emergency Stop", role: .destructive) { manager.emergencyStop() }
        }
    }

    // MARK: - Header

    private func header(now: Date) -> some View {
        let look = self.look(now: now)
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
            if let lastLoop = data.lastLoopDate {
                let minutes = max(0, Int(now.timeIntervalSince(lastLoop) / 60))
                return ("applewatch", .green, "Untethered", "Last loop \(minutes) min ago")
            }
            return ("applewatch", .green, "Untethered", "Looping on the watch")
        case .preparing,
             .starting:
            return ("applewatch.radiowaves.left.and.right", .yellow, "Starting…", "Taking over the pump and sensor")
        case .ending:
            return ("arrow.uturn.backward.circle", .blue, "Handing Back…", "Waiting for the phone to take the pump")
        case .idle:
            if unsynced > 0 {
                return ("arrow.triangle.2.circlepath", .blue, "Syncing History", "\(unsynced) entries on the way to the phone")
            }
            return ("applewatch.slash", .secondary, "Phone in Charge", "The watch can take over pump and sensor")
        }
    }

    // MARK: - Figures

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            tile("Basal", systemImage: "chart.bar.fill", tint: .blue, value: data.lastDetermination?.rate.map {
                String(format: "%.2f U/h", NSDecimalNumber(decimal: $0).doubleValue)
            })
            tile("Reservoir", systemImage: "drop.fill", tint: .blue, value: data.reservoir.map {
                "\(NSDecimalNumber(decimal: $0).intValue) U"
            })
            tile(
                "Phone",
                systemImage: isPhoneReachable ? "iphone" : "iphone.slash",
                tint: isPhoneReachable ? .green : .secondary,
                value: isPhoneReachable ? String(localized: "Nearby") : String(localized: "Away")
            )
            tile("To Sync", systemImage: "arrow.triangle.2.circlepath", tint: .secondary, value: "\(unsynced)")
        }
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

    // MARK: - Alerts

    /// The pump's and the sensor's alerts while the watch holds them; scheduled ones once they are due.
    @ViewBuilder private func alerts(now: Date) -> some View {
        let due = manager.isActive ? data.pendingPumpAlerts.filter { ($0.due ?? .distantPast) <= now } : []
        ForEach(due) { alert in
            card(tint: .orange) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(alert.title, systemImage: "bell.fill").font(.footnote.bold())
                    Text(alert.body).font(.caption2).foregroundStyle(.secondary)
                    Button("Acknowledge") { manager.acknowledgePumpAlert(alert) }
                        .tint(.orange)
                }
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder private var actions: some View {
        if manager.isBusy {
            HStack(spacing: 8) {
                ProgressView().frame(width: 20)
                Text(phase == .ending ? "Handing back…" : "Starting…").font(.footnote)
            }
            .padding(.top, 4)
        } else {
            switch phase {
            case .idle:
                Button { manager.requestStart() } label: {
                    Label("Start Untethered", systemImage: "applewatch")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!isPhoneReachable)
                if !isPhoneReachable {
                    note("Starts with the phone nearby and Trio open on it.")
                }
            case .active:
                Button { confirmEnd = true } label: {
                    Label("Hand Back", systemImage: "iphone")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(manager.isBolusing)
                if manager.isBolusing {
                    note("A bolus is running. Hand back once it is done, or stop it with the treatment button.")
                }
                stopButton
            case .ending:
                stopButton
            case .preparing,
                 .starting:
                EmptyView()
            }
        }
    }

    private var stopButton: some View {
        Button(role: .destructive) { confirmStop = true } label: {
            Label("Emergency Stop", systemImage: "stop.circle")
        }
        .tint(.red)
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

/// Glucose, meals and insulin of the last hours, from the watch's own records. Glucose and carbs can be
/// deleted; the deletion reaches the phone with the rest of the history.
struct UntetheredHistoryView: View {
    let manager: UntetheredWatchManager
    /// Picked in the bottom bar.
    let kind: Kind
    /// The crown keeps turning the pages here; the list scrolls by touch.
    @Binding var page: Int
    let lastPage: Int
    @FocusState private var hasCrown: Bool

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
        ZStack {
            List {
                switch kind {
                case .glucose: glucoseRows
                case .carbs: carbRows
                case .insulin: insulinRows
                }
            }
        }
        .focusable()
        .focused($hasCrown)
        .digitalCrownRotation($page.doubleBinding(), from: 0, through: Double(lastPage), by: 1)
        .onAppear { hasCrown = true }
    }

    @ViewBuilder private var glucoseRows: some View {
        let units = manager.data.grant?.units ?? .mgdL
        let readings = manager.data.glucose.filter { $0.dateString >= since }.sorted { $0.dateString > $1.dateString }
        if readings.isEmpty { Text("No glucose").foregroundStyle(.secondary) }
        ForEach(readings, id: \.id) { reading in
            let value = reading.glucose ?? reading.sgv ?? 0
            row(reading.dateString, Text(units == .mgdL ? "\(value)" : Decimal(value).formattedAsMmolL))
                .swipeActions {
                    Button("Delete", role: .destructive) { manager.deleteGlucose(id: reading.id) }
                }
        }
    }

    @ViewBuilder private var carbRows: some View {
        let entries = manager.data.carbs.filter { ($0.actualDate ?? $0.createdAt) >= since && !($0.isFPU ?? false) }
            .sorted { ($0.actualDate ?? $0.createdAt) > ($1.actualDate ?? $1.createdAt) }
        if entries.isEmpty { Text("No carbs").foregroundStyle(.secondary) }
        ForEach(entries, id: \.self) { entry in
            row(
                entry.actualDate ?? entry.createdAt,
                Text("\(NSDecimalNumber(decimal: entry.carbs).intValue) g").foregroundStyle(.orange)
            )
            .swipeActions {
                if let id = entry.id {
                    Button("Delete", role: .destructive) { manager.deleteCarbs(id: id) }
                }
            }
        }
    }

    @ViewBuilder private var insulinRows: some View {
        let events = manager.data.pumpHistory
            .filter { [.bolus, .smb, .tempBasal, .pumpSuspend, .pumpResume].contains($0.type) && $0.timestamp >= since }
            .sorted { $0.timestamp > $1.timestamp }
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
            return (event.isSMB ?? false) ? "SMB " + units : "Bolus " + units
        case .tempBasal:
            return String(format: "Temp %.2f U/h", NSDecimalNumber(decimal: event.rate ?? 0).doubleValue)
        case .pumpSuspend: return String(localized: "Suspended")
        case .pumpResume: return String(localized: "Resumed")
        default: return event.type.rawValue
        }
    }
}

/// The running bolus as an edge around the treatment button that fills as it is delivered; by the clock, as the
/// pump itself counts a bolus done.
struct BolusProgressRing: View {
    let window: DateInterval?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let progress = window.map { min(1, max(0, context.date.timeIntervalSince($0.start) / max($0.duration, 1))) } ?? 0
            ZStack {
                Circle().stroke(Color.tabBar.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.tabBar, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
            }
            .padding(-5)
        }
        .allowsHitTesting(false)
    }
}
