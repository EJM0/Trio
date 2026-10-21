import SwiftUI
import WatchConnectivity

extension Color {
    /// Untethered watch mode, as on the phone.
    static let untethered = Color(red: 0x33 / 255, green: 0xE3 / 255, blue: 0xFF / 255)
}

/// The landing page while untethered: what the watch is doing, and the ways to stop it. Otherwise the
/// place to start it from the wrist.
struct UntetheredStatusView: View {
    let manager: UntetheredWatchManager
    @State private var confirmEnd = false
    @State private var confirmStartWithoutPhone = false
    @State private var phoneUnreachable = false
    @State private var confirmStop = false
    @State private var confirmDeactivate = false
    @State private var confirmDiscard = false
    @State private var isDeactivating = false
    @State private var deactivateError: String?

    private var data: UntetheredWatchData { manager.data }
    private var phase: UntetheredSession.Phase { data.session.phase }
    private var unsynced: Int { data.pending.values.reduce(0) { $0 + $1.count } }
    private var isPhoneReachable: Bool { WatchState.shared.isReachable }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                VStack(spacing: 10) {
                    header(now: context.date)
                    if manager.isPairingSensor {
                        card(tint: .untethered) {
                            Label(
                                "Pairing the sensor: keep Trio open until a glucose value shows, and accept the Bluetooth pairing request.",
                                systemImage: "sensor.tag.radiowaves.forward"
                            )
                            .font(.footnote)
                        }
                    }
                    if let error = data.lastError ?? (manager.isActive ? data.lastLoopError : nil) {
                        card(tint: .orange) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                        }
                    }
                    if manager.isActive { tiles }
                    if manager.isActive || unsynced > 0 { historyButton }
                    if manager.isActive, let mode = data.grant?.dosingMode { loopModePicker(mode) }
                    if manager.isActive { phoneTile }
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
            "Start from the phone's copy of \(Int((manager.standingGrantAge ?? 0) / 60)) min ago? Only if the phone is off or out of reach; it stops dosing once it hears from the watch.",
            isPresented: $confirmStartWithoutPhone
        ) {
            Button("Start Without Phone") { manager.startWithoutPhone() }
        }
        .alert("Phone Not Reachable", isPresented: $phoneUnreachable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Bring the phone close and open Trio on it, then hand back again. Use Emergency Stop if it isn't coming back.")
        }
        .confirmationDialog(
            "Stop now? The watch lets go of the pump at once, cancels the temp basal and stops looping until the phone takes over.",
            isPresented: $confirmStop
        ) {
            Button("Emergency Stop", role: .destructive) { manager.emergencyStop() }
        }
        .confirmationDialog(
            "Deactivate the pod? It stops delivering insulin and its alarm ends. Remove it, then pair a new pod on the phone.",
            isPresented: $confirmDeactivate
        ) {
            Button("Deactivate Pod", role: .destructive) {
                isDeactivating = true
                deactivateError = nil
                manager.deactivatePod { error in
                    isDeactivating = false
                    deactivateError = error
                }
            }
        }
        .confirmationDialog(
            "Discard the pod without reaching it? It may keep alarming until you remove it.",
            isPresented: $confirmDiscard
        ) {
            Button("Discard Pod", role: .destructive) {
                deactivateError = nil
                manager.discardPod()
            }
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
        case .active where data.podEnded:
            return ("xmark.circle", .orange, "Pod Deactivated", "The phone pairs the next pod; hand back once it is nearby")
        case .active:
            if let lastLoop = data.lastLoopDate {
                let minutes = max(0, Int(now.timeIntervalSince(lastLoop) / 60))
                return ("applewatch", .untethered, "Untethered", "Last loop \(minutes) min ago")
            }
            return ("applewatch", .untethered, "Untethered", "Looping on the watch")
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
            tile("Basal", systemImage: "chart.bar.fill", tint: .blue, value: (manager.deliveredBasalRate ?? data.lastDetermination?.rate).map {
                String(format: "%.2f U/h", NSDecimalNumber(decimal: $0).doubleValue)
            })
            // above 50 U the pod doesn't measure: the phone's "50+ U" marker
            tile("Reservoir", systemImage: "drop.fill", tint: .blue, value: data.reservoir.map {
                // not `NSDecimalNumber.intValue`: it misreads long fractions such as the fill-based estimate's
                "\($0.formatted(.number.precision(.fractionLength(0)))) U"
            } ?? (data.grant?.reservoir == Decimal(UInt32(0xDEAD_BEEF)) ? "50+ U" : nil))
            tile(
                "Watch Battery",
                systemImage: "battery.75percent",
                tint: (UntetheredWatchManager.batteryPercent ?? 100) < 20 ? .red : .green,
                value: UntetheredWatchManager.batteryPercent.map { "\($0) %" }
            )
        }
    }

    private var phoneTile: some View {
        tile(
            "Phone",
            systemImage: isPhoneReachable ? "iphone" : "iphone.slash",
            tint: isPhoneReachable ? .green : .secondary,
            value: isPhoneReachable ? String(localized: "Nearby") : String(localized: "Away")
        )
    }

    /// The watch's own history, on its own screen: as a page it would trap the pager in its list and shift the pages
    /// after it whenever a session starts or ends. The second row shows the number of records still to sync.
    private var historyButton: some View {
        NavigationLink { UntetheredHistoryView(manager: manager) } label: {
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
                Text("\(unsynced)")
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

    private func loopModePicker(_ mode: DosingMode) -> some View {
        NavigationLink {
            UntetheredLoopModeSelectionView(manager: manager)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Label("Loop Mode", systemImage: mode.icon)
                        .font(.caption2)
                        .foregroundStyle(Color.untethered)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(mode.displayName)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(data.session.phase != .active)
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

    /// Checked at the press, not from the last reachability change, which can lag.
    private func whenPhoneReachable(_ action: () -> Void) {
        if WCSession.default.isReachable { action() } else { phoneUnreachable = true }
    }

    @ViewBuilder private var actions: some View {
        if isDeactivating {
            HStack(spacing: 8) {
                ProgressView().frame(width: 20)
                Text("Deactivating the pod…").font(.footnote)
            }
            .padding(.top, 4)
        } else if manager.isBusy {
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
                .tint(.untethered)
                .disabled(!isPhoneReachable || manager.versionMismatch != nil)
                if let mismatch = manager.versionMismatch {
                    note(mismatch)
                } else if !isPhoneReachable {
                    note("Starts with the phone nearby and Trio open on it.")
                    // without a copy the note below says why
                    if WatchState.shared.allowUntetheredStartWithoutPhone, manager.startWithoutPhoneUnavailable == nil {
                        Button { confirmStartWithoutPhone = true } label: {
                            Label("Start Without Phone", systemImage: "iphone.slash")
                        }
                        .tint(.untethered)
                    }
                }
                copyNote
            case .active where data.podEnded:
                Button { whenPhoneReachable { manager.end() } } label: {
                    Label("Hand Back", systemImage: "iphone")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                if !isPhoneReachable {
                    note("Hands back by itself once the phone is nearby.")
                }
            case .active:
                Button { whenPhoneReachable { confirmEnd = true } } label: {
                    Label("Hand Back", systemImage: "iphone")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(manager.isBolusing)
                if manager.isBolusing {
                    note("A bolus is running. Hand back once it is done, or stop it with the treatment button.")
                }
                stopButton
                // an alarming pod goes quiet when deactivated; the phone pairs the next one
                if let deactivateError {
                    card(tint: .orange) {
                        Label(deactivateError, systemImage: "exclamationmark.triangle.fill").font(.footnote)
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
        note(Text(text))
    }

    /// Whether a copy from the phone is stored to start without it, and how old, or why not.
    @ViewBuilder private var copyNote: some View {
        if WatchState.shared.allowUntetheredStartWithoutPhone {
            if let age = manager.standingGrantAge {
                Label(
                    "The iPhone's copy of \(Int(age / 60)) min ago is ready to start without it",
                    systemImage: "checkmark.circle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Label {
                    Text("Can't start without the iPhone: \(manager.startWithoutPhoneUnavailable ?? "")")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption2)
                .foregroundStyle(.orange)
            }
        }
    }

    private func note(_ text: Text) -> some View {
        text
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
    @State private var kind = Kind.glucose

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
                Text("\(entry.carbs.formatted(.number.precision(.fractionLength(0)))) g").foregroundStyle(.orange)
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

// MARK: - Loop status

private struct UntetheredLoopModeSelectionView: View {
    let manager: UntetheredWatchManager
    @Environment(\.dismiss) private var dismiss

    private var currentMode: DosingMode? { manager.data.grant?.dosingMode }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Loop Mode")
                    .font(.headline)
                    .padding(.bottom, 2)
                ForEach(DosingMode.userSelectable) { mode in
                    Button {
                        manager.setDosingMode(mode)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Label(mode.displayName, systemImage: mode.icon)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.untethered)
                                Spacer(minLength: 0)
                                if mode == currentMode {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Color.untethered)
                                }
                            }
                            Text(mode.miniHint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.data.session.phase != .active)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Loop Mode")
    }
}

/// The phone's Loop Status sheet, from the watch's own loop: how recent it is, oref's values in
/// pills, and its reasoning.
struct UntetheredLoopStatusView: View {
    let manager: UntetheredWatchManager

    private var data: UntetheredWatchData { manager.data }

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
                        .foregroundStyle(status.color == .secondary ? Color.white : Color.bgDarkerDarkBlue)
                        .background(status.color, in: Capsule())
                    if let error = data.lastLoopError {
                        Text(error).font(.caption2).foregroundStyle(Color.loopRed)
                    }
                    if let determination = data.lastDetermination {
                        Text("Latest Raw Algorithm Output").font(.footnote.bold()).padding(.top, 6)
                        PillFlow(spacing: 4) {
                            ForEach(tags(determination), id: \.self) { AlgorithmPill(tag: $0) }
                        }
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

    /// As the phone's sheet: enacted within 5 minutes green, within 10 yellow, then red.
    private func status(now: Date) -> (title: String, color: Color) {
        guard let deliverAt = data.lastDetermination?.deliverAt else {
            return (String(localized: "Not looping."), .secondary)
        }
        let isOpenLoop = data.grant?.dosingMode.automation == .off
        let age = now.timeIntervalSince(data.lastLoopDate ?? deliverAt) - 30
        let color: Color = age <= 5 * 60 ? .loopGreen : age <= 10 * 60 ? .loopYellow : .loopRed
        guard deliverAt >= now.addingTimeInterval(-5 * 60) else {
            let minutes = Int((now.timeIntervalSince(deliverAt) / 60).rounded())
            return (
                isOpenLoop
                    ? String(localized: "Trio has not run in \(minutes) minutes.")
                    : String(localized: "Trio has not looped in \(minutes) minutes."),
                color
            )
        }
        let time = deliverAt.formatted(date: .omitted, time: .shortened)
        return (isOpenLoop ? String(localized: "Determined at \(time)") : String(localized: "Enacted at \(time)"), color)
    }

    private func tags(_ determination: Determination) -> [String] {
        let isMmolL = data.grant?.units == .mmolL
        var tags = determination.reasonParts.map { AlgorithmPill.formatted($0, isMmolL: isMmolL) }
        if data.grant?.smoothGlucose == true { tags.append("Smoothing: On") }
        if let tdd = data.tddRows.max(by: { $0.date < $1.date })?.total ?? data.grant?.tdd.currentTDD, tdd != 0 {
            tags
                .append(
                    "TDD: \(NSDecimalNumber(decimal: tdd).doubleValue.formatted(.number.precision(.fractionLength(0 ... 1))))"
                )
        }
        return tags
    }
}

/// One of the phone's `TagCloudView` pills, in its colors.
private struct AlgorithmPill: View {
    let tag: String

    private var color: Color {
        if tag.contains("SMB Delivery Ratio:") { return .UAM }
        if tag.contains("Bolus") { return .green }
        if [
            "TDD:",
            "tdd_factor",
            "Sigmoid function",
            "Logarithmic formula",
            "AF:",
            "Autosens/Dynamic Limit:",
            "Dynamic ISF/CR",
            "Basal ratio",
            "SMB Ratio"
        ].contains(where: tag.contains) { return .ZT }
        if tag.contains("Middleware:") { return .red }
        if tag.contains("Smoothing: On") { return .gray }
        return .insulin
    }

    var body: some View {
        Text(tag)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1.5))
    }

    private static let glucoseNames = [
        "ISF",
        "Target",
        "Dev",
        "BGI",
        "minPredBG",
        "minGuardBG",
        "IOBpredBG",
        "COBpredBG",
        "UAMpredBG"
    ]

    /// As `TagCloudView.formatGlucoseTags`: "minPredBG 150" reads "minPredBG: 150", and glucose values go to mmol/L.
    static func formatted(_ tag: String, isMmolL: Bool) -> String {
        guard let name = glucoseNames.first(where: { tag.hasPrefix($0 + ":") || tag.hasPrefix($0 + " ") }) else { return tag }
        var values = String(tag.dropFirst(name.count)).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        if isMmolL, let regex = try? NSRegularExpression(pattern: "-?\\d+\\.?\\d*") {
            for match in regex.matches(in: values, range: NSRange(values.startIndex..., in: values)).reversed() {
                guard let range = Range(match.range, in: values),
                      let mgdl = Decimal(string: String(values[range])) else { continue }
                values.replaceSubrange(range, with: mgdl.asMmolL.description)
            }
        }
        return "\(name): \(values)"
    }
}

/// Lays its pills out in rows, wrapping like the phone's tag cloud.
private struct PillFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0) { $0 + $1 } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map { $0.reduce(0) { $0 + $1.width } }.max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var index = 0
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += (row.map(\.height).max() ?? 0) + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }
        return rows
    }
}
