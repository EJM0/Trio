import CoreData
import Foundation
import LoopKit
import OmnipodKit
import Swinject
import UserNotifications
import WatchConnectivity

/// The phone's side of the Watch Loop: it lends the pump to the watch, stores what the watch records, and takes the
/// pump back (after LoopKit/Loop#2545's PodLoanPhoneController). Every decision about who controls the pump comes from
/// `WatchLoopControl`; this carries them out.
protocol WatchLoopPhoneManager: AnyObject {
    /// A Watch Loop message from the watch, from any channel. Ignores anything else.
    func receive(_ userInfo: [String: Any])
    /// The looper tapped Take Back on the phone. Returns why it couldn't, or nil once the phone has the pump.
    func takeBack() async -> String?
    /// Asked before every dose the phone sends: false holds it.
    func mayDose() async -> Bool
    /// After each of the phone's own loops.
    func didLoop() async
    var state: WatchLoopPhoneState { get }
}

final class BaseWatchLoopPhoneManager: WatchLoopPhoneManager, Injectable, ObservableObject {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var deviceDataManager: DeviceDataManager!
    @Injected() private var fetchGlucoseManager: FetchGlucoseManager!
    @Injected() private var storage: FileStorage!
    @Injected() private var pumpHistoryStorage: PumpHistoryStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var tddStorage: TDDStorage!
    @Injected() private var tempTargetsStorage: TempTargetsStorage!
    @Injected() private var overrideStorage: OverrideStorage!
    @Injected() private var apsManager: APSManager!

    /// Touched on the main actor only.
    @Published private(set) var state: WatchLoopPhoneState {
        didSet { save() }
    }

    /// The watch has the pump, or is handing it over.
    var isWatchInCharge: Bool { state.role != .holdsPump }

    /// The doses the watch recorded in the running session, for the audit at its end.
    private var sessionDoses: [WatchLoopDose] = []
    private var seen = WatchLoopSeenEnvelopes()
    private var pendingQuery: (id: UUID, onSilence: WatchLoopControl.Decision)?
    private var overdueTimer: Timer?
    /// Insulin a pump reading showed that the phone's records don't explain, while it asks the watch.
    private var unexplained: (units: Double, reading: (units: Double, at: Date))?
    /// What the last copy was made from, so an unchanged one isn't sent again.
    private var standingCopyFingerprint: String?

    init(resolver: Resolver) {
        state = Self.load()
        injectServices(resolver)
        WatchLoopGate.update(state.role)
        DispatchQueue.main.async { [weak self] in
            self?.overdueTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkOverdue() }
            }
        }
    }

    // MARK: - State

    private static func load() -> WatchLoopPhoneState {
        guard let data = UserDefaults.standard.data(forKey: WatchLoopGate.storageKey),
              let state = try? JSONDecoder().decode(WatchLoopPhoneState.self, from: data)
        else { return WatchLoopPhoneState() }
        return state
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: WatchLoopGate.storageKey)
        }
        WatchLoopGate.update(state.role)
    }

    // MARK: - The wire

    func receive(_ userInfo: [String: Any]) {
        let envelope: WatchLoopTransport.Envelope
        do {
            guard let decoded = try WatchLoopTransport.decode(userInfo) else { return }
            envelope = decoded
        } catch {
            warning(.watch, "Watch Loop message unreadable", error: error)
            return
        }
        Task { @MainActor in await self.handle(envelope) }
    }

    @MainActor private func handle(_ envelope: WatchLoopTransport.Envelope) async {
        guard seen.firstSighting(of: envelope.id) else { return }
        switch envelope.message {
        case let .request(request): await grant(request)
        case let .checkpoint(checkpoint): await receiveCheckpoint(checkpoint)
        case let .handBack(handBack): await receiveHandBack(handBack)
        case let .statusReport(report): await receiveReport(report)
        case .ack,
             .grant,
             .handBackAck,
             .standingCopy,
             .startRefused,
             .statusQuery,
             .stop:
            break
        }
    }

    /// Bookkeeping goes queued; what a person or a query waits through also goes live (`WatchLoopTransport`).
    @MainActor private func send(_ message: WatchLoopMessage) {
        let session = WCSession.default
        guard session.activationState == .activated, let payload = try? WatchLoopTransport.encode(message) else { return }
        if WatchLoopTransport.ridesBothChannels(message), session.isReachable, WatchLoopTransport.fitsLivePath(payload) {
            session.sendMessage(payload, replyHandler: nil) { error in
                debug(.watch, "Watch Loop \(message.kind) not delivered live: \(error.localizedDescription)")
            }
        }
        session.transferUserInfo(payload)
        debug(.watch, "Watch Loop sent \(message.kind)")
    }

    // MARK: - Lending the pump

    private var controllablePump: (PumpManager & ExclusiveDeviceControl)? {
        deviceDataManager.pumpManager as? (PumpManager & ExclusiveDeviceControl)
    }

    @MainActor private func grant(_ request: WatchLoopRequest) async {
        func refuse(_ reason: String) {
            info(.watch, "Watch Loop start refused: \(reason)")
            send(.startRefused(requestID: request.id, reason: reason))
        }
        guard settingsManager.settings.watchLoopEnabled else {
            return refuse(String(localized: "Watch Loop is off in Trio's settings."))
        }
        guard state.role == .holdsPump else { return refuse(String(localized: "The watch already has the pump.")) }
        guard Date().timeIntervalSince(request.sentAt) < WatchLoopControl.takeoverLease else {
            return refuse(String(localized: "The request arrived too late. Try again."))
        }
        guard let pump = controllablePump, let odometer = pump as? PumpDeliveryOdometer else {
            return refuse(String(localized: "This pump can't be handed to the watch."))
        }
        guard let cgm = fetchGlucoseManager.cgmManager as? DeviceConfigurationSharing, cgm.isConfigurationSharingEnabled else {
            return refuse(String(localized: "Turn on Read on Apple Watch in the CGM's settings first."))
        }
        if case .noBolus = pump.status.bolusState {} else {
            return refuse(WatchLoopControl.bolusRefusal(.init(endsAt: odometer.bolusUnderWayEndsAt), now: Date()))
        }

        // the phone's own loop may be talking to the pod: a grant waits for it, briefly
        var waited = 0
        while apsManager.isLooping.value, waited < 20 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
        }
        guard !apsManager.isLooping.value else {
            return refuse(String(localized: "Your iPhone is looping right now. Try again in a moment."))
        }

        _ = await odometer.refreshDeliveredUnits()
        let session = max(state.session, request.highestSession) + 1
        let grant: WatchLoopGrant
        do {
            grant = try await makeGrant(session: session, pump: pump, cgm: cgm)
        } catch {
            warning(.watch, "Watch Loop grant could not be built", error: error)
            return refuse(String(localized: "Trio couldn't gather its settings for the watch."))
        }

        pump.releaseControl()
        // the driver keeps the pump while a command to it is unconfirmed
        guard pump.isControlReleased else {
            pump.takeControl()
            return refuse(WatchLoopControl.unconfirmedCommandRefusal)
        }

        var next = state
        next.role = .lending
        next.session = session
        next.sessionStartedAt = Date()
        next.lastReportAt = Date()
        next.liveStatus = nil
        next.deliveredAtRelease = odometer.deliveredUnits?.units
        next.releasedAt = Date()
        state = next
        sessionDoses = []
        info(.watch, "Watch Loop session \(session) granted; the phone let go of the pump")
        send(.grant(grant))

        // the grant or the takeover may be lost: the watch reports once it has the pump, else the phone asks
        let grantedAt = next.lastReportAt
        try? await Task.sleep(nanoseconds: UInt64((WatchLoopControl.takeoverLease + 5) * 1_000_000_000))
        guard state.session == session, state.role == .lending, state.lastReportAt == grantedAt, pendingQuery == nil
        else { return }
        await run(.query(.inBackground, onSilence: .takeOnSilence(.watchDidNotTake)))
    }

    private enum GrantError: Error {
        case missingSetting(String)
    }

    private func setting<T: JSON>(_ name: String, as type: T.Type) async throws -> T {
        guard let value = await storage.retrieveAsync(name, as: type) else { throw GrantError.missingSetting(name) }
        return value
    }

    private func plist(_ configuration: SharedDeviceConfiguration) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: configuration.rawValue, format: .binary, options: 0)
    }

    private func makeGrant(
        session: Int,
        pump: PumpManager & ExclusiveDeviceControl,
        cgm: DeviceConfigurationSharing
    ) async throws -> WatchLoopGrant {
        let settings = settingsManager.settings
        let now = Date()
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "watchLoopGrant"
        let preferences = try await setting(OpenAPS.Settings.preferences, as: Preferences.self)
        let (tdd, activeOverride, overridePresets) = try await context.perform {
            let tdd = try OpenAPS.tddSummary(now: now, on: context)
            let active = (try CoreDataStack.shared.fetchEntities(
                ofType: OverrideStored.self,
                onContext: context,
                predicate: NSPredicate.lastActiveOverride,
                key: "date",
                ascending: false,
                fetchLimit: 1
            ) as? [OverrideStored])?.first?.orefOverride(preferences: preferences)
            let presets = (try CoreDataStack.shared.fetchEntities(
                ofType: OverrideStored.self,
                onContext: context,
                predicate: NSPredicate.allOverridePresets,
                key: "orderPosition",
                ascending: true
            ) as? [OverrideStored] ?? []).map { $0.orefOverride(preferences: preferences) }
            return (tdd, active, presets)
        }

        return WatchLoopGrant(
            session: session,
            issuedAt: now,
            leaseExpiresAt: now.addingTimeInterval(WatchLoopControl.takeoverLease),
            pumpConfiguration: try plist(pump.exportConfiguration()),
            cgmConfiguration: try plist(cgm.exportConfiguration()),
            pumpSettings: try await setting(OpenAPS.Settings.settings, as: PumpSettings.self),
            bgTargets: try await setting(OpenAPS.Settings.bgTargets, as: BGTargets.self),
            basalProfile: try await setting(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self),
            insulinSensitivities: try await setting(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self),
            carbRatios: try await setting(OpenAPS.Settings.carbRatios, as: CarbRatios.self),
            preferences: preferences,
            dosingMode: settings.dosingMode,
            smoothGlucose: settings.smoothGlucose,
            units: settings.units,
            tdd: tdd,
            hasSufficientTDD: try await tddStorage.hasSufficientTDD(),
            autosens: await storage.retrieveAsync(OpenAPS.Settings.autosense, as: Autosens.self),
            maxBolus: settingsManager.pumpSettings.maxBolus,
            maxCarbs: settings.maxCarbs,
            bolusCalculator: WatchLoopBolusSettings(
                fraction: settings.overrideFactor,
                fattyMeals: settings.fattyMeals,
                fattyMealFactor: settings.fattyMealFactor,
                sweetMeals: settings.sweetMeals,
                sweetMealFactor: settings.sweetMealFactor
            ),
            lowGlucose: settings.low,
            highGlucose: settings.high,
            pumpHistory: try await pumpHistoryStorage.getPumpHistory(),
            // raw: the watch smooths them together with its own readings
            glucose: try await glucoseStorage.getGlucoseForAlgorithm(shouldSmoothGlucose: false, fetchHours: 24),
            carbs: try await carbsStorage.getCarbsForAlgorithm(additionalCarbs: nil, carbsDate: nil),
            activeOverride: activeOverride,
            tempTargets: await storage.retrieveAsync(OpenAPS.Settings.tempTargets, as: [TempTarget].self) ?? [],
            overridePresets: overridePresets,
            tempTargetPresets: tempTargetsStorage.presets(),
            lastDetermination: nil
        )
    }

    // MARK: - The watch's word

    @MainActor private func claimed(_ session: Int) -> WatchLoopControl.ClaimedSession {
        if session > state.session { return .newer }
        if session == state.session, state.role != .holdsPump { return .current }
        return .closed
    }

    @MainActor private func situation(_ trigger: WatchLoopControl.Trigger) -> WatchLoopControl.Situation {
        WatchLoopControl.Situation(
            device: .phone,
            trigger: trigger,
            phoneRole: state.role,
            tookOverOnSilenceAt: state.tookOverOnSilenceAt,
            sensorFresh: glucoseStorage.isGlucoseFresh(),
            standingCopyOut: state.standingCopyOut
        )
    }

    @MainActor private func receiveCheckpoint(_ checkpoint: WatchLoopCheckpoint) async {
        let claim = WatchLoopControl.Claim(
            session: claimed(checkpoint.session),
            startedAt: checkpoint.startedAt,
            pumpReachable: true,
            refusedBefore: state.refusedSessions.contains(checkpoint.session)
        )
        let decision = WatchLoopControl.decide(situation(.watchClaims(claim)))
        switch decision {
        case .renewHold:
            var next = state
            next.lastReportAt = max(next.lastReportAt ?? .distantPast, checkpoint.sentAt)
            next.liveStatus = checkpoint.status ?? next.liveStatus
            state = next
            // the watch's loop is the loop: Home shows it, and Not Looping waits for it
            if let loopedAt = checkpoint.status?.lastLoopAt { apsManager.lastLoopDateSubject.send(loopedAt) }
        case .standAside:
            await standAside(for: checkpoint.session, startedAt: checkpoint.startedAt)
        default:
            break
        }
        // insulin is booked whatever the decision (rule 1); carbs only while the session runs, as a session that is
        // over can no longer dose for them
        let running = state.session == checkpoint.session && state.role != .holdsPump
        let stored = await store(checkpoint.records, carbsAllowed: running)
        send(.ack(session: checkpoint.session, recordIDs: stored))
        if decision == .sendStop { refuse(checkpoint.session) }
    }

    @MainActor private func receiveReport(_ report: WatchLoopStatusReport) async {
        if !report.holdsPump, let pending = state.stopPendingSession, (report.session ?? 0) >= pending {
            state.stopPendingSession = nil
            state.stopPendingSince = nil
        }
        if let query = pendingQuery, report.replyTo == query.id {
            pendingQuery = nil
            let answer: WatchLoopControl.Answer = !report.holdsPump ? .holdsNothing
                : report.pumpReachable == false ? .holdsPumpButCannotReach : .answered
            if answer == .answered { state.lastReportAt = Date() }
            await run(WatchLoopControl.afterQuery(answer, onSilence: query.onSilence))
            guard answer == .answered else { return }
        }
        // the watch never took the pump it was granted (or let it go): no reason to wait for the query
        if !report.holdsPump, state.role == .lending, report.session == state.session {
            await run(.takeOnSilence(.watchDidNotTake))
            return
        }
        guard report.holdsPump, let session = report.session else { return }
        let claim = WatchLoopControl.Claim(
            session: claimed(session),
            startedAt: report.startedAt,
            pumpReachable: report.pumpReachable,
            refusedBefore: state.refusedSessions.contains(session)
        )
        let decision = WatchLoopControl.decide(situation(.watchClaims(claim)))
        if decision == .renewHold { state.lastReportAt = Date() }
        if decision == .sendStop { refuse(session) }
        if decision == .standAside { await standAside(for: session, startedAt: report.startedAt) }
        // a watch that dosed and doesn't keep the pump: its insulin is booked (rule 1), and the phone doses on
        if let unexplained, state.role == .holdsPump {
            await bookPlaceholder(unexplained.units)
            verified(unexplained.reading)
            self.unexplained = nil
        }
    }

    /// The stop goes again on each overdue check until the watch reports it holds nothing (at most 30 min): a watch
    /// off when it was sent hears it when it comes back.
    @MainActor private func sendStop(_ session: Int) {
        var next = state
        if next.stopPendingSession != session { next.stopPendingSince = Date() }
        next.stopPendingSession = session
        state = next
        send(.stop(session: session))
    }

    @MainActor private func refuse(_ session: Int) {
        if !state.refusedSessions.contains(session) { state.refusedSessions.append(session) }
        sendStop(session)
    }

    /// Control row 17: a watch that started without the phone and is alive keeps the pump.
    @MainActor private func standAside(for session: Int, startedAt: Date?) async {
        guard let pump = controllablePump else { return }
        // the driver keeps the pod while a command is unconfirmed: asked again until it lets go
        pump.releaseControl()
        let deadline = Date().addingTimeInterval(30)
        while !pump.isControlReleased, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            pump.releaseControl()
        }
        guard pump.isControlReleased else {
            warning(.watch, "Watch Loop: the pod driver didn't let go; the phone doesn't stand aside")
            return
        }
        var next = state
        next.role = .standingAside
        next.session = session
        next.sessionStartedAt = startedAt
        next.lastReportAt = Date()
        next.deliveredAtRelease = (pump as? PumpDeliveryOdometer)?.deliveredUnits?.units
        next.releasedAt = Date()
        state = next
        sessionDoses = []
        unexplained = nil
        info(.watch, "Watch Loop: standing aside for the watch's session \(session)")
    }

    // MARK: - Storing the watch's records

    /// Stores each record once, through the phone's own stores, so Nightscout, statistics and TDD see them as
    /// they see the phone's own. Returns every id handled, stored now or before, for the acknowledgement.
    @MainActor private func store(_ records: [WatchLoopRecord], carbsAllowed: Bool) async -> [UUID] {
        var handled: [UUID] = []
        for record in records.sorted(by: { $0.seq < $1.seq }) {
            if state.storedRecordIDs.contains(record.id) {
                handled.append(record.id)
                continue
            }
            do {
                try await store(record.kind, carbsAllowed: carbsAllowed)
                handled.append(record.id)
            } catch {
                // not acknowledged: the watch sends it again
                warning(.watch, "Watch Loop record \(record.seq) not stored", error: error)
            }
        }
        state.noteStored(handled)
        return handled
    }

    @MainActor private func store(_ kind: WatchLoopRecord.Kind, carbsAllowed: Bool) async throws {
        switch kind {
        case let .dose(dose):
            sessionDoses.removeAll { $0.syncIdentifier == dose.syncIdentifier }
            sessionDoses.append(dose)
            try await pumpHistoryStorage.storePumpEvents([Self.pumpEvent(dose)], replacePendingEvents: false)
        case let .carbs(entry):
            guard carbsAllowed else { return }
            try await carbsStorage.storeCarbs([entry], areFetchedFromRemote: false)
        case let .carbsDeleted(id):
            guard let uuid = UUID(uuidString: id) else { return }
            let context = CoreDataStack.shared.newTaskContext()
            let objectID: NSManagedObjectID? = try await context.perform {
                let request = CarbEntryStored.fetchRequest() as NSFetchRequest<CarbEntryStored>
                request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                request.fetchLimit = 1
                return try context.fetch(request).first?.objectID
            }
            if let objectID { await carbsStorage.deleteCarbsEntryStored(objectID) }
        case let .override(override):
            if let override {
                try await overrideStorage.storeOverride(override: override)
            } else {
                try await endRunningOverride()
            }
        case let .tempTarget(tempTarget):
            try await tempTargetsStorage.storeTempTarget(tempTarget: tempTarget ?? TempTarget.cancel(at: Date()))
        }
    }

    private func endRunningOverride() async throws {
        let context = CoreDataStack.shared.newTaskContext()
        try await context.perform {
            let running = try CoreDataStack.shared.fetchEntities(
                ofType: OverrideStored.self,
                onContext: context,
                predicate: NSPredicate.lastActiveOverride,
                key: "date",
                ascending: false
            ) as? [OverrideStored] ?? []
            running.forEach { $0.enabled = false }
            if context.hasChanges { try context.save() }
        }
    }

    /// The watch's dose as a pump event with the identity it was recorded under.
    static func pumpEvent(_ dose: WatchLoopDose) -> NewPumpEvent {
        let entry: DoseEntry
        let type: PumpEventType
        switch dose.kind {
        case .bolus:
            type = .bolus
            entry = DoseEntry(
                type: .bolus,
                startDate: dose.startDate,
                endDate: dose.endDate,
                value: dose.value,
                unit: .units,
                deliveredUnits: dose.deliveredUnits,
                syncIdentifier: dose.syncIdentifier,
                automatic: dose.automatic,
                isMutable: dose.isMutable
            )
        case .tempBasal:
            type = .tempBasal
            entry = DoseEntry(
                type: .tempBasal,
                startDate: dose.startDate,
                endDate: dose.endDate,
                value: dose.value,
                unit: .unitsPerHour,
                syncIdentifier: dose.syncIdentifier,
                automatic: dose.automatic,
                isMutable: dose.isMutable
            )
        case .suspend:
            type = .suspend
            entry = DoseEntry(suspendDate: dose.startDate, automatic: dose.automatic)
        case .resume:
            type = .resume
            entry = DoseEntry(resumeDate: dose.startDate, automatic: dose.automatic)
        }
        return NewPumpEvent(
            date: dose.startDate,
            dose: entry,
            raw: WatchLoopIdentity.raw(dose.syncIdentifier),
            title: "Watch Loop \(dose.kind.rawValue)",
            type: type
        )
    }

    // MARK: - Taking the pump back

    @MainActor private func receiveHandBack(_ handBack: WatchLoopHandBack) async {
        guard handBack.session == state.session, state.role == .lending || state.role == .standingAside else {
            // a hand-back of a session already over: answer again, harmless to receive twice
            if handBack.session <= state.session { send(.handBackAck(session: handBack.session)) }
            return
        }
        let previous = state.role
        state.role = .transferring
        _ = await store(handBack.records, carbsAllowed: true)
        if handBack.podEnded == true {
            // the pod was deactivated or discarded on the watch: nothing to take back
            (controllablePump as? OmniPumpManager)?.forgetPodEndedElsewhere()
            controllablePump?.takeControl()
            send(.handBackAck(session: handBack.session))
            finish()
            info(.watch, "Watch Loop session \(handBack.session) ended with the pod on the watch")
            return
        }
        guard await take(within: 30) else {
            // the watch keeps the pump and offers it again
            controllablePump?.releaseControl()
            state.role = previous
            info(.watch, "Watch Loop hand-back: the phone couldn't reach the pump; the watch keeps it")
            return
        }
        send(.handBackAck(session: handBack.session))
        await audit(recordsComplete: true)
        finish()
        info(.watch, "Watch Loop session \(handBack.session) handed back")
    }

    func takeBack() async -> String? {
        await MainActor.run { () -> Bool in
            state.role == .lending || state.role == .standingAside
        } ? await takeBackNow() : nil
    }

    @MainActor private func takeBackNow() async -> String? {
        let previous = state.role
        state.role = .transferring
        guard await take(within: 5) else {
            controllablePump?.releaseControl()
            state.role = previous
            return String(localized: "Trio couldn't reach the pod. Try again near it.")
        }
        sendStop(state.session)
        await audit(recordsComplete: false)
        finish()
        info(.watch, "Watch Loop: taken back on the phone")
        return nil
    }

    /// Reaches for the pump: `takeControl()` until the link is up and the pump answered. #177 escalates the take
    /// by itself until the pump answers.
    @MainActor private func take(within seconds: TimeInterval) async -> Bool {
        guard let pump = controllablePump else { return false }
        pump.takeControl()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !pump.isControlReleased, pump.isControlReady { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return !pump.isControlReleased && pump.isControlReady
    }

    @MainActor private func finish() {
        var next = state
        next.role = .holdsPump
        next.liveStatus = nil
        next.deliveredAtRelease = nil
        next.releasedAt = nil
        state = next
        sessionDoses = []
    }

    /// The pump's own total against the records (control document, rule 1). After a hand-back the records are
    /// complete, so a difference is only reported; after a take-back records may be missing, so the difference is
    /// booked as a bolus now, which can only overstate IOB.
    @MainActor private func audit(recordsComplete: Bool) async {
        guard let odometer = controllablePump as? PumpDeliveryOdometer, await odometer.refreshDeliveredUnits(),
              let latest = odometer.deliveredUnits, let start = state.deliveredAtRelease, let releasedAt = state.releasedAt
        else {
            warning(.watch, "Watch Loop audit skipped: no pump total to compare")
            return
        }
        let basalProfile = await storage.retrieveAsync(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
        let delivered = latest.units - start
        let recorded = WatchLoopAudit.recordedInsulin(sessionDoses, basalProfile: basalProfile, from: releasedAt, to: latest.at)
        // whatever the audit finds is booked or reported here; the check before each dose starts again from now
        defer { verified(latest) }
        switch WatchLoopAudit.compare(delivered: delivered, recorded: recorded) {
        case .matches:
            info(.watch, "Watch Loop audit: the pump's \(delivered) U match the records")
        case let .missing(units):
            guard !recordsComplete else {
                warning(.watch, "Watch Loop audit: the pump delivered \(units) U more than the complete records")
                return
            }
            await bookPlaceholder(units)
        case let .overstated(units):
            notify(
                id: "watchLoop.overstated",
                title: String(localized: "Insulin On Board May Be Overstated"),
                body: String(
                    localized: "The records claim \((units * 100).rounded() / 100) U more than the pod delivered."
                )
            )
        }
    }

    /// Insulin the records don't explain, booked as a bolus now: IOB errs high, so dosing errs low. Reminders follow,
    /// as the watch's records, once they arrive, explain it.
    @MainActor private func bookPlaceholder(_ units: Double) async {
        let rounded = Decimal((units * 20).rounded(.down) / 20)
        guard rounded > 0 else { return }
        await pumpHistoryStorage.storeExternalInsulinEvent(amount: rounded, timestamp: Date())
        warning(.watch, "Watch Loop: booked \(rounded) U the records don't explain")
        notify(
            id: "watchLoop.placeholder",
            title: String(localized: "Insulin From the Watch Booked"),
            body: String(
                localized: "The pod delivered \(rounded.formatted()) U the iPhone's records don't explain. Trio booked it as a bolus now."
            )
        )
        for hours in [2.0, 4.0] {
            notify(
                id: "watchLoop.placeholder.\(Int(hours))",
                title: String(localized: "Check the Watch's Insulin"),
                body: String(
                    localized: "Trio booked insulin its records didn't explain. Bring the watch near the iPhone to replace it with the watch's records."
                ),
                after: hours * 3600
            )
        }
    }

    // MARK: - The copy for a start without the phone

    /// After each of the phone's own loops, with Allow Without iPhone on: a new copy when the insulin, carbs or
    /// settings changed, and every 30 min regardless. Only the newest waits in the queue.
    func didLoop() async {
        await MainActor.run { () -> Bool in state.role == .holdsPump } ? await refreshStandingCopy() : ()
    }

    @MainActor private func refreshStandingCopy() async {
        guard settingsManager.settings.watchLoopEnabled, settingsManager.settings.watchLoopWithoutPhone else {
            if state.standingCopyOut { info(.watch, "Watch Loop: Allow Without iPhone is off; the copy is no longer renewed") }
            return
        }
        guard let pump = controllablePump, let odometer = pump as? PumpDeliveryOdometer,
              let cgm = fetchGlucoseManager.cgmManager as? DeviceConfigurationSharing, cgm.isConfigurationSharingEnabled,
              let reading = odometer.deliveredUnits
        else { return }
        var copy: WatchLoopGrant
        do {
            copy = try await makeGrant(session: state.session, pump: pump, cgm: cgm)
        } catch {
            warning(.watch, "Watch Loop copy could not be built", error: error)
            return
        }
        let fingerprint = [
            copy.pumpHistory.first?.id ?? "",
            copy.carbs.map { $0.id ?? "" }.joined(),
            String(describing: copy.basalProfile.map(\.rate)),
            String(describing: copy.preferences.maxIOB),
            copy.activeOverride?.id ?? "",
            copy.tempTargets.last?.id ?? ""
        ].joined(separator: "|")
        let sentAt = state.standingCopySentAt ?? .distantPast
        guard fingerprint != standingCopyFingerprint || Date().timeIntervalSince(sentAt) > WatchLoopStanding.refreshInterval
        else { return }
        // issued expired: a start from it takes a new session and lease (`WatchLoopSession.startWithoutPhone`)
        copy = WatchLoopGrant(
            session: copy.session, issuedAt: copy.issuedAt, leaseExpiresAt: copy.issuedAt,
            pumpConfiguration: copy.pumpConfiguration, cgmConfiguration: copy.cgmConfiguration,
            pumpSettings: copy.pumpSettings, bgTargets: copy.bgTargets, basalProfile: copy.basalProfile,
            insulinSensitivities: copy.insulinSensitivities, carbRatios: copy.carbRatios, preferences: copy.preferences,
            dosingMode: copy.dosingMode, smoothGlucose: copy.smoothGlucose, units: copy.units, tdd: copy.tdd,
            hasSufficientTDD: copy.hasSufficientTDD, autosens: copy.autosens, maxBolus: copy.maxBolus,
            maxCarbs: copy.maxCarbs, bolusCalculator: copy.bolusCalculator, lowGlucose: copy.lowGlucose,
            highGlucose: copy.highGlucose, pumpHistory: copy.pumpHistory, glucose: copy.glucose, carbs: copy.carbs,
            activeOverride: copy.activeOverride, tempTargets: copy.tempTargets, overridePresets: copy.overridePresets,
            tempTargetPresets: copy.tempTargetPresets, lastDetermination: copy.lastDetermination,
            deliveredUnits: reading.units, deliveredUnitsAt: reading.at
        )
        let session = WCSession.default
        for transfer in session.outstandingUserInfoTransfers {
            if let envelope = try? WatchLoopTransport.decode(transfer.userInfo), case .standingCopy = envelope.message {
                transfer.cancel()
            }
        }
        send(.standingCopy(copy))
        standingCopyFingerprint = fingerprint
        var next = state
        next.standingCopyOut = true
        next.standingCopySentAt = Date()
        if next.verifiedDelivered == nil {
            next.verifiedDelivered = reading.units
            next.verifiedAt = reading.at
        }
        state = next
        debug(.watch, "Watch Loop: copy for a start without the iPhone sent")
    }

    // MARK: - Before the phone doses

    /// While a copy is out, a watch may have started from it: each dose waits for a pump reading whose total the
    /// phone's own records explain. Insulin they don't means another controller dosed: the phone asks the watch
    /// whether it holds the pump (it stands aside if so, control row 17) and, without an answer, books the
    /// difference as a bolus and loops on (rows 5 and 18).
    func mayDose() async -> Bool {
        await check()
    }

    @MainActor private func check() async -> Bool {
        guard state.role == .holdsPump else { return false }
        guard state.standingCopyOut else { return true }
        guard unexplained == nil, pendingQuery == nil else { return false }
        guard let odometer = controllablePump as? PumpDeliveryOdometer else { return true }
        if (odometer.deliveredUnits?.at ?? .distantPast) < Date().addingTimeInterval(-120) {
            _ = await odometer.refreshDeliveredUnits()
        }
        guard let reading = odometer.deliveredUnits, reading.at > Date().addingTimeInterval(-300) else {
            warning(.watch, "Watch Loop: no recent pump total; the phone doesn't dose until it has one")
            return false
        }
        guard let baseline = state.verifiedDelivered, let since = state.verifiedAt, reading.at > since else {
            verified(reading)
            return true
        }
        let basalProfile = await storage.retrieveAsync(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
        let history = (try? await pumpHistoryStorage.getPumpHistory()) ?? []
        let recorded = WatchLoopAudit.recordedInsulin(
            WatchLoopStanding.doses(history, now: reading.at) { [controllablePump] units in
                controllablePump?.estimatedDuration(toBolus: units) ?? 0
            },
            basalProfile: basalProfile,
            from: since,
            to: reading.at
        )
        let delivered = reading.units - baseline
        guard case let .missing(units) = WatchLoopAudit.compare(delivered: delivered, recorded: recorded) else {
            verified(reading)
            return true
        }
        warning(.watch, "Watch Loop: the pod delivered \(units) U the iPhone's records don't explain; asking the watch")
        unexplained = (units, reading)
        let decision = WatchLoopControl.decide(situation(.pumpReading(differenceBeyondBand: true)))
        Task { await run(decision) }
        return false
    }

    @MainActor private func verified(_ reading: (units: Double, at: Date)) {
        var next = state
        next.verifiedDelivered = reading.units
        next.verifiedAt = reading.at
        state = next
    }

    // MARK: - When the watch goes quiet

    @MainActor private func checkOverdue() {
        if let session = state.stopPendingSession {
            if Date().timeIntervalSince(state.stopPendingSince ?? Date()) < 30 * 60 {
                send(.stop(session: session))
            } else {
                state.stopPendingSession = nil
                state.stopPendingSince = nil
            }
        }
        guard state.role == .lending || state.role == .standingAside, pendingQuery == nil,
              let last = state.lastReportAt, Date().timeIntervalSince(last) > WatchLoopControl.watchReportOverdue
        else { return }
        Task { await run(WatchLoopControl.decide(situation(.watchReportOverdue))) }
    }

    @MainActor private func run(_ decision: WatchLoopControl.Decision) async {
        switch decision {
        case let .query(wait, onSilence):
            let id = UUID()
            pendingQuery = (id, onSilence)
            send(.statusQuery(id: id))
            try? await Task.sleep(nanoseconds: UInt64(wait.seconds * 1_000_000_000))
            guard pendingQuery?.id == id else { return }
            pendingQuery = nil
            await run(WatchLoopControl.afterQuery(.silence, onSilence: onSilence))
        case let .takeOnSilence(tell):
            let previous = state.role
            state.role = .transferring
            guard await take(within: 30) else {
                controllablePump?.releaseControl()
                state.role = previous
                return
            }
            state.tookOverOnSilenceAt = Date()
            sendStop(state.session)
            await audit(recordsComplete: false)
            finish()
            switch tell {
            case .watchNotResponding:
                notify(
                    id: "watchLoop.notResponding",
                    title: String(localized: "Watch Not Responding"),
                    body: String(localized: "The watch stopped reporting, so this iPhone took the pod back and loops again.")
                )
            case .watchDidNotTake:
                notify(
                    id: "watchLoop.didNotTake",
                    title: String(localized: "Watch Loop Didn't Start"),
                    body: String(localized: "The watch didn't take the pod. This iPhone kept it and loops again.")
                )
            default:
                break
            }
        case .keepPumpOnSilence:
            state.tookOverOnSilenceAt = Date()
            if let unexplained {
                await bookPlaceholder(unexplained.units)
                verified(unexplained.reading)
            }
            unexplained = nil
        case .sendStop:
            sendStop(state.session)
        default:
            break
        }
    }

    private func notify(id: String, title: String, body: String, after delay: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
