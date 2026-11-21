import Combine
import CoreData
import Foundation
import G7SensorKit
import HealthKit
import LoopKit
import LoopKitUI
import Swinject

/// The app side of `WatchLoanCoordinator`: pump, stores, alerts and the snapshot.
final class BaseWatchLoanPhoneHost: WatchLoanPhoneHost, Injectable {
    /// Older pump status than this refuses Start: the hand-off needs a pump that answers.
    static let pumpStatusMaxAge: TimeInterval = 15 * 60
    /// The phone's own glucose filter time: readings closer than this are the same reading.
    static let glucoseFilterTime: TimeInterval = 3.5 * 60

    @Injected() private var apsManager: APSManager!
    @Injected() private var deviceDataManager: DeviceDataManager!
    @Injected() private var fetchGlucoseManager: FetchGlucoseManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var fileStorage: FileStorage!
    @Injected() private var pumpHistoryStorage: PumpHistoryStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var tddStorage: TDDStorage!
    @Injected() private var trioAlertManager: TrioAlertManager!
    @Injected() private var notLoopingMonitor: NotLoopingMonitor!

    private let resolver: Resolver
    private let makeContext: () -> NSManagedObjectContext
    private var subscriptions = Set<AnyCancellable>()
    private lazy var openAPS = OpenAPS(
        storage: fileStorage,
        tddStorage: tddStorage,
        glucoseStorage: glucoseStorage,
        carbsStorage: carbsStorage,
        contextProvider: makeContext
    )
    /// While the watch-silence alarm is armed, the last batch it counts from; re-issued when a snooze changes.
    private var silenceAnchor: Date?

    init(resolver: Resolver, contextProvider: (() -> NSManagedObjectContext)? = nil) {
        self.resolver = resolver
        makeContext = contextProvider ?? { CoreDataStack.shared.newTaskContext() }
        injectServices(resolver)
        resolver.resolve(Broadcaster.self)?.register(SnoozeObserver.self, observer: self)
    }

    var pump: WatchLoanPumpAdapter? { WatchLoanPumpAdapter(deviceDataManager.pumpManager) }

    // resolved late: the watch manager forwards loan messages to the coordinator
    var transport: WatchLoanTransport? { resolver.resolve(WatchManager.self) as? WatchLoanTransport }

    private var sharedCGM: DeviceConfigurationSharing? {
        guard let cgm = fetchGlucoseManager.cgmManager as? DeviceConfigurationSharing,
              cgm.isConfigurationSharingEnabled else { return nil }
        return cgm
    }

    // MARK: Start

    func startRefusal() async -> LoanRefusal? {
        #if TRIO_ON_WATCH
            let override = (try? await activeAdjustments())?.override
            return Self.preconditionRefusal(
                dosingMode: settingsManager.settings.dosingMode,
                pump: pump,
                cgmShared: sharedCGM != nil,
                kitScreenOpen: PumpConfig.isKitScreenOpen,
                indefiniteOverride: override.map { $0.endsAt == nil } ?? false,
                now: Date()
            )
        #else
            return .featureOff
        #endif
    }

    /// The phone's Start preconditions, in the order they are reported.
    static func preconditionRefusal(
        dosingMode: DosingMode,
        pump: WatchLoanPumpAdapter?,
        cgmShared: Bool,
        kitScreenOpen: Bool,
        indefiniteOverride: Bool,
        now: Date
    ) -> LoanRefusal? {
        guard dosingMode == .closed else { return .notClosedLoop }
        guard let pump, cgmShared else { return .unsupportedDevice }
        if kitScreenOpen { return .pumpScreenOpen }
        if pump.status.bolusState != .noBolus { return .bolusRunning }
        if pump.status.deliveryIsUncertain { return .deliveryUncertain }
        guard let reading = pump.deliveredUnits, now.timeIntervalSince(reading.at) < pumpStatusMaxAge else {
            return .pumpStatusStale
        }
        if indefiniteOverride { return .indefiniteOverride }
        return nil
    }

    func awaitPumpIdle() async {
        await apsManager.awaitPumpIdle()
    }

    // MARK: Snapshot

    func snapshot(
        requestID: UUID,
        epoch: Int64,
        expiresAt: Date,
        release: WatchLoanSnapshot.OdometerReading,
        pump: WatchLoanPumpAdapter
    ) async throws -> WatchLoanSnapshot {
        guard let cgm = sharedCGM else { throw WatchLoanHostError.noSharedCGM }
        let settings = settingsManager.settings
        let now = Date()
        // the hand-off cancelled the temp basal before the release
        let oref = try await openAPS.orefInputs(
            for: settings.dosingMode,
            currentTemp: TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now),
            supportedBasalRates: pump.supportedBasalRates.map { Decimal($0).rounded(scale: 3) },
            shouldSmoothGlucose: settings.smoothGlucose
        )
        let adjustments = try await activeAdjustments()
        let appBuild = WatchLoanSnapshot.appBuild(Bundle.main.infoDictionary)

        return WatchLoanSnapshot(
            versions: WatchLoanSnapshot.Versions(
                schema: WatchLoanSnapshot.currentSchemaVersion,
                protocolVersion: WatchLoanEnvelope.currentProtocolVersion,
                appBuild: appBuild,
                pumpManager: pump.pluginIdentifier,
                pumpStateVersion: pump.rawState["version"] as? Int,
                cgmManager: cgm.pluginIdentifier,
                cgmStateVersion: cgm.rawState["version"] as? Int
            ),
            requestID: requestID,
            epoch: epoch,
            expiresAt: expiresAt,
            phoneTime: now,
            timeZoneIdentifier: TimeZone.current.identifier,
            oref: oref,
            overrideAtGrant: adjustments.override,
            tempTargetAtGrant: adjustments.tempTarget,
            bolusCalculator: WatchLoanSnapshot.BolusCalculatorSettings(
                units: settings.units,
                fraction: settings.overrideFactor,
                fattyMealFactor: settings.fattyMealFactor,
                sweetMealFactor: settings.sweetMealFactor,
                maxCarbs: settings.maxCarbs,
                supportedBolusVolumes: pump.supportedBolusVolumes,
                confirmBolus: settings.confirmBolus
            ),
            glucoseAlarms: GlucoseAlertsStore.shared.alerts,
            glucoseAlarmConfiguration: GlucoseAlertsStore.shared.configuration,
            pumpExport: try pump.exportedConfiguration(),
            cgmExport: try PropertyListSerialization.data(
                fromPropertyList: cgm.exportConfiguration().rawValue,
                format: .binary,
                options: 0
            ),
            deliveryPulseUnits: pump.pulse,
            releaseReading: release,
            podEndsAt: pump.endsAt,
            sensorEndsAt: (cgm as? G7CGMManager)?.sensorEndsAt,
            smoothGlucose: settings.smoothGlucose,
            smoothingWindow: settings.smoothGlucose ? try await fetchGlucoseManager.smoothingWindow() : []
        )
    }

    func startFacts() async -> WatchLoanStartFacts {
        let adjustments = try? await activeAdjustments()
        return WatchLoanStartFacts(
            override: adjustments?.override,
            tempTarget: adjustments?.tempTarget,
            podEndsAt: pump?.endsAt,
            sensorEndsAt: (sharedCGM as? G7CGMManager)?.sensorEndsAt
        )
    }

    private func activeAdjustments() async throws
        -> (override: WatchLoanSnapshot.Adjustment?, tempTarget: WatchLoanSnapshot.Adjustment?)
    {
        let context = makeContext()
        context.name = "watchLoanAdjustments"
        let openAPS = openAPS
        return try await context.perform {
            let override = try openAPS.fetchActiveOverrides(on: context).first.flatMap { override in
                override.date.map { start in
                    WatchLoanSnapshot.Adjustment(
                        name: override.name,
                        startedAt: start,
                        endsAt: override.indefinite ? nil : start
                            .addingTimeInterval(TimeInterval(minutes: override.duration?.doubleValue ?? 0))
                    )
                }
            }
            let tempTarget = try openAPS.fetchActiveTempTargets(on: context).first.flatMap { tempTarget in
                tempTarget.date.map { start in
                    WatchLoanSnapshot.Adjustment(
                        name: tempTarget.name,
                        startedAt: start,
                        endsAt: start.addingTimeInterval(TimeInterval(minutes: tempTarget.duration?.doubleValue ?? 0))
                    )
                }
            }
            return (override, tempTarget)
        }
    }

    // MARK: Records

    func merge(_ batch: WatchLoanRecordBatch) async throws {
        // the watch booked these doses for unconfirmed commands; the kit's own records in this batch replace them
        let replaced = batch.pumpEvents.compactMap(\.replacesSyncIdentifier)
        if !replaced.isEmpty {
            let uploadedIDs = try await pumpHistoryStorage.deletePumpEvents(syncIdentifiers: replaced)
            info(.watch, "\(replaced.count) watch booking(s) replaced by the pump's own record")
            if let nightscoutManager = resolver.resolve(NightscoutManager.self) {
                for id in uploadedIDs { await nightscoutManager.deleteInsulin(withID: id) }
            }
        }
        let pumpEvents = batch.storablePumpEvents
        if pumpEvents.count < batch.pumpEvents.count {
            warning(.watch, "\(batch.pumpEvents.count - pumpEvents.count) unfinished or unidentified watch doses not stored")
        }
        if !pumpEvents.isEmpty {
            // finalized rows are never purged by the phone driver's pending report
            try await pumpHistoryStorage.storePumpEvents(pumpEvents, replacePendingEvents: false)
        }

        let carbs = try await carbsNotStored(batch.carbs)
        if !carbs.isEmpty {
            try await carbsStorage.storeCarbs(carbs, areFetchedFromRemote: false)
        }
        for id in batch.deletedCarbIDs {
            guard let objectID = try await carbObjectID(id) else { continue }
            do {
                _ = try await resolver.resolve(CarbEntryMutationService.self)?.deleteMeal(rootObjectID: objectID)
            } catch {
                warning(.storage, "Deleting a carb entry removed on Apple Watch failed", error: error)
            }
        }

        let glucose = try await glucoseNotStored(batch.glucose)
        if !glucose.isEmpty {
            try await glucoseStorage.storeGlucose(glucose)
        }
    }

    private func carbsNotStored(_ carbs: [CarbsEntry]) async throws -> [CarbsEntry] {
        let ids = carbs.compactMap { $0.id.flatMap(UUID.init(uuidString:)) }
        guard !ids.isEmpty else { return carbs }
        let context = makeContext()
        let stored: Set<UUID> = try await context.perform {
            let request = CarbEntryStored.fetchRequest() as NSFetchRequest<CarbEntryStored>
            request.predicate = NSPredicate(format: "id IN %@", ids)
            return Set(try context.fetch(request).compactMap(\.id))
        }
        return carbs.filter { entry in entry.id.flatMap(UUID.init(uuidString:)).map { !stored.contains($0) } ?? true }
    }

    private func carbObjectID(_ id: String) async throws -> NSManagedObjectID? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let context = makeContext()
        return try await context.perform {
            let request = CarbEntryStored.fetchRequest() as NSFetchRequest<CarbEntryStored>
            request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            return try context.fetch(request).first?.objectID
        }
    }

    /// The phone reads the same sensor: keep only readings it has nothing for within the glucose filter time.
    private func glucoseNotStored(_ glucose: [BloodGlucose]) async throws -> [BloodGlucose] {
        let dates = glucose.map(\.dateString)
        guard let first = dates.min(), let last = dates.max() else { return [] }
        let window = Self.glucoseFilterTime
        let context = makeContext()
        let stored: [Date] = try await context.perform {
            let request = GlucoseStored.fetchRequest() as NSFetchRequest<GlucoseStored>
            request.predicate = NSPredicate(
                format: "date >= %@ AND date <= %@",
                first.addingTimeInterval(-window) as NSDate,
                last.addingTimeInterval(window) as NSDate
            )
            return try context.fetch(request).compactMap(\.date)
        }
        return glucose.filter { reading in !stored.contains { abs($0.timeIntervalSince(reading.dateString)) < window } }
    }

    // MARK: Audit

    func bookedEvents(since date: Date) async throws -> [PumpHistoryEvent] {
        try await pumpHistoryStorage.getPumpHistory(since: date)
    }

    func replaceAuditBolus(id: String, units: Double, at date: Date) async throws {
        let uploadedID = try await pumpHistoryStorage.replaceTaggedBolus(
            id: id,
            amount: Decimal(units).rounded(scale: 2),
            timestamp: date
        )
        if let uploadedID, let nightscoutManager = resolver.resolve(NightscoutManager.self) {
            await nightscoutManager.deleteInsulin(withID: uploadedID)
        }
    }

    func basalProfile() async -> [BasalProfileEntry] {
        await fileStorage.retrieveAsync(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
    }

    // MARK: Alarms and alerts

    private static let managerIdentifier = "trio.watchloan"
    /// No record batch from the watch for this long while it holds the pump: notify, then repeat.
    static let watchSilenceMinutes = [30, 60, 90]
    static let watchSilenceCriticalMinutes = 120

    private static func silenceID(_ minutes: Int) -> Alert.Identifier {
        Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: "noWatchUpdates.\(minutes)")
    }

    func setAlarm(_ alarm: LoanAlarm, armed: Bool, anchor: Date) {
        switch alarm {
        case .phoneNotLooping:
            notLoopingMonitor.setArmed(armed, since: anchor)
        case .phoneNoWatchUpdates:
            let steps = Self.watchSilenceMinutes + [Self.watchSilenceCriticalMinutes]
            steps.forEach { trioAlertManager.retractAlert(identifier: Self.silenceID($0)) }
            silenceAnchor = armed ? anchor : nil
            guard armed else { return }
            for minutes in steps {
                let remaining = anchor.addingTimeInterval(TimeInterval(minutes * 60)).timeIntervalSinceNow
                guard remaining > 0 else { continue }
                let content = Alert.Content(
                    title: String(localized: "No updates from Apple Watch"),
                    body: String(localized: "No update from Trio on Watch for \(minutes) min. Check your watch."),
                    acknowledgeActionButtonLabel: String(localized: "OK")
                )
                trioAlertManager.issueAlert(Alert(
                    identifier: Self.silenceID(minutes),
                    foregroundContent: content,
                    backgroundContent: content,
                    trigger: .delayed(interval: remaining),
                    interruptionLevel: minutes >= Self.watchSilenceCriticalMinutes ? .critical : .timeSensitive,
                    sound: .sound(name: "honk.caf")
                ))
            }
        case .watchNotLooping:
            break
        }
    }

    func alert(_ alert: LoanAlert) {
        guard let (title, body) = Self.content(for: alert) else { return }
        issue(alertIdentifier: "\(alert)", title: title, body: body)
    }

    func auditNotice(units: Double, isShortfall: Bool) {
        let number = Formatter.bolusFormatter.string(from: Decimal(units).rounded(scale: 2) as NSNumber) ?? "\(units)"
        let amount = "\(number) \(HKUnit.internationalUnit().localizedShortUnitString)"
        if isShortfall {
            issue(
                alertIdentifier: "auditShortfall",
                title: String(localized: "Check Your Insulin History"),
                body: String(
                    localized: "Trio on Watch recorded \(amount) more insulin than your pod reports delivering. Insulin on board may read high for a while."
                )
            )
        } else {
            issue(
                alertIdentifier: "auditExcess",
                title: String(localized: "Insulin Added to History"),
                body: String(
                    localized: "Your pod delivered \(amount) that Trio on Watch didn't record. Trio counts it as insulin on board, so insulin on board may read high for a while."
                )
            )
        }
    }

    private func issue(alertIdentifier: String, title: String, body: String) {
        let content = Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: String(localized: "OK"))
        trioAlertManager.issueAlert(Alert(
            identifier: Alert.Identifier(managerIdentifier: Self.managerIdentifier, alertIdentifier: alertIdentifier),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: .timeSensitive
        ))
    }

    private static let pumpFailSafe =
        String(
            localized: "Your pump keeps running the last temp basal until it ends (at most 2 hours), then your scheduled basal."
        )

    /// Phone alerts only; the watch's are its own.
    static func content(for alert: LoanAlert) -> (title: String, body: String)? {
        switch alert {
        case .watchDidNotConfirm:
            return (
                String(localized: "Apple Watch Didn't Confirm"),
                String(localized: "Open Trio to check, or take back your pump.")
            )
        case .startDidNotFinish:
            return (
                String(localized: "Trio on Watch Didn't Start"),
                String(localized: "Trio closed while starting Trio on Watch. Open Trio to check, or take back your pump.")
            )
        case .takeBackPodUnreachable:
            return (
                String(localized: "Can't Reach Your Pump"),
                String(localized: "Keep your iPhone close to your pod. Nothing is giving insulin automatically.") + " " +
                    pumpFailSafe
            )
        case .takeBackUseEnd:
            return (
                String(localized: "Apple Watch Is in Control"),
                String(localized: "End Trio on Watch on your watch, so your history comes back first.")
            )
        case .watchStopped:
            return (
                String(localized: "Trio on Watch Stopped"),
                String(localized: "Your watch stopped controlling your pump. Take back your pump on this iPhone.") + " " +
                    pumpFailSafe
            )
        case .watchContactedPodAfterTakeBack:
            return (
                String(localized: "Apple Watch Contacted Your Pod"),
                String(
                    localized: "Apple Watch contacted your pod after you took it back. Trio counts any insulin it gave. Open Trio on your watch to stop it."
                )
            )
        case .unexpectedPodSession:
            return (
                String(localized: "Another Device Used Your Pod"),
                String(localized: "iPhone stopped sending commands to your pod.") + " " + pumpFailSafe + " " +
                    String(localized: "Open Trio to use the pod on this iPhone.")
            )
        case .podTakenOnThisPhone:
            return (
                String(localized: "Pod in Use on This iPhone"),
                String(localized: "If another device still runs this pod, it stops when it next reaches your pod.")
            )
        case .loanStateUnreadable:
            return (
                String(localized: "Trio stopped sending pump commands"),
                String(
                    localized: "Trio couldn't read which device controls your pump. Your pump finishes any running temp basal and then follows its basal schedule."
                )
            )
        case .podTotalUnreliable:
            return (
                String(localized: "Pod Total Not Checked"),
                String(
                    localized: "Trio couldn't check your pod's delivered insulin against your history, so it added nothing. Insulin on board may read too low. Check your insulin history."
                )
            )
        case .endRefused,
             .phoneDidNotAnswer,
             .podUnreachable,
             .startRefused,
             .stopped:
            return nil
        }
    }

    func didReturnHome() {
        deviceDataManager.resyncPumpAfterTakeBack()
    }

    func onForeignPodSession(_ action: @escaping () -> Void) {
        deviceDataManager.foreignPodSession
            .sink { _ in action() }
            .store(in: &subscriptions)
    }
}

enum WatchLoanHostError: Error {
    case noSharedCGM
}

extension BaseWatchLoanPhoneHost: SnoozeObserver {
    /// A snooze clears pending non-critical notifications; re-arm from the same anchor, as `NotLoopingMonitor` does.
    func snoozeDidChange(_: Date) {
        guard let silenceAnchor else { return }
        setAlarm(.phoneNoWatchUpdates, armed: true, anchor: silenceAnchor)
    }
}
