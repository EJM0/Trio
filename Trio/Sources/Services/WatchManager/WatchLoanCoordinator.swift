import Foundation

protocol WatchLoanTransport: AnyObject {
    var isReachable: Bool { get }
    /// A live message only. False when the watch isn't reachable.
    func sendLive(_ payload: [String: Any]) -> Bool
    /// Live when reachable, otherwise queued for delivery.
    func send(_ payload: [String: Any])
    func cancelOutstandingLoanTransfers()
}

/// What the coordinator needs from the rest of the app.
protocol WatchLoanPhoneHost: AnyObject {
    var pump: WatchLoanPumpAdapter? { get }
    var transport: WatchLoanTransport? { get }
    func startRefusal() async -> LoanRefusal?
    func awaitPumpIdle() async
    func snapshot(
        requestID: UUID,
        epoch: Int64,
        expiresAt: Date,
        release: WatchLoanSnapshot.OdometerReading,
        pump: WatchLoanPumpAdapter
    ) async throws -> WatchLoanSnapshot
    func merge(_ batch: WatchLoanRecordBatch) async throws
    func bookedEvents(since date: Date) async throws -> [PumpHistoryEvent]
    func replaceAuditBolus(id: String, units: Double, at date: Date) async throws
    func basalProfile() async -> [BasalProfileEntry]
    func setAlarm(_ alarm: LoanAlarm, armed: Bool, anchor: Date)
    func alert(_ alert: LoanAlert)
    func auditNotice(units: Double, isShortfall: Bool)
    func didReturnHome()
    func onForeignPodSession(_ action: @escaping () -> Void)
    /// What the watch's Start screen shows before the user confirms.
    func startFacts() async -> WatchLoanStartFacts
}

extension WatchLoanPhoneHost {
    func startFacts() async -> WatchLoanStartFacts { WatchLoanStartFacts() }
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

    static let keptAudits = 20
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
    private var grantTimer: Task<Void, Never>?
    /// Audits run one at a time: each reads its ledger entry, awaits the stores and writes the entry back.
    private var auditChain: Task<Void, Never>?
    private var isCheckingForeignSession = false

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
            if case let .status(watchState) = envelope.message.kind, let pendingStatus {
                self.pendingStatus = nil
                pendingStatus.resume(returning: watchState)
            } else if WatchLoanInbox.passes(envelope.message, phoneEpoch: state.epoch) {
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
        guard var batch = try? WatchLoanRecordBatch.decode(data), batch.version == WatchLoanRecordBatch.currentVersion else {
            warning(.watch, "Watch record batch can't be read; not acknowledged")
            return
        }
        if ledger.inbox.seen.contains(batch.batchID) {
            acknowledge(batch)
            return
        }
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
            host.setAlarm(.phoneNoWatchUpdates, armed: true, anchor: ledger.lastBatchAt ?? now())
        }
        if let at = batch.lastLoopAt, ledger.watchLoop.map({ ($0.epoch, $0.at) < (batch.epoch, at) }) ?? true {
            ledger.watchLoop = WatchLoanLedger.WatchLoop(epoch: batch.epoch, at: at)
        }
        saveLedger()
        acknowledge(batch)
        info(.watch, "Watch records stored: \(batch.pumpEvents.count) pump events, \(batch.carbs.count) carb entries")

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
        var context = PhoneLoanContext(now: now())
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

    // MARK: - Effects

    /// False stops the rest of the list.
    private func execute(_ effect: PhoneLoanEffect, event: PhoneLoanEvent) async -> Bool {
        switch effect {
        case let .persist(next):
            do {
                try store.save(next)
            } catch let saveError {
                error(.watch, "Saving the watch loan state failed; nothing more is done", error: saveError)
                return false
            }
            let previous = state
            state = next
            if previous.loan?.supersededUntil != nil, next.loan?.supersededUntil == nil, previous.loan?.epoch == next.loan?.epoch,
               let pump = host.pump
            {
                // the superseded watch confirmed it let go of the pod
                await pump.endSuperseding()
            }
            if case .takingBack = previous, case .home = next {
                host.didReturnHome()
            }

        case .awaitPumpIdle:
            guard await finishes(within: pumpIdleTimeout, { [host] in await host.awaitPumpIdle() }) else {
                warning(.watch, "Trio on Watch start stopped: the loop, a bolus or pump events didn't finish in time")
                return failPumpStep()
            }

        case .cancelTemp:
            guard let pump = host.pump else { return failPumpStep() }
            do {
                try await pump.cancelTempBasal()
            } catch {
                warning(.pump, "Cancelling the temp basal for the hand-off failed", error: error)
                return failPumpStep()
            }

        case .refreshDeliveredUnits:
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
            host.setAlarm(alarm, armed: true, anchor: anchor)

        case let .disarm(alarm):
            host.setAlarm(alarm, armed: false, anchor: now())

        case let .alert(alert):
            host.alert(alert)
        }
        return true
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
            warning(.watch, "Grant not sent to Apple Watch: \(reason.rawValue)")
            // otherwise the watch waits until its request times out
            send(WatchLoanMessage(epoch: epoch, kind: .refused(requestID: requestID, reason: reason)))
            enqueue(.received(WatchLoanMessage(epoch: epoch, kind: .grantRejected(requestID: requestID, reason: reason))))
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
                pump: pump
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
            guard host.transport?.sendLive([WatchLoanWireKey.message: messageData, WatchLoanWireKey.snapshot: snapshotData]) ==
                true
            else { return reject(.phoneUnreachable) }
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
                guard host.transport?.sendLive(payload) == true else { return reject(.phoneUnreachable) }
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
