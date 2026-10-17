import Foundation
import LoopKit
import UserNotifications
import WatchConnectivity

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
    private static let takeoverReadInterval: UInt64 = 8_000_000_000

    var isActive: Bool { data.session.phase == .active || data.session.phase == .ending }

    private init() {
        data = store.data
        DispatchQueue.main.async {
            self.restoreDevices()
            self.updateTimers()
            // the saved state, background loops included, is on screen at once, not after the phone link is up
            if self.isActive { self.publishToWatchState() }
        }
    }

    /// Every change reaches the screens at once, with the phone or without it.
    func refresh() {
        data = store.data
        if isActive { publishToWatchState() }
    }

    func setError(_ message: String?) {
        if let message { Task { await WatchLogger.shared.log("⌚️ Untethered: \(message)", force: true) } }
        store.update { $0.lastError = message }
        refresh()
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
        data.tddTenDaySum = grant.tddTenDaySum
        data.tddTenDayCount = grant.tddTenDayCount
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
            case .reconcile,
                 .takePump:
                break
            }
        }
        reply?([:])
        // the grant's sensor, in case it changed since the phone's last update
        if !wasActive, store.data.session.phase == .active {
            startCGM()
        }
        if wasActive != isActive { handOverAlertNotifications(toWatch: isActive) }
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

    /// Interactive when the phone is reachable; what must arrive in any case is also queued.
    func send(_ message: UntetheredMessage, epoch: Int) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let payload = try? UntetheredEnvelope(epoch: epoch, message: message).payload()
        else { return }
        let session = WCSession.default

        // what must reach the phone even if it is away right now; the rest is resent by its own retry
        let queued: Bool
        switch message {
        case .records,
             .released,
             .syncDone,
             .takeoverComplete,
             .takeoverFailed: queued = true
        default: queued = false
        }
        guard session.isReachable else {
            if queued { session.transferUserInfo(payload) }
            return
        }
        var queuedAfterFailure = false
        for part in UntetheredChunks.split(payload) ?? [payload] {
            session.sendMessage(part, replyHandler: { [weak self] reply in
                guard reply[UntetheredEnvelope.key] != nil else { return }
                self?.receive(reply, replyHandler: nil)
            }, errorHandler: { error in
                Task { await WatchLogger.shared.log("⌚️ Untethered: sending failed: \(error.localizedDescription)") }
                // the whole envelope goes queued once, whichever part failed
                if queued, !queuedAfterFailure {
                    queuedAfterFailure = true
                    session.transferUserInfo(payload)
                }
            })
        }
    }

    // MARK: - Taking the pump

    private func takeover() {
        guard let grant = data.grant, let configuration = Self.configuration(grant.pumpConfiguration),
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
                    self.apply(.takeoverSucceeded(status))
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
                    self.apply(.takeoverSucceeded(status))
                    return
                }
                try? await Task.sleep(nanoseconds: Self.takeoverReadInterval)
            }
        }
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

    private func handback() {
        isBusy = true
        Task { @MainActor in
            defer { self.isBusy = false }
            // a hand-back asked for by the phone also waits for a running bolus
            while self.isLooping || self.isBolusing { try? await Task.sleep(nanoseconds: 500_000_000) }
            self.expireAdjustments(now: Date())
            let status = await self.pumpManager.asyncMap { await self.readPump($0) } ?? nil
            self.streamRecords()
            self.releasePump()
            self.apply(.handbackReady(status))
        }
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
            self.streamRecords()
            self.apply(.emergencyStop(status))
        }
    }

    // MARK: - History to the phone

    /// Hands every new version to WatchConnectivity. The phone confirms what it stored, and only then
    /// does the watch drop it, so its backlog stays as small as the phone's reach allows.
    func streamRecords() {
        let unsent = store.data.unsent
        guard !unsent.isEmpty else { return }
        for (epoch, records) in store.data.pending {
            let batch = records.values.filter { unsent.contains($0.id) }.sorted { $0.date < $1.date }
            for chunk in stride(from: 0, to: batch.count, by: Self.recordsPerMessage)
                .map({ Array(batch[$0 ..< min($0 + Self.recordsPerMessage, batch.count)]) })
            {
                send(.records(chunk), epoch: epoch)
            }
        }
        store.update { $0.unsent = [] }
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

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
