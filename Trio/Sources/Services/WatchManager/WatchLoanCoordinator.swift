import Foundation

protocol WatchLoanTransport: AnyObject {
    var isReachable: Bool { get }
    /// A live message only. False when the watch isn't reachable; `failed` when it didn't get there after all.
    func sendLive(_ payload: [String: Any], failed: ((Error) -> Void)?) -> Bool
    /// Live when reachable, otherwise queued for delivery.
    func send(_ payload: [String: Any])
    /// Queued, replacing any queued payload under the same key.
    func sendNewest(_ payload: [String: Any], key: String)
    func cancelOutstandingLoanTransfers()
}

extension WatchLoanTransport {
    func sendLive(_ payload: [String: Any]) -> Bool { sendLive(payload, failed: nil) }
}

/// What the coordinator needs from the rest of the app.
protocol WatchLoanPhoneHost: AnyObject {
    var pump: WatchLoanPumpAdapter? { get }
    var transport: WatchLoanTransport? { get }
    /// Trio on Watch and Allow Without iPhone are on: the phone leaves a copy with the watch.
    var standingCopyAllowed: Bool { get }
    func startRefusal() async -> LoanRefusal?
    func awaitPumpIdle() async
    func snapshot(
        requestID: UUID,
        epoch: Int64,
        expiresAt: Date,
        release: WatchLoanSnapshot.OdometerReading,
        pump: WatchLoanPumpAdapter,
        /// The copy for a start without the phone: exported while the phone still holds the pod.
        asCopy: Bool
    ) async throws -> WatchLoanSnapshot
    func merge(_ batch: WatchLoanRecordBatch) async throws
    func bookedEvents(since date: Date) async throws -> [PumpHistoryEvent]
    func replaceAuditBolus(id: String, units: Double, at date: Date) async throws
    func basalProfile() async -> [BasalProfileEntry]
    func setAlarm(_ alarm: LoanAlarm, armed: Bool, anchor: Date)
    func alert(_ alert: LoanAlert)
    func auditNotice(units: Double, isShortfall: Bool)
    func didReturnHome()
    /// The watch looped (from a record batch's loop time), so the phone's loop timer reflects the watch's loop.
    func noteWatchLoop(at date: Date)
    func onForeignPodSession(_ action: @escaping () -> Void)
    /// What the watch's Start screen shows before the user confirms.
    func startFacts() async -> WatchLoanStartFacts
    /// Called after the phone stores glucose, its own sensor's or the watch's.
    func onGlucoseStored(_ action: @escaping () -> Void)
    /// The phone's readings of the last 20 minutes, unsmoothed.
    func recentGlucose() async -> [BloodGlucose]
}

extension WatchLoanPhoneHost {
    func startFacts() async -> WatchLoanStartFacts { WatchLoanStartFacts() }
    func onGlucoseStored(_: @escaping () -> Void) {}
    func recentGlucose() async -> [BloodGlucose] { [] }
}

/// What the phone keeps besides its loan state: release readings and audits, seen message ids, the last record batch.
struct WatchLoanLedger: Codable, Equatable {
    struct Audit: Codable, Equatable {
        /// Nil: the pod's whole life, from activation.
        var epoch: Int64?
        var start: Date
        var startUnits: Double
        var basalProfile: [BasalProfileEntry]
        var timeZoneIdentifier: String
        var pulse: Double
        var end: Date?
        var endUnits: Double?
        var bolusRemainder: Double = 0
        var bookedUnits: Double = 0
        var notedShortfall = false

        var bolusID: String {
            WatchLoanAudit.auditBolusIDPrefix + (epoch.map(String.init) ?? "pod-\(Int(start.timeIntervalSince1970))")
        }
    }

    struct WatchLoop: Codable, Equatable {
        var epoch: Int64
        var at: Date
    }

    /// When the watch had the pump, for the chart's band. Nil end: it still has it.
    struct Span: Codable, Equatable {
        var start: Date
        var end: Date?
    }

    static let keptAudits = 20
    static let keptSpans = 50
    static let keptReplacedBookings = 512

    var audits: [Audit] = []
    var inbox = WatchLoanInbox()
    var lastBatchAt: Date?
    /// The watch's last confirmed loop, from its newest record batch.
    var watchLoop: WatchLoop?
    /// Watch bookings a kit record replaced, so a late batch carrying one doesn't store it again.
    var replacedBookings: [String]?
    /// The kit's latest foreign-session time this phone has handled, saved after the audit it caused.
    var lastForeignSessionHandled: Date?
    /// The last copy left with the watch for a start without the phone.
    var standingCopySentAt: Date?
    var spans: [Span]?

    mutating func save(_ audit: Audit) {
        audits.removeAll { $0.epoch == audit.epoch && $0.start == audit.start }
        audits.append(audit)
        if audits.count > Self.keptAudits { audits.removeFirst(audits.count - Self.keptAudits) }
    }
}

extension WatchLoanStore where State == WatchLoanLedger {
    static var ledger: WatchLoanStore {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return WatchLoanStore(url: documents.appendingPathComponent("watch-loan-ledger.json"))
    }
}

/// Runs the phone side of a loan: feeds events to `WatchLoan.decide` one at a time and executes its effects in order.
/// State is persisted before any pump action; pump results come back as epoch-tagged events.
actor WatchLoanCoordinator {
    /// Leaves room within `WatchLoan.phoneWorstCaseLend` for the temp cancel, the read and the release.
    static let defaultPumpIdleTimeout: TimeInterval = 40
    static let statusQueryTimeout: TimeInterval = 5
    /// Booked events this long before an audit window, to see a temp or suspend already running at its start.
    static let auditLookBehind: TimeInterval = 12 * 60 * 60

    let host: WatchLoanPhoneHost
    private let store: WatchLoanStore<PhoneLoanState>
    private let ledgerStore: WatchLoanStore<WatchLoanLedger>
    private let now: () -> Date
    private let pumpIdleTimeout: TimeInterval

    private(set) var state: PhoneLoanState
    private(set) var ledger: WatchLoanLedger
    private var queue: [PhoneLoanEvent] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isDraining = false
    private var pendingStatus: CheckedContinuation<WatchLoanState?, Never>?
    /// The loan whose pod the watch deactivated. Noted before the batch's merge, during which the hand-back can run.
    private var podDeactivatedInLoan: Int64?
    private var grantTimer: Task<Void, Never>?
    /// A grant part that didn't reach the watch: the grant goes again while it is valid, then the pump comes back.
    private var grantResend: Task<Void, Never>?
    /// Counts grant sends, so a failure reported for an earlier send doesn't start another.
    private var grantSends = 0
    /// Audits run one at a time: each reads its ledger entry, awaits the stores and writes the entry back.
    private var auditChain: Task<Void, Never>?
    private var isCheckingForeignSession = false
    /// The newest reading sent to the watch, so each goes once.
    private var lastForwardedReading: Date?
    /// Record batches are merged one at a time: each checks what is stored before storing, so batches that arrive
    /// together would otherwise each store the readings and carbs the others are about to store.
    private var recordsChain: Task<Void, Never>?
    /// When the watch-silence alarm was last armed; a burst of queued batches arms it once.
    private var silenceArmedAt: Date?

    init(
        host: WatchLoanPhoneHost,
        store: WatchLoanStore<PhoneLoanState> = .phone,
        ledgerStore: WatchLoanStore<WatchLoanLedger> = .ledger,
        now: @escaping () -> Date = Date.init,
        pumpIdleTimeout: TimeInterval = defaultPumpIdleTimeout
    ) {
        self.host = host
        self.store = store
        self.ledgerStore = ledgerStore
        self.now = now
        self.pumpIdleTimeout = pumpIdleTimeout
        switch store.load() {
        case let .success(state): self.state = state ?? .initial
        case .failure: state = .unreadable
        }
        switch ledgerStore.load() {
        case let .success(ledger): self.ledger = ledger ?? WatchLoanLedger()
        case let .failure(loadError):
            warning(.watch, "Watch loan records can't be read; audits fall back to the pod's whole life", error: loadError)
            ledger = WatchLoanLedger()
        }
    }

    func start() async {
        host.onForeignPodSession { [weak self] in
            Task { await self?.checkForeignSession() }
        }
        host.onGlucoseStored { [weak self] in
            Task { await self?.forwardReadings() }
        }
        await handle(.relaunched)
        await checkForeignSession()
    }

    /// Handles a foreign session the kit reports and this phone hasn't handled yet. It reads the kit's own
    /// persisted time, so a report lost to a crash or to launch order is handled at the next check.
    func checkForeignSession() async {
        guard !isCheckingForeignSession, let detectedAt = host.pump?.foreignSessionDetectedAt,
              detectedAt > ledger.lastForeignSessionHandled ?? .distantPast
        else { return }
        isCheckingForeignSession = true
        await handle(.foreignPodSession)
        ledger.lastForeignSessionHandled = detectedAt
        saveLedger()
        isCheckingForeignSession = false
        await checkForeignSession()
    }

    /// Queues `event` and returns once the queue, including results it caused, has run.
    func handle(_ event: PhoneLoanEvent) async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            enqueue(event)
        }
    }

    // MARK: - User actions

    /// In `lending`, asks the watch first: if it holds the pump, End on the watch is the safer way.
    func takeBack() async {
        var answer: WatchLoanState?
        if case let .lending(epoch, _) = state, host.transport?.isReachable == true {
            answer = await queryWatchStatus(epoch: epoch)
        }
        await handle(.takeBackTapped(watchAnswer: answer))
    }

    func usePodOnThisPhone() async {
        await handle(.usePodOnThisPhoneConfirmed)
    }

    /// The reply to the watch's status query: this phone's epoch, nothing while its state can't be read.
    func statusAnswer() -> [String: Any] {
        state.epoch.map { [WatchLoanWireKey.phoneEpoch: NSNumber(value: $0)] } ?? [:]
    }

    // MARK: - Transport in

    func receive(_ payload: [String: Any]) async {
        if let data = payload[WatchLoanWireKey.records] as? Data {
            await receiveRecords(data)
        }
        guard let data = payload[WatchLoanWireKey.message] as? Data else { return }
        switch WatchLoanWire.decode(data) {
        case let .stop(stop):
            await handle(.receivedStop(stop))
        case let .message(envelope):
            guard !ledger.inbox.seen.contains(envelope.messageID) else {
                debug(.watch, "Duplicate watch loan message dropped")
                return
            }
            let kind = String(describing: envelope.message.kind).prefix { $0 != "(" }
            info(
                .watch,
                "Watch loan message received: \(kind), epoch \(envelope.message.epoch), phone at epoch \(state.epoch.map(String.init) ?? "none")"
            )
            if case let .status(watchState) = envelope.message.kind, let pendingStatus {
                self.pendingStatus = nil
                pendingStatus.resume(returning: watchState)
            } else if WatchLoanInbox.passes(envelope.message, phoneEpoch: state.epoch) {
                // a batch that came in before this message is merged first, so a hand-back finds the watch's doses
                await recordsChain?.value
                await handle(.received(envelope.message))
            } else {
                debug(.watch, "Watch loan message from an older loan dropped")
            }
            // seen once handled: a crash before this lets the watch's resend through, and every row is idempotent
            _ = ledger.inbox.accept(envelope.messageID)
            saveLedger()
        case let .unsupportedVersion(version):
            warning(.watch, "Watch loan message from protocol version \(version) dropped")
        case .malformed:
            warning(.watch, "Malformed watch loan message dropped")
        }
    }

    private func receiveRecords(_ data: Data) async {
        let previous = recordsChain
        let next = Task {
            await previous?.value
            await self.mergeRecords(data)
        }
        recordsChain = next
        await next.value
    }

    private func mergeRecords(_ data: Data) async {
        guard var batch = try? WatchLoanRecordBatch.decode(data), batch.version == WatchLoanRecordBatch.currentVersion else {
            warning(.watch, "Watch record batch can't be read; not acknowledged")
            return
        }
        if ledger.inbox.seen.contains(batch.batchID) {
            acknowledge(batch)
            return
        }
        if batch.podDeactivatedAt != nil { podDeactivatedInLoan = batch.epoch }
        let replaced = Set(ledger.replacedBookings ?? [])
        batch.pumpEvents.removeAll { $0.newPumpEvent.dose?.syncIdentifier.map(replaced.contains) ?? false }
        do {
            try await host.merge(batch)
        } catch {
            warning(.storage, "Storing watch records failed; not acknowledged", error: error)
            return
        }
        _ = ledger.inbox.accept(batch.batchID)
        let replacing = batch.pumpEvents.compactMap(\.replacesSyncIdentifier)
        if !replacing.isEmpty {
            ledger
                .replacedBookings = Array(
                    ((ledger.replacedBookings ?? []) + replacing)
                        .suffix(WatchLoanLedger.keptReplacedBookings)
                )
        }
        if case let .lent(epoch) = state, epoch == batch.epoch {
            ledger.lastBatchAt = now()
            if silenceArmedAt.map({ now().timeIntervalSince($0) >= Self.silenceRearmInterval }) ?? true {
                setAlarm(.phoneNoWatchUpdates, armed: true, anchor: now())
            }
        }
        if let at = batch.lastLoopAt, ledger.watchLoop.map({ ($0.epoch, $0.at) < (batch.epoch, at) }) ?? true {
            ledger.watchLoop = WatchLoanLedger.WatchLoop(epoch: batch.epoch, at: at)
            // the phone doesn't loop while the watch holds the pump, so its loop timer follows the watch's loop
            host.noteWatchLoop(at: at)
            announceWatchMode()
        }
        saveLedger()
        acknowledge(batch)
        info(.watch, "Watch records stored: \(batch.pumpEvents.count) pump events, \(batch.carbs.count) carb entries")
        await forgetPodIfDeactivated()

        await recomputeAudits(after: batch)
        if WatchLoanInbox.passes(WatchLoanMessage(epoch: batch.epoch, kind: .records), phoneEpoch: state.epoch) {
            await handle(.received(WatchLoanMessage(epoch: batch.epoch, kind: .records)))
        }
    }

    private func acknowledge(_ batch: WatchLoanRecordBatch) {
        guard let data = try? JSONEncoder().encode(WatchLoanRecordAck(epoch: batch.epoch, batchID: batch.batchID)) else { return }
        host.transport?.send([WatchLoanWireKey.recordsAck: data])
    }

    // MARK: - Queue

    private func enqueue(_ event: PhoneLoanEvent) {
        queue.append(event)
        guard !isDraining else { return }
        isDraining = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            await process(queue.removeFirst())
        }
        isDraining = false
        let finished = waiters
        waiters = []
        finished.forEach { $0.resume() }
    }

    private func process(_ event: PhoneLoanEvent) async {
        var context = PhoneLoanContext(now: now(), standingCopyOut: host.standingCopyAllowed && ledger.standingCopySentAt != nil)
        if case let .received(message) = event, case .request = message.kind, case .home = state {
            context.startRefusal = await host.startRefusal()
            if let refusal = context.startRefusal { info(.watch, "Trio on Watch start refused: \(refusal.rawValue)") }
        }
        let (next, effects) = WatchLoan.decide(state, event, context)
        if next != state { info(.watch, "Watch loan: \(state.logName) to \(next.logName)") }
        for effect in effects {
            guard await execute(effect, event: event) else { return }
        }
    }

    // MARK: - Readings for the watch

    /// Sends the watch the phone's readings it hasn't sent yet. The watch uses one only when its own sensor missed it.
    func forwardReadings() async {
        guard case let .lent(epoch) = state else {
            lastForwardedReading = nil
            return
        }
        let readings = await host.recentGlucose()
            .filter { $0.dateString > lastForwardedReading ?? .distantPast }
        guard let newest = readings.map(\.dateString).max(),
              let data = try? WatchLoanPhoneReadings(epoch: epoch, readings: readings).encoded()
        else { return }
        lastForwardedReading = newest
        host.transport?.send([WatchLoanWireKey.phoneReadings: data])
        debug(.watch, "Sent the watch \(readings.count) phone readings, newest \(newest)")
    }

    /// Batches closer together than this re-arm the watch-silence alarm once: its first warning is 30 min out.
    static let silenceRearmInterval: TimeInterval = 60

    private func setAlarm(_ alarm: LoanAlarm, armed: Bool, anchor: Date) {
        if alarm == .phoneNoWatchUpdates { silenceArmedAt = armed ? now() : nil }
        host.setAlarm(alarm, armed: armed, anchor: anchor)
    }

    // MARK: - Live Activity

    /// Watch mode as the Live Activity shows it: from asking the watch to start until the phone has the pump back.
    var watchMode: LiveActivityAttributes.WatchMode? {
        guard state.isLent, let epoch = state.epoch else { return nil }
        return LiveActivityAttributes.WatchMode(
            since: ledger.audits.last { $0.epoch == epoch }?.start ?? now(),
            lastLoop: ledger.watchLoop.flatMap { $0.epoch == epoch ? $0.at : nil }
        )
    }

    private func announceWatchMode() {
        let mode = watchMode
        Task { @MainActor in
            Foundation.NotificationCenter.default.post(
                name: .trioOnWatchModeDidChange,
                object: nil,
                userInfo: ["mode": mode as Any]
            )
        }
    }

    // MARK: - Effects

    /// False stops the rest of the list.
    private func execute(_ effect: PhoneLoanEffect, event: PhoneLoanEvent) async -> Bool {
        switch effect {
        case let .persist(next):
            do {
                try store.save(next)
            } catch let saveError {
                error(.watch, "Saving the watch loan state failed; nothing more is done", error: saveError)
                // A lend abandoned here never reached `lending`, so no `releaseResult` will tell the watch.
                // Refuse the request outright so it leaves `requesting` now instead of waiting out its timeout.
                if case .lending = next, case let .received(message) = event, case let .request(requestID) = message.kind {
                    warning(.watch, "Lend abandoned before it could start; refusing the watch request")
                    send(WatchLoanMessage(
                        epoch: state.epoch ?? message.epoch,
                        kind: .refused(requestID: requestID, reason: .busy)
                    ))
                }
                return false
            }
            let previous = state
            state = next
            noteSpan(next)
            if previous.loan?.supersededUntil != nil, next.loan?.supersededUntil == nil, previous.loan?.epoch == next.loan?.epoch,
               let pump = host.pump
            {
                // the superseded watch confirmed it let go of the pod
                await pump.endSuperseding()
            }
            if case .takingBack = previous, case .home = next {
                host.didReturnHome()
            }
            if previous.isLent != next.isLent { announceWatchMode() }

        case .awaitPumpIdle:
            guard await finishes(within: pumpIdleTimeout, { [host] in await host.awaitPumpIdle() }) else {
                warning(.watch, "Trio on Watch start stopped: the loop, a bolus or pump events didn't finish in time")
                return failPumpStep()
            }

        case .cancelTemp:
            // a pod the watch deactivated is forgotten here: no temp to cancel, no total to read
            if case .takingBack = state, host.pump?.startedAt == nil { break }
            guard let pump = host.pump else { return failPumpStep() }
            do {
                try await pump.cancelTempBasal()
            } catch {
                warning(.pump, "Cancelling the temp basal for the hand-off failed", error: error)
                return failPumpStep()
            }

        case .refreshDeliveredUnits:
            if case .takingBack = state, host.pump?.startedAt == nil { break }
            guard let pump = host.pump, await pump.refreshDeliveredUnits(), let reading = pump.deliveredUnits else {
                warning(.pump, "Reading the pump's delivered total for the hand-off failed")
                return failPumpStep()
            }
            if case let .lending(epoch, _) = state {
                ledger.save(WatchLoanLedger.Audit(
                    epoch: epoch,
                    start: reading.at,
                    startUnits: reading.units,
                    basalProfile: await host.basalProfile(),
                    timeZoneIdentifier: pump.status.timeZone.identifier,
                    pulse: pump.pulse
                ))
                saveLedger()
            }

        case .releaseControl:
            let epoch = state.epoch ?? 0
            guard let pump = host.pump else {
                enqueue(.releaseResult(epoch: epoch, released: false))
                return false
            }
            // standing aside for a watch that started without the phone: the window starts at the phone's last own
            // reading, not touching the pod, so the hand-back's audit covers exactly the watch's loan
            if case let .lent(lentEpoch) = state, !ledger.audits.contains(where: { $0.epoch == lentEpoch }),
               let reading = pump.deliveredUnits
            {
                ledger.save(WatchLoanLedger.Audit(
                    epoch: lentEpoch,
                    start: reading.at,
                    startUnits: reading.units,
                    basalProfile: await host.basalProfile(),
                    timeZoneIdentifier: pump.status.timeZone.identifier,
                    pulse: pump.pulse
                ))
                saveLedger()
            }
            let released = await pump.release()
            info(.pump, released ? "Pump released for Apple Watch" : "The pump refused the release")
            enqueue(.releaseResult(epoch: epoch, released: released))

        case let .takeControl(until):
            let epoch = state.epoch ?? 0
            guard let pump = host.pump else {
                enqueue(.takeControlResult(epoch: epoch, succeeded: false))
                return false
            }
            // no window and no known peer: the user chose this phone (or the state file was lost)
            let take: WatchLoanPumpAdapter.Take = until.map { .superseding(until: $0) }
                ?? (state.loan.map { $0.epoch == nil } == true ? .liftingRefusal : .plain)
            await forgetPodIfDeactivated()
            let succeeded = await pump.take(take)
            info(.pump, succeeded ? "Pump taken back" : "Taking the pump back failed")
            enqueue(.takeControlResult(epoch: epoch, succeeded: succeeded))

        case .adoptControl:
            break

        case let .audit(scope):
            if case .foreignPodSession = event, let pump = host.pump, pump.holdsPod {
                _ = await pump.refreshDeliveredUnits()
            }
            await audit(scope)

        case let .podSession(verdict):
            guard let pump = host.pump else { break }
            switch verdict {
            case let .keepCommanding(until): await pump.keepSuperseding(until: until)
            case .refuse:
                // stop now, even if the kit's own scope hasn't run out; Use the pod on this iPhone lifts it
                await pump.endSuperseding()
                _ = await pump.release()
            }

        case .cancelOutstandingTransfers:
            host.transport?.cancelOutstandingLoanTransfers()

        case let .send(message):
            if case .grant = message.kind {
                await sendGrant(message)
            } else {
                send(message)
            }

        case let .sendStop(stop):
            guard let data = try? WatchLoanWire.encode(stop) else { break }
            host.transport?.send([WatchLoanWireKey.message: data])

        case let .arm(alarm):
            var anchor = now()
            if alarm == .phoneNotLooping, case .home = state {
                // at home the phone's own loop dates anchor the series, as without a loan
                anchor = .distantPast
            }
            if alarm == .phoneNoWatchUpdates {
                if case .relaunched = event, let lastBatchAt = ledger.lastBatchAt {
                    anchor = lastBatchAt
                } else {
                    ledger.lastBatchAt = anchor
                    saveLedger()
                }
            }
            setAlarm(alarm, armed: true, anchor: anchor)

        case let .disarm(alarm):
            setAlarm(alarm, armed: false, anchor: now())

        case let .alert(alert):
            host.alert(alert)
        }
        return true
    }

    /// Before any take: a take first would resume the dead pod and look for it. The kit forgets only a released pod
    /// it still has, so a repeat, or a pod this phone holds, is a no-op.
    private func forgetPodIfDeactivated() async {
        guard let epoch = podDeactivatedInLoan, state.epoch == epoch || state.loan?.epoch == epoch, let pump = host.pump,
              pump.isReleased
        else { return }
        podDeactivatedInLoan = nil
        await pump.forgetDeactivatedElsewhere()
        info(.pump, "The watch deactivated the faulted pod; forgotten on this iPhone")
    }

    /// A failed pump step: a lend reports the release as refused, a take-back keeps the pump closed and tells the user.
    private func failPumpStep() -> Bool {
        switch state {
        case let .lending(epoch, _):
            enqueue(.releaseResult(epoch: epoch, released: false))
        case .takingBack:
            host.alert(.takeBackPodUnreachable)
        default:
            break
        }
        return false
    }

    private func send(_ message: WatchLoanMessage) {
        let envelope = WatchLoanEnvelope(
            protocolVersion: WatchLoanEnvelope.currentProtocolVersion,
            messageID: UUID(),
            sentAt: now(),
            message: message
        )
        guard let data = try? WatchLoanWire.encode(envelope) else { return }
        host.transport?.send([WatchLoanWireKey.message: data])
    }

    /// Exports and sends only after the release held. Any failure counts as the watch rejecting the grant,
    /// so the phone takes the pump back at once: the watch never had it.
    private func sendGrant(_ message: WatchLoanMessage) async {
        guard case let .grant(requestID, expiresAt) = message.kind, case let .lending(epoch, _) = state else { return }
        func reject(_ reason: LoanRefusal) {
            rejectGrant(epoch: epoch, requestID: requestID, reason: reason)
        }
        grantSends += 1
        let send = grantSends
        let partFailed: (Error) -> Void = { [weak self] _ in
            Task { await self?.grantPartFailed(message, send: send) }
        }
        guard let pump = host.pump, pump.isReleased,
              let audit = ledger.audits.last(where: { $0.epoch == epoch })
        else { return reject(.releaseRefused) }

        let snapshotData: Data
        var builtSnapshot: WatchLoanSnapshot?
        do {
            let snapshot = try await host.snapshot(
                requestID: requestID,
                epoch: epoch,
                expiresAt: expiresAt,
                release: WatchLoanSnapshot.OdometerReading(units: audit.startUnits, at: audit.start),
                pump: pump,
                asCopy: false
            )
            guard snapshot.missingParts.isEmpty else {
                warning(.watch, "Grant snapshot incomplete: \(snapshot.missingParts.joined(separator: ", "))")
                return reject(.snapshotIncomplete)
            }
            snapshotData = try snapshot.encoded()
            builtSnapshot = snapshot
        } catch {
            warning(.watch, "Building the grant snapshot failed", error: error)
            return reject(.snapshotIncomplete)
        }

        let envelope = WatchLoanEnvelope(
            protocolVersion: WatchLoanEnvelope.currentProtocolVersion,
            messageID: UUID(),
            sentAt: now(),
            message: message
        )
        guard let messageData = try? WatchLoanWire.encode(envelope) else { return reject(.snapshotIncomplete) }
        let size = messageData.count + snapshotData.count
        if size <= WatchLoanSnapshot.grantBudgetBytes {
            guard host.transport?.sendLive(
                [WatchLoanWireKey.message: messageData, WatchLoanWireKey.snapshot: snapshotData],
                failed: partFailed
            ) == true
            else { return resendLater(message) }
            info(.watch, "Grant sent to Apple Watch, \(size) bytes")
        } else {
            let pieces = WatchLoanSnapshot.split(snapshotData, requestID: requestID, epoch: epoch)
            let parts = builtSnapshot?.partSizes().map { "\($0.part) \($0.bytes) B (\($0.count))" }.joined(separator: ", ")
            guard pieces.count <= WatchLoanSnapshot.maxParts else {
                warning(.watch, "Grant too large even in \(WatchLoanSnapshot.maxParts) parts: \(size) bytes; \(parts ?? "")")
                return reject(.snapshotIncomplete)
            }
            let encoder = JSONEncoder()
            for (offset, piece) in pieces.enumerated() {
                guard let header = try? encoder.encode(piece.header) else { return reject(.snapshotIncomplete) }
                var payload: [String: Any] = [
                    WatchLoanWireKey.snapshotPartHeader: header,
                    WatchLoanWireKey.snapshotPart: piece.bytes
                ]
                if offset == pieces.count - 1 { payload[WatchLoanWireKey.message] = messageData }
                guard host.transport?.sendLive(payload, failed: partFailed) == true else { return resendLater(message) }
            }
            info(.watch, "Grant sent to Apple Watch, \(size) bytes in \(pieces.count) parts")
            if let parts { info(.watch, "Grant parts, compressed: \(parts)") }
        }
        grantTimer?.cancel()
        grantTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WatchLoan.grantConfirmTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.handle(.grantUnconfirmed)
        }
    }

    // MARK: - The copy for a start without the phone

    /// After each of the phone's own loops: the newest copy, built as a grant's snapshot without releasing the pod.
    /// Exporting the pod marks it shared, so the phone's driver refuses a pod another controller used since.
    func sendStandingCopy() async {
        // a bolus under way would be in the copy's history whole but only partly in its pump total: the last copy stands
        guard host.standingCopyAllowed, case let .home(epoch, _) = state, let pump = host.pump,
              pump.status.bolusState == .noBolus, let reading = pump.deliveredUnits
        else { return }
        do {
            let snapshot = try await host.snapshot(
                requestID: UUID(),
                epoch: epoch,
                expiresAt: now(),
                release: WatchLoanSnapshot.OdometerReading(units: reading.units, at: reading.at),
                pump: pump,
                asCopy: true
            )
            guard snapshot.missingParts.isEmpty else {
                debug(.watch, "Copy for Apple Watch incomplete: \(snapshot.missingParts.joined(separator: ", "))")
                return
            }
            let data = try snapshot.encoded()
            host.transport?.sendNewest([WatchLoanWireKey.standingCopy: data], key: WatchLoanWireKey.standingCopy)
            ledger.standingCopySentAt = now()
            saveLedger()
            debug(.watch, "Copy left with Apple Watch, \(data.count) bytes")
        } catch {
            warning(.watch, "Copy for Apple Watch not built", error: error)
        }
    }

    private func rejectGrant(epoch: Int64, requestID: UUID, reason: LoanRefusal) {
        warning(.watch, "Grant not sent to Apple Watch: \(reason.rawValue)")
        enqueue(.received(WatchLoanMessage(epoch: epoch, kind: .grantRejected(requestID: requestID, reason: reason))))
    }

    static let grantResendPoll: UInt64 = 500_000_000

    /// The pump is released, so a grant the watch never got leaves nothing in control: send it again once the watch
    /// is reachable, or take the pump back once the grant has expired.
    private func grantPartFailed(_ message: WatchLoanMessage, send: Int) {
        guard send == grantSends else { return }
        resendLater(message, "Part of the grant didn't reach Apple Watch; sending it again")
    }

    private func resendLater(
        _ message: WatchLoanMessage,
        _ why: String = "Apple Watch isn't reachable for the grant; sending it once it is"
    ) {
        guard case let .grant(requestID, _) = message.kind, case let .lending(_, current) = state, current == requestID,
              grantResend == nil
        else { return }
        warning(.watch, why)
        grantResend = Task { [weak self] in await self?.resendGrant(message) }
    }

    private func resendGrant(_ message: WatchLoanMessage) async {
        guard case let .grant(requestID, expiresAt) = message.kind else { return }
        while !Task.isCancelled {
            guard case let .lending(epoch, current) = state, current == requestID else { break }
            if now() >= expiresAt {
                grantResend = nil
                warning(.watch, "The grant didn't reach Apple Watch before it expired; taking the pump back")
                rejectGrant(epoch: epoch, requestID: requestID, reason: .grantExpired)
                return
            }
            if host.transport?.isReachable == true {
                grantResend = nil
                await sendGrant(message)
                return
            }
            try? await Task.sleep(nanoseconds: Self.grantResendPoll)
        }
        grantResend = nil
    }

    // MARK: - Audit

    private func audit(_ scope: AuditScope) async {
        await serializedAudit { await self.auditNow(scope) }
    }

    private func serializedAudit(_ work: @escaping () async -> Void) async {
        let previous = auditChain
        let task = Task {
            await previous?.value
            await work()
        }
        auditChain = task
        await task.value
    }

    private func auditNow(_ scope: AuditScope) async {
        let pump = host.pump
        var entry: WatchLoanLedger.Audit
        if case let .loan(epoch) = scope, let loanAudit = ledger.audits.last(where: { $0.epoch == epoch }) {
            entry = loanAudit
        } else if let pump, let started = pump.startedAt {
            if case .loan = scope { warning(.watch, "No release reading for this loan; auditing the pod's whole life") }
            let basalProfile = await host.basalProfile()
            entry = ledger.audits.last(where: { $0.epoch == nil && $0.start == started }) ?? WatchLoanLedger.Audit(
                epoch: nil,
                start: started,
                startUnits: 0,
                basalProfile: basalProfile,
                timeZoneIdentifier: pump.status.timeZone.identifier,
                pulse: pump.pulse
            )
        } else {
            warning(.watch, "Delivered-total audit unavailable: no release reading and no pod activation time")
            return
        }

        if let pump, let reading = pump.deliveredUnits {
            // a faulted pod's total is final; only a fault reading from before the window can't be used
            if pump.isFaulted, reading.at < entry.start {
                warning(.watch, "Delivered-total audit skipped: the faulted pod's last total predates the window")
                host.alert(.podTotalUnreliable)
                return
            }
            if reading.at >= entry.end ?? .distantPast, reading.at >= entry.start {
                guard reading.units >= entry.endUnits ?? entry.startUnits else {
                    warning(.watch, "Delivered-total audit skipped: the pod's delivered total went down")
                    host.alert(.podTotalUnreliable)
                    return
                }
                entry.end = reading.at
                entry.endUnits = reading.units
                // a faulted pod delivers nothing more
                entry.bolusRemainder = pump.isFaulted ? 0 : pump.bolusRemainder(at: reading.at)
            }
        }
        await recompute(&entry)
        ledger.save(entry)
        saveLedger()
    }

    /// Late records explain more of the window: recompute its audit bolus (replace, never add).
    private func recomputeAudits(after batch: WatchLoanRecordBatch) async {
        await serializedAudit {
            guard var entry = await self.ledger.audits.last(where: { $0.epoch == batch.epoch && $0.end != nil })
                ?? self.ledger.audits.last(where: { $0.epoch == nil && $0.end != nil })
            else { return }
            await self.recompute(&entry)
            await self.saveAudit(entry)
        }
    }

    private func saveAudit(_ entry: WatchLoanLedger.Audit) {
        ledger.save(entry)
        saveLedger()
    }

    private func recompute(_ entry: inout WatchLoanLedger.Audit) async {
        guard let end = entry.end, let endUnits = entry.endUnits,
              let timeZone = TimeZone(identifier: entry.timeZoneIdentifier)
        else { return }
        let events: [PumpHistoryEvent]
        do {
            events = try await host.bookedEvents(since: entry.start.addingTimeInterval(-Self.auditLookBehind))
        } catch {
            warning(.storage, "Reading pump history for the delivered-total audit failed", error: error)
            return
        }
        let input = WatchLoanAudit.Input(
            start: entry.start,
            startUnits: entry.startUnits,
            end: end,
            endUnits: endUnits,
            bolusRemainder: entry.bolusRemainder,
            basalProfile: entry.basalProfile,
            timeZone: timeZone,
            pulse: entry.pulse,
            events: events,
            ownBolusID: entry.bolusID
        )
        let result = WatchLoanAudit.evaluate(input)
        if result.unexplained != entry.bookedUnits {
            do {
                try await host.replaceAuditBolus(id: entry.bolusID, units: result.unexplained, at: end)
            } catch {
                warning(.storage, "Booking the audit insulin failed", error: error)
                return
            }
        }
        if result.unexplained > entry.bookedUnits {
            info(.watch, "Delivered-total audit booked insulin no record explains")
            host.auditNotice(units: result.unexplained, isShortfall: false)
        } else if result.isShortfall, !entry.notedShortfall {
            info(.watch, "Delivered-total audit: the pump delivered less than booked")
            host.auditNotice(units: result.expected - result.actual, isShortfall: true)
            entry.notedShortfall = true
        }
        entry.bookedUnits = result.unexplained
    }

    // MARK: - Helpers

    private func queryWatchStatus(epoch: Int64) async -> WatchLoanState? {
        await withCheckedContinuation { continuation in
            pendingStatus = continuation
            send(WatchLoanMessage(epoch: epoch, kind: .statusQuery))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.statusQueryTimeout * 1_000_000_000))
                await self?.resolveStatusQuery(nil)
            }
        }
    }

    private func resolveStatusQuery(_ answer: WatchLoanState?) {
        guard let pendingStatus else { return }
        self.pendingStatus = nil
        pendingStatus.resume(returning: answer)
    }

    /// The chart's band: from lent until the phone is home again.
    private func noteSpan(_ next: PhoneLoanState) {
        var spans = ledger.spans ?? []
        if case .lent = next, spans.last.map({ $0.end != nil }) ?? true {
            spans.append(WatchLoanLedger.Span(start: now()))
        } else if case .home = next, !spans.isEmpty, spans[spans.count - 1].end == nil {
            spans[spans.count - 1].end = now()
        } else {
            return
        }
        ledger.spans = Array(spans.suffix(WatchLoanLedger.keptSpans))
        saveLedger()
    }

    private func saveLedger() {
        do {
            try ledgerStore.save(ledger)
        } catch let saveError {
            warning(.storage, "Saving the watch loan records failed", error: saveError)
        }
    }

    private func finishes(within seconds: TimeInterval, _ work: @escaping () async -> Void) async -> Bool {
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            let worker = Task {
                await work()
                once.resume(continuation, returning: true)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                worker.cancel()
                once.resume(continuation, returning: false)
            }
        }
    }
}

private final class ResumeOnce {
    private let lock = NSLock()
    private var done = false

    func resume(_ continuation: CheckedContinuation<Bool, Never>, returning value: Bool) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { continuation.resume(returning: value) }
    }
}

extension PhoneLoanState {
    var loan: LoanRecord? {
        switch self {
        case let .home(_, lastLoan): return lastLoan
        case let .takingBack(_, loan): return loan
        case .lending,
             .lent,
             .unreadable: return nil
        }
    }

    var logName: String {
        switch self {
        case let .home(epoch, _): return "home (epoch \(epoch))"
        case let .lending(epoch, _): return "lending (epoch \(epoch))"
        case let .lent(epoch): return "lent (epoch \(epoch))"
        case let .takingBack(epoch, _): return "taking back (epoch \(epoch))"
        case .unreadable: return "unreadable"
        }
    }
}

extension Notification.Name {
    /// `userInfo["mode"]` is the `LiveActivityAttributes.WatchMode?` now shown.
    static let trioOnWatchModeDidChange = Notification.Name("trioOnWatchModeDidChange")
}

extension PhoneLoanState {
    /// The watch has the pump, or is being given it or giving it back.
    var isLent: Bool {
        switch self {
        case .lending,
             .lent,
             .takingBack: return true
        case .home,
             .unreadable: return false
        }
    }
}
