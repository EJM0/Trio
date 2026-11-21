import Foundation
import LoopKit
import Observation

enum WatchLoanHostError: Error {
    case notStored
}

/// Sends to the phone over the app's one WatchConnectivity session.
protocol WatchLoanTransport: AnyObject {
    var isReachable: Bool { get }
    /// Live when the phone is reachable, otherwise queued.
    func send(_ payload: [String: Any])
    /// Live only; false when the phone isn't reachable.
    @discardableResult func sendLive(_ payload: [String: Any], reply: (([String: Any]) -> Void)?) -> Bool
}

protocol WatchLoanNotifier: AnyObject {
    func post(id: String, title: String, body: String, at date: Date?, timeSensitive: Bool, category: String?)
    func cancel(ids: [String])
}

/// The one CGM manager the watch keeps while it holds the pump.
@MainActor protocol LoanCGMSource: AnyObject {
    func adopt(export: Data) async
    func restore()
    func recheckAcquisition()
    func retire() async
}

struct WatchLoanEnvironment {
    var files: WatchLoanFiles
    var transport: WatchLoanTransport
    var notifier: WatchLoanNotifier
    var pumpFactory: LoanPumpFactory
    var cgm: LoanCGMSource?
    var now: () -> Date = Date.init
    var isForeground: () -> Bool
    /// 0 to 1, nil when unknown.
    var batteryLevel: () -> Float?
    /// Notifications and time-sensitive delivery are both allowed.
    var notificationsAllowed: () async -> Bool
    /// `hw.machine`, for example `Watch6,2`; nil when unknown.
    var modelIdentifier: () -> String?
    var appBuild: String
    var timeZone: () -> TimeZone = { TimeZone.current }
    /// Holds background time for a piece of work; the host ends it on every path.
    var beginActivity: (String) -> LoanBackgroundActivity = { _ in NoBackgroundActivity() }
    var adoptTimeout: TimeInterval = 60
    var requestTimeout: TimeInterval = WatchLoan.watchRequestTimeout
    var handBackResendInterval: TimeInterval = 60
    var phoneAnswerTimeout: TimeInterval = 5
    var grantPartsWait: TimeInterval = 5
}

/// Background time held for one cycle or message.
protocol LoanBackgroundActivity: AnyObject {
    /// The system wants the time back: start no pump command.
    var isExpired: Bool { get }
    func end()
}

final class NoBackgroundActivity: LoanBackgroundActivity {
    var isExpired: Bool { false }
    func end() {}
}

/// Runs the watch side of a loan: the state machine's effects, the one pump manager, the loop cycle on each CGM
/// reading, and the not-looping, glucose and device alerts. Every event, cycle and treatment runs one at a time.
@MainActor @Observable final class WatchLoanHost {
    enum BolusProgress: Equatable {
        case idle
        case requested
        case accepted
        case delivering
        case done
        case cancelled
        case failed(String)
        /// The pump didn't confirm. Never retried; the recent doses tell what happened.
        case uncertain
    }

    struct LoopStatus: Equatable {
        var lastCycleAt: Date?
        var lastConfirmedCycleAt: Date?
        var iob: Decimal?
        var cob: Decimal?
        var eventualGlucose: Int?
        var tempBasalRate: Decimal?
        var pumpSuspended = false
    }

    private(set) var state: WatchLoanState
    var loop = LoopStatus()
    var bolus: BolusProgress = .idle
    var isCycleRunning = false
    /// After the adopt, until the watch's own first CGM reading: the first G7 bond needs Trio in front, so the
    /// watch doesn't report itself in control before then.
    var awaitingFirstReading = false
    var isInControl: Bool { state.mayCommandPump && !awaitingFirstReading }
    /// The last loan notice, so the screens can keep a refusal on screen until the user dismisses it.
    var lastAlert: LoanAlert?

    @ObservationIgnored let env: WatchLoanEnvironment
    @ObservationIgnored let records: WatchLoanRecordStore
    @ObservationIgnored let alerts: WatchLoanAlerts
    @ObservationIgnored private(set) var pump: LoanPump?
    @ObservationIgnored private var pumpDelegate: WatchLoanPumpDelegate
    @ObservationIgnored private(set) var snapshot: WatchLoanSnapshot?
    /// Commands written down before they were sent, until each outcome is known. Never overwritten: each command adds one.
    @ObservationIgnored var intents: [WatchDoseIntent] = []
    @ObservationIgnored var cycleInfo = WatchLoanCycleInfo()
    @ObservationIgnored private var inbox = WatchLoanInbox()
    @ObservationIgnored private var snapshotParts = WatchLoanSnapshotAssembler()
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var followUps: [WatchSideLoanEvent] = []
    @ObservationIgnored private var lastReportedForeignSession = false
    @ObservationIgnored var lastOutputs: OrefRun.Outputs?
    /// Called once a cycle has finished, so held background tasks can complete.
    @ObservationIgnored var onCycleFinished: (() -> Void)?
    /// The background time of the cycle or message in progress.
    @ObservationIgnored var activity: LoanBackgroundActivity?
    @ObservationIgnored var adoptedAt: Date?
    @ObservationIgnored private var requestTimer: Task<Void, Never>?
    @ObservationIgnored private var handBackTimer: Task<Void, Never>?
    /// The saved files, read on the file queue; every entry point waits for it.
    @ObservationIgnored private(set) var loaded: Task<Void, Never>!

    init(env: WatchLoanEnvironment) {
        self.env = env
        records = WatchLoanRecordStore(files: env.files)
        alerts = WatchLoanAlerts(notifier: env.notifier)
        pumpDelegate = WatchLoanPumpDelegate(files: env.files, records: records, now: env.now)
        state = .initial
        pumpDelegate.host = self
        loaded = Task { await self.loadFiles() }
        tail = loaded
    }

    private struct Saved {
        var state: WatchLoanState?
        var stateUnreadable = false
        var cycleInfo: WatchLoanCycleInfo?
        var intents: [WatchDoseIntent] = []
        var inbox: WatchLoanInbox?
        var snapshot: WatchLoanSnapshot?
    }

    /// Reads every loan file off the main thread before any event, cycle or treatment runs.
    private func loadFiles() async {
        let (files, records) = (env.files, records)
        let saved = (try? await WatchLoanFiles.io { () -> Saved in
            var saved = Saved()
            do {
                saved.state = try files.load(WatchLoanState.self, from: .state)
            } catch {
                WatchLogger.shared.error(.loop, "Watch loan state can't be read", error: error)
                saved.stateUnreadable = true
            }
            do {
                saved.cycleInfo = try files.load(WatchLoanCycleInfo.self, from: .cycle)
                saved.intents = try files.load([WatchDoseIntent].self, from: .intent) ?? []
                saved.inbox = try files.load(WatchLoanInbox.self, from: .inbox)
                saved.snapshot = try files.read(.snapshot).map { try WatchLoanSnapshot.decode($0) }
            } catch {
                WatchLogger.shared.error(.loop, "Watch loan files can't be read", error: error)
            }
            records.load()
            return saved
        }) ?? Saved()
        if saved.stateUnreadable {
            // can't tell what it held: command nothing; the relaunch releases the pod
            state = .stopped(epoch: 0, reason: .unconfirmed)
            alerts.post(.stopped(.unconfirmed))
        } else {
            state = saved.state ?? .initial
        }
        cycleInfo = saved.cycleInfo ?? WatchLoanCycleInfo()
        intents = saved.intents
        inbox = saved.inbox ?? WatchLoanInbox()
        snapshot = saved.snapshot
        loop.lastCycleAt = cycleInfo.lastCycleAt
        loop.lastConfirmedCycleAt = cycleInfo.lastConfirmedCycleAt
    }

    // MARK: - Serial work

    /// Runs `work` after everything queued before it.
    func serially(_ work: @escaping @MainActor() async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        await task.value
    }

    func handle(_ event: WatchSideLoanEvent) async {
        await serially { await self.process(event) }
    }

    /// Inside serial work: the event and the results its effects report.
    func process(_ event: WatchSideLoanEvent) async {
        var events = [event]
        while !events.isEmpty {
            let next = events.removeFirst()
            followUps = []
            await processOne(next)
            events += followUps
        }
    }

    private func processOne(_ event: WatchSideLoanEvent) async {
        let context = WatchSideLoanContext(
            now: env.now(),
            newRequestID: UUID(),
            startRefusal: event == .startTapped ? await startRefusal() : nil,
            endRefusal: event == .endTapped ? endRefusal() : nil,
            grantRefusal: grantRefusal(for: event)
        )
        let (next, effects) = WatchLoan.decide(state, event, context)
        if next != state {
            WatchLogger.shared.info(.loop, "Loan \(Self.describe(state)) to \(Self.describe(next))")
        }
        for effect in effects {
            guard await execute(effect) else {
                WatchLogger.shared.warning(.loop, "Loan effects stopped after a failure")
                break
            }
        }
    }

    // MARK: - Preconditions

    static let minimumStartBattery: Float = 0.3

    private func startRefusal() async -> LoanRefusal? {
        guard let model = env.modelIdentifier(), WatchLoopPolicy.isSupportedWatch(modelIdentifier: model) else {
            return .unsupportedWatch
        }
        if !env.transport.isReachable { return .phoneUnreachable }
        if let level = env.batteryLevel(), level < Self.minimumStartBattery { return .watchBatteryLow }
        let notificationsAllowed = await env.notificationsAllowed()
        if !notificationsAllowed { return .notificationsOff }
        return nil
    }

    private func endRefusal() -> LoanRefusal? {
        if !intents.isEmpty { return .unconfirmedCommand }
        guard let pump else { return nil }
        if pump.status.deliveryIsUncertain { return .deliveryUncertain }
        if pump.status.bolusState != .noBolus { return .bolusRunning }
        return nil
    }

    private func grantRefusal(for event: WatchSideLoanEvent) -> LoanRefusal? {
        guard case let .received(message) = event, case .grant = message.kind,
              case let .requesting(_, requestID) = state
        else { return nil }
        guard let snapshot else { return .snapshotIncomplete }
        return snapshot.refusal(for: .init(
            requestID: requestID,
            epoch: message.epoch,
            appBuild: env.appBuild,
            now: env.now(),
            timeZone: env.timeZone()
        ))
    }

    // MARK: - Effects

    /// False stops the rest of the list: nothing acts on a state that wasn't saved.
    private func execute(_ effect: WatchSideLoanEffect) async -> Bool {
        switch effect {
        case let .persist(next):
            return await persist(next)
        case let .arm(alarm):
            guard alarm == .watchNotLooping else { return true }
            alerts.armNotLooping(after: notLoopingAnchor(), now: env.now())
        case let .disarm(alarm):
            guard alarm == .watchNotLooping else { return true }
            alerts.disarmNotLooping()
        case .adoptControl:
            await adopt()
        case .releaseControl:
            await release()
        case .cancelTemp:
            _ = await command(.tempBasal(unitsPerHour: 0, minutes: 0))
        case .refreshDeliveredUnits:
            if let pump {
                let read = await pump.refreshDeliveredUnits()
                WatchLogger.shared.info(.loop, "Pump total read before release: \(read ? "ok" : "failed")")
            }
        case let .send(message):
            // the hand-back carries what the phone hasn't acknowledged yet
            if message.kind == .handBack { await sendRecords(epoch: message.epoch) }
            send(message)
            if message.kind == .handBack { resendHandBack(epoch: message.epoch) }
        case let .sendStop(stop):
            if stop.kind == .stop { await sendRecords(epoch: stop.epoch) }
            guard let data = try? WatchLoanWire.encode(stop) else { return true }
            env.transport.send([WatchLoanWireKey.message: data])
            WatchLogger.shared.info(.connectivity, "Sent \(stop.kind.rawValue), released \(stop.released)")
        case let .alert(alert):
            lastAlert = alert
            alerts.post(alert)
        case .audit,
             .awaitPumpIdle,
             .cancelOutstandingTransfers,
             .podSession,
             .takeControl:
            WatchLogger.shared.error(.loop, "Phone effect reached the watch; ignored")
        }
        return true
    }

    /// The series runs from the loan's last confirmed cycle; a loan about to start has none yet.
    private func notLoopingAnchor() -> Date {
        switch state {
        case .holding,
             .returning,
             .stopped:
            return cycleInfo.lastConfirmedCycleAt ?? cycleInfo.holdingSince ?? env.now()
        case .idle,
             .requesting:
            return env.now()
        }
    }

    private func persist(_ next: WatchLoanState) async -> Bool {
        do {
            if case let .holding(epoch) = next, state.epoch != epoch || !state.mayCommandPump {
                try await startLoanRecords(epoch: epoch)
            }
            let files = env.files
            try await WatchLoanFiles.io { try files.save(next, to: .state) }
        } catch {
            WatchLogger.shared.error(.loop, "Saving the loan state failed", error: error)
            alerts.postNotSaved()
            return false
        }
        let previous = state
        state = next
        // the watch no longer sees the pump, so it can't tell when insulin resumes
        if previous.mayCommandPump, !next.mayCommandPump { cancelSuspendReminders() }
        if case .idle = next, previous != next {
            Task { await self.retireDevices() }
        }
        updateRequestTimeout(from: previous, to: next)
        return true
    }

    /// Until the phone acknowledges, the hand-back goes again while the phone is reachable (W17); an unreachable phone
    /// gets the queued copy once it connects.
    private func resendHandBack(epoch: Int64) {
        handBackTimer?.cancel()
        let interval = env.handBackResendInterval
        handBackTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self, case let .returning(current) = state, current == epoch else { return }
                if env.transport.isReachable {
                    await handle(.handBackUnacknowledged)
                    return
                }
            }
        }
    }

    /// The phone may have released the pump without its grant arriving: nothing doses then, so the request ends
    /// with a notice that is already pending in the system.
    private func updateRequestTimeout(from previous: WatchLoanState, to next: WatchLoanState) {
        guard case let .requesting(_, requestID) = next else {
            guard case .requesting = previous else { return }
            requestTimer?.cancel()
            env.notifier.cancel(ids: [WatchLoanAlerts.requestTimeoutID])
            return
        }
        if case let .requesting(_, previousID) = previous, previousID == requestID { return }
        let timeout = env.requestTimeout
        alerts.post(.phoneDidNotAnswer, id: WatchLoanAlerts.requestTimeoutID, at: env.now().addingTimeInterval(timeout))
        requestTimer?.cancel()
        requestTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, case let .requesting(_, current) = state, current == requestID else { return }
            await handle(.requestTimedOut)
        }
    }

    private func startLoanRecords(epoch: Int64) async throws {
        guard records.snapshot.epoch != epoch else { return }
        let (records, pulse) = (records, snapshot?.deliveryPulseUnits ?? 0.05)
        try await WatchLoanFiles.io { try records.reset(epoch: epoch, pulseUnits: pulse) }
        cycleInfo = WatchLoanCycleInfo(holdingSince: env.now(), autosens: snapshot?.oref.autosens)
        let (files, info) = (env.files, cycleInfo)
        try await WatchLoanFiles.io { try files.save(info, to: .cycle) }
    }

    func send(_ message: WatchLoanMessage) {
        let envelope = WatchLoanEnvelope(
            protocolVersion: WatchLoanEnvelope.currentProtocolVersion,
            messageID: UUID(),
            sentAt: env.now(),
            message: message
        )
        guard let data = try? WatchLoanWire.encode(envelope) else { return }
        env.transport.send([WatchLoanWireKey.message: data])
        WatchLogger.shared.info(.connectivity, "Sent loan message \(Self.kindName(message.kind)), epoch \(message.epoch)")
    }

    // MARK: - Pump lifetime

    /// The one adopt of a loan: from the grant, bounded by the kit to the session the phone released.
    private func adopt() async {
        guard pump == nil else {
            WatchLogger.shared.warning(.loop, "Adopt skipped: a pump manager already exists")
            return
        }
        guard let snapshot, let raw = WatchLoanSnapshot.configuration(from: snapshot.pumpExport),
              let configuration = SharedDeviceConfiguration(rawValue: raw)
        else {
            WatchLogger.shared.error(.loop, "Adopt failed: no pump export in the grant")
            followUps.append(.takeControlResult(succeeded: false))
            return
        }
        let files = env.files
        let localState = try? await WatchLoanFiles.io { try files.loadPlist(from: .pumpLocalState) }
        guard let manager = env.pumpFactory.adopt(configuration, localState) else {
            WatchLogger.shared.error(.loop, "Adopt failed: the kit refused the export")
            followUps.append(.takeControlResult(succeeded: false))
            return
        }
        do {
            let rawState = manager.rawState
            try await WatchLoanFiles.io { try files.savePlist(rawState, to: .pumpState) }
        } catch {
            // without its saved state a relaunch can't know the kit adopted: don't let it reach the pod
            WatchLogger.shared.error(.loop, "Adopt stopped: saving the pump state failed", error: error)
            alerts.postNotSaved()
            followUps.append(.takeControlResult(succeeded: false))
            return
        }
        install(manager)
        adoptedAt = env.now()
        awaitingFirstReading = true
        WatchLogger.shared.info(.loop, "Pump adopted from the grant; taking control")
        await offMain { manager.takeControl() }
        await env.cgm?.adopt(export: snapshot.cgmExport)
        watchAdopt(manager)
    }

    /// A take that hasn't answered in time is reported, unless the kit refused the pod.
    private func watchAdopt(_ manager: LoanPump) {
        let timeout = env.adoptTimeout
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, self.pump === manager, !manager.refusesSessions, !manager.isControlReady,
                  case .holding = self.state
            else { return }
            await self.handle(.takeControlResult(succeeded: false))
        }
    }

    private func install(_ manager: LoanPump) {
        manager.delegateQueue = DispatchQueue(label: "org.nightscout.Trio.watch.pump")
        manager.pumpManagerDelegate = pumpDelegate
        // its heartbeat is a delayed connect, which watchOS fires minutes late; the CGM reading wakes the watch
        manager.setMustProvideBLEHeartbeat(false)
        manager.setBLEHeartbeatRequest(nil)
        pump = manager
        lastReportedForeignSession = manager.refusesSessions || manager.foreignSessionDetectedAt != nil
    }

    /// Rebuilds the manager from its own saved state, never from the grant.
    func restorePump() {
        guard pump == nil else { return }
        do {
            guard let raw = try env.files.loadPlist(from: .pumpState) else { return }
            guard let manager = env.pumpFactory.restore(raw) else {
                WatchLogger.shared.error(.loop, "The saved pump state can't be restored")
                return
            }
            install(manager)
            WatchLogger.shared.info(.loop, "Pump manager restored from its saved state")
        } catch {
            WatchLogger.shared.error(.loop, "The saved pump state can't be read", error: error)
        }
    }

    private func release() async {
        guard let pump else {
            followUps.append(.releaseResult(released: true))
            return
        }
        await offMain { pump.releaseControl() }
        let released = pump.isControlReleased
        WatchLogger.shared.info(.loop, released ? "Pump released" : "Pump release refused: a command is unconfirmed")
        followUps.append(.releaseResult(released: released))
    }

    /// After the loan: let the managers go, keeping only what the next adopt needs.
    private func retireDevices() async {
        let files = env.files
        if let pump {
            if let local = pump.localState {
                try? await WatchLoanFiles.io { try files.savePlist(local, to: .pumpLocalState) }
            }
            pump.pumpManagerDelegate = nil
            self.pump = nil
            WatchLogger.shared.info(.loop, "Pump manager let go after the loan")
        }
        // what never settled is booked as the cycle would book it, and goes to the phone before it is forgotten
        let (records, pending) = (records, intents)
        for intent in pending where intent.resolve(
            kitUncertain: false,
            kitBookedIt: records.kitRecorded(intent),
            deliveredNow: nil,
            pulseUnits: records.snapshot.pulseUnits
        ) == .bookAsDelivered {
            try? await WatchLoanFiles.io { try records.book(intent) }
            WatchLogger.shared.warning(.loop, "Unsettled command \(Self.name(intent.kind)) booked as delivered at the loan's end")
        }
        if !pending.isEmpty {
            alerts.postBookedIntent()
            await sendRecords(epoch: records.snapshot.epoch)
        }
        try? await WatchLoanFiles.io {
            try files.remove(.pumpState)
            try files.remove(.intent)
        }
        intents = []
        await env.cgm?.retire()
    }

    /// Kit calls that wait on a session in progress.
    private func offMain(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                work()
                done.resume()
            }
        }
    }

    // MARK: - Kit reports

    func pumpStateChanged(foreignSession: Bool) {
        guard foreignSession, !lastReportedForeignSession else { return }
        lastReportedForeignSession = true
        WatchLogger.shared.warning(.loop, "The pod reported a session this watch didn't start")
        Task { await self.handle(.foreignPodSession) }
    }

    func pumpStateNotSaved() {
        alerts.postNotSaved()
    }

    func deviceError(_ error: Error) {
        if WatchLoanAlerts.isBluetoothBudgetError(error) {
            noteSummary { $0.budgetErrors += 1 }
            alerts.postBluetoothBudget()
        }
    }

    /// A background task the app was handed, by type.
    func noteWake(_ type: String) async {
        await loaded.value
        noteSummary { $0.wakes[type, default: 0] += 1 }
    }

    /// Adds to today's counts; the first note of a new day logs yesterday's line and starts over.
    func noteSummary(_ change: (inout WatchLoanCycleInfo.DailySummary) -> Void) {
        let now = env.now()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = snapshot?.timeZone ?? env.timeZone()
        if let since = cycleInfo.summary.since, !calendar.isDate(since, inSameDayAs: now) {
            WatchLogger.shared.info(.lifecycle, Self.summaryLine(cycleInfo.summary, until: now, battery: env.batteryLevel()))
            cycleInfo.summary = WatchLoanCycleInfo.DailySummary()
        }
        if cycleInfo.summary.since == nil {
            cycleInfo.summary.since = now
            cycleInfo.summary.batteryAtStart = env.batteryLevel()
        }
        change(&cycleInfo.summary)
        saveCycleInfo()
    }

    static func summaryLine(_ summary: WatchLoanCycleInfo.DailySummary, until now: Date, battery: Float?) -> String {
        let hours = max(now.timeIntervalSince(summary.since ?? now) / 3600, 1 / 60)
        let expected = Int(hours * 12)
        let wakes = summary.wakes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let drain = summary.batteryAtStart.flatMap { start in battery.map { (start - $0) * 100 / Float(hours) } }
        return "Daily summary over \(String(format: "%.1f", hours)) h: readings \(summary.readings) of \(expected) expected, "
            + "cycles \(summary.cycles) (\(summary.confirmed) confirmed), wakes \(wakes.isEmpty ? "none" : wakes), "
            + "Bluetooth budget errors \(summary.budgetErrors), longest reading gap \(summary.longestGapSeconds / 60) min, "
            + "battery \(drain.map { String(format: "%.1f %%/h", $0) } ?? "unknown")"
    }

    func issueKitAlert(_ alert: Alert) async {
        alerts.postKitAlert(alert, line: WatchLoanAlerts.podNeedsPhone, now: env.now())
    }

    /// The sensor's own alerts, while the watch reads it: with the phone away nothing else tells the user (G-R2).
    func issueSensorAlert(_ alert: Alert) async {
        await loaded.value
        guard readsGlucose else {
            WatchLogger.shared.info(.cgm, "CGM alert left to the iPhone: \(alert.identifier.alertIdentifier)")
            return
        }
        alerts.postKitAlert(alert, line: WatchLoanAlerts.sensorNeedsPhone, now: env.now())
    }

    func retractKitAlert(_ identifier: Alert.Identifier) async {
        alerts.retractKitAlert(identifier)
    }

    // MARK: - Messages

    /// A WatchConnectivity payload. True when it was a loan payload.
    @discardableResult func receive(_ payload: [String: Any]) async -> Bool {
        await loaded.value
        let held = env.beginActivity("Trio loan message")
        defer { held.end() }
        return await receiveHeld(payload)
    }

    private func receiveHeld(_ payload: [String: Any]) async -> Bool {
        if let data = payload[WatchLoanWireKey.recordsAck] as? Data {
            if let ack = try? JSONDecoder().decode(WatchLoanRecordAck.self, from: data) {
                let (records, now) = (records, env.now())
                do { try await WatchLoanFiles.io { try records.acknowledge(ack, now: now) } } catch {
                    WatchLogger.shared.warning(.loop, "Saving the records acknowledgement failed", error: error)
                }
            }
            return true
        }
        let part = receivePart(payload)
        guard let data = payload[WatchLoanWireKey.message] as? Data else { return part != nil }
        switch WatchLoanWire.decode(data) {
        case let .stop(stop):
            WatchLogger.shared.info(.connectivity, "Received \(stop.kind.rawValue), epoch \(stop.epoch)")
            await handle(.receivedStop(stop))
        case let .message(envelope):
            guard inbox.accept(envelope.messageID) else {
                WatchLogger.shared.debug(.connectivity, "Duplicate loan message dropped")
                return true
            }
            let (files, inbox) = (env.files, inbox)
            WatchLoanFiles.later("the loan inbox") { try files.save(inbox, to: .inbox) }
            if case let .grant(requestID, expiresAt) = envelope.message.kind, case .requesting = state {
                if let whole = payload[WatchLoanWireKey.snapshot] as? Data {
                    await acceptSnapshot(whole, epoch: envelope.message.epoch)
                } else if part != nil {
                    let assembled = await assembleSnapshot(
                        requestID: requestID,
                        epoch: envelope.message.epoch,
                        until: min(expiresAt, env.now().addingTimeInterval(env.grantPartsWait))
                    )
                    await acceptSnapshot(assembled, epoch: envelope.message.epoch)
                } else {
                    await acceptSnapshot(nil, epoch: envelope.message.epoch)
                }
            }
            WatchLogger.shared.info(
                .connectivity,
                "Received loan message \(Self.kindName(envelope.message.kind)), epoch \(envelope.message.epoch)"
            )
            await handle(.received(envelope.message))
        case let .unsupportedVersion(version):
            WatchLogger.shared.warning(.connectivity, "Loan message from protocol version \(version) dropped")
        case .malformed:
            WatchLogger.shared.warning(.connectivity, "Malformed loan message dropped")
        }
        return true
    }

    private func receivePart(_ payload: [String: Any]) -> WatchLoanSnapshotPart? {
        guard let headerData = payload[WatchLoanWireKey.snapshotPartHeader] as? Data,
              let bytes = payload[WatchLoanWireKey.snapshotPart] as? Data,
              let header = try? JSONDecoder().decode(WatchLoanSnapshotPart.self, from: headerData)
        else { return nil }
        guard case let .requesting(_, requestID) = state, header.requestID == requestID else {
            WatchLogger.shared.debug(
                .connectivity,
                "Grant part \(header.index + 1) of \(header.count) dropped: not requesting it"
            )
            return header
        }
        snapshotParts.add(header, bytes)
        WatchLogger.shared.debug(.connectivity, "Grant part \(header.index + 1) of \(header.count) received")
        return header
    }

    /// Waits for missing pieces until `deadline`. Nil when incomplete or the digest doesn't match.
    private func assembleSnapshot(requestID: UUID, epoch: Int64, until deadline: Date) async -> Data? {
        defer { snapshotParts.reset() }
        var polls = Int(max(0, deadline.timeIntervalSince(env.now())) / 0.1)
        while (snapshotParts.missing(requestID: requestID, epoch: epoch) ?? 1) > 0, polls > 0 {
            polls -= 1
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let missing = snapshotParts.missing(requestID: requestID, epoch: epoch)
        guard let data = snapshotParts.assembled(requestID: requestID, epoch: epoch) else {
            let reason: String
            switch missing {
            case nil: reason = "no parts for this grant"
            case 0?: reason = "the parts don't match their digest"
            case let count?: reason = "\(count) part(s) missing"
            }
            WatchLogger.shared.warning(.connectivity, "Grant snapshot incomplete: \(reason)")
            return nil
        }
        WatchLogger.shared.info(.connectivity, "Grant snapshot assembled, \(data.count) bytes")
        return data
    }

    /// Saved before the grant is decided, so an adopt after a crash still has it.
    private func acceptSnapshot(_ data: Data?, epoch: Int64) async {
        guard let data else {
            snapshot = nil
            return
        }
        do {
            let decoded = try WatchLoanSnapshot.decode(data)
            guard decoded.epoch == epoch else {
                snapshot = nil
                return
            }
            let files = env.files
            try await WatchLoanFiles.io { try files.write(data, to: .snapshot) }
            snapshot = decoded
        } catch {
            WatchLogger.shared.warning(.loop, "Grant snapshot can't be read or saved", error: error)
            snapshot = nil
        }
    }

    // MARK: - User

    func startTapped() async { await handle(.startTapped) }
    func endTapped() async { await handle(.endTapped) }
    func stopAcknowledged() async { await handle(.stopAcknowledged) }

    // MARK: - Relaunch

    /// Launch: rebuild what the persisted state says the watch has, then let the state machine decide. Never takes control.
    func relaunch() async {
        await serially {
            switch self.state {
            case .holding,
                 .returning,
                 .stopped:
                self.restorePump()
                self.env.cgm?.restore()
            case .idle,
                 .requesting:
                break
            }
            var phoneEpoch: Int64?
            if case .holding = self.state {
                phoneEpoch = await self.askPhoneEpoch()
            }
            let foreign = self.pump.map { $0.refusesSessions || $0.foreignSessionDetectedAt != nil } ?? false
            WatchLogger.shared.info(
                .lifecycle,
                "Relaunched in \(Self.describe(self.state)); pump manager \(self.pump == nil ? "none" : "restored"), phone epoch \(phoneEpoch.map(String.init) ?? "no answer")"
            )
            await self.process(.relaunched(
                lastCycleAt: self.cycleInfo.lastCycleAt ?? self.cycleInfo.holdingSince ?? .distantPast,
                phoneEpoch: phoneEpoch,
                podSessionForeign: foreign,
                kitHasControl: self.pump != nil
            ))
        }
    }

    /// The phone answers a status query with its epoch. Nil when it doesn't answer in time.
    private func askPhoneEpoch() async -> Int64? {
        let envelope = WatchLoanEnvelope(
            protocolVersion: WatchLoanEnvelope.currentProtocolVersion,
            messageID: UUID(),
            sentAt: env.now(),
            message: WatchLoanMessage(epoch: state.epoch, kind: .statusQuery)
        )
        guard let data = try? WatchLoanWire.encode(envelope) else { return nil }
        let timeout = env.phoneAnswerTimeout
        return await withCheckedContinuation { (done: CheckedContinuation<Int64?, Never>) in
            let once = ResumeOnce(done)
            let sent = env.transport.sendLive([WatchLoanWireKey.message: data]) { reply in
                once.resume((reply[WatchLoanWireKey.phoneEpoch] as? NSNumber)?.int64Value)
            }
            guard sent else { return once.resume(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }

    // MARK: - Logging

    static func describe(_ state: WatchLoanState) -> String {
        switch state {
        case let .idle(epoch): return "idle (\(epoch))"
        case let .requesting(epoch, _): return "requesting (\(epoch))"
        case let .holding(epoch): return "holding (\(epoch))"
        case let .returning(epoch): return "returning (\(epoch))"
        case let .stopped(epoch, reason): return "stopped (\(epoch), \(reason.rawValue))"
        }
    }

    static func kindName(_ kind: WatchLoanMessage.Kind) -> String {
        switch kind {
        case .request: return "request"
        case .grantRejected: return "grantRejected"
        case .holding: return "holding"
        case .records: return "records"
        case .handBack: return "handBack"
        case .status: return "status"
        case .grant: return "grant"
        case .refused: return "refused"
        case .handBackAck: return "handBackAck"
        case .statusQuery: return "statusQuery"
        }
    }
}

/// Resumes a continuation once, whichever answer comes first.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.withLock {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
