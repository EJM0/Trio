import Foundation
import LoopKit
import UserNotifications
import WatchConnectivity
import WatchKit

/// The watch's side of untethered mode: takes the pump from the phone, loops with its own pump and
/// CGM connections, and gives the pump and its history back. Everything runs on the main queue,
/// device delegates included; every change is persisted before it is acted on.
@Observable final class UntetheredWatchManager {
    static let shared = UntetheredWatchManager()

    @ObservationIgnored let store = UntetheredStore()
    /// What the screens read, refreshed after every change.
    private(set) var data: UntetheredWatchData
    /// Taking over or handing back.
    private(set) var isBusy = false

    @ObservationIgnored var pumpManager: (PumpManager & ExclusiveDeviceControl)?
    @ObservationIgnored var cgmManager: CGMManager?
    @ObservationIgnored var isLooping = false
    /// A treatment came in while a loop ran; its determination follows.
    @ObservationIgnored var isDeterminationPending = false
    /// A mode changed while a loop ran; its constrained determination and enactment follow.
    @ObservationIgnored var isModeChangePending = false
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let assembler = UntetheredChunks.Assembler()
    @ObservationIgnored var loopTimer: Timer?
    /// Keeps the loop's age and the stale-data checks on screen current between loops.
    @ObservationIgnored private var displayTimer: Timer?
    /// The pump is delivering a bolus: no hand-back, and the treatment button stops it.
    private(set) var isBolusing = false
    /// The running bolus from start to end, for its progress; nil while it is being started.
    private(set) var bolusWindow: DateInterval?
    @ObservationIgnored private var bolusEndTimer: Timer?
    /// When the pod link was last torn down and searched for afresh (`checkPodLink`).
    @ObservationIgnored var lastPodLinkReset: Date?
    /// A sensor pairing is due: Trio has to be in front for its Bluetooth pairing request.
    var isPairingSensor = false
    @ObservationIgnored var pairingKeepAlive: SensorPairingKeepAlive?

    /// Records travel in batches small enough for an interactive message.
    private static let recordsPerMessage = 40
    /// Keep a small pipeline in flight: one-at-a-time made a large history take many phone round trips, while
    /// sending the whole backlog at once could clog WatchConnectivity's durable queue.
    private static let batchesInFlightLimit = 4
    private static let recordAckTimeout: TimeInterval = 30
    /// After a batch failed with the phone in reach: no tight loop of sends that keep failing.
    private static let retryDelay: TimeInterval = 15
    @ObservationIgnored private var streamTimer: Timer?
    /// The hand-back's last stage: no loop or bolus between the pod's last read and the phone taking it.
    @ObservationIgnored var isFinalizing = false
    /// How long the hand-back's backlog may take before the rest goes with the last records.
    private static let drainLimit: TimeInterval = 3 * 60
    /// How long the last records may take to be confirmed before the pump is offered anyway.
    private static let finalConfirmLimit: TimeInterval = 30
    /// Batches the phone has not confirmed storing yet. This also bounds durable transfers while the phone is away.
    @ObservationIgnored private var recordFlights: [UUID: (ids: Set<UUID>, sentAt: Date)] = [:]
    private static let takeoverReadInterval: UInt64 = 8_000_000_000
    /// One recent, valid watch reading proves the watch's own sensor link is live; phone liveness has separate checks.
    private static let fallbackMissedReadings = 1
    /// The phone's sensor feed and successful loop must both be this old before takeover is considered.
    private static let fallbackPhoneStaleInterval: TimeInterval = 10 * 60
    /// Standby readings older than this cannot prove that the watch's own sensor link is live.
    private static let fallbackWatchReadingFreshness: TimeInterval = 12 * 60
    /// Before takeover, one direct app-level health check gets one chance; reachability alone is not app liveness.
    private static let fallbackHealthResponseTimeout: TimeInterval = 15
    private static let fallbackHealthRequestLimit = 1
    private static let fallbackHealthFreshness: TimeInterval = 30
    private static let fallbackHealthReadingInterval: TimeInterval = 5 * 60
    @ObservationIgnored private var fallbackPhoneHealth: FallbackPhoneHealth?
    /// Mirrored in the store so an app relaunch can finish an in-flight fallback probe.
    @ObservationIgnored private var fallbackTriedAfter: Date?
    @ObservationIgnored private var fallbackHealthRequestID: UUID?
    @ObservationIgnored private var fallbackHealthRequestSentAt: Date?
    @ObservationIgnored private var fallbackHealthRequestCount = 0
    @ObservationIgnored private var fallbackCheckScheduledAt: Date?
    @ObservationIgnored private var fallbackHandbackRequestedAt: Date?
    /// A missing standing grant is asked for at most this often, the standby link's readings asking again.
    private static let standingGrantRequestInterval: TimeInterval = 5 * 60
    @ObservationIgnored private var standingGrantRequestedAt: Date?
    /// An unanswered automatic hand-back was given up then: the phone's next asks wait this long, so a phone that never
    /// acknowledges doesn't keep the watch from dosing.
    @ObservationIgnored private var handbackAbandonedAt: Date?
    private static let handbackRetryDelay: TimeInterval = 10 * 60

    private struct FallbackPhoneHealth {
        let checkedAt: Date
        /// The last successful loop detects an outage before takeover.
        let lastLoopDate: Date
        /// Successful loops are intentionally blocked while the watch owns the pump.
        let lastLoopAttemptDate: Date
        let newestReadingDate: Date?
        let phoneMayDose: Bool
    }

    var isActive: Bool { data.session.phase == .active || data.session.phase == .ending }

    private init() {
        data = store.data
        fallbackTriedAfter = store.data.fallbackTriedAfter
        fallbackHealthRequestID = store.data.fallbackHealthRequestID
        fallbackHealthRequestSentAt = store.data.fallbackHealthRequestSentAt
        fallbackHealthRequestCount = store.data.fallbackHealthRequestCount
        DispatchQueue.main.async {
            self.restoreDevices()
            self.updateStandbySensor()
            self.requestStandingGrantIfMissing()
            self.updateTimers()
            self.checkFallback(trigger: "manager-restore")
            // a hand-back the last process left: the pump offered stays without loops; one still draining goes on
            if self.data.session.phase == .ending {
                if self.data.session.handbackStatus == nil { self.handback() } else { self.isFinalizing = true }
            }
            // what the last process handed over it can no longer follow; it goes once the phone link is up
            self.requeueUnconfirmed(stream: false)
            // the saved state, background loops included, is on screen at once, not after the phone link is up
            if self.isActive { self.publishToWatchState() }
        }
    }

    /// Every change reaches the screens at once, with the phone or without it.
    func refresh() {
        data = store.data
        if isActive {
            publishToWatchState()
        } else if !WatchState.shared.treatmentMarkers.isEmpty {
            WatchState.shared.treatmentMarkers = []
        }
    }

    func setError(_ message: String?) {
        if let message { Task { await WatchLogger.shared.log("⌚️ Untethered: \(message)", force: true) } }
        store.update { $0.lastError = message }
        refresh()
    }

    /// Changes the algorithm and its pump permissions for the watch-owned session.
    func setDosingMode(_ mode: DosingMode, notifyPhone: Bool = true) {
        guard data.session.phase == .active, let currentMode = data.grant?.dosingMode, currentMode != mode else { return }
        store.update { $0.grant?.dosingMode = mode }
        refresh()
        if notifyPhone {
            send(.dosingModeChanged(mode), epoch: data.session.epoch, queueing: true)
        }
        let shouldClearTempForBasalTesting = mode == .basalTesting && (pumpManager.map { pump in
            if case let .tempBasal(dose) = pump.status.basalDeliveryState { return dose.automatic ?? true }
            return false
        } ?? false)
        if shouldClearTempForBasalTesting, let pump = pumpManager {
            Task { @MainActor in
                do {
                    try await pump.enactTempBasal(unitsPerHour: 0, for: 0)
                    self.recordPumpStatus()
                } catch {
                    self.setError(String(
                        localized: "Couldn't cancel the automatic temp basal for basal testing: \(error.localizedDescription)"
                    ))
                }
                self.runLoop(.modeChanged)
            }
        } else {
            runLoop(.modeChanged)
        }
    }

    // MARK: - Messages from the phone

    /// One part of a large envelope; the completing part is handled with its own reply handler.
    func receiveChunk(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        DispatchQueue.main.async {
            if let payload = self.assembler.add(message) {
                self.receive(payload, replyHandler: replyHandler)
            } else {
                replyHandler?([:])
            }
        }
    }

    /// Called by `WatchState` for any payload carrying an `UntetheredEnvelope`.
    func receive(_ payload: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        guard let envelope = try? UntetheredEnvelope.decode(payload) else {
            replyHandler?([:])
            return
        }
        DispatchQueue.main.async { self.handle(envelope, replyHandler: replyHandler) }
    }

    private func handle(_ envelope: UntetheredEnvelope, replyHandler: (([String: Any]) -> Void)?) {
        switch envelope.message {
        case let .prepare(grant):
            if let reason = rejection(of: grant) {
                isBusy = false
                if let replyHandler {
                    reply(.rejected(reason: reason), epoch: envelope.epoch, via: replyHandler)
                } else {
                    send(.rejected(reason: reason), epoch: envelope.epoch)
                }
                return
            }
            let wasIdle = data.session.phase == .idle || data.session.phase == .preparing
            apply(.received(envelope.message, epoch: envelope.epoch), reply: replyHandler) {
                if wasIdle, $0.session.phase == .preparing, $0.session.epoch == envelope.epoch {
                    Self.seed(&$0, with: grant)
                }
            }

        case let .recordsStored(ids):
            replyHandler?([:])
            let stored = Set(ids)
            store.update { data in
                for epoch in data.pending.keys {
                    data.pending[epoch] = data.pending[epoch]?.filter { !stored.contains($0.value.id) }
                }
                data.unsent.subtract(stored)
            }
            for flightID in Array(recordFlights.keys) {
                guard var flight = recordFlights[flightID] else { continue }
                flight.ids.subtract(stored)
                if flight.ids.isEmpty {
                    recordFlights[flightID] = nil
                } else {
                    recordFlights[flightID] = flight
                }
            }
            debug(
                .watchManager,
                "Untethered: phone stored \(stored.count) history record(s); \(recordFlights.count)/\(Self.batchesInFlightLimit) batches remain in flight"
            )
            finishSyncIfDone(epoch: envelope.epoch)
            refresh()
            // A confirmation frees a slot in the bounded send window; immediately push the next batch.
            streamRecords()

        case let .syncRequest(bucketStart, checksums):
            replyHandler?([:])
            answerSync(epoch: envelope.epoch, bucketStart: bucketStart, checksums: checksums)

        case let .commit(handover):
            apply(.received(envelope.message, epoch: envelope.epoch), reply: replyHandler) {
                if $0.session.phase == .starting, $0.session.epoch == envelope.epoch { $0.handover = handover }
            }

        case let .standingGrant(grant, issuedAt):
            replyHandler?([:])
            // a late copy from before a session would miss what the session dosed
            guard data.session.phase == .idle else { return }
            store.update {
                $0.standingGrant = grant
                $0.standingGrantIssuedAt = issuedAt
            }
            updateStandbySensor()
            refresh()

        case let .startRefused(reason):
            replyHandler?([:])
            isBusy = false
            setError(reason)

        case let .fallbackHealthResponse(
            requestID,
            checkedAt,
            lastLoopDate,
            lastLoopAttemptDate,
            newestReadingDate,
            phoneMayDose
        ):
            replyHandler?([:])
            guard requestID == fallbackHealthRequestID else { return }
            fallbackHealthRequestID = nil
            fallbackHealthRequestSentAt = nil
            fallbackHealthRequestCount = 0
            store.update { $0.fallbackCheckDueAt = nil }
            persistFallbackProbeState()
            fallbackPhoneHealth = FallbackPhoneHealth(
                checkedAt: checkedAt,
                lastLoopDate: lastLoopDate,
                lastLoopAttemptDate: lastLoopAttemptDate,
                newestReadingDate: newestReadingDate,
                phoneMayDose: phoneMayDose
            )
            WatchState.shared.phoneLastLoopDate = lastLoopDate
            if let newestReadingDate {
                WatchState.shared.phoneHealthNewestReadingDate = newestReadingDate
            }
            if data.startedByFallback, data.session.phase == .active {
                handleFallbackPhoneHealthResponse()
            } else {
                checkFallback()
            }

        case .fallbackHandbackAccepted:
            replyHandler?([:])
            guard envelope.epoch == data.session.epoch,
                  data.startedByFallback,
                  data.session.phase == .active || data.session.phase == .ending
            else { return }
            if !data.phoneReturnNoted {
                store.update { $0.phoneReturnNoted = true }
                notify(
                    id: "untethered.phoneBack",
                    title: String(localized: "iPhone Is Back"),
                    body: String(localized: "The iPhone is responding with fresh readings. The pump is returning to it.")
                )
            }
            // This is the phone's acceptance of the watch's fresh-reading snapshot. Start hand-back from this
            // durable background message itself; don't depend on a separate endRequest arriving first.
            if data.session.phase == .active, !isBolusing {
                Task {
                    await WatchLogger.shared.log(
                        "⌚️ Untethered: phone accepted the fallback hand-back; starting the pump hand-back",
                        force: true
                    )
                }
                apply(.end)
            }

        case let .adjustmentCancelled(kind, start, date):
            replyHandler?([:])
            // sent both ways, interactive and queued: the second finds it ended already
            guard isActive else { return }
            switch kind {
            case .override:
                if let running = activeOverride(at: Date()), abs(running.date.timeIntervalSince(start)) < 1 {
                    endOverride(at: date)
                }
            case .tempTarget:
                if let running = activeTempTarget(at: Date()), abs(running.createdAt.timeIntervalSince(start)) < 1 {
                    endTempTarget(at: date)
                }
            }

        case .endRequest where data.startedByFallback && data.session.phase == .active
            && (handbackAbandonedAt.map { Date().timeIntervalSince($0) < Self.handbackRetryDelay } ?? false):
            replyHandler?([:])

        case let .dosingModeChanged(mode):
            replyHandler?([:])
            guard data.session.phase == .active, envelope.epoch == data.session.epoch else { return }
            setDosingMode(mode, notifyPhone: false)

        default:
            apply(.received(envelope.message, epoch: envelope.epoch), reply: replyHandler)
        }
    }

    func reachabilityChanged() {
        DispatchQueue.main.async {
            self.checkFallback()
            guard WCSession.default.isReachable else { return }
            // A sensor reading may have arrived while the iPhone was unreachable. Probe it now that it is back.
            self.reportFallbackSession(trigger: "phone became reachable")
            self.requestStandingGrantIfMissing()
            self.streamRecords()
            if self.data.session.phase == .ending { self.apply(.tick) }
            // the phone pairs the next pod
            if self.data.podEnded, self.data.session.phase == .active { self.end() }
            self.notePhoneReturn()
            self.checkLinkedOverride()
        }
    }

    /// Why this grant can't run here, or nil.
    private func rejection(of grant: UntetheredGrant) -> String? {
        guard let pump = Self.configuration(grant.pumpConfiguration) else {
            return String(localized: "The pump's configuration could not be read.")
        }
        guard watchPumpManagers[pump.managerIdentifier] != nil else {
            return String(localized: "This pump can't be run by the watch yet.")
        }
        guard let cgm = Self.configuration(grant.cgmConfiguration), watchCGMManagers[cgm.managerIdentifier] != nil else {
            return String(localized: "This CGM can't be read by the watch yet.")
        }
        guard !grant.basalProfile.isEmpty, !grant.insulinSensitivities.sensitivities.isEmpty,
              !grant.carbRatios.schedule.isEmpty, !grant.bgTargets.targets.isEmpty
        else {
            return String(localized: "The therapy settings are incomplete.")
        }
        return nil
    }

    /// The phone's history and settings become the watch's starting point.
    private static func seed(_ data: inout UntetheredWatchData, with grant: UntetheredGrant) {
        data.grant = grant
        data.pumpHistory = grant.pumpHistory
        data.glucose = grant.glucose
        data.smoothedGlucose = grant.smoothedGlucose
        data.carbs = grant.carbs
        data.tempTargets = grant.tempTargets
        data.activeOverride = grant.activeOverride
        data.activeOverrideKey = grant.activeOverride.map { UntetheredRecord.overrideKey($0.date) }
        // only a temp target still running has an end to report
        data.activeTempTargetKey = grant.tempTargets.max(by: { $0.createdAt < $1.createdAt })
            .flatMap {
                $0.duration > 0 && $0.createdAt
                    .addingTimeInterval(Double(truncating: $0.duration as NSNumber) * 60) > Date() ? $0 : nil }
            .map { UntetheredRecord.tempTargetKey($0.createdAt) }
        data.autosens = grant.autosens
        data.tddPumpHistory = grant.tddPumpHistory
        data.tddRows = grant.tddRecentRows
        data.tddHours = grant.tddHours ?? []
        // the phone's "50+ U" marker is no amount: above 50 U the pod doesn't measure
        data.reservoir = grant.reservoir.flatMap { $0 == Decimal(UInt32(0xDEAD_BEEF)) ? nil : $0 }
        // the phone's last loop stands until the watch's own first one
        data.lastDetermination = grant.lastDetermination
        data.lastLoopDate = grant.lastLoopDate
        // the reading the phone's last loop dosed on doesn't loop again on the watch
        data.lastLoopGlucose = grant.lastLoopDate.flatMap { loop in grant.glucose.map(\.dateString).filter { $0 <= loop }.max() }
        data.lastLoopError = nil
        data.lastError = nil
        data.pendingPumpAlerts = []
        data.podEnded = false
        // from before this session: its pod state and history miss what the session doses
        data.standingGrant = nil
        data.standingGrantIssuedAt = nil
    }

    // MARK: - State machine

    func apply(
        _ event: UntetheredSession.WatchEvent,
        reply: (([String: Any]) -> Void)? = nil,
        also change: ((inout UntetheredWatchData) -> Void)? = nil
    ) {
        let wasActive = isActive
        let wasIdle = store.data.session.phase == .idle
        let effects = store.update { data -> [UntetheredSession.Effect] in
            let effects = data.session.watch(event, now: Date())
            change?(&data)
            return effects
        }
        let epoch = store.data.session.epoch
        // a start that never got going, as when the phone's commit was lost and it took the pump back (2026-10-20
        // 06:22): nothing is in progress any more, so the spinner goes
        if !wasIdle, store.data.session.phase == .idle { isBusy = false }
        refresh()
        var reply = reply
        for effect in effects {
            switch effect {
            case let .send(message):
                if let replyHandler = reply {
                    self.reply(message, epoch: epoch, via: replyHandler)
                    reply = nil
                } else {
                    send(message, epoch: epoch)
                }
            case .takeover:
                takeover()
            case .releasePump:
                releasePump()
            case .handback:
                handback()
            case let .failed(reason):
                setError(reason)
            case .commit,
                 .reconcile,
                 .takePump:
                break
            }
        }
        reply?([:])
        // the grant's sensor, in case it changed since the phone's last update
        if !wasActive, store.data.session.phase == .active {
            if let configuration = data.grant.flatMap({ Self.configuration($0.cgmConfiguration) }) {
                startCGM(configuration)
            }
            resumeHandedOverTempBasal()
            recordPumpStatus()
            // what the standby link read since the copy, the phone's readings having stopped
            let standby = store.data.standbyGlucose
            if !standby.isEmpty {
                store.update { $0.standbyGlucose = [] }
                ingest(standby)
            }
        }
        if wasActive != isActive { handOverAlertNotifications(toWatch: isActive) }
        // the phone may have confirmed the last records while the hand-back was still open: nothing else says so
        if wasActive, !isActive { finishSyncIfDone(epoch: epoch) }
        if wasActive, !isActive {
            Task { await WatchLogger.shared.flushPersistedLogs() }
        }
        // the session's start dropped the copy, and the phone sends the next only when something changed
        if store.data.session.phase == .idle { requestStandingGrantIfMissing() }
        // after the devices are in place, so the Devices page shows them too
        if isActive { publishToWatchState() }
        updateTimers()
    }

    /// The fallback loop's hand-back isn't let go unanswered: the watch doses on, the temp it ended for the phone set
    /// again, and tries once the phone asks again after `handbackRetryDelay`.
    private func tick() {
        let session = data.session
        guard data.startedByFallback, session.phase == .ending, !session.handbackLetGo,
              let offered = session.handbackOfferedAt,
              Date() > offered.addingTimeInterval(UntetheredSession.handbackAckWait)
        else { return apply(.tick) }
        let handedTemp = session.handbackStatus??.tempBasal
        apply(.handbackUnanswered)
        isFinalizing = false
        handbackAbandonedAt = Date()
        // should the phone have taken the pod after all, the pod refuses the watch's next command rather than let
        // both dose; `phoneTookAbandonedPump` then lets go
        pumpManager?.refusesForeignSessionsSince = Date()
        for transfer in WCSession.default.outstandingUserInfoTransfers {
            if case .handback = (try? UntetheredEnvelope.decode(transfer.userInfo))?.message { transfer.cancel() }
        }
        Task { await WatchLogger.shared.log("⌚️ Untethered: the phone didn't acknowledge the hand-back, dosing on", force: true) }
        if let pump = pumpManager, let handedTemp {
            Task { @MainActor in _ = await pump.resumeTempBasal(handedTemp) }
        }
    }

    /// After a hand-back given up: the pod saw another controller's session, so the phone took it after all.
    func phoneTookAbandonedPump() -> Bool {
        // the session's kept offer, not `handbackAbandonedAt`: it outlives a relaunch
        guard data.session.phase == .active, data.session.handbackOfferedAt != nil,
              let pump = pumpManager, let since = pump.refusesForeignSessionsSince,
              let foreign = pump.lastForeignSessionAt, foreign > since
        else { return false }
        Task { await WatchLogger.shared.log("⌚️ Untethered: the phone has the pod after all, letting go", force: true) }
        handbackAbandonedAt = nil
        apply(.received(.handbackAck, epoch: data.session.epoch))
        return true
    }

    private func updateTimers() {
        let phase = data.session.phase
        if phase == .preparing || phase == .starting || phase == .ending {
            if ticker == nil {
                ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
            }
        } else {
            ticker?.invalidate()
            ticker = nil
        }
        if phase == .active {
            if loopTimer == nil {
                // the CGM drives the loop; this covers a missed reading while the app runs
                // no loop of its own: the sensor's acquisition and the alarms, for when no reading comes
                loopTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
                    self?.recheckCGM(trigger: "five-minute-loop-timer")
                }
            }
        } else {
            loopTimer?.invalidate()
            loopTimer = nil
        }
        if isActive {
            if displayTimer == nil {
                displayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                    self?.publishToWatchState()
                }
            }
        } else {
            displayTimer?.invalidate()
            displayTimer = nil
        }
    }

    // MARK: - Transport

    private func reply(_ message: UntetheredMessage, epoch: Int, via replyHandler: ([String: Any]) -> Void) {
        replyHandler((try? UntetheredEnvelope(epoch: epoch, message: message).payload()) ?? [:])
    }

    /// Interactive when the phone is reachable; what must arrive in any case is also queued, unless `queueing`
    /// says otherwise. On the main queue, after the reply is handled, `onReply` runs when the phone answered with an
    /// envelope; `onFailure` runs once when the message reached neither way.
    func send(
        _ message: UntetheredMessage,
        epoch: Int,
        queueing: Bool? = nil,
        onReply: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let payload = try? UntetheredEnvelope(epoch: epoch, message: message).payload()
        else {
            if let onFailure { DispatchQueue.main.async(execute: onFailure) }
            return
        }
        let session = WCSession.default

        // what must reach the phone even if it is away right now; the rest is resent by its own retry
        let queued: Bool
        switch message {
        case .fallbackHandbackRequest,
             .fallbackHealthRequest,
             // The phone may become unreachable just after answering the health check; keep its return request queued.
             .handback,
             .records,
             .released,
             .syncDone,
             .takeoverComplete,
             // the phone takes the pump on it: a wake later, not never
             .takeoverFailed: queued = queueing ?? true
        default: queued = queueing ?? false
        }
        // resent until answered: only the newest of these waits in the queue
        let queue = { (payload: [String: Any]) in
            if message.isResentUntilAnswered {
                for transfer in session.outstandingUserInfoTransfers
                    where (try? UntetheredEnvelope.decode(transfer.userInfo))?.message == message
                {
                    transfer.cancel()
                }
            }
            session.transferUserInfo(payload)
        }
        guard session.isReachable else {
            if queued {
                queue(payload)
            } else {
                if let onFailure { DispatchQueue.main.async(execute: onFailure) }
            }
            return
        }
        var queuedAfterFailure = false
        var failureReported = false
        for part in UntetheredChunks.split(payload) ?? [payload] {
            session.sendMessage(part, replyHandler: { [weak self] reply in
                guard reply[UntetheredEnvelope.key] != nil else { return }
                self?.receive(reply, replyHandler: nil)
                // queued behind the reply's own handling, which `receive` puts on the main queue
                if let onReply { DispatchQueue.main.async(execute: onReply) }
            }, errorHandler: { error in
                Task { await WatchLogger.shared.log("⌚️ Untethered: sending failed: \(error.localizedDescription)") }
                // the whole envelope goes queued once, whichever part failed
                DispatchQueue.main.async {
                    if queued, !queuedAfterFailure {
                        queuedAfterFailure = true
                        queue(payload)
                    } else if !queued, !failureReported {
                        failureReported = true
                        onFailure?()
                    }
                }
            })
        }
    }

    // MARK: - Taking the pump

    private func takeover() {
        guard let grant = data.grant,
              let configuration = Self.configuration(data.handover?.pumpConfiguration ?? grant.pumpConfiguration),
              let type = watchPumpManagers[configuration.managerIdentifier],
              let pump = type.init(adopting: configuration, localState: localState(for: configuration.managerIdentifier))
        else {
            apply(.takeoverFailed(String(localized: "The watch could not set up the pump.")))
            return
        }
        install(pump)
        pump.takeControl()
        isBusy = true
        let epoch = data.session.epoch
        Task { @MainActor in
            defer { self.isBusy = false }
            while self.data.session.phase == .starting, self.data.session.epoch == epoch {
                if let status = await self.readPump(pump) {
                    // the phone's last loop stays on screen; the next CGM reading starts the watch's own
                    self.apply(.takeoverSucceeded(self.startStatus(status, pump: pump)))
                    return
                }
                try? await Task.sleep(nanoseconds: Self.takeoverReadInterval)
                // a later tick past the lease releases the pump
            }
        }
    }

    /// A bolus ends by the clock: the pump reports no change when it runs out, so the end is checked
    /// for at the time it is due rather than at the pump's next status read minutes later.
    func updateBolusState(_ status: PumpManagerStatus?) {
        bolusEndTimer?.invalidate()
        bolusEndTimer = nil
        isBolusing = (status?.bolusState ?? .noBolus) != .noBolus
        bolusWindow = nil
        guard case let .inProgress(dose) = status?.bolusState else { return }
        bolusWindow = DateInterval(start: dose.startDate, end: max(dose.endDate, dose.startDate))
        bolusEndTimer = Timer.scheduledTimer(withTimeInterval: max(1, dose.endDate.timeIntervalSinceNow + 1), repeats: false) {
            [weak self] _ in
            guard let self else { return }
            self.updateBolusState(self.pumpManager?.status)
            self.refresh()
        }
    }

    func install(_ pump: PumpManager & ExclusiveDeviceControl) {
        pump.pumpManagerDelegate = self
        pump.delegateQueue = .main
        pumpManager = pump
        updateBolusState(pump.status)
        savePumpState()
    }

    /// Reads the pump; nil when it doesn't answer.
    func readPump(_ pump: PumpManager) async -> UntetheredPodStatus? {
        if let odometer = pump as? PumpDeliveryOdometer {
            let answered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                odometer.refreshDeliveredUnits { continuation.resume(returning: $0) }
            }
            guard answered else { return nil }
            return UntetheredPodStatus(
                date: Date(),
                deliveredUnits: odometer.deliveredUnits?.units,
                reservoir: store.data.reservoir.map { NSDecimalNumber(decimal: $0).doubleValue }
            )
        }
        let synced = await withCheckedContinuation { (continuation: CheckedContinuation<Date?, Never>) in
            pump.ensureCurrentPumpData { continuation.resume(returning: $0) }
        }
        return synced.map { UntetheredPodStatus(date: $0, deliveredUnits: nil, reservoir: nil) }
    }

    func releasePump() {
        isFinalizing = false
        if let pump = pumpManager {
            pump.releaseControl()
            savePumpState()
        }
        pumpManager = nil
        updateBolusState(nil)
        store.update { $0.pumpRawValue = nil }
        // with the standing link on, the sensor stays connected for the watch's own readings
        if !WatchState.shared.watchReadsSensor { stopCGM() }
        updateStandingSensor()
        refresh()
    }

    // MARK: - The sensor link

    /// The watch reads the sensor in its own display slot while untethered, and with the standing link on also
    /// outside a session. Its saved state (key and Bluetooth handle) outlives either, so the next start reconnects
    /// with the same pairing instead of pairing afresh; a different sensor or code starts over.
    private func startCGM(_ configuration: SharedDeviceConfiguration) {
        let sameSensor = Self.dictionary(store.data.cgmBuiltFrom)
            .map { NSDictionary(dictionary: $0).isEqual(to: configuration.state) } ?? false
        // one manager per sensor: a second one would claim the same Bluetooth restore identifier
        if cgmManager != nil {
            if sameSensor { return }
            stopCGM()
        }
        if sameSensor, let restored = restoredCGM() {
            install(restored)
        } else if let type = watchCGMManagers[configuration.managerIdentifier],
                  let cgm = type.init(adopting: configuration, localState: localState(for: configuration.managerIdentifier))
        {
            Task { await WatchLogger.shared.log("⌚️ Untethered: new sensor, pairing the watch afresh", force: true) }
            sensorPairingDue()
            store.update {
                $0.cgmBuiltFrom = Self.plist(configuration.state)
                $0.pendingPumpAlerts.removeAll { $0.managerIdentifier == cgm.pluginIdentifier }
            }
            install(cgm)
        } else {
            setError(String(localized: "The watch could not set up the CGM."))
        }
    }

    /// The watch stops connecting; its saved state stays for the next session.
    private func stopCGM() {
        sensorPairingDone()
        guard let cgm = cgmManager else { return }
        saveCGMState()
        cgm.cgmManagerDelegate = nil
        // an adopted manager only lets go of the sensor: the phone owns its lifecycle and records
        cgm.delete {}
        cgmManager = nil
    }

    /// Outside a session: the sensor link the phone asks for (Watch Reads the Sensor), or none.
    func updateStandingSensor() {
        guard !isActive, data.session.phase != .starting else { return }
        guard WatchState.shared.watchReadsSensor else {
            if cgmManager != nil { stopCGM() }
            return
        }
        if let data = WatchState.shared.sensorConfiguration, let configuration = Self.configuration(data),
           watchCGMManagers[configuration.managerIdentifier] != nil
        {
            startCGM(configuration)
        }
    }

    func install(_ cgm: CGMManager) {
        cgm.cgmManagerDelegate = self
        cgm.delegateQueue = .main
        cgmManager = cgm
        saveCGMState()
    }

    /// The phone's wake after its reading: the sensor is re-checked and the history goes, the phone being in reach.
    func phoneWake() {
        DispatchQueue.main.async {
            guard self.isActive else { return }
            self.recheckCGM(trigger: "phone-wake")
            self.streamRecords()
        }
    }

    /// Trio leaves the screen (wrist down or another app). watchOS freezes it within seconds, and twice on
    /// 20 October that froze the sensor's next connect before it was made: nothing woke the app for over 30 minutes.
    func appLeavingScreen() {
        watchCGMAppLeavingScreen(cgmManager)
        guard holdsSensorLink else { return }
        scheduleSessionRefresh()
    }

    /// A background refresh as the backstop wake: if a connect is still missing, it is put in on that wake.
    /// One refresh is pending per app at a time; this one replaces the watch reader's while a session runs.
    func scheduleSessionRefresh() {
        guard holdsSensorLink else { return }
        let regularRefresh = Date().addingTimeInterval(10 * 60)
        let preferredDate = store.data.fallbackCheckDueAt.map { min($0, regularRefresh) } ?? regularRefresh
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: preferredDate,
            userInfo: nil
        ) { _ in }
    }

    /// Looking at the watch, the loop timer and Bluetooth wakes are the times no reading came: the sensor's
    /// acquisition puts itself right, and the loop and sensor alarms are checked.
    func recheckCGM(trigger: String = "unspecified") {
        checkFallback(trigger: trigger)
        watchCGMRecheckAcquisition(cgmManager)
        checkAlarms()
        checkPodLink()
    }

    /// After a relaunch the session continues with the devices as they were saved.
    private func restoreDevices() {
        switch data.session.phase {
        case .active,
             .ending,
             .starting:
            if let pump = restoredPump() {
                install(pump)
                if data.session.phase == .starting { takeover(continuing: pump) }
            }
            if data.session.phase != .starting, let cgm = restoredCGM() { install(cgm) }
        case .idle,
             .preparing:
            updateStandingSensor()
        }
    }

    private func takeover(continuing pump: PumpManager & ExclusiveDeviceControl) {
        pump.takeControl()
        let epoch = data.session.epoch
        Task { @MainActor in
            while self.data.session.phase == .starting, self.data.session.epoch == epoch {
                if let status = await self.readPump(pump) {
                    self.apply(.takeoverSucceeded(self.startStatus(status, pump: pump)))
                    return
                }
                try? await Task.sleep(nanoseconds: Self.takeoverReadInterval)
            }
        }
    }

    /// The temp basal the phone cancelled at its release goes on as the watch's own. A loop already running
    /// decides for itself.
    private func resumeHandedOverTempBasal() {
        guard let pump = pumpManager, let tempBasal = data.handover?.tempBasal, !isLooping else { return }
        Task { @MainActor in
            if let error = await pump.resumeTempBasal(tempBasal) {
                await WatchLogger.shared.log("⌚️ Untethered: the phone's temp basal could not be set again: \(error)", force: true)
            } else {
                // the phone shows its own cancel until this record arrives, not waiting for the first loop
                self.streamRecords()
            }
        }
    }

    // MARK: - The fallback loop

    /// The fallback loop can start: it's on with the start without the phone it needs, and the watch reads the sensor
    /// through its own link (Watch Reads the Sensor), which sees the phone's readings stop.
    var keepsStandbySensor: Bool {
        WatchState.shared.fallbackLoop && WatchState.shared.allowUntetheredStartWithoutPhone
            && WatchState.shared.untetheredMode && holdsSensorLink
    }

    /// Between sessions: the sensor link as the phone asks for it, its readings let go without it, and the fallback
    /// disarmed once it can't start.
    func updateStandbySensor() {
        guard data.session.phase == .idle else { return }
        updateStandingSensor()
        if holdsSensorLink {
            // Bluetooth usually wakes the reader at each sensor burst. Keep a scheduled refresh as a backstop
            // for restored/lost CoreBluetooth requests so fallback checks do not depend on opening the app.
            scheduleSessionRefresh()
        } else if !data.standbyGlucose.isEmpty {
            store.update { $0.standbyGlucose = [] }
        }
    }

    /// The sensor link's readings between sessions, kept for the next one: it starts with them, nothing being left to
    /// backfill.
    func holdStandby(_ readings: [BloodGlucose]) {
        guard holdsSensorLink else { return }
        let dayAgo = Date().addingTimeInterval(-24 * 60 * 60)
        store.update { data in
            var known = Set(data.standbyGlucose.map { Int($0.dateString.timeIntervalSince1970 / 30) })
            for reading in readings where reading.dateString >= dayAgo
                && known.insert(Int(reading.dateString.timeIntervalSince1970 / 30)).inserted
            {
                data.standbyGlucose.append(reading)
            }
            data.standbyGlucose.removeAll { $0.dateString < dayAgo }
        }
        // `data` is an in-memory snapshot; refresh it before checkFallback counts the just-saved readings.
        refresh()
        checkFallback(trigger: "standby-reading")
        // the readings wake the app in the background too, where no reachability change arrives to ask on
        requestStandingGrantIfMissing()
    }

    /// Require a live watch sensor and stale phone feed/loop data. A live app health reply or one unanswered
    /// application-level checks decides the fallback; `WCSession.isReachable` is not treated as proof of liveness.
    func checkFallback(trigger: String = "event") {
        let now = Date()
        if let dueAt = store.data.fallbackCheckDueAt, dueAt <= now {
            store.update { $0.fallbackCheckDueAt = nil }
        }
        if data.startedByFallback, data.session.phase == .active {
            checkFallbackHandbackHealthTimeout(now: now)
            if trigger == "scheduled-background-refresh" {
                Task {
                    await WatchLogger.shared.log(
                        "⌚️ Untethered: scheduled background check asking the iPhone for health",
                        force: true
                    )
                }
                // Queue it when a live reply is unavailable: the phone can answer from its background wake.
                requestFallbackPhoneHealth(queueing: true)
            }
            return
        }
        let cachedPhoneNewest = WatchState.shared.phoneNewestReading ?? .distantPast
        let cachedPhoneLoopDate = WatchState.shared.phoneLastLoopDate
        let cachedPhoneFeedIsStale = cachedPhoneNewest <= now.addingTimeInterval(-Self.fallbackPhoneStaleInterval)

        // A backfilled reading cannot prove that the watch's own sensor link is live now.
        let recentWatchReadings = data.standbyGlucose.filter {
            $0.dateString >= now.addingTimeInterval(-Self.fallbackWatchReadingFreshness)
                && $0.sgv != nil && $0.isStateValid
        }
        let cachedMissed = recentWatchReadings.filter {
            $0.dateString > cachedPhoneNewest.addingTimeInterval(60)
        }.count
        let phoneFeedAge = now.timeIntervalSince(cachedPhoneNewest)
        let phoneLoopAge = cachedPhoneLoopDate.map { now.timeIntervalSince($0) }
        let phoneFeedAgeMinutes = Int(phoneFeedAge / 60)
        let phoneLoopAgeDescription = phoneLoopAge.map { "\(Int($0 / 60))min" } ?? "unknown"
        let standbyCount = data.standbyGlucose.count
        let phase = data.session.phase
        let busy = isBusy
        let hasStandingGrant = standingGrantAge != nil
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: fallback evaluation trigger=\(trigger) standby=\(standbyCount) "
                    + "recent=\(recentWatchReadings.count) missed=\(cachedMissed) "
                    + "feedAge=\(phoneFeedAgeMinutes)min loopAge=\(phoneLoopAgeDescription) "
                    + "phase=\(phase) busy=\(busy) grant=\(hasStandingGrant)",
                force: true
            )
        }
        guard cachedMissed >= Self.fallbackMissedReadings else {
            if !cachedPhoneFeedIsStale {
                fallbackPhoneHealth = nil
                fallbackHealthRequestID = nil
                fallbackHealthRequestSentAt = nil
                fallbackHealthRequestCount = 0
                store.update { $0.fallbackCheckDueAt = nil }
                persistFallbackProbeState()
            }
            return
        }

        let blocker: String? = !keepsStandbySensor ? "fallback off"
            : data.session.phase != .idle ? "session \(data.session.phase)"
            : isBusy ? "busy"
            : !cachedPhoneFeedIsStale ? "phone readings are not stale"
            : nil
        if let blocker {
            Task {
                await WatchLogger.shared.log(
                    "⌚️ Untethered: \(cachedMissed) recent readings not sent by the phone, no fallback: \(blocker)",
                    force: true
                )
            }
            return
        }

        if let health = fallbackPhoneHealth,
           now.timeIntervalSince(health.checkedAt) >= 0,
           now.timeIntervalSince(health.checkedAt) <= Self.fallbackHealthFreshness
        {
            let healthAge = now.timeIntervalSince(health.checkedAt)
            guard health.phoneMayDose else {
                Task {
                    await WatchLogger.shared.log(
                        "⌚️ Untethered: phone answered but cannot confirm pump ownership; fallback held",
                        force: true
                    )
                }
                // Honor an explicit ownership refusal only while that response is fresh. If the phone
                // goes silent, one unanswered app-level check must be able to authorize fallback.
                scheduleFallbackCheck(after: Self.fallbackHealthFreshness - healthAge)
                return
            }

            let phoneNewest = health.newestReadingDate ?? .distantPast
            let missed = recentWatchReadings.filter {
                $0.dateString > phoneNewest.addingTimeInterval(60)
            }.count
            let feedIsStale = phoneNewest <= now.addingTimeInterval(-Self.fallbackPhoneStaleInterval)
            let loopIsStale = now.timeIntervalSince(health.lastLoopDate) >= Self.fallbackPhoneStaleInterval

            // A live response means the phone still owns the pump when its gate allows dosing. Even if its feed and
            // loop look stale, the watch must not start a second controller alongside it.
            Task {
                await WatchLogger.shared.log(
                    "⌚️ Untethered: phone answered its health check; fallback held (new readings \(missed), feed stale \(feedIsStale), loop stale \(loopIsStale))",
                    force: true
                )
            }
            return
        }

        // Ask the phone app directly. The connectivity flag can be true while the app is not processing messages.
        if let sentAt = fallbackHealthRequestSentAt {
            let elapsed = now.timeIntervalSince(sentAt)
            guard elapsed >= Self.fallbackHealthResponseTimeout else {
                scheduleFallbackCheck(after: Self.fallbackHealthResponseTimeout - elapsed)
                return
            }
            fallbackHealthRequestID = nil
            fallbackHealthRequestSentAt = nil
            fallbackHealthRequestCount += 1
            persistFallbackProbeState()
            Task {
                await WatchLogger.shared.log(
                    "⌚️ Untethered: no phone health reply to fallback check \(fallbackHealthRequestCount)/\(Self.fallbackHealthRequestLimit)",
                    force: true
                )
            }
        }

        guard fallbackHealthRequestCount >= Self.fallbackHealthRequestLimit else {
            requestFallbackPhoneHealth()
            return
        }

        // After one unanswered app-level check, use only the last known stale loop state and the standing grant.
        guard let cachedPhoneLoopDate,
              now.timeIntervalSince(cachedPhoneLoopDate) >= Self.fallbackPhoneStaleInterval
        else {
            Task {
                await WatchLogger.shared.log(
                    "⌚️ Untethered: phone did not answer, but its last known loop time is not confirmed stale",
                    force: true
                )
            }
            return
        }
        startFallback(phoneNewest: cachedPhoneNewest, reason: "phone did not answer its health check")
    }

    private func requestFallbackPhoneHealth(queueing: Bool = false) {
        let activeFallback = data.startedByFallback && data.session.phase == .active
        if activeFallback {
            if let sentAt = fallbackHealthRequestSentAt,
               Date().timeIntervalSince(sentAt) < Self.fallbackHealthResponseTimeout
            { return }
        } else {
            guard fallbackHealthRequestID == nil else { return }
            if fallbackHealthRequestCount >= Self.fallbackHealthRequestLimit { fallbackHealthRequestCount = 0 }
        }
        // Keep one request ID across background retries. A delayed queued reply still answers this probe.
        let requestID = activeFallback ? (fallbackHealthRequestID ?? UUID()) : UUID()
        fallbackHealthRequestID = requestID
        fallbackHealthRequestSentAt = Date()
        persistFallbackProbeState()
        // During fallback, a queued answer can arrive well after a live-message timeout. Keep its request ID
        // and retry that same probe on a new reading or scheduled background run.
        if !data.startedByFallback || data.session.phase != .active {
            scheduleFallbackCheck(after: Self.fallbackHealthResponseTimeout)
        }
        send(.fallbackHealthRequest(requestID), epoch: data.session.epoch, queueing: queueing) {
            guard self.fallbackHealthRequestID == requestID else { return }
            if self.data.startedByFallback, self.data.session.phase == .active {
                // Keep the ID: a queued copy may still reach the phone, or the next wake can retry it.
                self.fallbackHealthRequestSentAt = nil
            } else {
                self.fallbackHealthRequestID = nil
                self.fallbackHealthRequestSentAt = nil
                self.fallbackHealthRequestCount = Self.fallbackHealthRequestLimit
                self.store.update { $0.fallbackCheckDueAt = nil }
            }
            self.persistFallbackProbeState()
            Task {
                await WatchLogger.shared.log(
                    "⌚️ Untethered: fallback health request was not delivered; keeping it for the next retry",
                    force: true
                )
            }
            guard !self.data.startedByFallback || self.data.session.phase != .active else { return }
            self.checkFallback(trigger: "health-request-undeliverable")
        }
    }

    private func checkFallbackHandbackHealthTimeout(now: Date) {
        guard let sentAt = fallbackHealthRequestSentAt else { return }
        let elapsed = now.timeIntervalSince(sentAt)
        guard elapsed >= Self.fallbackHealthResponseTimeout else {
            scheduleFallbackCheck(after: Self.fallbackHealthResponseTimeout - elapsed)
            return
        }
        // UserInfo delivery can take longer than a live message. Keep its request ID so a late phone
        // response still matches; the next sensor or scheduled wake resends the same probe.
        fallbackHealthRequestSentAt = nil
        persistFallbackProbeState()
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: iPhone health check unanswered during fallback; keeping its ID for a late reply or retry",
                force: true
            )
        }
    }

    private func handleFallbackPhoneHealthResponse() {
        guard let health = fallbackPhoneHealth, let status = data.session.startStatus, status.byFallback == true else { return }
        guard let newestReadingDate = health.newestReadingDate else {
            Task {
                await WatchLogger.shared.log(
                    "⌚️ Untethered: phone health check had no glucose date; watch keeps the pump",
                    force: true
                )
            }
            return
        }
        let readingAgeAtHealthCheck = health.checkedAt.timeIntervalSince(newestReadingDate)
        let phoneFeedIsFresh = readingAgeAtHealthCheck >= 0
            && readingAgeAtHealthCheck < Self.fallbackPhoneStaleInterval
        guard phoneFeedIsFresh else {
            Task {
                await WatchLogger.shared.log(
                    "⌚️ Untethered: phone glucose was over 10 minutes old at health-check time; watch keeps the pump",
                    force: true
                )
            }
            return
        }
        var handbackStatus = status
        handbackStatus.fallbackHealthCheck = UntetheredFallbackHealthCheck(
            checkedAt: health.checkedAt,
            newestReadingDate: newestReadingDate
        )
        let now = Date()
        if let sentAt = fallbackHandbackRequestedAt,
           now.timeIntervalSince(sentAt) < Self.fallbackHealthResponseTimeout
        { return }
        fallbackHandbackRequestedAt = now
        send(.fallbackHandbackRequest(handbackStatus), epoch: data.session.epoch)
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: phone replied with fresh glucose; asking it to take the pump back",
                force: true
            )
        }
    }

    private func startFallback(phoneNewest: Date, reason: String) {
        guard standingGrantAge != nil else {
            Task {
                await WatchLogger.shared.log("⌚️ Untethered: fallback blocked; no standing grant young enough", force: true)
            }
            return
        }
        guard fallbackTriedAfter != phoneNewest else {
            Task { await WatchLogger.shared.log("⌚️ Untethered: fallback already tried for this phone feed", force: true) }
            return
        }
        guard startWithoutPhone(byFallback: true) else {
            Task {
                await WatchLogger.shared
                    .log("⌚️ Untethered: fallback conditions changed before takeover could start", force: true) }
            return
        }
        fallbackTriedAfter = phoneNewest
        fallbackPhoneHealth = nil
        fallbackHealthRequestID = nil
        fallbackHealthRequestSentAt = nil
        fallbackHealthRequestCount = 0
        fallbackHandbackRequestedAt = nil
        store.update {
            $0.fallbackCheckDueAt = nil
            $0.fallbackHealthLastReadingRequestAt = nil
        }
        persistFallbackProbeState()
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: starting watch fallback; watch sensor is live, phone feed and loop are stale, \(reason)",
                force: true
            )
        }
        notify(
            id: "untethered.fallback",
            title: String(localized: "Phone Loop Stalled"),
            body: String(localized: "The iPhone's loop and readings stopped. The watch is taking over.")
        )
    }

    private func scheduleFallbackCheck(after delay: TimeInterval) {
        let requestedDate = Date().addingTimeInterval(max(0.25, delay))
        let existingDueAt = store.data.fallbackCheckDueAt
        let dueAt = min(existingDueAt ?? requestedDate, requestedDate)
        if existingDueAt.map({ dueAt < $0 }) ?? true {
            store.update { $0.fallbackCheckDueAt = dueAt }
            scheduleSessionRefresh()
        }
        guard fallbackCheckScheduledAt != dueAt else { return }
        fallbackCheckScheduledAt = dueAt
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.25, dueAt.timeIntervalSinceNow)) {
            guard self.fallbackCheckScheduledAt == dueAt else { return }
            self.fallbackCheckScheduledAt = nil
            guard self.store.data.fallbackCheckDueAt == dueAt else { return }
            self.store.update { $0.fallbackCheckDueAt = nil }
            self.checkFallback(trigger: "timeout")
        }
    }

    /// Keeps the probe count and deadline when watchOS suspends or relaunches this process.
    private func persistFallbackProbeState() {
        store.update {
            $0.fallbackHealthRequestID = fallbackHealthRequestID
            $0.fallbackHealthRequestSentAt = fallbackHealthRequestSentAt
            $0.fallbackHealthRequestCount = fallbackHealthRequestCount
            $0.fallbackTriedAfter = fallbackTriedAfter
        }
    }

    // MARK: - Starting without the phone

    /// The standing grant's age, while one is stored and young enough to start from: older than insulin's action time
    /// its history has too large a gap, and what the pod delivered meanwhile too much to book as one dose.
    var standingGrantAge: TimeInterval? {
        guard let grant = data.standingGrant, let issuedAt = data.standingGrantIssuedAt, rejection(of: grant) == nil
        else { return nil }
        let age = Date().timeIntervalSince(issuedAt)
        let actionTime = NSDecimalNumber(decimal: grant.pumpSettings.insulinActionCurve).doubleValue * 60 * 60
        return age < actionTime ? age : nil
    }

    /// The fallback loop as the status page shows it, between sessions.
    enum FallbackStatus: Equatable {
        case off
        /// The watch keeps the sensor and watches for the phone's readings to stop.
        case watching
    }

    var fallbackStatus: FallbackStatus {
        guard keepsStandbySensor else { return .off }
        return .watching
    }

    /// A fresh reading, or the phone becoming reachable after one, can start a health check every five minutes.
    /// Reachability alone never hands back the pump; the phone must answer with a fresh glucose timestamp.
    func reportFallbackSession(trigger: String = "incoming sensor reading") {
        let now = Date()
        guard data.startedByFallback, data.session.phase == .active,
              WCSession.default.isReachable,
              (store.data.fallbackHealthLastReadingRequestAt ?? .distantPast)
              .addingTimeInterval(Self.fallbackHealthReadingInterval) < now
        else { return }
        if let sentAt = fallbackHealthRequestSentAt,
           now.timeIntervalSince(sentAt) < Self.fallbackHealthResponseTimeout
        { return }
        store.update { $0.fallbackHealthLastReadingRequestAt = now }
        if fallbackHealthRequestCount >= Self.fallbackHealthRequestLimit { fallbackHealthRequestCount = 0 }
        Task {
            await WatchLogger.shared.log(
                "⌚️ Untethered: requesting iPhone health check after \(trigger)",
                force: true
            )
        }
        requestFallbackPhoneHealth()
    }

    /// No standing grant young enough to start from, as after a session, whose start dropped it: asked for, as the
    /// phone otherwise sends the next only when something changed or half an hour passed.
    func requestStandingGrantIfMissing() {
        let now = Date()
        guard data.session.phase == .idle, standingGrantAge == nil, WatchState.shared.untetheredMode,
              WatchState.shared.allowUntetheredStartWithoutPhone,
              (standingGrantRequestedAt ?? .distantPast).addingTimeInterval(Self.standingGrantRequestInterval) < now
        else { return }
        standingGrantRequestedAt = now
        // queued, so a phone out of reach or asleep answers once it can; only the newest request waits
        send(.standingGrantRequest, epoch: data.session.epoch, queueing: true)
    }

    /// Why there is no start without the phone, for the status page; nil when one can start.
    var startWithoutPhoneUnavailable: String? {
        guard let grant = data.standingGrant, let issuedAt = data.standingGrantIssuedAt else {
            return String(localized: "No copy from the phone to start from yet. It sends one while it has the pump.")
        }
        if let rejection = rejection(of: grant) { return rejection }
        guard standingGrantAge == nil else { return nil }
        let hours = Int(Date().timeIntervalSince(issuedAt) / 3600)
        return String(
            localized: "The phone's copy is \(hours) h old, older than the insulin's action time: too much is unknown to start from it."
        )
    }

    /// From the phone's standing grant: the watch takes control with its own epoch, then reports ownership to the
    /// phone. Manual starts still require the phone to be out of reach; the automatic fallback uses app-level health.
    @discardableResult func startWithoutPhone(byFallback: Bool = false) -> Bool {
        guard WatchState.shared.untetheredMode, WatchState.shared.allowUntetheredStartWithoutPhone,
              data.session.phase == .idle, !isBusy,
              !WatchState.shared.isReachable || byFallback, standingGrantAge != nil,
              let grant = data.standingGrant
        else { return false }
        setError(nil)
        Task { await WatchLogger.shared.log("⌚️ Untethered: starting without the phone", force: true) }
        apply(.startWithoutPhone) {
            guard $0.session.phase == .starting else { return }
            Self.seed(&$0, with: grant)
            // the standing grant's pump, not an earlier session's hand-over
            $0.handover = nil
            $0.phoneReturnNoted = false
            $0.startedByFallback = byFallback
        }
        return true
    }

    /// The takeover's reading; started without the phone, before the first loop, with what the phone dosed after its
    /// copy booked and the copy's time for the phone.
    private func startStatus(_ status: UntetheredPodStatus, pump: PumpManager) -> UntetheredPodStatus {
        guard data.session.startedWithoutPhone, let grant = data.grant,
              let copy = Self.configuration(grant.pumpConfiguration)
        else { return status }
        bookUnexplainedSinceCopy(status, copy: copy, pump: pump as? PumpDeliveryOdometer)
        var status = status
        status.copyAsOf = copy.asOf
        if data.startedByFallback { status.byFallback = true }
        return status
    }

    /// What the pod delivered since the standing grant's copy that its history can't explain, and the rest of a bolus
    /// the phone started after it (the pump manager doesn't track another controller's bolus), booked as a bolus in
    /// the watch's own history only: the phone has the real records of it.
    private func bookUnexplainedSinceCopy(
        _ status: UntetheredPodStatus,
        copy: SharedDeviceConfiguration,
        pump: PumpDeliveryOdometer?
    ) {
        guard let grant = data.grant else { return }
        let untrackedBolus = pump?.untrackedBolusRemaining ?? 0
        let unexplained = UntetheredAudit.unexplainedSinceCopy(
            copyUnits: copy.deliveredUnits,
            copyAt: copy.asOf,
            podUnits: status.deliveredUnits,
            podAt: status.date,
            history: grant.tddPumpHistory,
            basalProfile: grant.basalProfile,
            bolusDeliveryRate: pump?.bolusDeliveryRate ?? 0
        ) ?? 0
        let units = unexplained + Decimal(untrackedBolus).rounded(scale: 2)
        guard units > UntetheredAudit.tolerance else { return }
        let epoch = data.session.epoch
        let bolus = PumpHistoryEvent(
            id: "untethered-copy-gap-\(epoch)",
            type: .bolus,
            timestamp: status.date,
            amount: units,
            duration: 0,
            isSMB: false,
            isExternal: false
        )
        // the TDD counts it too, as it does every bolus
        store.update { $0.upsertPumpEvent(id: bolus.id, history: [bolus], tdd: bolus) }
        Task {
            await WatchLogger.shared
                .log(
                    "⌚️ Untethered: \(units) U the standing grant had no record of (\(untrackedBolus) U still running), a bolus",
                    force: true
                )
        }
    }

    /// Connectivity alone does not start a fallback health check; the next incoming reading does.
    private func notePhoneReturn() {
        guard isActive, data.session.startedWithoutPhone else { return }
        if data.startedByFallback {
            return
        }
        guard WCSession.default.isReachable else { return }
        send(.statusReport(holding: data.session.startStatus), epoch: data.session.epoch)
        guard !data.phoneReturnNoted else { return }
        store.update { $0.phoneReturnNoted = true }
        notify(
            id: "untethered.phoneBack",
            title: String(localized: "iPhone Is Back"),
            body: String(localized: "The watch still has the pump. Hand back on its status page when you're ready.")
        )
    }

    // MARK: - Starting from the wrist

    /// Asks the phone to start, as its settings toggle does; the phone's answer is the usual prepare.
    func requestStart() {
        guard WatchState.shared.untetheredMode, data.session.phase == .idle, !isBusy else { return }
        guard WCSession.default.isReachable else {
            setError(String(localized: "The phone must be reachable to start untethered mode."))
            return
        }
        setError(nil)
        isBusy = true
        send(.startRequest, epoch: data.session.epoch)
        // the phone's prepare, or its refusal, comes once it has read the pump (up to 30 s); this only frees the button
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if self.data.session.phase == .idle { self.isBusy = false }
        }
    }

    // MARK: - Handing back

    /// From the wrist, or because the linked override is over. Needs the phone close by.
    func end() {
        guard !isBolusing else {
            setError(String(localized: "Wait for the bolus to finish, or stop it, before handing back."))
            return
        }
        guard WCSession.default.isReachable else {
            setError(
                String(
                    localized: "The phone must be reachable to take the pump back. Use Emergency Stop if it isn't coming back."
                )
            )
            return
        }
        apply(.end)
    }

    /// Two-phase, as LoopKit/Loop#2545: the watch doses on while its history drains, so the phone has all of it
    /// before the pod changes hands; then it stops dosing, reads the pod, sends its last records and offers the
    /// pump, which it lets go only once the phone acknowledges (`UntetheredSession`).
    private func handback() {
        isBusy = true
        let epoch = data.session.epoch
        Task { @MainActor in
            defer { self.isBusy = false }
            // a phone that doesn't confirm the backlog in time gets the rest with the last records
            let drainUntil = Date().addingTimeInterval(Self.drainLimit)
            while self.hasUnconfirmedRecords(epoch), Date() < drainUntil, self.data.session.phase == .ending {
                self.streamRecords()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard self.data.session.phase == .ending else { return }
            // from here no loop or bolus: the last read is the last command to the pod
            self.isFinalizing = true
            // a hand-back asked for by the phone also waits for a running bolus
            while self.isLooping || self.isBolusing { try? await Task.sleep(nanoseconds: 500_000_000) }
            self.expireAdjustments(now: Date())
            // a low temp ends here and goes with the last records, for the phone to set again; a high one runs on
            // until the phone, having the pod, cancels it
            let scheduled = BolusCalculator.scheduleValue(
                (self.data.grant?.basalProfile ?? []).map { ($0.start, $0.rate) },
                at: Date()
            )
            let handed = await self.pumpManager.asyncMap {
                await $0.handOverTempBasal(scheduledRate: scheduled, cancellingHigh: false)
            }
            var status = await self.pumpManager.asyncMap { await self.readPump($0) } ?? nil
            status?.tempBasal = handed?.resume
            status?.runningHighTemp = handed?.leftRunning
            self.recordPumpStatus()
            // only these few records are left: no pacing around the sensor for them
            self.streamRecords(ignoringSensor: true)
            let confirmUntil = Date().addingTimeInterval(Self.finalConfirmLimit)
            while self.hasUnconfirmedRecords(epoch), Date() < confirmUntil {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            // the pod stays held until the phone acknowledges: its connect is standing as the watch lets go
            self.apply(.handbackReady(status))
        }
    }

    private func hasUnconfirmedRecords(_ epoch: Int) -> Bool {
        !(store.data.pending[epoch] ?? [:]).isEmpty
    }

    /// Lets go of the pump at once, with the phone or without it. A running temp basal is cancelled
    /// first, so the pump falls back to its schedule.
    func emergencyStop() {
        isBusy = true
        Task { @MainActor in
            defer { self.isBusy = false }
            var status: UntetheredPodStatus?
            if let pump = self.pumpManager {
                _ = try? await pump.enactTempBasal(unitsPerHour: 0, for: 0)
                status = await self.readPump(pump)
            }
            self.streamRecords(ignoringSensor: true)
            self.apply(.emergencyStop(status))
        }
    }

    // MARK: - History to the phone

    /// Hands record batches to WatchConnectivity and keeps each record locally until the phone confirms storage.
    /// A bounded window avoids serial round trips and prevents a large history from flooding the durable transfer
    /// queue. Hand-back can pipeline four batches; during normal sensor use only one goes at a time, in a clear
    /// window, to protect the sensor link. The phone's confirmation opens the next slot(s).
    func streamRecords(ignoringSensor: Bool = false) {
        streamTimer?.invalidate()
        streamTimer = nil
        // before activation nothing can go, not even queued: what left `unsent` now would never be sent
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        let now = Date()
        let pendingIDs = Set(store.data.pending.values.flatMap { $0.values.map(\.id) })
        for flightID in Array(recordFlights.keys) {
            guard var flight = recordFlights[flightID] else { continue }
            flight.ids.formIntersection(pendingIDs)
            if flight.ids.isEmpty {
                recordFlights[flightID] = nil
            } else {
                recordFlights[flightID] = flight
            }
        }

        // If a live interactive send stopped answering, retry its records. When the phone is away, leave durable
        // transfers alone; WatchConnectivity will deliver them on reconnection, and reachability will resume here.
        if session.isReachable {
            let expiredFlightIDs = recordFlights.compactMap { entry in
                now.timeIntervalSince(entry.value.sentAt) >= Self.recordAckTimeout ? entry.key : nil
            }
            if !expiredFlightIDs.isEmpty {
                let expiredIDs = Set(expiredFlightIDs.flatMap { recordFlights[$0]?.ids ?? [] })
                debug(.watchManager, "Untethered: no storage confirmation for \(expiredIDs.count) history record(s) in 30 s; retrying")
                for id in expiredFlightIDs { recordFlights[id] = nil }
                resend(Array(expiredIDs))
            }
        }

        let paced = holdsSensorLink && !ignoringSensor && !isFinalizing
        let unsent = store.data.unsent
        guard !unsent.isEmpty else {
            scheduleRecordAckTimeoutIfNeeded()
            return
        }
        let pending = store.data.pending.sorted { $0.key < $1.key }
        var batches: [(epoch: Int, records: [UntetheredRecord])] = []
        for (epoch, records) in pending {
            let batch = records.values.filter { unsent.contains($0.id) }.sorted { $0.date < $1.date }
            for start in stride(from: 0, to: batch.count, by: Self.recordsPerMessage) {
                batches.append((epoch, Array(batch[start ..< min(start + Self.recordsPerMessage, batch.count)])))
            }
        }
        guard !batches.isEmpty else { return }

        if paced {
            // The next phone reachability change or sensor reading retries; never queue history over the sensor link.
            guard session.isReachable else { return }
            if let clear = sensorWindowEnd(now: Date()) {
                scheduleStream(at: clear)
                return
            }
        }

        let batchLimit = paced ? 1 : Self.batchesInFlightLimit
        let availableSlots = max(0, batchLimit - recordFlights.count)
        guard availableSlots > 0 else {
            scheduleRecordAckTimeoutIfNeeded()
            return
        }
        let sending = Array(batches.prefix(availableSlots))
        for batch in sending {
            let ids = batch.records.map(\.id)
            let flightID = UUID()
            recordFlights[flightID] = (Set(ids), now)
            debug(
                .watchManager,
                "Untethered: sending \(ids.count) history record(s); \(recordFlights.count)/\(Self.batchesInFlightLimit) batches in flight"
            )
            send(
                .records(batch.records),
                epoch: batch.epoch,
                queueing: paced ? false : nil,
                onFailure: { [weak self] in self?.recordBatchFailed(flightID: flightID, ids: ids) }
            )
        }
        // what is no longer pending was confirmed meanwhile and needs no sending
        let currentPendingIDs = Set(pending.flatMap { $0.value.values.map(\.id) })
        let sent = Set(sending.flatMap { $0.records.map(\.id) })
        store.update { $0.unsent = $0.unsent.subtracting(sent).intersection(currentPendingIDs) }
        scheduleRecordAckTimeoutIfNeeded()
    }

    private func recordBatchFailed(flightID: UUID, ids: [UUID]) {
        recordFlights[flightID] = nil
        resend(ids)
        scheduleStream(at: Date().addingTimeInterval(Self.retryDelay))
    }

    /// Retry an unanswered interactive batch, or wake it when its slot is due.
    private func scheduleRecordAckTimeoutIfNeeded() {
        guard WCSession.default.isReachable,
              let oldest = recordFlights.values.map(\.sentAt).min()
        else { return }
        scheduleStream(at: oldest.addingTimeInterval(Self.recordAckTimeout))
    }

    /// The end of the window around the watch's next sensor reading, or nil while clear of it or holding no sensor.
    /// A link still up after its reading (backfill) holds it too, checked again shortly.
    func sensorWindowEnd(now: Date) -> Date? {
        guard holdsSensorLink else { return nil }
        if watchCGMIsConnected(cgmManager) { return now.addingTimeInterval(5) }
        return UntetheredSensorWindow.end(now: now, lastReading: store.data.glucose.map(\.dateString).max())
    }

    /// The watch reads the sensor itself, in an untethered session.
    var holdsSensorLink: Bool { cgmManager != nil }

    /// Bulk traffic to the phone, the watch's log included, may go now: always without a sensor link, with one
    /// only to a reachable phone and clear of the next reading.
    var mayStreamToPhone: Bool {
        guard holdsSensorLink else { return true }
        return WCSession.default.isReachable && sensorWindowEnd(now: Date()) == nil
    }

    /// Runs only while the app does; a suspended app picks up at its next loop.
    private func scheduleStream(at date: Date) {
        streamTimer?.invalidate()
        streamTimer = Timer.scheduledTimer(withTimeInterval: max(1, date.timeIntervalSinceNow), repeats: false) {
            [weak self] _ in self?.streamRecords()
        }
    }

    /// Every version the phone hasn't confirmed goes again: after a relaunch, whose process lost the replies and
    /// failures it waited for, and after a queued transfer failed. The phone stores each version once.
    func requeueUnconfirmed(stream: Bool = true) {
        recordFlights.removeAll()
        store.update { $0.unsent = Set($0.pending.values.flatMap { $0.values.map(\.id) }) }
        if stream { streamRecords() }
    }

    /// A batch that reached the phone neither way goes again with the next one, unless confirmed meanwhile.
    private func resend(_ ids: [UUID]) {
        let retrying = Set(ids)
        for flightID in Array(recordFlights.keys) {
            guard var flight = recordFlights[flightID] else { continue }
            flight.ids.subtract(retrying)
            if flight.ids.isEmpty {
                recordFlights[flightID] = nil
            } else {
                recordFlights[flightID] = flight
            }
        }
        let pendingIDs = Set(store.data.pending.values.flatMap { $0.values.map(\.id) })
        store.update { $0.unsent.formUnion(retrying.intersection(pendingIDs)) }
    }

    /// The phone's checksums against ours: what it misses is resent; a finished session whose every
    /// version the phone confirmed is done.
    private func answerSync(epoch: Int, bucketStart: Int, checksums: [Int]) {
        let entries = Array((store.data.entries[epoch] ?? [:]).values)
        let differing = UntetheredSyncEntry.differingBuckets(local: entries, remoteStart: bucketStart, remoteChecksums: checksums)
        let missing = (store.data.pending[epoch] ?? [:]).values.filter { differing.contains($0.syncEntry.bucket) }
        if !missing.isEmpty {
            resend(missing.map(\.id))
            streamRecords()
        }
        finishSyncIfDone(epoch: epoch)
    }

    private func finishSyncIfDone(epoch: Int) {
        let session = store.data.session
        let over = epoch != session.epoch || session.phase == .idle
        guard over, store.data.entries[epoch] != nil, (store.data.pending[epoch] ?? [:]).isEmpty else { return }
        send(.syncDone, epoch: epoch)
        store.update {
            $0.pending[epoch] = nil
            $0.entries[epoch] = nil
        }
        refresh()
    }

    // MARK: - Persistence of the devices

    static func configuration(_ data: Data) -> SharedDeviceConfiguration? {
        (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
            .flatMap(SharedDeviceConfiguration.init(rawValue:))
    }

    private static func plist(_ value: [String: Any]?) -> Data? {
        value.flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
    }

    private static func dictionary(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any] }
    }

    private func localState(for identifier: String) -> [String: Any]? {
        Self.dictionary(store.data.localStates[identifier])
    }

    func savePumpState() {
        guard let pump = pumpManager else { return }
        store.update {
            $0.pumpRawValue = Self.plist(["managerIdentifier": pump.pluginIdentifier, "state": pump.rawState])
            if let local = Self.plist(pump.localState) { $0.localStates[pump.pluginIdentifier] = local }
        }
    }

    func saveCGMState() {
        guard let cgm = cgmManager else { return }
        store.update {
            $0.cgmRawValue = Self.plist(["managerIdentifier": cgm.pluginIdentifier, "state": cgm.rawState])
            if let sharing = cgm as? DeviceConfigurationSharing, let local = Self.plist(sharing.localState) {
                $0.localStates[cgm.pluginIdentifier] = local
            }
        }
    }

    private func restoredPump() -> (PumpManager & ExclusiveDeviceControl)? {
        guard let raw = Self.dictionary(store.data.pumpRawValue), let identifier = raw["managerIdentifier"] as? String,
              let state = raw["state"] as? [String: Any]
        else { return nil }
        return watchPumpManagers[identifier]?.init(rawState: state)
    }

    private func restoredCGM() -> CGMManager? {
        guard let raw = Self.dictionary(store.data.cgmRawValue), let identifier = raw["managerIdentifier"] as? String,
              let state = raw["state"] as? [String: Any]
        else { return nil }
        return watchCGMManagers[identifier]?.init(rawState: state)
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
