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

    /// Records travel in batches small enough for an interactive message.
    private static let recordsPerMessage = 40
    /// While the watch holds the sensor link, a backlog goes one batch at a time, each checked against the reading
    /// window; the next waits until the phone answered for the last, or this long at most.
    private static let batchesPerBurst = 1
    private static let burstTimeout: TimeInterval = 30
    /// After a batch failed with the phone in reach: no tight loop of sends that keep failing.
    private static let retryDelay: TimeInterval = 15
    @ObservationIgnored private var streamTimer: Timer?
    /// The hand-back's last stage: no loop or bolus between the pod's last read and the phone taking it.
    @ObservationIgnored var isFinalizing = false
    /// How long the hand-back's backlog may take before the rest goes with the last records.
    private static let drainLimit: TimeInterval = 3 * 60
    /// How long the last records may take to be confirmed before the pump is offered anyway.
    private static let finalConfirmLimit: TimeInterval = 30
    /// The paced burst on its way, how many of its batches the phone has yet to answer for, and whether one failed.
    @ObservationIgnored private var burst: (id: Int, startedAt: Date, outstanding: Int, failed: Bool)?
    @ObservationIgnored private var burstCount = 0
    private static let takeoverReadInterval: UInt64 = 8_000_000_000

    var isActive: Bool { data.session.phase == .active || data.session.phase == .ending }

    private init() {
        data = store.data
        DispatchQueue.main.async {
            self.restoreDevices()
            self.updateTimers()
            // a hand-back the last process left: the pump offered stays without loops; one still draining goes on
            if self.data.session.phase == .ending {
                if self.data.session.handbackOfferedAt == nil { self.handback() } else { self.isFinalizing = true }
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
            finishSyncIfDone(epoch: envelope.epoch)
            refresh()

        case let .syncRequest(bucketStart, checksums):
            replyHandler?([:])
            answerSync(epoch: envelope.epoch, bucketStart: bucketStart, checksums: checksums)

        case let .commit(handover):
            apply(.received(envelope.message, epoch: envelope.epoch), reply: replyHandler) {
                if $0.session.phase == .starting, $0.session.epoch == envelope.epoch { $0.handover = handover }
            }

        case let .standingGrant(grant, issuedAt):
            replyHandler?([:])
            // a late copy from before a session would miss what the session dosed. Kept even before the watch has
            // heard the setting is on (the two travel separately); starting stays gated on the setting.
            guard data.session.phase == .idle else { return }
            store.update {
                $0.standingGrant = grant
                $0.standingGrantIssuedAt = issuedAt
            }
            refresh()

        case let .startRefused(reason):
            replyHandler?([:])
            isBusy = false
            setError(reason)

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
            guard WCSession.default.isReachable else { return }
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
        let effects = store.update { data -> [UntetheredSession.Effect] in
            let effects = data.session.watch(event, now: Date())
            change?(&data)
            return effects
        }
        let epoch = store.data.session.epoch
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
            startCGM()
            resumeHandedOverTempBasal()
            recordPumpStatus()
        }
        if wasActive != isActive {
            handOverAlertNotifications(toWatch: isActive)
            noteSessionBattery(started: isActive)
        }
        // the phone may have confirmed the last records while the hand-back was still open: nothing else says so
        if wasActive, !isActive { finishSyncIfDone(epoch: epoch) }
        // after the devices are in place, so the Devices page shows them too
        if isActive { publishToWatchState() }
        updateTimers()
    }

    private func updateTimers() {
        let phase = data.session.phase
        if phase == .preparing || phase == .starting || phase == .ending {
            if ticker == nil {
                ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.apply(.tick) }
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
                    self?.recheckCGM()
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
        case .records,
             .released,
             .syncDone,
             .takeoverComplete,
             .takeoverFailed: queued = queueing ?? true
        default: queued = queueing ?? false
        }
        guard session.isReachable else {
            if queued {
                session.transferUserInfo(payload)
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
                        session.transferUserInfo(payload)
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
        stopCGM()
        refresh()
    }

    // MARK: - The sensor link

    /// The watch reads the sensor in its own display slot only while untethered. Its saved state (key and
    /// Bluetooth handle) outlives the session, so the next takeover reconnects with the same pairing
    /// instead of pairing afresh; a different sensor or code starts over.
    private func startCGM() {
        guard let grant = data.grant, let configuration = Self.configuration(grant.cgmConfiguration) else { return }
        let sameSensor = Self.dictionary(store.data.cgmBuiltFrom)
            .map { NSDictionary(dictionary: $0).isEqual(to: configuration.state) } ?? false
        if sameSensor, let restored = restoredCGM() {
            install(restored)
        } else if let type = watchCGMManagers[configuration.managerIdentifier],
                  let cgm = type.init(adopting: configuration, localState: localState(for: configuration.managerIdentifier))
        {
            Task { await WatchLogger.shared.log("⌚️ Untethered: new sensor, pairing the watch afresh", force: true) }
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
        guard let cgm = cgmManager else { return }
        saveCGMState()
        cgm.cgmManagerDelegate = nil
        // an adopted manager only lets go of the sensor: the phone owns its lifecycle and records
        cgm.delete {}
        cgmManager = nil
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
            self.recheckCGM()
            self.streamRecords()
        }
    }

    /// Looking at the watch, the loop timer and Bluetooth wakes are the times no reading came: the sensor's
    /// acquisition puts itself right, and the loop and sensor alarms are checked.
    func recheckCGM() {
        watchCGMRecheckAcquisition(cgmManager)
        checkAlarms()
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
            break
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

    // MARK: - Starting without the phone

    /// Settings › Allow Start Without iPhone turned off: the copy the phone left goes with it.
    func dropStandingGrant() {
        guard data.standingGrant != nil || data.standingGrantIssuedAt != nil else { return }
        store.update {
            $0.standingGrant = nil
            $0.standingGrantIssuedAt = nil
        }
        refresh()
    }

    /// The standing grant's age, while one is stored and young enough to start from: older than insulin's action time
    /// its history has too large a gap, and what the pod delivered meanwhile too much to book as one dose.
    var standingGrantAge: TimeInterval? {
        guard let grant = data.standingGrant, let issuedAt = data.standingGrantIssuedAt, rejection(of: grant) == nil
        else { return nil }
        let age = Date().timeIntervalSince(issuedAt)
        let actionTime = NSDecimalNumber(decimal: grant.pumpSettings.insulinActionCurve).doubleValue * 60 * 60
        return age < actionTime ? age : nil
    }

    /// With the phone off or out of reach, from the phone's standing grant: the ordinary takeover, with a fresh lease
    /// and an epoch of the watch's own. The phone stands aside once it hears from the watch. As LoopKit/Loop#2545.
    func startWithoutPhone() {
        guard WatchState.shared.allowUntetheredStartWithoutPhone,
              data.session.phase == .idle, !isBusy, !WCSession.default.isReachable, standingGrantAge != nil,
              let grant = data.standingGrant
        else { return }
        setError(nil)
        Task { await WatchLogger.shared.log("⌚️ Untethered: starting without the phone", force: true) }
        apply(.startWithoutPhone) {
            guard $0.session.phase == .starting else { return }
            Self.seed(&$0, with: grant)
            // the standing grant's pump, not an earlier session's hand-over
            $0.handover = nil
            $0.phoneReturnNoted = false
        }
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

    /// The phone back during a session started without it: told at once that the watch has the pump, so it stops
    /// dosing; the wrist is asked once whether to hand back. Never handed back on its own.
    private func notePhoneReturn() {
        guard isActive, data.session.startedWithoutPhone, WCSession.default.isReachable else { return }
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
        guard data.session.phase == .idle, !isBusy else { return }
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

    /// Hands every new version to WatchConnectivity. The phone confirms what it stored, and only then
    /// does the watch drop it, so its backlog stays as small as the phone's reach allows.
    ///
    /// While the watch holds the sensor link the two share its radio: history then goes only to a reachable
    /// phone, never while the sensor's link is up or around the next reading, and one batch at a time, each once the
    /// phone has answered for the last, so none piles up in WatchConnectivity and runs into the reading. Nothing is
    /// queued there either while the phone is away, which would send the whole backlog at once whenever it came back.
    /// A hand-back lets go of the sensor anyway and sends everything (`ignoringSensor`).
    func streamRecords(ignoringSensor: Bool = false) {
        streamTimer?.invalidate()
        streamTimer = nil
        // before activation nothing can go, not even queued: what left `unsent` now would never be sent
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let paced = holdsSensorLink && !ignoringSensor
        if paced, let burst {
            let overdue = burst.startedAt.addingTimeInterval(Self.burstTimeout)
            // the phone's last answer continues the stream; a burst it never answered for stops holding it
            guard Date() >= overdue else {
                scheduleStream(at: overdue)
                return
            }
        }
        burst = nil
        let unsent = store.data.unsent
        guard !unsent.isEmpty else { return }
        let pending = store.data.pending.sorted { $0.key < $1.key }
        var batches: [(epoch: Int, records: [UntetheredRecord])] = []
        for (epoch, records) in pending {
            let batch = records.values.filter { unsent.contains($0.id) }.sorted { $0.date < $1.date }
            for start in stride(from: 0, to: batch.count, by: Self.recordsPerMessage) {
                batches.append((epoch, Array(batch[start ..< min(start + Self.recordsPerMessage, batch.count)])))
            }
        }
        var sending = batches
        if paced, !batches.isEmpty {
            // the next loop or the phone's return tries again
            guard WCSession.default.isReachable else { return }
            if let clear = sensorWindowEnd(now: Date()) {
                scheduleStream(at: clear)
                return
            }
            sending = Array(batches.prefix(Self.batchesPerBurst))
            burstCount += 1
            burst = (burstCount, Date(), sending.count, false)
            scheduleStream(at: Date().addingTimeInterval(Self.burstTimeout))
        }
        let burstID = burst?.id
        for batch in sending {
            let ids = batch.records.map(\.id)
            // the phone's answer or the failure, whichever comes, settles the batch once
            var settled = false
            let settle: (_ delivered: Bool) -> Void = { [weak self] delivered in
                guard !settled else { return }
                settled = true
                if !delivered { self?.resend(ids) }
                if let burstID { self?.batchSettled(inBurst: burstID, delivered: delivered) }
            }
            send(
                .records(batch.records),
                epoch: batch.epoch,
                queueing: paced ? false : nil,
                onReply: paced ? { settle(true) } : nil,
                onFailure: paced ? { settle(false) } : nil
            )
        }
        // what is no longer pending was confirmed meanwhile and needs no sending
        let pendingIDs = Set(pending.flatMap { $0.value.values.map(\.id) })
        let sent = Set(sending.flatMap { $0.records.map(\.id) })
        store.update { $0.unsent = $0.unsent.subtracting(sent).intersection(pendingIDs) }
    }

    /// The last batch the phone answered for, or that failed, sends the next burst: at once, or after a pause
    /// when one failed.
    private func batchSettled(inBurst id: Int, delivered: Bool) {
        guard let current = burst, current.id == id else { return }
        let failed = current.failed || !delivered
        guard current.outstanding > 1 else {
            burst = nil
            if failed {
                scheduleStream(at: Date().addingTimeInterval(Self.retryDelay))
            } else {
                streamRecords()
            }
            return
        }
        burst = (current.id, current.startedAt, current.outstanding - 1, failed)
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
        store.update { $0.unsent = Set($0.pending.values.flatMap { $0.values.map(\.id) }) }
        if stream { streamRecords() }
    }

    /// A batch that reached the phone neither way goes again with the next one, unless confirmed meanwhile.
    private func resend(_ ids: [UUID]) {
        let pendingIDs = Set(store.data.pending.values.flatMap { $0.values.map(\.id) })
        store.update { $0.unsent.formUnion(Set(ids).intersection(pendingIDs)) }
    }

    /// The phone's checksums against ours: what it misses is resent; a finished session whose every
    /// version the phone confirmed is done.
    private func answerSync(epoch: Int, bucketStart: Int, checksums: [Int]) {
        let entries = Array((store.data.entries[epoch] ?? [:]).values)
        let differing = UntetheredSyncEntry.differingBuckets(local: entries, remoteStart: bucketStart, remoteChecksums: checksums)
        let missing = (store.data.pending[epoch] ?? [:]).values.filter { differing.contains($0.syncEntry.bucket) }
        if !missing.isEmpty {
            store.update { $0.unsent.formUnion(missing.map(\.id)) }
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

// MARK: - Battery

extension UntetheredWatchManager {
    private static let batteryAtStartKey = "untethered.batteryAtStart"
    private static let sessionStartKey = "untethered.sessionStart"

    /// The watch's battery in percent; nil while watchOS doesn't report it.
    static var batteryPercent: Int? {
        let device = WKInterfaceDevice.current()
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        return level < 0 ? nil : Int((level * 100).rounded())
    }

    static var batteryText: String { batteryPercent.map { "\($0) %" } ?? "–" }

    /// Logs the battery when a session starts and, when it ends, how much it used and per hour.
    /// Kept in UserDefaults, so a relaunch in between doesn't lose the start.
    func noteSessionBattery(started: Bool) {
        let defaults = UserDefaults.standard
        let now = Date()
        let battery = Self.batteryPercent
        if started {
            defaults.set(battery, forKey: Self.batteryAtStartKey)
            defaults.set(now, forKey: Self.sessionStartKey)
            let text = battery.map { "\($0) %" } ?? "–"
            Task { await WatchLogger.shared.log("⌚️ Untethered session started, battery \(text)", force: true) }
            return
        }
        let startBattery = defaults.object(forKey: Self.batteryAtStartKey) as? Int
        let start = defaults.object(forKey: Self.sessionStartKey) as? Date
        defaults.removeObject(forKey: Self.batteryAtStartKey)
        defaults.removeObject(forKey: Self.sessionStartKey)
        var line = "⌚️ Untethered session ended"
        if let start {
            let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
            line += " after \(minutes / 60) h \(minutes % 60) min"
            if let startBattery, let battery {
                line += ", battery \(startBattery) % → \(battery) %"
                if minutes >= 10 {
                    let perHour = Double(startBattery - battery) / (Double(minutes) / 60)
                    line += String(format: " (%.1f %% per hour)", perHour)
                }
            }
        }
        Task { await WatchLogger.shared.log(line, force: true) }
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
