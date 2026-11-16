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
    var notificationsAllowed: () async -> Bool
    var appBuild: String
    var timeZone: () -> TimeZone = { TimeZone.current }
    /// Holds background time for a piece of work; the host ends it on every path.
    var beginActivity: (String) -> LoanBackgroundActivity = { _ in NoBackgroundActivity() }
    var adoptTimeout: TimeInterval = 60
    var phoneAnswerTimeout: TimeInterval = 5
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

    @ObservationIgnored let env: WatchLoanEnvironment
    @ObservationIgnored let records: WatchLoanRecordStore
    @ObservationIgnored let alerts: WatchLoanAlerts
    @ObservationIgnored private(set) var pump: LoanPump?
    @ObservationIgnored private var pumpDelegate: WatchLoanPumpDelegate
    @ObservationIgnored private(set) var snapshot: WatchLoanSnapshot?
    @ObservationIgnored var intent: WatchDoseIntent?
    @ObservationIgnored var cycleInfo = WatchLoanCycleInfo()
    @ObservationIgnored private var inbox = WatchLoanInbox()
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var followUps: [WatchSideLoanEvent] = []
    @ObservationIgnored private var lastReportedForeignSession = false
    @ObservationIgnored var lastOutputs: OrefRun.Outputs?
    /// Called once a cycle has finished, so held background tasks can complete.
    @ObservationIgnored var onCycleFinished: (() -> Void)?
    /// The background time of the cycle or message in progress.
    @ObservationIgnored var activity: LoanBackgroundActivity?
    @ObservationIgnored var adoptedAt: Date?

    init(env: WatchLoanEnvironment) {
        self.env = env
        records = WatchLoanRecordStore(files: env.files)
        alerts = WatchLoanAlerts(notifier: env.notifier)
        pumpDelegate = WatchLoanPumpDelegate(files: env.files, records: records, now: env.now)
        do {
            state = try env.files.load(WatchLoanState.self, from: .state) ?? .initial
        } catch {
            // can't tell what it held: command nothing; the relaunch releases the pod and alerts
            WatchLogger.shared.error(.loop, "Watch loan state can't be read", error: error)
            state = .stopped(epoch: 0, reason: .unconfirmed)
        }
        do {
            cycleInfo = try env.files.load(WatchLoanCycleInfo.self, from: .cycle) ?? WatchLoanCycleInfo()
            intent = try env.files.load(WatchDoseIntent.self, from: .intent)
            inbox = try env.files.load(WatchLoanInbox.self, from: .inbox) ?? WatchLoanInbox()
            if let data = try env.files.read(.snapshot) {
                snapshot = try WatchLoanSnapshot.decode(data)
            }
        } catch {
            WatchLogger.shared.error(.loop, "Watch loan files can't be read", error: error)
        }
        pumpDelegate.host = self
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
        if !env.transport.isReachable { return .phoneUnreachable }
        if let level = env.batteryLevel(), level < Self.minimumStartBattery { return .watchBatteryLow }
        let notificationsAllowed = await env.notificationsAllowed()
        if !notificationsAllowed { return .notificationsOff }
        return nil
    }

    private func endRefusal() -> LoanRefusal? {
        if intent != nil { return .unconfirmedCommand }
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
            return persist(next)
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
            if message.kind == .handBack { sendRecords(epoch: message.epoch) }
            send(message)
        case let .sendStop(stop):
            if stop.kind == .stop { sendRecords(epoch: stop.epoch) }
            guard let data = try? WatchLoanWire.encode(stop) else { return true }
            env.transport.send([WatchLoanWireKey.message: data])
            WatchLogger.shared.info(.connectivity, "Sent \(stop.kind.rawValue), released \(stop.released)")
        case let .alert(alert):
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

    private func persist(_ next: WatchLoanState) -> Bool {
        do {
            if case let .holding(epoch) = next, state.epoch != epoch || !state.mayCommandPump {
                try startLoanRecords(epoch: epoch)
            }
            try env.files.save(next, to: .state)
        } catch {
            WatchLogger.shared.error(.loop, "Saving the loan state failed", error: error)
            alerts.postNotSaved()
            return false
        }
        let previous = state
        state = next
        if case .idle = next, previous != next {
            Task { await self.retireDevices() }
        }
        return true
    }

    private func startLoanRecords(epoch: Int64) throws {
        guard records.snapshot.epoch != epoch else { return }
        try records.reset(epoch: epoch)
        cycleInfo = WatchLoanCycleInfo(holdingSince: env.now(), autosens: snapshot?.oref.autosens)
        try env.files.save(cycleInfo, to: .cycle)
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
        let localState = try? env.files.loadPlist(from: .pumpLocalState)
        guard let manager = env.pumpFactory.adopt(configuration, localState) else {
            WatchLogger.shared.error(.loop, "Adopt failed: the kit refused the export")
            followUps.append(.takeControlResult(succeeded: false))
            return
        }
        do {
            try env.files.savePlist(manager.rawState, to: .pumpState)
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
        if let pump {
            if let local = pump.localState {
                try? env.files.savePlist(local, to: .pumpLocalState)
            }
            pump.pumpManagerDelegate = nil
            self.pump = nil
            WatchLogger.shared.info(.loop, "Pump manager let go after the loan")
        }
        try? env.files.remove(.pumpState)
        try? env.files.remove(.intent)
        intent = nil
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
            alerts.postBluetoothBudget()
        }
    }

    func issueKitAlert(_ alert: Alert) async {
        alerts.postKitAlert(alert)
    }

    func retractKitAlert(_ identifier: Alert.Identifier) async {
        alerts.retractKitAlert(identifier)
    }

    // MARK: - Messages

    /// A WatchConnectivity payload. True when it was a loan payload.
    @discardableResult func receive(_ payload: [String: Any]) async -> Bool {
        let held = env.beginActivity("Trio loan message")
        defer { held.end() }
        return await receiveHeld(payload)
    }

    private func receiveHeld(_ payload: [String: Any]) async -> Bool {
        if let data = payload[WatchLoanWireKey.recordsAck] as? Data {
            if let ack = try? JSONDecoder().decode(WatchLoanRecordAck.self, from: data) {
                do { try records.acknowledge(ack, now: env.now()) } catch {
                    WatchLogger.shared.warning(.loop, "Saving the records acknowledgement failed", error: error)
                }
            }
            return true
        }
        guard let data = payload[WatchLoanWireKey.message] as? Data else { return false }
        switch WatchLoanWire.decode(data) {
        case let .stop(stop):
            WatchLogger.shared.info(.connectivity, "Received \(stop.kind.rawValue), epoch \(stop.epoch)")
            await handle(.receivedStop(stop))
        case let .message(envelope):
            guard inbox.accept(envelope.messageID) else {
                WatchLogger.shared.debug(.connectivity, "Duplicate loan message dropped")
                return true
            }
            do { try env.files.save(inbox, to: .inbox) } catch {
                WatchLogger.shared.warning(.loop, "Saving the loan inbox failed", error: error)
            }
            if case .grant = envelope.message.kind, case .requesting = state {
                acceptSnapshot(payload[WatchLoanWireKey.snapshot] as? Data, epoch: envelope.message.epoch)
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

    /// Saved before the grant is decided, so an adopt after a crash still has it.
    private func acceptSnapshot(_ data: Data?, epoch: Int64) {
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
            try env.files.write(data, to: .snapshot)
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
