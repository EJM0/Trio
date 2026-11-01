import CoreData
import Foundation
import LoopKit
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
    var state: WatchLoopPhoneState { get }
}

final class BaseWatchLoopPhoneManager: WatchLoopPhoneManager, Injectable {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var deviceDataManager: DeviceDataManager!
    @Injected() private var fetchGlucoseManager: FetchGlucoseManager!
    @Injected() private var storage: FileStorage!
    @Injected() private var pumpHistoryStorage: PumpHistoryStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var tddStorage: TDDStorage!
    @Injected() private var tempTargetsStorage: TempTargetsStorage!
    @Injected() private var nightscoutManager: NightscoutManager!
    @Injected() private var healthKitManager: HealthKitManager!
    @Injected() private var overrideStorage: OverrideStorage!
    @Injected() private var apsManager: APSManager!
    @Injected() private var tidepoolManager: TidepoolManager!
    /// The phone's own algorithm inputs, so the watch's algorithm reads what the phone's would.
    private lazy var openAPS = OpenAPS(
        storage: storage,
        tddStorage: tddStorage,
        glucoseStorage: glucoseStorage,
        carbsStorage: carbsStorage
    )

    /// Touched on the main actor only.
    private(set) var state: WatchLoopPhoneState {
        didSet { save() }
    }

    private var seen = WatchLoopSeenEnvelopes()
    private var pendingQuery: (id: UUID, onSilence: WatchLoopControl.Decision)?
    private var overdueTimer: Timer?
    private var isAuditing = false

    init(resolver: Resolver) {
        state = Self.load()
        injectServices(resolver)
        WatchLoopGate.update(state)
        DispatchQueue.main.async { [weak self] in
            Task { await self?.uploadSpans() }
            // a transfer cut off by a kill is resolved now, not a cycle later; an audit waiting for the pod goes on
            self?.checkOverdue()
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
        WatchLoopGate.update(state)
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

        // The phone doses nothing more from here, and a loop under way finishes first, so the history and the total
        // the grant carries include the phone's last dose.
        state.role = .transferring
        func keep(_ reason: String) {
            state.role = .holdsPump
            refuse(reason)
        }
        guard await loopFinished(within: 30) else {
            return keep(String(localized: "Trio is looping. Try again in a minute."))
        }
        // the audit at the take-back needs the total at the release
        guard await odometer.refreshDeliveredUnits(), let deliveredAtRelease = odometer.deliveredUnits?.units else {
            return keep(String(localized: "Trio couldn't read the pod's insulin total. Try again near the pod."))
        }
        let session = max(state.session, request.highestSession) + 1
        let grant: WatchLoopGrant
        do {
            grant = try await makeGrant(session: session, pump: pump, cgm: cgm)
        } catch {
            warning(.watch, "Watch Loop grant could not be built", error: error)
            return keep(String(localized: "Trio couldn't gather its settings for the watch."))
        }

        pump.releaseControl()
        // the driver keeps the pump while a command to it is unconfirmed
        guard pump.isControlReleased else {
            pump.takeControl()
            return keep(WatchLoopControl.unconfirmedCommandRefusal)
        }

        var next = state
        next.role = .lending
        next.session = session
        next.sessionStartedAt = Date()
        next.lastReportAt = Date()
        next.liveStatus = nil
        next.deliveredAtRelease = deliveredAtRelease
        next.releasedAt = Date()
        next.noteSpan(at: Date())
        state = next
        info(.watch, "Watch Loop session \(session) granted; the phone let go of the pump")
        send(.grant(grant))

        // the grant or the takeover may be lost: the watch reports once it has the pump, else the phone asks
        let grantedAt = next.lastReportAt
        try? await Task.sleep(nanoseconds: UInt64((WatchLoopControl.takeoverLease + 5) * 1_000_000_000))
        guard state.session == session, state.role == .lending, state.lastReportAt == grantedAt, pendingQuery == nil
        else { return }
        await run(.query(.inBackground, onSilence: .takeOnSilence(.watchDidNotTake)))
    }

    /// A loop under way (`APSManager.isLooping`) ends within `seconds`.
    @MainActor private func loopFinished(within seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while apsManager.isLooping.value {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return true
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
            pumpHistory: try await openAPS.algorithmPumpHistory(),
            glucose: try await glucoseStorage.getGlucoseForAlgorithm(shouldSmoothGlucose: settings.smoothGlucose, fetchHours: 24),
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
        await reaudit(checkpoint.session, after: checkpoint.records)
    }

    @MainActor private func receiveReport(_ report: WatchLoopStatusReport) async {
        if let query = pendingQuery, report.replyTo == query.id {
            pendingQuery = nil
            let answer: WatchLoopControl.Answer = !report.holdsPump ? .holdsNothing
                : report.pumpReachable == false ? .holdsPumpButCannotReach : .answered
            if answer == .answered { state.lastReportAt = Date() }
            await run(WatchLoopControl.afterQuery(answer, onSilence: query.onSilence))
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
    }

    @MainActor private func refuse(_ session: Int) {
        if !state.refusedSessions.contains(session) { state.refusedSessions.append(session) }
        send(.stop(session: session))
    }

    /// Control row 17: a watch that started without the phone and is alive keeps the pump.
    @MainActor private func standAside(for session: Int, startedAt: Date?) async {
        guard let pump = controllablePump else { return }
        pump.releaseControl()
        var next = state
        next.role = .standingAside
        next.session = session
        next.sessionStartedAt = startedAt
        next.lastReportAt = Date()
        next.deliveredAtRelease = (pump as? PumpDeliveryOdometer)?.deliveredUnits?.units
        next.releasedAt = Date()
        next.noteSpan(at: Date())
        state = next
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
                // at once: a kill mid-batch must not store it again
                state.noteStored([record.id])
            } catch {
                // not acknowledged: the watch sends it again
                warning(.watch, "Watch Loop record \(record.seq) not stored", error: error)
            }
        }
        return handled
    }

    @MainActor private func store(_ kind: WatchLoopRecord.Kind, carbsAllowed: Bool) async throws {
        switch kind {
        case let .dose(dose):
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
        case let .glucoseDeleted(date):
            try await deleteManualGlucose(at: date)
        case let .override(override):
            if let override {
                try await overrideStorage.storeOverride(override: override)
            } else {
                try await endRunningOverride()
            }
        case let .tempTarget(tempTarget):
            try await tempTargetsStorage.storeTempTarget(tempTarget: tempTarget ?? TempTarget.cancel(at: Date()))
        case let .glucose(reading):
            // `mbg` makes it a manual reading, as History's Add Glucose stores one
            try await glucoseStorage.storeGlucose([reading])
        case let .determination(determination, enacted):
            // as the phone's own: its charts and loop status read it, and Nightscout gets it at its own time
            let context = CoreDataStack.shared.newTaskContext()
            context.name = "watchLoopDetermination"
            await openAPS.processDetermination(determination, on: context, enacted: enacted)
        }
    }

    /// The manual reading at a meter's BG deleted on the watch, deleted as History deletes one.
    private func deleteManualGlucose(at date: Date) async throws {
        let context = CoreDataStack.shared.newTaskContext()
        let found: (objectID: NSManagedObjectID, id: String?)? = try await context.perform {
            let request = GlucoseStored.fetchRequest() as NSFetchRequest<GlucoseStored>
            request.predicate = NSPredicate(
                format: "isManual == YES AND date >= %@ AND date <= %@",
                date.addingTimeInterval(-1) as NSDate,
                date.addingTimeInterval(1) as NSDate
            )
            request.fetchLimit = 1
            return try context.fetch(request).first.map { ($0.objectID, $0.id?.uuidString) }
        }
        guard let found else { return }
        if let id = found.id {
            await nightscoutManager.deleteGlucose(withID: id, withDate: date)
            await healthKitManager.deleteGlucose(syncID: id)
        }
        await glucoseStorage.deleteGlucose(found.objectID)
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
        // Stored before anything is acknowledged: an acknowledged record is gone from the watch. Carbs of the session
        // just ended count, it dosed for them; of an older one not, as for its checkpoints.
        let handled = await store(handBack.records, carbsAllowed: handBack.session == state.session)
        guard Set(handled) == Set(handBack.records.map(\.id)) else {
            // not all stored: the stored ones are acknowledged, the hand-back comes again
            send(.ack(session: handBack.session, recordIDs: handled))
            return
        }
        guard handBack.session == state.session, state.role == .lending || state.role == .standingAside else {
            // a session already over, or taken back meanwhile: its records are in, answer again
            if handBack.session <= state.session { send(.handBackAck(session: handBack.session)) }
            await reaudit(handBack.session, after: handBack.records)
            return
        }
        let previous = state.role
        state.role = .transferring
        guard await take(within: 30) else {
            // the watch keeps the pump and offers it again
            controllablePump?.releaseControl()
            state.role = previous
            info(.watch, "Watch Loop hand-back: the phone couldn't reach the pump; the watch keeps it")
            return
        }
        send(.handBackAck(session: handBack.session))
        openAudit(recordsComplete: true)
        finish()
        await runAudit()
        info(.watch, "Watch Loop session \(handBack.session) handed back")
    }

    func takeBack() async -> String? {
        switch await MainActor.run(body: { state.role }) {
        case .holdsPump:
            return nil
        case .transferring:
            return String(localized: "The pod is being handed over. Try again in a moment.")
        case .lending,
             .standingAside:
            return await takeBackNow()
        }
    }

    @MainActor private func takeBackNow() async -> String? {
        let previous = state.role
        state.role = .transferring
        guard await take(within: 5) else {
            controllablePump?.releaseControl()
            state.role = previous
            return String(localized: "Trio couldn't reach the pod. Try again near it.")
        }
        send(.stop(session: state.session))
        openAudit(recordsComplete: false)
        finish()
        await runAudit()
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
        next.noteSpan(at: Date())
        state = next
        Task { await uploadSpans() }
    }

    /// Each finished span as a Nightscout note with its duration; one that didn't go goes with the next, or at launch.
    @MainActor private func uploadSpans() async {
        for span in state.spans where !span.uploaded {
            guard let end = span.end, await nightscoutManager.uploadWatchLoopSession(from: span.start, to: end) else { continue }
            var next = state
            if let index = next.spans.firstIndex(where: { $0.start == span.start }) { next.spans[index].uploaded = true }
            state = next
        }
    }

    /// Opens the audit of a session the phone has just taken back; nothing to audit if the pump was never let go.
    @MainActor private func openAudit(recordsComplete: Bool) {
        guard let releasedAt = state.releasedAt else { return }
        state.openAudit = WatchLoopOpenAudit(
            session: state.session,
            releasedAt: releasedAt,
            deliveredAtRelease: state.deliveredAtRelease,
            recordsComplete: recordsComplete,
            takenAt: Date()
        )
    }

    /// More of an audited session's records arrived: the audit runs again, and its placeholder follows. Records that
    /// arrive after a take-back are what the watch still had, so without a total to compare against they end the hold.
    @MainActor private func reaudit(_ session: Int, after records: [WatchLoopRecord]) async {
        guard let audit = state.openAudit, audit.session == session, !records.isEmpty else { return }
        guard audit.deliveredAtRelease != nil else {
            // nothing to compare against: the records arriving is all the audit can wait for
            if audit.holdsDosing { releaseHold(String(localized: "The watch's records arrived.")) }
            state.openAudit = nil
            return
        }
        await runAudit()
    }

    /// The pod's total against what the pump history records from the release to the take (control document,
    /// rule 1): the watch's doses as stored, the phone's own, and the schedule. After a hand-back the records are
    /// complete, so a difference is only reported. After a take-back records may still be missing: the difference is
    /// booked as a bolus (IOB errs high, so dosing errs low) and rebooked as they arrive; until the pod's total could
    /// be read, the phone doses nothing by itself.
    @MainActor private func runAudit() async {
        guard !isAuditing, var audit = state.openAudit else { return }
        isAuditing = true
        defer { isAuditing = false }
        let odometer = controllablePump as? PumpDeliveryOdometer
        if audit.deliveredAtTake == nil {
            guard state.role == .holdsPump, let odometer, await odometer.refreshDeliveredUnits(),
                  let reading = odometer.deliveredUnits
            else {
                warning(.watch, "Watch Loop audit: no pump total yet")
                if !audit.recordsComplete, !audit.holdsDosing { hold(&audit) }
                return
            }
            audit.deliveredAtTake = reading.units
            audit.readAt = reading.at
        }
        guard let start = audit.deliveredAtRelease, let total = audit.deliveredAtTake, let readAt = audit.readAt else {
            // no total at the release: nothing to compare against until the watch's records are known to be in
            warning(.watch, "Watch Loop audit: no pump total from the release")
            if !audit.recordsComplete, !audit.holdsDosing { hold(&audit) }
            if audit.recordsComplete { state.openAudit = nil }
            return
        }
        let basalProfile = await storage.retrieveAsync(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
        let history = (try? await openAPS.algorithmPumpHistory()) ?? []
        let recorded = WatchLoopAudit.recordedInsulin(
            WatchLoopAudit.doses(history, now: readAt) { [controllablePump] units in
                controllablePump?.estimatedDuration(toBolus: units) ?? 0
            },
            basalProfile: basalProfile,
            from: audit.releasedAt,
            to: readAt,
            pulseUnits: odometer?.deliveryPulseUnits
        )
        let delivered = total - start
        var missing = 0.0
        switch WatchLoopAudit.compare(delivered: delivered, recorded: recorded) {
        case .matches:
            info(.watch, "Watch Loop audit: the pump's \(delivered) U match the records")
        case let .missing(units):
            missing = units
        case let .overstated(units):
            notify(
                id: "watchLoop.overstated",
                title: String(localized: "Insulin On Board May Be Overstated"),
                body: String(
                    localized: "The records claim \((units * 100).rounded() / 100) U more than the pod delivered."
                )
            )
        }
        if audit.holdsDosing {
            audit.holdsDosing = false
            releaseHold(String(localized: "The pod's insulin has been compared with the watch's records."))
        }
        guard !audit.recordsComplete else {
            if missing > 0 {
                warning(.watch, "Watch Loop audit: the pump delivered \(missing) U more than the complete records")
            }
            state.openAudit = nil
            return
        }
        await rebookPlaceholder(&audit, units: missing)
        state.openAudit = audit
    }

    /// Automatic dosing waits for the audit (`WatchLoopGate.automaticDosingHeld`).
    @MainActor private func hold(_ audit: inout WatchLoopOpenAudit) {
        audit.holdsDosing = true
        state.openAudit = audit
        warning(.watch, "Watch Loop: the phone loops open until the watch's insulin is checked")
        notify(
            id: "watchLoop.hold",
            title: String(localized: "Trio Loops Open for Now"),
            body: String(
                localized: "Trio couldn't compare the pod's insulin with the watch's records yet. It doses nothing by itself until it can; boluses still work."
            )
        )
    }

    @MainActor private func releaseHold(_ reason: String) {
        info(.watch, "Watch Loop: the phone loops closed again")
        notify(id: "watchLoop.hold", title: String(localized: "Trio Loops Again"), body: reason)
    }

    /// The placeholder for what the records don't explain, at the time of the reading: replaced when the amount
    /// changes, removed (here and wherever it was uploaded) when the records explain everything.
    @MainActor private func rebookPlaceholder(_ audit: inout WatchLoopOpenAudit, units: Double) async {
        let rounded = (units * 20).rounded(.down) / 20
        guard rounded != audit.placeholderUnits else { return }
        let at = audit.readAt ?? audit.takenAt
        if let id = audit.placeholderID {
            await deleteInsulin(id: id, units: audit.placeholderUnits, at: at)
            audit.placeholderID = nil
            audit.placeholderUnits = 0
        }
        let reminders = ["watchLoop.placeholder.2", "watchLoop.placeholder.4"]
        guard rounded > 0 else {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: reminders)
            info(.watch, "Watch Loop audit: the records explain the pod's insulin; the placeholder is removed")
            notify(
                id: "watchLoop.placeholder",
                title: String(localized: "Watch's Insulin Records Arrived"),
                body: String(localized: "They explain all of the pod's insulin. Trio removed the bolus it had booked.")
            )
            return
        }
        audit.placeholderID = await pumpHistoryStorage.storeExternalInsulinEvent(
            amount: Decimal(rounded),
            timestamp: at
        )
        audit.placeholderUnits = audit.placeholderID == nil ? 0 : rounded
        warning(.watch, "Watch Loop: booked \(rounded) U the records don't explain")
        notify(
            id: "watchLoop.placeholder",
            title: String(localized: "Insulin From the Watch Booked"),
            body: String(
                localized: "The pod delivered \(Decimal(rounded).formatted()) U the watch's records don't explain. Trio booked it as a bolus."
            )
        )
        for hours in [2.0, 4.0] {
            notify(
                id: "watchLoop.placeholder.\(Int(hours))",
                title: String(localized: "Check the Watch's Insulin"),
                body: String(
                    localized: "Trio booked insulin the watch's records didn't explain. Bring the watch near the phone to replace it with the records."
                ),
                after: hours * 3600
            )
        }
    }

    /// As History deletes an entry: Nightscout, Apple Health, Tidepool and the store.
    @MainActor private func deleteInsulin(id: String, units: Double, at date: Date) async {
        await nightscoutManager.deleteInsulin(withID: id)
        await healthKitManager.deleteInsulin(syncID: id)
        tidepoolManager.deleteInsulin(withSyncId: id, amount: Decimal(units), at: date)
        let context = CoreDataStack.shared.newTaskContext()
        let objectID: NSManagedObjectID? = try? await context.perform {
            let request = PumpEventStored.fetchRequest() as NSFetchRequest<PumpEventStored>
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            return try context.fetch(request).first?.objectID
        }
        if let objectID { await CoreDataStack.shared.deleteObject(identifiedBy: objectID) }
    }

    // MARK: - When the watch goes quiet

    @MainActor private func checkOverdue() {
        if let audit = state.openAudit {
            let actionTime = Double(truncating: settingsManager.pumpSettings.insulinActionCurve as NSNumber) * 3600
            if Date().timeIntervalSince(audit.takenAt) > actionTime {
                // the session's insulin has acted: nothing missing from its records can matter any more
                if audit.holdsDosing {
                    releaseHold(String(localized: "The watch's insulin from before the take-back has acted."))
                }
                state.openAudit = nil
            } else if audit.holdsDosing {
                Task { await runAudit() }
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
            send(.stop(session: state.session))
            openAudit(recordsComplete: false)
            finish()
            await runAudit()
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
        case .sendStop:
            send(.stop(session: state.session))
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
