import Foundation
import LoopKit
import UserNotifications
import WatchConnectivity
import WatchKit

/// The watch's side of the Watch Loop: it asks for the pump, holds it while it loops, records what it does for the
/// phone and gives the pump back (after LoopKit/Loop#2545's PodLoanWatchController). Who holds the pump is decided
/// in `WatchLoopControl`; this carries it out.
@MainActor @Observable final class WatchLoopSession {
    static let shared = WatchLoopSession()

    private static let pumpKey = "WatchLoopPump"
    private static let pumpLocalKey = "WatchLoopPumpLocal"
    private static var stateURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WatchLoop.json")
    }

    var state: WatchLoopWatchState {
        didSet { save() }
    }

    /// What the Watch Loop page tells the looper: a refusal, a takeover in progress, the session's end.
    var note: String?
    /// A Start or an End in progress.
    private(set) var isBusy = false

    @ObservationIgnored private(set) var pumpManager: PumpManager?
    @ObservationIgnored private var seen = WatchLoopSeenEnvelopes()
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored var cycleRunning = false
    /// Back from off with the pump: no dose until the phone had the time to say it holds it (control rows 12, 13).
    @ObservationIgnored var resumingUntil: Date?

    private var control: ExclusiveDeviceControl? { pumpManager as? ExclusiveDeviceControl }

    var isActive: Bool { state.phase == .active || state.phase == .handingBack }

    private init() {
        state = (try? Data(contentsOf: Self.stateURL))
            .flatMap { try? JSONCoding.decoder.decode(WatchLoopWatchState.self, from: $0) }
            ?? WatchLoopWatchState()
        resume()
    }

    private func save() {
        guard let data = try? JSONCoding.encoder.encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }

    // MARK: - The wire

    /// A Watch Loop message from the phone, from any channel. False: not one.
    nonisolated static func receive(_ userInfo: [String: Any]) -> Bool {
        guard userInfo[WatchLoopTransport.key] != nil else { return false }
        let envelope: WatchLoopTransport.Envelope?
        do {
            envelope = try WatchLoopTransport.decode(userInfo)
        } catch {
            WatchLogger.shared.warning(.connectivity, "Watch Loop message unreadable", error: error)
            return true
        }
        guard let envelope else { return true }
        Task { @MainActor in await shared.handle(envelope) }
        return true
    }

    private func handle(_ envelope: WatchLoopTransport.Envelope) async {
        guard seen.firstSighting(of: envelope.id) else { return }
        WatchLogger.shared.debug(.connectivity, "Watch Loop received \(envelope.message.kind)")
        switch envelope.message {
        case let .grant(grant): await takeOver(grant)
        case let .startRefused(id, reason):
            guard state.phase == .requested, id == requestID else { return }
            state.phase = .idle
            refuse(reason)
        case let .ack(_, ids): state.acknowledge(ids)
        case let .handBackAck(session):
            guard state.phase == .handingBack, session == state.session else { return }
            endSession(note: String(localized: "Your iPhone has the pod again."))
        case let .stop(session):
            guard session == state.session, isActive else { return }
            endSession(note: String(localized: "Your iPhone took the pod back."))
            WKInterfaceDevice.current().play(.notification)
        case let .statusQuery(id): sendStatus(replyTo: id)
        case .checkpoint,
             .handBack,
             .request,
             .standingCopy,
             .statusReport:
            break
        }
        if !isActive { drain() }
    }

    func send(_ message: WatchLoopMessage) {
        let session = WCSession.default
        guard session.activationState == .activated, let payload = try? WatchLoopTransport.encode(message) else { return }
        if WatchLoopTransport.ridesBothChannels(message), session.isReachable, WatchLoopTransport.fitsLivePath(payload) {
            session.sendMessage(payload, replyHandler: nil) { error in
                WatchLogger.shared.debug(
                    .connectivity,
                    "Watch Loop \(message.kind) not delivered live: \(error.localizedDescription)"
                )
            }
        }
        session.transferUserInfo(payload)
    }

    private func sendStatus(replyTo id: UUID?) {
        send(.statusReport(WatchLoopStatusReport(
            replyTo: id,
            session: state.session,
            holdsPump: state.phase == .active && pumpManager != nil,
            startedAt: state.startedAt,
            pumpReachable: state.pumpReachable
        )))
    }

    /// What the phone hasn't acknowledged, after the session ended: insulin is booked whatever happens (rule 1).
    func drain() {
        for (session, records) in Dictionary(grouping: state.pending, by: \.session) {
            send(.checkpoint(WatchLoopCheckpoint(
                session: session,
                sentAt: Date(),
                startedAt: records.map(\.loggedAt).min() ?? Date(),
                records: records,
                status: nil
            )))
        }
    }

    private func refuse(_ reason: String) {
        note = reason
        WKInterfaceDevice.current().play(.failure)
    }

    private func tell(_ tell: WatchLoopControl.Tell) {
        switch tell {
        case .noResponseFromPhone:
            refuse(String(localized: "No response from your iPhone. Bring it near and try again."))
        case .noResponseFromPhoneAndNoCGM:
            refuse(String(localized: "No response from your iPhone, and the watch reads no CGM of its own."))
        case .phoneAwayCannotHandBack:
            refuse(String(localized: "Your iPhone didn't answer. The watch keeps the pod and loops on."))
        default:
            break
        }
    }

    // MARK: - Start

    func start() {
        guard state.phase == .idle, !isBusy else { return }
        let decision = WatchLoopControl.decide(.init(
            device: .watch,
            trigger: .startTapped,
            watchReadsCGM: WatchCGMHost.shared.cgmManager != nil
        ))
        guard case let .query(wait, onSilence) = decision else { return }
        let request = WatchLoopRequest(id: UUID(), sentAt: Date(), highestSession: state.session)
        requestID = request.id
        note = String(localized: "Asking your iPhone for the pod…")
        state.phase = .requested
        send(.request(request))
        WatchLogger.shared.info(.treatments, "Watch Loop: asked the phone for the pump")
        Task {
            try? await Task.sleep(nanoseconds: UInt64(wait.seconds * 1_000_000_000))
            guard state.phase == .requested, requestID == request.id else { return }
            state.phase = .idle
            if case let .tell(tell) = onSilence { self.tell(tell) }
        }
    }

    /// The grant: build the phone's pump here and take it within the lease. A grant nobody asked for, or one that
    /// cannot be taken, is answered with "holding nothing", so the phone takes its pump back at once.
    private func takeOver(_ grant: WatchLoopGrant) async {
        func decline(_ reason: String) {
            state.phase = .idle
            state.session = max(state.session, grant.session)
            send(.statusReport(WatchLoopStatusReport(
                replyTo: nil,
                session: grant.session,
                holdsPump: false,
                startedAt: nil,
                pumpReachable: nil
            )))
            refuse(reason)
            WatchLogger.shared.warning(.treatments, "Watch Loop grant \(grant.session) declined: \(reason)")
        }
        guard state.phase == .requested, grant.session > state.session, Date() < grant.leaseExpiresAt else {
            if grant.session > state.session { decline(String(localized: "The start was cancelled. Tap Start to try again.")) }
            return
        }
        guard let raw = try? PropertyListSerialization.propertyList(from: grant.pumpConfiguration, format: nil) as? [String: Any],
              let configuration = SharedDeviceConfiguration(rawValue: raw),
              let pump = watchPumpManager(
                  adopting: configuration,
                  localState: UserDefaults.standard.dictionary(forKey: Self.pumpLocalKey)
              ),
              let control = pump as? ExclusiveDeviceControl
        else {
            return decline(String(localized: "This pump can't be run from the watch."))
        }
        isBusy = true
        defer { isBusy = false }
        install(pump)
        note = String(localized: "Connecting to the pod…")
        control.takeControl()
        while Date() < grant.leaseExpiresAt, !(control.isControlReady && !control.isControlReleased) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard control.isControlReady, !control.isControlReleased else {
            releasePump()
            return decline(String(localized: "The watch couldn't reach the pod. Your iPhone keeps it."))
        }
        state.begin(grant, at: Date())
        if let odometer = pump as? PumpDeliveryOdometer, await odometer.refreshDeliveredUnits(),
           let reading = odometer.deliveredUnits
        {
            state.deliveredAtStart = reading.units
            state.deliveredAtStartReadAt = reading.at
        }
        note = nil
        sendStatus(replyTo: nil)
        WKInterfaceDevice.current().play(.success)
        WatchLogger.shared.info(.treatments, "Watch Loop session \(grant.session) started; the watch has the pump")
        await runCycle(reason: "start")
    }

    // MARK: - End

    /// The looper's End: dosing stops, the pump is let go and offered back. Without the phone's answer the watch
    /// takes it again and loops on (control rows 7, 8).
    func end() async {
        guard state.phase == .active, !isBusy, let pump = pumpManager, let control else { return }
        if case .noBolus = pump.status.bolusState {} else {
            let endsAt = (pump as? PumpDeliveryOdometer)?.bolusUnderWayEndsAt
            return refuse(WatchLoopControl.bolusRefusal(.init(endsAt: endsAt), now: Date()))
        }
        isBusy = true
        defer { isBusy = false }
        let odometer = await readOdometer()
        control.releaseControl()
        guard control.isControlReleased else {
            control.takeControl()
            return refuse(WatchLoopControl.unconfirmedCommandRefusal)
        }
        note = String(localized: "Handing the pod back to your iPhone…")
        state.phase = .handingBack
        send(.handBack(WatchLoopHandBack(session: state.session, records: state.pending, odometer: odometer)))
        // the phone acknowledges once it has the pump, which can take it up to 30 s
        let deadline = Date().addingTimeInterval(45)
        while state.phase == .handingBack, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard state.phase == .handingBack else { return }
        control.takeControl()
        state.phase = .active
        tell(.phoneAwayCannotHandBack)
        // a phone that did take the pump answers this with the stop
        sendStatus(replyTo: nil)
    }

    /// Ends the session on the watch: the pump is let go; records not yet acknowledged keep going to the phone.
    func endSession(note: String?) {
        releasePump()
        state.end()
        self.note = note
        drain()
        WatchLogger.shared.info(.treatments, "Watch Loop session \(state.session) ended")
    }

    private func readOdometer() async -> WatchLoopOdometer? {
        guard let odometer = pumpManager as? PumpDeliveryOdometer, await odometer.refreshDeliveredUnits(),
              let latest = odometer.deliveredUnits, let start = state.deliveredAtStart,
              let startAt = state.deliveredAtStartReadAt else { return nil }
        return WatchLoopOdometer(
            deliveredAtStart: start,
            startReadAt: startAt,
            deliveredLatest: latest.units,
            latestReadAt: latest.at
        )
    }

    // MARK: - The pod on the watch

    /// The pod's end on the watch: deactivated, or discarded when it can't be reached. The phone forgets it.
    func endPod(discard: Bool) async -> String? {
        guard state.phase == .active, let pump = pumpManager else { return nil }
        let failure: String? = await withCheckedContinuation { continuation in
            if discard {
                watchDiscardPod(pump) { continuation.resume(returning: nil) }
            } else {
                watchDeactivatePod(pump) { error in continuation.resume(returning: error?.localizedDescription) }
            }
        }
        if let failure { return failure }
        send(.handBack(WatchLoopHandBack(session: state.session, records: state.pending, odometer: nil, podEnded: true)))
        state.phase = .handingBack
        // without the phone's answer the session still ends: there is no pod left to loop
        endSession(note: String(localized: "Pod ended. Pair a new one on your iPhone."))
        return nil
    }

    private func install(_ pump: PumpManager) {
        pump.delegateQueue = .main
        pump.pumpManagerDelegate = self
        pumpManager = pump
    }

    private func releasePump() {
        control?.releaseControl()
        if let pumpManager, let local = watchPumpLocalState(pumpManager) {
            UserDefaults.standard.set(local, forKey: Self.pumpLocalKey)
        }
        pumpManager = nil
        UserDefaults.standard.removeObject(forKey: Self.pumpKey)
    }

    /// After a relaunch: a session with its pump saved is rebuilt, and asks before dosing; anything else rests.
    private func resume() {
        switch state.phase {
        case .idle:
            return
        case .requested:
            state.phase = .idle
        case .active,
             .handingBack:
            guard let raw = UserDefaults.standard.dictionary(forKey: Self.pumpKey), let pump = watchPumpManager(rawValue: raw)
            else {
                state.end()
                return
            }
            install(pump)
            control?.takeControl()
            state.phase = .active
            let decision = WatchLoopControl.decide(.init(device: .watch, trigger: .backFromOff))
            if case let .query(wait, _) = decision { resumingUntil = Date().addingTimeInterval(wait.seconds) }
            WatchLogger.shared.info(.treatments, "Watch Loop session \(state.session) resumed after a relaunch")
            DispatchQueue.main.async { self.sendStatus(replyTo: nil) }
        }
    }

    // MARK: - From the looper

    func setClosedLoop(_ closed: Bool) {
        state.closedLoop = closed
    }

    func bolus(_ units: Double) async -> String? {
        guard state.phase == .active, let pump = pumpManager, let grant = state.grant else { return nil }
        guard units > 0, Decimal(units) <= grant.maxBolus else {
            return String(localized: "Above the maximum bolus.")
        }
        let rounded = pump.roundToSupportedBolusVolume(units: units)
        do {
            try await pump.enactBolus(units: rounded, automatic: false)
            WatchLogger.shared.info(.bolus, "Watch Loop bolus enacted: \(rounded) U")
            return nil
        } catch {
            WatchLogger.shared.warning(.bolus, "Watch Loop bolus failed", error: error)
            return error.localizedDescription
        }
    }

    func addCarbs(_ grams: Decimal, at date: Date) {
        guard state.phase == .active, grams > 0 else { return }
        let entry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: Date(),
            actualDate: date,
            carbs: min(grams, state.grant?.maxCarbs ?? grams),
            fat: 0,
            protein: 0,
            note: nil,
            enteredBy: CarbsEntry.local,
            isFPU: false,
            fpuID: nil
        )
        state.carbs.append(entry)
        state.record(.carbs(entry), at: Date())
        Task { await runCycle(reason: "carbs") }
    }

    func deleteCarbs(_ entry: CarbsEntry) {
        guard state.phase == .active, let id = entry.id else { return }
        if state.carbs.contains(where: { $0.id == id }) {
            state.carbs.removeAll { $0.id == id }
        } else {
            state.deletedCarbIDs.append(id)
        }
        state.record(.carbsDeleted(id: id), at: Date())
        sendCheckpoint()
    }

    func setOverride(_ override: Override?) {
        guard state.phase == .active else { return }
        state.override = override
        state.record(.override(override), at: Date())
        Task { await runCycle(reason: "override") }
    }

    func startOverride(presetName: String) {
        guard let preset = state.grant?.overridePresets.first(where: { $0.name == presetName }) else { return }
        setOverride(preset.started(at: Date()))
    }

    func startTempTarget(presetName: String) {
        guard var preset = state.grant?.tempTargetPresets.first(where: { $0.name == presetName }) else { return }
        preset.id = UUID().uuidString
        preset.createdAt = Date()
        preset.enabled = true
        setTempTarget(preset)
    }

    func setTempTarget(_ target: TempTarget?) {
        guard state.phase == .active else { return }
        let entry = target ?? TempTarget.cancel(at: Date())
        state.tempTargets.append(entry)
        state.record(.tempTarget(target), at: Date())
        Task { await runCycle(reason: "temp target") }
    }

    /// The watch's own readings: each new one is a cycle.
    func noteReadings(_ readings: [BloodGlucose]) {
        guard state.phase == .active else { return }
        let known = Set(state.glucose.map(\.dateString))
        state.glucose += readings.filter { !known.contains($0.dateString) }
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        state.glucose.removeAll { $0.dateString < dayAgo }
        Task { await runCycle(reason: "reading") }
    }

    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "trio.watch.watchLoop.\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }
}

// MARK: - Hosting the pump

extension WatchLoopSession: PumpManagerDelegate {
    private func isCurrent(_ manager: PumpManager) -> Bool {
        (manager as AnyObject) === (pumpManager as AnyObject?)
    }

    nonisolated func pumpManagerDidUpdateState(_ manager: PumpManager) {
        MainActor.assumeIsolated {
            if let local = watchPumpLocalState(manager) { UserDefaults.standard.set(local, forKey: Self.pumpLocalKey) }
            guard isCurrent(manager) else { return }
            UserDefaults.standard.set(manager.watchRawValue, forKey: Self.pumpKey)
        }
    }

    nonisolated func pumpManager(
        _ manager: PumpManager,
        hasNewPumpEvents events: [NewPumpEvent],
        lastReconciliation _: Date?,
        replacePendingEvents _: Bool,
        completion: @escaping (Error?) -> Void
    ) {
        MainActor.assumeIsolated {
            // a driver let go of can still report a command that was finishing; the phone reads it from the pod
            guard isCurrent(manager) else { return completion(nil) }
            let now = Date()
            for event in events {
                guard let dose = Self.dose(event) else { continue }
                state.noteDose(dose, at: now)
            }
            completion(nil)
        }
    }

    /// A pump event in the form that travels, under the identity the phone stores it by.
    nonisolated static func dose(_ event: NewPumpEvent) -> WatchLoopDose? {
        guard let entry = event.dose else { return nil }
        let kind: WatchLoopDose.Kind
        switch entry.type {
        case .bolus: kind = .bolus
        case .tempBasal: kind = .tempBasal
        case .suspend: kind = .suspend
        case .resume: kind = .resume
        default: return nil
        }
        return WatchLoopDose(
            kind: kind,
            syncIdentifier: entry.syncIdentifier ?? WatchLoopIdentity.hexEncoded(event.raw),
            startDate: entry.startDate,
            endDate: entry.endDate,
            value: kind == .bolus ? entry.programmedUnits : kind == .tempBasal ? entry.unitsPerHour : 0,
            deliveredUnits: entry.deliveredUnits,
            automatic: entry.automatic ?? (kind != .bolus),
            isMutable: entry.isMutable
        )
    }

    nonisolated func pumpManager(
        _: PumpManager,
        didReadReservoirValue units: Double,
        at date: Date,
        completion: @escaping (Result<
            (newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool),
            Error
        >)
            -> Void
    ) {
        struct Reading: ReservoirValue {
            let startDate: Date
            let unitVolume: Double
        }
        completion(.success((
            newValue: Reading(startDate: date, unitVolume: units),
            lastValue: nil,
            areStoredValuesContinuous: false
        )))
    }

    nonisolated func startDateToFilterNewPumpEvents(for _: PumpManager) -> Date {
        Date().addingTimeInterval(-24 * 3600)
    }

    /// Cycles run on the CGM's readings.
    nonisolated func pumpManagerBLEHeartbeatDidFire(_: PumpManager) {}
    nonisolated func pumpManagerMustProvideBLEHeartbeat(_: PumpManager) -> Bool { false }
    nonisolated func pumpManagerWillDeactivate(_: PumpManager) {}
    nonisolated func pumpManager(_: PumpManager, didUpdate _: PumpManagerStatus, oldStatus _: PumpManagerStatus) {}
    nonisolated func pumpManagerPumpWasReplaced(_: PumpManager) {}
    nonisolated func pumpManager(_: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents _: Bool) {}
    nonisolated func pumpManager(_: PumpManager, didAdjustPumpClockBy _: TimeInterval) {}

    nonisolated func pumpManager(_: PumpManager, didError error: PumpManagerError) {
        WatchLogger.shared.warning(.treatments, "Watch Loop pump error", error: error)
    }

    /// The schedule is the phone's; the audit uses the same one.
    nonisolated func pumpManager(
        _: PumpManager,
        didRequestBasalRateScheduleChange _: BasalRateSchedule,
        completion: @escaping (Error?) -> Void
    ) {
        completion(PumpManagerError.configuration(nil))
    }

    nonisolated var detectedSystemTimeOffset: TimeInterval { 0 }

    nonisolated var automaticDosingEnabled: Bool {
        MainActor.assumeIsolated { state.phase == .active && state.closedLoop }
    }

    nonisolated func deviceManager(
        _: DeviceManager,
        logEventForDeviceIdentifier _: String?,
        type: DeviceLogEntryType,
        message: String,
        completion: ((Error?) -> Void)?
    ) {
        WatchLogger.shared.debug(.treatments, "Pump \(type): \(message)")
        completion?(nil)
    }

    nonisolated func deviceManagerControlDidBecomeReady(_: DeviceManager) {}
    nonisolated func deviceManager(_: DeviceManager, recordAnalyticsEvent _: String, properties _: [AnyHashable: Any]?) {}

    /// The pod's alerts (expiry, low reservoir, faults) are the watch's while it holds the pod.
    nonisolated func issueAlert(_ alert: Alert) {
        MainActor.assumeIsolated {
            notify(alert.backgroundContent.title, alert.backgroundContent.body)
            WatchLogger.shared.info(.treatments, "Pod alert: \(alert.identifier.alertIdentifier)")
        }
    }

    nonisolated func retractAlert(identifier _: Alert.Identifier) {}

    nonisolated func doesIssuedAlertExist(identifier _: Alert.Identifier, completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(false))
    }

    nonisolated func lookupAllUnretracted(
        managerIdentifier _: String,
        completion: @escaping (Result<[PersistedAlert], Error>) -> Void
    ) {
        completion(.success([]))
    }

    nonisolated func lookupAllUnacknowledgedUnretracted(
        managerIdentifier _: String,
        completion: @escaping (Result<[PersistedAlert], Error>) -> Void
    ) {
        completion(.success([]))
    }

    nonisolated func recordRetractedAlert(_: Alert, at _: Date) {}
}

extension PumpManager {
    func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enactTempBasal(unitsPerHour: unitsPerHour, for: duration) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func enactBolus(units: Double, automatic: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enactBolus(units: units, activationType: automatic ? .automatic : .manualRecommendationAccepted) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// The pump's own status read, at most `timeout` long. True when it answered.
    func refreshStatus(timeout: TimeInterval) async -> Bool {
        let started = Date()
        let lastSync: Date? = await withCheckedContinuation { continuation in
            let once = OnceFlag()
            ensureCurrentPumpData { date in if once.claim() { continuation.resume(returning: date) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { if once.claim() { continuation.resume(returning: nil) } }
        }
        return (lastSync ?? .distantPast) >= started.addingTimeInterval(-60)
    }
}

/// Resumes a continuation once, from whichever of two paths comes first.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
