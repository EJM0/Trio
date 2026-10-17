import Combine
import CoreData
import Foundation
import HealthKit
import LoopKit
import OmnipodKit
import Swinject
import WatchConnectivity

/// What the phone persists of untethered watch mode.
struct UntetheredPhoneState: Codable, Equatable {
    var session = UntetheredSession()
    /// The pump came back from the watch but hasn't been read and audited yet: dosing stays held.
    var pumpReturnPending = false
    /// The watch ended the pod; the phone forgets it instead of reading it back.
    var podEndedOnWatch = false
    /// Per epoch, the latest version of each record already stored.
    var applied: [Int: [String: UntetheredSyncEntry]] = [:]
    /// Per epoch, the sync identifiers of doses the watch last reported as still running. Only the watch's pump
    /// manager can finalize them, so the phone's own pending reports must not purge them.
    var watchPendingDoses: [Int: Set<String>] = [:]
    /// The return's audit, judged again once the watch's last records are in.
    var audit: UntetheredAuditPoint?
    /// What the complete history still couldn't explain; on the home screen until acknowledged.
    var auditFinding: String?
    var lastError: String?

    var watchPendingDoseIdentifiers: Set<String> { watchPendingDoses.values.reduce(into: []) { $0.formUnion($1) } }
}

/// A field added since the file was written decodes to its default instead of failing the whole file, which would
/// start over and forget a session the watch is still running.
extension UntetheredPhoneState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UntetheredPhoneState()
        session = try container.decodeIfPresent(UntetheredSession.self, forKey: .session) ?? defaults.session
        pumpReturnPending = try container.decodeIfPresent(Bool.self, forKey: .pumpReturnPending) ?? defaults.pumpReturnPending
        podEndedOnWatch = try container.decodeIfPresent(Bool.self, forKey: .podEndedOnWatch) ?? defaults.podEndedOnWatch
        applied = try container.decodeIfPresent([Int: [String: UntetheredSyncEntry]].self, forKey: .applied) ?? defaults.applied
        watchPendingDoses = try container.decodeIfPresent([Int: Set<String>].self, forKey: .watchPendingDoses)
            ?? defaults.watchPendingDoses
        audit = try container.decodeIfPresent(UntetheredAuditPoint.self, forKey: .audit)
        auditFinding = try container.decodeIfPresent(String.self, forKey: .auditFinding)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// Read by the loop, bolus and watch paths without resolving any service, so a relaunch holds
/// dosing from its first loop on.
enum UntetheredGate {
    private static let lock = NSLock()
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("untethered-phone.json")
    private static var cached: UntetheredPhoneState = (try? Data(contentsOf: url))
        .flatMap { try? JSONDecoder().decode(UntetheredPhoneState.self, from: $0) } ?? UntetheredPhoneState()

    static var state: UntetheredPhoneState { lock.withLock { cached } }

    /// The phone may loop, bolus and change the pump.
    static var phoneMayDose: Bool {
        let state = self.state
        return state.session.isIdle && !state.pumpReturnPending
    }

    /// Every change reaches the screens, whichever path made it.
    @discardableResult static func update<T>(_ change: (inout UntetheredPhoneState) -> T) -> T {
        let result = lock.withLock {
            let result = change(&cached)
            if let data = try? JSONEncoder().encode(cached) {
                try? data.write(to: url, options: .atomic)
            }
            return result
        }
        DispatchQueue.main.async {
            Foundation.NotificationCenter.default.post(name: .untetheredGateDidChange, object: nil)
        }
        return result
    }
}

extension Notification.Name {
    static let untetheredSessionDidChange = Notification.Name("untetheredSessionDidChange")
    static let untetheredGateDidChange = Notification.Name("untetheredGateDidChange")
}

enum UntetheredError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason): return reason
        }
    }
}

/// The phone's side of untethered watch mode: hands the pump to the watch, holds its own dosing
/// meanwhile, takes the pump back and stores what the watch did.
final class UntetheredPhoneManager: ObservableObject, Injectable {
    @Injected() private var apsManager: APSManager!
    @Injected() private var fetchGlucoseManager: FetchGlucoseManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var storage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var tddStorage: TDDStorage!
    @Injected() private var pumpHistoryStorage: PumpHistoryStorage!
    @Injected() private var adjustmentManager: AdjustmentManager!
    @Injected() private var determinationStorage: DeterminationStorage!
    @Injected() private var nightscoutManager: NightscoutManager!
    @Injected() private var healthkitManager: HealthKitManager!
    @Injected() private var tidepoolManager: TidepoolManager!

    /// Read from the gate itself, never a copy: the screens can't show a state the loop no longer holds.
    var state: UntetheredPhoneState { UntetheredGate.state }
    private var wasIdle = UntetheredGate.state.session.isIdle

    static let leaseLength: TimeInterval = 120
    /// How old the newest glucose may be when the watch takes over.
    static let maxGlucoseAge: TimeInterval = 12 * 60

    private var openAPS: OpenAPS!
    private var ticker: Timer?
    private let assembler = UntetheredChunks.Assembler()
    private var endRequestTimer: Timer?
    /// How long a normal hand-back waits for the watch's last records before the audit judges the pump.
    private static let historyWait: TimeInterval = 60
    private var linkedOverrideTimer: Timer?
    /// What ran on the phone at the last change, so a cancel made here can be told to the watch.
    private var runningOverrideStart: Date?
    private var runningTempTargetStart: Date?
    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        injectServices(resolver)
        openAPS = OpenAPS(storage: storage, tddStorage: tddStorage, glucoseStorage: glucoseStorage, carbsStorage: carbsStorage)
        Foundation.NotificationCenter.default.publisher(for: .untetheredGateDidChange)
            .sink { [weak self] _ in Task { @MainActor in self?.publish() } }
            .store(in: &subscriptions)
        Foundation.NotificationCenter.default.publisher(for: .didUpdateOverrideConfiguration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task {
                    await self?.forwardCancellations()
                    await self?.checkLinkedOverride()
                }
            }
            .store(in: &subscriptions)
        Foundation.NotificationCenter.default.publisher(for: .didUpdateTempTargetConfiguration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.forwardCancellations() } }
            .store(in: &subscriptions)
        Task { @MainActor in
            await self.forwardCancellations()
            if self.state.pumpReturnPending { await self.finishPumpReturn() }
            self.updateTimers()
        }
    }

    var isWatchInCharge: Bool { !state.session.isIdle }
    /// The start reads the pump before it offers it: the toggle shows a spinner meanwhile.
    @Published private(set) var isCheckingDevices = false
    /// How long the start waits for the pump to answer.
    private static let pumpCheckTimeout: TimeInterval = 30

    // MARK: - User actions

    /// - Returns: why the start was refused, nil when it went on to the watch
    @discardableResult @MainActor func start(linkedOverrideID: String? = nil) async -> String? {
        guard state.session.isIdle, !state.pumpReturnPending else {
            return String(localized: "The phone is still taking the pump back from the last session.")
        }
        setError(nil)
        // about the last session; this one is judged on its own
        UntetheredGate.update { $0.auditFinding = nil }
        isCheckingDevices = true
        defer { isCheckingDevices = false }
        do {
            try preflight()
            // a pump the phone can't reach now is one the watch can't reach after the hand-over either
            guard await pumpAnswers() else {
                throw UntetheredError.unavailable(
                    String(localized: "The pump doesn't answer. Keep the phone close to the pod and try again.")
                )
            }
            let grant = try await makeGrant(linkedOverrideID: linkedOverrideID)
            await apply(.start(grant))
            return nil
        } catch {
            setError(error.localizedDescription)
            return error.localizedDescription
        }
    }

    @MainActor func end() async {
        await apply(.end)
    }

    @MainActor func forceTakeBack() async {
        await apply(.forceTakeBack)
    }

    @MainActor func acknowledgeAuditFinding() {
        UntetheredGate.update { $0.auditFinding = nil }
        publish()
    }

    // MARK: - From the watch

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

    /// `payload` holds an `UntetheredEnvelope`. Every path calls `replyHandler` when there is one.
    func receive(_ payload: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        guard let envelope = try? UntetheredEnvelope.decode(payload) else {
            warning(.watchManager, "Untethered: unreadable message from the watch")
            replyHandler?([:])
            return
        }
        Task { @MainActor in
            switch envelope.message {
            case let .records(records):
                let stored = await self.ingest(records, epoch: envelope.epoch)
                // acknowledged as soon as stored, so the watch's backlog stays small while it loops
                if let replyHandler,
                   let payload = try? UntetheredEnvelope(epoch: envelope.epoch, message: .recordsStored(stored)).payload()
                {
                    replyHandler(payload)
                } else {
                    replyHandler?([:])
                    self.send(.recordsStored(stored), epoch: envelope.epoch)
                }
            case .syncDone:
                replyHandler?([:])
                await self.finishSync(epoch: envelope.epoch)
            case .startRequest:
                replyHandler?([:])
                if let reason = await self.start() {
                    self.send(.startRefused(reason: reason), epoch: envelope.epoch)
                }
            default:
                await self.apply(.received(envelope.message, epoch: envelope.epoch), reply: replyHandler)
            }
        }
    }

    @MainActor func reachabilityChanged() {
        guard WCSession.default.isReachable else { return }
        switch state.session.phase {
        case .ending: send(.endRequest, epoch: state.session.epoch)
        case .starting where state.session.statusQueried: send(.statusQuery, epoch: state.session.epoch)
        default: break
        }
        for epoch in state.applied.keys {
            requestSync(epoch: epoch)
        }
    }

    // MARK: - State machine

    @MainActor private func apply(_ event: UntetheredSession.PhoneEvent, reply: (([String: Any]) -> Void)? = nil) async {
        let effects = UntetheredGate.update { $0.session.phone(event, now: Date()) }
        let epoch = UntetheredGate.state.session.epoch
        publish()
        var reply = reply
        func deliver(_ message: UntetheredMessage) {
            if let replyHandler = reply, let payload = try? UntetheredEnvelope(epoch: epoch, message: message).payload() {
                replyHandler(payload)
                reply = nil
            } else {
                send(message, epoch: epoch)
            }
        }
        for effect in effects {
            switch effect {
            case let .send(message):
                deliver(message)
            case .commit:
                deliver(.commit(await releasePump()))
            case .takePump:
                takePump()
            case .reconcile:
                UntetheredGate.update { $0.applied[epoch] = $0.applied[epoch] ?? [:] }
                requestSync(epoch: epoch)
            case let .failed(reason):
                setError(reason)
            case .handback,
                 .releasePump,
                 .takeover:
                break
            }
        }
        reply?([:])
        publish()
        updateTimers()
    }

    @MainActor private func publish() {
        objectWillChange.send()
        let isIdle = state.session.isIdle
        if isIdle != wasIdle {
            wasIdle = isIdle
            Foundation.NotificationCenter.default.post(name: .untetheredSessionDidChange, object: nil)
        }
    }

    @MainActor private func setError(_ message: String?) {
        if let message { warning(.watchManager, "Untethered: \(message)") }
        UntetheredGate.update { $0.lastError = message }
        publish()
    }

    @MainActor private func updateTimers() {
        let phase = state.session.phase
        if phase == .preparing || phase == .starting {
            if ticker == nil {
                ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    Task { await self?.apply(.tick) }
                }
            }
        } else {
            ticker?.invalidate()
            ticker = nil
        }
        if phase == .ending {
            // repeated until the watch hands back; it may be reachable without a reachability change
            if endRequestTimer == nil {
                send(.endRequest, epoch: state.session.epoch)
                endRequestTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.send(.endRequest, epoch: self.state.session.epoch)
                }
            }
        } else {
            endRequestTimer?.invalidate()
            endRequestTimer = nil
        }
        Task { await scheduleLinkedOverrideCheck() }
    }

    // MARK: - Transport

    private func send(_ message: UntetheredMessage, epoch: Int) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let payload = try? UntetheredEnvelope(epoch: epoch, message: message).payload()
        else { return }
        let session = WCSession.default

        switch message {
        case .adjustmentCancelled,
             .revoke:
            // queued as well: the watch must hear it whenever it comes back
            session.transferUserInfo(payload)
        case .recordsStored:
            session.transferUserInfo(payload)
            return
        default: break
        }
        guard session.isReachable else {
            if case .prepare = message {
                Task { await self.apply(.received(.rejected(reason: Self.unreachable), epoch: epoch)) }
            }
            return
        }
        let replyHandler: ([String: Any]) -> Void = { [weak self] reply in
            guard reply[UntetheredEnvelope.key] != nil else { return }
            self?.receive(reply, replyHandler: nil)
        }
        var failed = false
        let errorHandler: (Error) -> Void = { [weak self] error in
            warning(.watchManager, "Untethered: sending failed: \(error.localizedDescription)")
            guard case .prepare = message, !failed else { return }
            failed = true
            Task { await self?.apply(.received(.rejected(reason: error.localizedDescription), epoch: epoch)) }
        }
        for part in UntetheredChunks.split(payload) ?? [payload] {
            session.sendMessage(part, replyHandler: replyHandler, errorHandler: errorHandler)
        }
    }

    private static let unreachable = String(localized: "The watch is not reachable. Open Trio on the watch and try again.")

    // MARK: - Starting

    @MainActor private func preflight() throws {
        guard WCSession.isSupported(), WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else {
            throw UntetheredError.unavailable(String(localized: "Trio is not installed on a paired Apple Watch."))
        }
        guard WCSession.default.isReachable else {
            throw UntetheredError.unavailable(Self.unreachable)
        }
        guard let pump = apsManager.pumpManager else {
            throw UntetheredError.unavailable(String(localized: "No pump is connected."))
        }
        guard pump is ExclusiveDeviceControl, pump is PumpDeliveryOdometer else {
            throw UntetheredError.unavailable(
                String(localized: "\(pump.localizedTitle) can't be handed to the watch. Untethered mode supports Omnipod DASH.")
            )
        }
        guard let cgm = fetchGlucoseManager.cgmManager, cgm is DeviceConfigurationSharing else {
            throw UntetheredError.unavailable(
                String(localized: "This CGM can't be read by the watch. Untethered mode supports Dexcom G7.")
            )
        }
        // the watch reads the same sensor; it links only around each reading, so its last contact proves nothing
        guard cgm.cgmManagerStatus.hasValidSensorSession else {
            throw UntetheredError.unavailable(String(localized: "The CGM has no active sensor."))
        }
        let status = pump.status
        guard case .noBolus = status.bolusState else {
            throw UntetheredError.unavailable(String(localized: "Wait for the bolus to finish."))
        }
        guard !status.deliveryIsUncertain else {
            throw UntetheredError
                .unavailable(String(localized: "The pump's delivery is uncertain. Resolve it on the phone first."))
        }
        guard !apsManager.isManualTempBasal else {
            throw UntetheredError.unavailable(String(localized: "Cancel the manual temp basal first."))
        }
        if let inoperable = pump.localizedInoperableDescription {
            throw UntetheredError.unavailable(inoperable)
        }
    }

    /// A live read of the pump's delivered total, or false when it doesn't answer within the timeout.
    @MainActor private func pumpAnswers() async -> Bool {
        guard let odometer = apsManager.pumpManager as? PumpDeliveryOdometer else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // whichever comes first answers; the other finds it answered
            let lock = NSLock()
            var answered = false
            func answer(_ result: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !answered else { return }
                answered = true
                continuation.resume(returning: result)
            }
            odometer.refreshDeliveredUnits { answer($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pumpCheckTimeout) { answer(false) }
        }
    }

    private func makeGrant(linkedOverrideID: String?) async throws -> UntetheredGrant {
        guard let pump = apsManager.pumpManager as? ExclusiveDeviceControl,
              let cgm = fetchGlucoseManager.cgmManager as? DeviceConfigurationSharing
        else { throw UntetheredError.unavailable(String(localized: "The pump or CGM can't be handed to the watch.")) }

        let now = Date()
        let settings = settingsManager.settings
        let preferences = settingsManager.preferences
        // raw readings travel; the watch smooths them as the phone does and syncs the originals back
        let glucose = try await glucoseStorage.getGlucoseForAlgorithm(shouldSmoothGlucose: false, fetchHours: 24)
        var smoothedGlucose: [String: Decimal] = [:]
        if settings.smoothGlucose {
            for reading in try await glucoseStorage.getGlucoseForAlgorithm(shouldSmoothGlucose: true, fetchHours: 24) {
                smoothedGlucose[reading.id] = (reading.sgv ?? reading.glucose).map { Decimal($0) }
            }
        }
        guard let newest = glucose.map(\.dateString).max(), now.timeIntervalSince(newest) < Self.maxGlucoseAge else {
            throw UntetheredError.unavailable(String(localized: "There is no recent glucose reading."))
        }

        let context = CoreDataStack.shared.newTaskContext()
        context.name = "untetheredGrant"
        let (tdd, tddRows, activeOverride, overridePresets, tempTargetPresets) = try await context.perform {
            let tdd = try self.openAPS.tddSummary(now: now, on: context)
            let tddRequest = TDDStored.fetchRequest() as NSFetchRequest<TDDStored>
            tddRequest.predicate = NSPredicate(
                format: "date > %@ AND total > 0",
                now.addingTimeInterval(-10 * 24 * 60 * 60) as NSDate
            )
            let tddRows = try context.fetch(tddRequest).compactMap { row -> UntetheredTDD? in
                guard let date = row.date, let total = row.total?.decimalValue else { return nil }
                return UntetheredTDD(
                    date: date, total: total,
                    bolus: row.bolus?.decimalValue ?? 0, tempBasal: row.tempBasal?.decimalValue ?? 0,
                    scheduledBasal: row.scheduledBasal?.decimalValue ?? 0, weightedAverage: row.weightedAverage?.decimalValue
                )
            }
            let active = try self.openAPS.fetchActiveOverrides(on: context).first
            let overrideRequest = OverrideStored.fetchRequest()
            overrideRequest.predicate = NSPredicate(format: "isPreset == %@", true as NSNumber)
            let presets = try context.fetch(overrideRequest).sorted { $0.orderPosition < $1.orderPosition }
            let tempTargetRequest = TempTargetStored.fetchRequest()
            tempTargetRequest.predicate = NSPredicate(format: "isPreset == %@", true as NSNumber)
            let tempTargets = try context.fetch(tempTargetRequest).sorted { $0.orderPosition < $1.orderPosition }
            return (
                tdd,
                tddRows,
                active?.orefOverride(preferences: preferences),
                presets.map { $0.orefOverride(preferences: preferences) },
                tempTargets.map { $0.untetheredPreset(halfBasalTarget: preferences.halfBasalExerciseTarget) }
            )
        }

        return UntetheredGrant(
            leaseExpiresAt: now.addingTimeInterval(Self.leaseLength),
            pumpConfiguration: try Self.plist(pump.exportConfiguration()),
            cgmConfiguration: try Self.plist(cgm.exportConfiguration()),
            pumpSettings: settingsManager.pumpSettings,
            bgTargets: storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self)
                ?? BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: []),
            basalProfile: storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? [],
            insulinSensitivities: storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
                ?? InsulinSensitivities(units: .mgdL, userPreferredUnits: .mgdL, sensitivities: []),
            carbRatios: storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self)
                ?? CarbRatios(units: .grams, schedule: []),
            preferences: preferences,
            dosingMode: settings.dosingMode,
            smoothGlucose: settings.smoothGlucose,
            units: settings.units,
            tdd: tdd,
            hasSufficientTDD: try await tddStorage.hasSufficientTDD(),
            tddRecentRows: tddRows.filter { $0.date >= now.addingTimeInterval(-2 * 60 * 60) },
            tddTenDaySum: tddRows.reduce(0) { $0 + $1.total },
            tddTenDayCount: tddRows.count,
            tddPumpHistory: try await pumpHistoryStorage.getPumpHistory(),
            autosens: storage.retrieve(OpenAPS.Settings.autosense, as: Autosens.self),
            reservoir: storage.retrieve(OpenAPS.Monitor.reservoir, as: Decimal.self),
            maxBolus: settingsManager.pumpSettings.maxBolus,
            maxCarbs: settings.maxCarbs,
            bolusCalculator: UntetheredBolusCalculatorSettings(
                fraction: settings.overrideFactor,
                fattyMeals: settings.fattyMeals,
                fattyMealFactor: settings.fattyMealFactor,
                sweetMeals: settings.sweetMeals,
                sweetMealFactor: settings.sweetMealFactor
            ),
            glucoseColorScheme: settings.glucoseColorScheme.rawValue,
            lastDetermination: await determinationStorage.getOrefDeterminationNotYetUploadedToNightscout(
                (
                    try? await determinationStorage
                        .fetchLastDeterminationObjectID(predicate: .predicateFor30MinAgoForDetermination)
                ) ?? []
            ),
            lastLoopDate: apsManager.lastLoopDate,
            lowGlucose: settings.low,
            highGlucose: settings.high,
            pumpHistory: try await openAPS.algorithmPumpHistory(),
            glucose: glucose,
            smoothedGlucose: smoothedGlucose,
            carbs: try await carbsStorage.getCarbsForAlgorithm(additionalCarbs: nil, carbsDate: nil),
            activeOverride: activeOverride,
            tempTargets: storage.retrieve(OpenAPS.Settings.tempTargets, as: [TempTarget].self) ?? [],
            overridePresets: overridePresets,
            tempTargetPresets: tempTargetPresets,
            linkedOverrideID: linkedOverrideID
        )
    }

    private static func plist(_ configuration: SharedDeviceConfiguration) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: configuration.rawValue, format: .binary, options: 0)
    }

    /// The watch loops from here on; a loop already running finishes first. A running temp basal is cancelled and
    /// goes to the watch to set again, and the pump is exported as released, after anything that loop enacted.
    @MainActor private func releasePump() async -> UntetheredHandover {
        for _ in 0 ..< 60 where apsManager.isLooping.value {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let tempBasal = await apsManager.pumpManager?.cancelTempBasalForHandover()
        let pump = apsManager.pumpManager as? ExclusiveDeviceControl
        let configuration = pump.flatMap { try? Self.plist($0.exportConfiguration()) }
        pump?.releaseControl()
        debug(.watchManager, "Untethered: pump released to the watch")
        if let tempBasal { debug(.watchManager, "Untethered: temp basal \(tempBasal.unitsPerHour) U/h handed to the watch") }
        return UntetheredHandover(pumpConfiguration: configuration, tempBasal: tempBasal)
    }

    // MARK: - Taking the pump back

    @MainActor private func takePump() {
        UntetheredGate.update { $0.pumpReturnPending = true }
        publish()
        (apsManager.pumpManager as? ExclusiveDeviceControl)?.takeControl()
        Task { await self.finishPumpReturn() }
    }

    /// Reads the pump until it answers, then audits its delivered total against the history before
    /// the loop may dose again.
    @MainActor private func finishPumpReturn() async {
        guard let odometer = apsManager.pumpManager as? PumpDeliveryOdometer else {
            UntetheredGate.update { $0.pumpReturnPending = false }
            publish()
            return
        }
        (apsManager.pumpManager as? ExclusiveDeviceControl)?.takeControl()
        debug(.watchManager, "Untethered: reading the pump back")
        var attempts = 0
        while !state.podEndedOnWatch, !(await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            odometer.refreshDeliveredUnits { continuation.resume(returning: $0) }
        }) {
            attempts += 1
            debug(.watchManager, "Untethered: the pump did not answer yet (attempt \(attempts)), retrying")
            // dosing stays held until the pump is read; after a minute the banner says why
            if attempts == 3 {
                setError(String(
                    localized: "The phone can't reach the pump yet, so it doesn't dose. Keep the phone close to the pod; it keeps trying."
                ))
            }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
        }
        if attempts >= 3 { setError(nil) }
        // the temp basal the watch cancelled goes on as the phone's own, before the loop is let go
        if !state.podEndedOnWatch, let tempBasal = state.session.returnedTempBasal,
           let error = await apsManager.pumpManager?.resumeTempBasal(tempBasal)
        {
            warning(.watchManager, "Untethered: the watch's temp basal could not be set again: \(error.localizedDescription)")
        }
        if state.podEndedOnWatch {
            // nothing to read or audit: the watch's records carry the pod's doses up to its end
            (apsManager.pumpManager as? OmniPumpManager)?.forgetPodEndedElsewhere()
            UntetheredGate.update {
                $0.podEndedOnWatch = false
                $0.pumpReturnPending = false
            }
            publish()
            debug(.watchManager, "Untethered: the watch ended the pod; the phone is ready for a new one")
            return
        }
        // after a hand-back the watch's last records are on their way; judge the pump once they're in
        let epoch = state.session.epoch
        if !state.session.forced {
            let deadline = Date().addingTimeInterval(Self.historyWait)
            while state.applied[epoch] != nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        await audit(odometer)
        // the last records may have come in while the audit read the history
        if let point = state.audit, point.epoch == epoch, state.applied[epoch] == nil {
            await judge(point, historyComplete: true)
        }
        UntetheredGate.update { $0.pumpReturnPending = false }
        publish()
        debug(.watchManager, "Untethered: pump is back on the phone")
        apsManager.heartbeat(date: Date())
    }

    /// Insulin the pump delivered that no record explains is booked now, as a bolus. Records claiming more than the
    /// pump delivered only warn: that direction is safe. A history still missing the watch's last records is judged
    /// again once they are in, and only that second verdict is shown.
    @MainActor private func audit(_ odometer: PumpDeliveryOdometer) async {
        let session = state.session
        guard let start = session.startStatus, let startUnits = start.deliveredUnits,
              let current = odometer.deliveredUnits
        else { return }
        let point = UntetheredAuditPoint(
            epoch: session.epoch,
            start: start.date,
            startUnits: startUnits,
            end: current.at,
            endUnits: current.units
        )
        await judge(point, historyComplete: state.applied[session.epoch] == nil)
    }

    /// Judges the span between the pump's two readings against the history as it is now.
    @MainActor private func judge(_ point: UntetheredAuditPoint, historyComplete: Bool) async {
        // taken before the history is read, so the complete history judges it only once
        UntetheredGate.update { $0.audit = historyComplete ? nil : point }
        do {
            // an earlier verdict's booking is replaced, never counted as a record
            await removeGap(epoch: point.epoch)
            let expected = UntetheredAudit.expectedDelivery(
                from: point.start,
                to: point.end,
                history: try await openAPS.algorithmPumpHistory(),
                basalProfile: storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
            )
            debug(
                .watchManager,
                "Untethered: audit\(historyComplete ? "" : " (watch history incomplete)") — pump \(point.delivered) U, records \(expected) U"
            )
            let verdict = UntetheredAudit.verdict(delivered: point.delivered, expected: expected)
            // insulin no record explains counts at once, whatever the history still lacks: dosing must not go over it
            if case let .unrecorded(units) = verdict {
                try await bookGap(units, at: point.end, epoch: point.epoch)
            }
            // only the complete history speaks: what the watch's last records would explain is no finding
            guard historyComplete else { return }
            let finding: String?
            switch verdict {
            case let .unrecorded(units):
                let amount = units.formatted(.number.precision(.fractionLength(0 ... 2)))
                finding = String(localized: "The pump delivered \(amount) U that no record explains. It is counted as a bolus.")
            case let .overstated(units):
                let amount = units.formatted(.number.precision(.fractionLength(0 ... 2)))
                finding = String(
                    localized: "The records show \(amount) U more insulin than the pump delivered. Insulin on board may be overstated."
                )
            case .explained:
                finding = nil
            }
            if let finding { warning(.watchManager, "Untethered: \(finding)") }
            UntetheredGate.update { $0.auditFinding = finding }
            publish()
        } catch {
            warning(.watchManager, "Untethered: audit failed: \(error.localizedDescription)")
        }
    }

    private static func gapIdentifier(_ epoch: Int) -> String { "untethered-gap-\(epoch)" }

    /// `NewPumpEvent` replaces a dose's sync identifier with its raw data in hex; the row is stored under that.
    private static func gapSyncIdentifier(_ epoch: Int) -> String {
        Data(gapIdentifier(epoch).utf8).map { String(format: "%02hhx", $0) }.joined()
    }

    private func bookGap(_ units: Decimal, at date: Date, epoch: Int) async throws {
        let identifier = Self.gapIdentifier(epoch)
        let dose = DoseEntry(
            type: .bolus,
            startDate: date,
            endDate: date,
            value: NSDecimalNumber(decimal: units).doubleValue,
            unit: .units,
            deliveredUnits: NSDecimalNumber(decimal: units).doubleValue,
            syncIdentifier: identifier
        )
        let event = NewPumpEvent(date: date, dose: dose, raw: Data(identifier.utf8), title: "Untethered gap", type: .bolus)
        try await pumpHistoryStorage.storePumpEvents([event], replacePendingEvents: false)
    }

    private func removeGap(epoch: Int) async {
        let context = CoreDataStack.shared.newTaskContext()
        let uploaded: [String] = await context.perform {
            let request = PumpEventStored.fetchRequest() as NSFetchRequest<PumpEventStored>
            request.predicate = NSPredicate(format: "syncIdentifier == %@", Self.gapSyncIdentifier(epoch))
            guard let rows = try? context.fetch(request), !rows.isEmpty else { return [] }
            let ids = rows.filter(\.isUploadedToNS).compactMap(\.id)
            rows.forEach(context.delete)
            try? context.save()
            return ids
        }
        // as the pump history withdraws a purged treatment
        for id in uploaded {
            await nightscoutManager.deleteInsulin(withID: id)
        }
    }

    // MARK: - Linked override

    /// Untethered mode started from an override ends with it.
    /// An override or temp target that stopped running on the phone while the watch is in charge — cancelled here,
    /// from any screen, shortcut or remote command — ends on the watch too. The watch ends it only if it is the one
    /// that started then, so one started later on the wrist, or copied over from it, stays.
    @MainActor private func forwardCancellations() async {
        let override = await runningAdjustmentStarted(OverrideStored.self, predicate: .lastActiveOverride)
        let tempTarget = await runningAdjustmentStarted(TempTargetStored.self, predicate: .lastActiveTempTarget)
        defer {
            runningOverrideStart = override
            runningTempTargetStart = tempTarget
        }
        guard isWatchInCharge else { return }
        let now = Date()
        if let before = runningOverrideStart, before != override {
            send(.adjustmentCancelled(.override, start: before, at: now), epoch: state.session.epoch)
        }
        if let before = runningTempTargetStart, before != tempTarget {
            send(.adjustmentCancelled(.tempTarget, start: before, at: now), epoch: state.session.epoch)
        }
    }

    @MainActor private func checkLinkedOverride() async {
        guard state.session.phase == .active, let linkedID = state.session.linkedOverrideID else { return }
        if await !isOverrideActive(id: linkedID) {
            debug(.watchManager, "Untethered: the linked override is over, ending")
            await end()
        }
    }

    @MainActor private func scheduleLinkedOverrideCheck() async {
        linkedOverrideTimer?.invalidate()
        linkedOverrideTimer = nil
        guard state.session.phase == .active, let linkedID = state.session.linkedOverrideID,
              let end = await overrideEnd(id: linkedID)
        else { return }
        linkedOverrideTimer = Timer
            .scheduledTimer(withTimeInterval: max(1, end.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                Task { await self?.checkLinkedOverride() }
            }
    }

    private func isOverrideActive(id: String) async -> Bool {
        guard let end = await overrideEnd(id: id) else { return false }
        return end > Date()
    }

    /// `.distantFuture` for an indefinite override, nil when it isn't enabled.
    private func overrideEnd(id: String) async -> Date? {
        let context = CoreDataStack.shared.newTaskContext()
        return await context.perform {
            let request = OverrideStored.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@ AND enabled == %@", id, true as NSNumber)
            guard let row = try? context.fetch(request).first, let start = row.date else { return nil }
            if row.indefinite { return .distantFuture }
            return start.addingTimeInterval((row.duration?.doubleValue ?? 0) * 60)
        }
    }

    // MARK: - History from the watch

    /// Returns the record versions now stored, including ones stored before.
    @MainActor private func ingest(_ records: [UntetheredRecord], epoch: Int) async -> [UUID] {
        var applied = state.applied[epoch] ?? [:]
        for record in records.sorted(by: { $0.date < $1.date }) where applied[record.key]?.id != record.id {
            do {
                try await store(record, epoch: epoch)
                applied[record.key] = record.syncEntry
            } catch {
                // left out of the applied set, so the next sync asks for it again
                warning(.watchManager, "Untethered: could not store \(record.key): \(error.localizedDescription)")
            }
        }
        UntetheredGate.update { $0.applied[epoch] = applied }
        publish()
        if settingsManager.settings.smoothGlucose,
           records.contains(where: {
               switch $0.kind {
               case .glucose,
                    .glucoseDeleted: return true
               default: return false
               }
           })
        {
            let context = CoreDataStack.shared.newTaskContext()
            context.name = "untetheredSmoothing"
            await fetchGlucoseManager.exponentialSmoothingGlucose(context: context)
        }
        return records.filter { applied[$0.key]?.id == $0.id }.map(\.id)
    }

    private func store(_ record: UntetheredRecord, epoch: Int) async throws {
        switch record.kind {
        case let .pumpEvent(data):
            guard let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? NewPumpEvent
                .RawValue,
                let event = NewPumpEvent(rawValue: raw)
            else { throw UntetheredError.unavailable("unreadable pump event") }
            // held before the row exists, so no purge can fall in between; released once the row is final
            let pendingDose = event.dose?.syncIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            if let pendingDose, event.dose?.isMutable == true {
                UntetheredGate.update { $0.watchPendingDoses[epoch, default: []].insert(pendingDose) }
            }
            try await pumpHistoryStorage.storePumpEvents([event], replacePendingEvents: false)
            if let pendingDose, event.dose?.isMutable != true {
                UntetheredGate.update { $0.watchPendingDoses[epoch]?.remove(pendingDose) }
            }
        case let .pumpEventDropped(syncIdentifier):
            // as `storePumpEvents(replacePendingEvents: true)` purges an unasserted pending row
            let context = CoreDataStack.shared.newTaskContext()
            await context.perform {
                let request = PumpEventStored.fetchRequest() as NSFetchRequest<PumpEventStored>
                request.predicate = NSPredicate(format: "syncIdentifier == %@ AND isMutable == YES", syncIdentifier)
                guard let rows = try? context.fetch(request), !rows.isEmpty else { return }
                rows.forEach(context.delete)
                try? context.save()
            }
            UntetheredGate.update { $0.watchPendingDoses[epoch]?.remove(syncIdentifier) }
        case let .glucose(glucose):
            try await glucoseStorage.storeGlucose([glucose])
        case let .glucoseDeleted(date):
            let context = CoreDataStack.shared.newTaskContext()
            let found: (objectID: NSManagedObjectID, id: String?, date: Date?)? = await context.perform {
                let request = GlucoseStored.fetchRequest() as NSFetchRequest<GlucoseStored>
                request.predicate = NSPredicate(
                    format: "date >= %@ AND date <= %@",
                    date.addingTimeInterval(-1) as NSDate,
                    date.addingTimeInterval(1) as NSDate
                )
                return (try? context.fetch(request).first).map { (objectID: $0.objectID, id: $0.id?.uuidString, date: $0.date) }
            }
            if let found {
                // as the History screen deletes a reading: from the services it reached, then here
                if let id = found.id {
                    if let date = found.date { await nightscoutManager.deleteGlucose(withID: id, withDate: date) }
                    await healthkitManager.deleteGlucose(syncID: id)
                }
                await glucoseStorage.deleteGlucose(found.objectID)
            }
        case let .carbs(entry):
            if await carbEntryID(entry.id) == nil {
                try await carbsStorage.storeCarbs([entry], areFetchedFromRemote: false)
            }
        case let .carbsDeleted(id):
            if let objectID = await carbEntryID(id) {
                await deleteCarbsFromServices(objectID)
                await carbsStorage.deleteCarbsEntryStored(objectID)
            }
        case let .override(override):
            try await adjustmentManager.activateOverride(
                .presetID(override.id),
                source: .watch,
                waitForUpload: false,
                at: record.date
            )
        case let .overrideEnded(start):
            // may arrive long after the hand-back: never end an override started since
            if await runningAdjustmentStarted(OverrideStored.self, predicate: .lastActiveOverride) == start.rounded {
                try await adjustmentManager.cancelOverride(source: .watch, waitForUpload: false, at: record.date)
            }
        case let .tempTarget(tempTarget):
            try await adjustmentManager.activateTempTarget(
                .presetID(tempTarget.id),
                source: .watch,
                waitForUpload: false,
                at: record.date
            )
        case let .tempTargetEnded(start):
            if await runningAdjustmentStarted(TempTargetStored.self, predicate: .lastActiveTempTarget) == start.rounded {
                try await adjustmentManager.cancelTempTarget(source: .watch, waitForUpload: false, at: record.date)
            }
        case let .determination(determination, enactedAt):
            let context = CoreDataStack.shared.newTaskContext()
            context.name = "untetheredDetermination"
            await openAPS.processDetermination(determination, enactedAt: enactedAt, on: context)
            await keepNewestDeterminationsForUpload()
        case let .tdd(tdd):
            await tddStorage.storeTDD(
                TDDResult(
                    total: tdd.total,
                    bolus: tdd.bolus,
                    tempBasal: tdd.tempBasal,
                    scheduledBasal: tdd.scheduledBasal,
                    weightedAverage: tdd.weightedAverage,
                    hoursOfData: 24
                ),
                at: tdd.date
            )
        case let .autosens(autosens):
            // the phone continues from the watch's ratio until its own next autosens run
            let stored = storage.retrieve(OpenAPS.Settings.autosense, as: Autosens.self)
            if (autosens.timestamp ?? .distantPast) > (stored?.timestamp ?? .distantPast) {
                storage.save(autosens, as: OpenAPS.Settings.autosense)
            }
        case .podEnded:
            UntetheredGate.update { $0.podEndedOnWatch = true }
        case let .loopCompleted(date):
            // the loop's age and the interval to the next loop go on from the watch's last loop
            await MainActor.run { self.apsManager.adoptLoop(at: date) }
        }
    }

    /// When the running override or temp target started, to the second.
    private func runningAdjustmentStarted<Entity: NSManagedObject>(_: Entity.Type, predicate: NSPredicate) async -> Date? {
        let context = CoreDataStack.shared.newTaskContext()
        return await context.perform {
            let request = NSFetchRequest<Entity>(entityName: String(describing: Entity.self))
            request.predicate = predicate
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            request.fetchLimit = 1
            return (try? context.fetch(request).first?.value(forKey: "date") as? Date)?.rounded
        }
    }

    /// Nightscout's live status is the newest loop; the upload takes the newest determination not yet uploaded, then
    /// the next older one, each stamped on arrival, so a session's backlog would end with Nightscout showing its oldest
    /// loop. The newest enacted and the newest suggested one stay for the live upload; the older ones go up as past
    /// statuses at their own times, so Nightscout's history shows their forecasts.
    private func keepNewestDeterminationsForUpload() async {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "untetheredDeterminationUpload"
        let older: [NSManagedObjectID] = await context.perform {
            let request = OrefDetermination.fetchRequest() as NSFetchRequest<OrefDetermination>
            request.predicate = NSPredicate(format: "isUploadedToNS == NO")
            request.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: false)]
            guard let rows = try? context.fetch(request), rows.count > 1 else { return [] }
            return Dictionary(grouping: rows, by: \.enacted).values.flatMap { $0.dropFirst().map(\.objectID) }
        }
        guard !older.isEmpty else { return }
        var determinations: [Determination] = []
        for objectID in older {
            if let determination = await determinationStorage.getOrefDeterminationNotYetUploadedToNightscout([objectID]) {
                determinations.append(determination)
            }
        }
        // left for the live upload to retry if Nightscout can't be reached now
        guard await nightscoutManager.uploadDeterminationHistory(determinations) else { return }
        await context.perform {
            for objectID in older {
                (try? context.existingObject(with: objectID) as? OrefDetermination)?.isUploadedToNS = true
            }
            if context.hasChanges { try? context.save() }
        }
    }

    /// As the History screen deletes an entry: carbs, and fat and protein entered with them, from Nightscout,
    /// Apple Health and Tidepool.
    private func deleteCarbsFromServices(_ objectID: NSManagedObjectID) async {
        let context = CoreDataStack.shared.newTaskContext()
        let entry: (id: UUID?, fpuID: UUID?, carbs: Decimal, date: Date?)? = await context.perform {
            (try? context.existingObject(with: objectID) as? CarbEntryStored)
                .map { (id: $0.id, fpuID: $0.fpuID, carbs: Decimal($0.carbs), date: $0.date) }
        }
        guard let entry else { return }
        if let fpuID = entry.fpuID?.uuidString {
            await nightscoutManager.deleteCarbs(withID: fpuID)
            for sampleType in [AppleHealthConfig.healthFatObject, AppleHealthConfig.healthProteinObject].compactMap({ $0 }) {
                await healthkitManager.deleteMealData(byID: fpuID, sampleType: sampleType)
            }
        }
        if let id = entry.id, let date = entry.date {
            await nightscoutManager.deleteCarbs(withID: id.uuidString)
            if let sampleType = AppleHealthConfig.healthCarbObject {
                await healthkitManager.deleteMealData(byID: id.uuidString, sampleType: sampleType)
            }
            tidepoolManager.deleteCarbs(withSyncId: id, carbs: entry.carbs, at: date, enteredBy: CarbsEntry.local)
        }
    }

    private func carbEntryID(_ id: String?) async -> NSManagedObjectID? {
        guard let uuid = id.flatMap(UUID.init(uuidString:)) else { return nil }
        let context = CoreDataStack.shared.newTaskContext()
        return await context.perform {
            let request = CarbEntryStored.fetchRequest() as NSFetchRequest<CarbEntryStored>
            request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            return try? context.fetch(request).first?.objectID
        }
    }

    /// Asks the watch for the buckets where its history and what the phone stored differ.
    @MainActor private func requestSync(epoch: Int) {
        let list = UntetheredSyncEntry.bucketChecksumList(of: Array((state.applied[epoch] ?? [:]).values))
        send(.syncRequest(bucketStart: list.start, checksums: list.checksums), epoch: epoch)
    }

    @MainActor private func finishSync(epoch: Int) async {
        await freezeWatchDoses(epoch: epoch)
        UntetheredGate.update { $0.applied[epoch] = nil }
        publish()
        debug(.watchManager, "Untethered: history of session \(epoch) complete")
        // a return audited before the history was complete is judged again; one still reading the pump does it itself
        if !state.pumpReturnPending, let point = state.audit, point.epoch == epoch {
            await judge(point, historyComplete: true)
        }
    }

    /// The watch's last records are in, so it finalizes nothing more: a dose it last reported as running stays as
    /// reported, final, and the phone's own pending reports leave it alone from here on.
    @MainActor private func freezeWatchDoses(epoch: Int) async {
        guard let identifiers = state.watchPendingDoses[epoch] else { return }
        if !identifiers.isEmpty {
            let context = CoreDataStack.shared.newTaskContext()
            await context.perform {
                let request = PumpEventStored.fetchRequest() as NSFetchRequest<PumpEventStored>
                request.predicate = NSPredicate(format: "syncIdentifier IN %@ AND isMutable == YES", Array(identifiers))
                guard let rows = try? context.fetch(request), !rows.isEmpty else { return }
                rows.forEach { $0.isMutable = false }
                try? context.save()
            }
            debug(.watchManager, "Untethered: \(identifiers.count) dose(s) the watch left running kept as it reported them")
        }
        UntetheredGate.update { $0.watchPendingDoses[epoch] = nil }
    }
}

private extension TempTargetStored {
    /// As the watch shows and activates it; `id` matches the preset for `AdjustmentRef.presetID`.
    func untetheredPreset(halfBasalTarget: Decimal) -> TempTarget {
        TempTarget(
            id: id?.uuidString ?? UUID().uuidString,
            name: name,
            createdAt: date ?? Date(),
            targetTop: target?.decimalValue,
            targetBottom: target?.decimalValue,
            duration: duration?.decimalValue ?? 0,
            enteredBy: TempTarget.local,
            reason: TempTarget.custom,
            isPreset: true,
            enabled: false,
            halfBasalTarget: self.halfBasalTarget?.decimalValue ?? halfBasalTarget
        )
    }
}

private extension Date {
    /// Whole seconds: dates that went through JSON and Core Data compare equal.
    var rounded: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded()) }
}
