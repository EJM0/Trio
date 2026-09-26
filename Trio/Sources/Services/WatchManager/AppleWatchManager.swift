import Combine
import CoreData
import Foundation
import Swinject
import UIKit
import WatchConnectivity

/// Protocol defining the base functionality for Watch communication
protocol WatchManager {
    func setupWatchState() async -> WatchState?
}

/// Main implementation of the Watch communication manager
/// Handles bidirectional communication between iPhone and Apple Watch
final class BaseWatchManager: NSObject, WCSessionDelegate, Injectable, WatchManager {
    private var session: WCSession?

    @Injected() var broadcaster: Broadcaster!
    @Injected() private var apsManager: APSManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var fileStorage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var determinationStorage: DeterminationStorage!
    @Injected() private var overrideStorage: OverrideStorage!
    @Injected() private var tempTargetStorage: TempTargetsStorage!
    @Injected() private var adjustmentManager: AdjustmentManager!
    @Injected() private var bolusCalculationManager: BolusCalculationManager!
    @Injected() private var iobService: IOBService!
    @Injected() private var notificationsManager: UserNotificationsManager!
    @Injected() private var fetchGlucoseManager: FetchGlucoseManager!

    private var units: GlucoseUnits = .mgdL
    private var glucoseColorScheme: GlucoseColorScheme = .staticColor
    private var lowGlucose: Decimal = 70.0
    private var highGlucose: Decimal = 180.0
    private var currentGlucoseTarget: Decimal = 100.0
    private var activeBolusAmount: Double = 0.0

    // Queue for handling Core Data change notifications
    private let queue = DispatchQueue(label: "BaseWatchManagerManager.queue", qos: .utility)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    /// Pending debounced watch state push. Only accessed on `queue`.
    private var pendingWatchStatePush: DispatchWorkItem?

    // Glucose history sync (see `WatchGlucoseSync`). Only accessed on the main actor.
    /// Newest reading and settings signature of the last payload built for the watch: the base of the next delta.
    private var lastSentGlucoseNewest: TimeInterval?
    private var lastSentGlucoseSignature: String?
    /// Set from every watch state request. Until the watch app says it can merge deltas, and for older watch
    /// builds, every payload carries the full glucose history.
    private var watchSupportsGlucoseDelta = false

    /// The application context carries the readings of this recent span once the watch merges deltas; the watch
    /// keeps the rest of the window saved, and asks for missing readings when the tail does not connect to it.
    private static let contextGlucoseTail: TimeInterval = 2 * 60 * 60
    /// Content of the last application context, without its per-build stamps, and when it was set. An unchanged
    /// context is not sent again until it is this old, so the watch never sees it go stale (15 minutes).
    private var lastContextContent: NSDictionary?
    private var lastContextUpdate: Date?
    private static let unchangedContextRefreshInterval: TimeInterval = 5 * 60
    /// Bytes handed to WatchConnectivity since launch, per route, for the transfer log.
    private var transferredBytes: [String: Int] = [:]

    typealias PumpEvent = PumpEventStored.EventType

    let viewContext = CoreDataStack.shared.persistentContainer.viewContext

    init(resolver: Resolver) {
        super.init()
        injectServices(resolver)
        setupWatchSession()

        units = settingsManager.settings.units
        glucoseColorScheme = settingsManager.settings.glucoseColorScheme
        lowGlucose = settingsManager.settings.low
        highGlucose = settingsManager.settings.high
        Task {
            currentGlucoseTarget = await getCurrentGlucoseTarget() ?? Decimal(100)
        }
        broadcaster.register(SettingsObserver.self, observer: self)
        broadcaster.register(PumpSettingsObserver.self, observer: self)
        broadcaster.register(PumpReservoirObserver.self, observer: self)
        broadcaster.register(PumpDeactivatedObserver.self, observer: self)

        // Observer for OrefDetermination and adjustments
        coreDataPublisher =
            CoreDataStack.shared.entityChangePublisher
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        // Observer for glucose and manual glucose
        glucoseStorage.updatePublisher
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                self?.scheduleWatchStatePush()
            }
            .store(in: &subscriptions)

        iobService.iobPublisher
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                self?.scheduleWatchStatePush()
            }
            .store(in: &subscriptions)

        registerPeripheralHandlers()
        registerHandlers()
    }

    /// Push-on-change for pump expiry and CGM lifecycle, so the watch's Devices
    /// page reflects new peripheral data as soon as the phone learns of it.
    /// `removeDuplicates` keeps a republished but unchanged value off the radio.
    private func registerPeripheralHandlers() {
        apsManager.pumpExpiresAtDate
            .removeDuplicates()
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                self?.pushPeripheralUpdate()
            }
            .store(in: &subscriptions)

        fetchGlucoseManager.cgmProgressHighlight
            .map { $0?.percentComplete }
            .removeDuplicates()
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                self?.pushPeripheralUpdate()
            }
            .store(in: &subscriptions)
    }

    /// Sends a fresh watch state whenever peripheral data changed. Cheap enough
    /// to do unconditionally: the sinks that call it are all deduplicated, and
    /// an app-less watch is filtered out before anything is sent.
    private func pushPeripheralUpdate() {
        scheduleWatchStatePush()
    }

    /// Coalesces bursts of triggers (a new glucose value, the loop's
    /// determination and the IOB update usually land together) into a single
    /// watch state build and push.
    private func scheduleWatchStatePush() {
        guard let session = session, session.isPaired, session.isWatchAppInstalled else { return }

        queue.async { [weak self] in
            guard let self = self else { return }
            self.pendingWatchStatePush?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                Task {
                    await self.pushWatchState()
                }
            }
            self.pendingWatchStatePush = workItem
            self.queue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }

    /// Builds the current watch state and sends it, unless it could not be built.
    private func pushWatchState() async {
        guard let state = await setupWatchState() else { return }
        await sendDataToWatch(state)
    }

    private func registerHandlers() {
        coreDataPublisher?.filteredByEntityName("OrefDetermination").sink { [weak self] _ in
            self?.scheduleWatchStatePush()
        }.store(in: &subscriptions)

        // Due to the Batch insert this only is used for observing Deletion of Glucose entries
        coreDataPublisher?.filteredByEntityName("GlucoseStored").sink { [weak self] _ in
            self?.scheduleWatchStatePush()
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("PumpEventStored").sink { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.getActiveBolusAmount()
            }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("OverrideStored").sink { [weak self] _ in
            self?.scheduleWatchStatePush()
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("TempTargetStored").sink { [weak self] _ in
            self?.scheduleWatchStatePush()
        }.store(in: &subscriptions)
    }

    /// Sets up the WatchConnectivity session if the device supports it
    private func setupWatchSession() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session

            debug(.watchManager, "📱 Phone session setup - isPaired: \(session.isPaired)")
        } else {
            debug(.watchManager, "📱 WCSession is not supported on this device")
        }
    }

    /// Attempts to reestablish the Watch connection if it becomes unreachable
    private func retryConnection() {
        guard let session = session else { return }

        if !session.isReachable {
            debug(.watchManager, "📱 Attempting to reactivate session...")
            session.activate()
        }
    }

    /// Prepares the current state data to be sent to the Watch
    /// - Returns: WatchState containing current glucose readings and trends and determination infos for displaying cob and iob in the view,
    ///   or `nil` if there is no watch to send it to or the state could not be built. Never an empty placeholder state: the watch
    ///   would accept and display it, since it carries the newest timestamp.
    func setupWatchState() async -> WatchState? {
        // Check if a watch is paired before doing expensive calculations. Reachability is not required:
        // an unreachable watch still gets the state through the application context.
        guard let session = session, session.isPaired, session.isWatchAppInstalled else {
            debug(.watchManager, "⌚️❌ Skipping setupWatchState - No Watch is paired or app not installed")
            return nil
        }

        // Skip if watch session is not activated
        guard session.activationState == .activated else {
            debug(.watchManager, "⌚️❌ Skipping setupWatchState - Watch session not activated")
            return nil
        }
        do {
            let context = CoreDataStack.shared.newTaskContext()
            context.name = "setupWatchState"

            // Get NSManagedObjectIDs
            let glucoseWindowStart = Date.oneDayAgo
            let glucoseIds = try await fetchGlucose(since: glucoseWindowStart)
            let deletedGlucoseDates = await fetchDeletedGlucoseDates(since: glucoseWindowStart)
            let determinationIds = try await determinationStorage.fetchLastDeterminationObjectID(
                predicate: NSPredicate.predicateFor30MinAgoForDetermination
            )
            let overridePresetIds = try await overrideStorage.fetchForOverridePresets()
            let tempTargetPresetIds = try await tempTargetStorage.fetchForTempTargetPresets()

            // Get NSManagedObjects
            let glucoseObjects: [GlucoseStored] = try await CoreDataStack.shared
                .getNSManagedObject(with: glucoseIds, context: context)
            let determinationObjects: [OrefDetermination] = try await CoreDataStack.shared
                .getNSManagedObject(with: determinationIds, context: context)
            let overridePresetObjects: [OverrideStored] = try await CoreDataStack.shared
                .getNSManagedObject(with: overridePresetIds, context: context)
            let tempTargetPresetObjects: [TempTargetStored] = try await CoreDataStack.shared
                .getNSManagedObject(with: tempTargetPresetIds, context: context)

            var watchState: WatchState = await context.perform {
                var watchState = WatchState(date: Date())

                // Set lastLoopDate
                let lastLoopMinutes = Int((Date().timeIntervalSince(self.apsManager.lastLoopDate) - 30) / 60) + 1
                if lastLoopMinutes > 1440 {
                    watchState.lastLoopTime = "--"
                } else {
                    watchState.lastLoopTime = "\(lastLoopMinutes) min"
                }

                // Set IOB and COB from latest determination
                let iob = self.iobService.currentIOB ?? 0
                watchState.iob = Formatter.decimalFormatterWithTwoFractionDigits.string(from: iob as NSNumber)

                if let latestDetermination = determinationObjects.first {
                    let cob = NSNumber(value: latestDetermination.cob)
                    watchState.cob = Formatter.integerFormatter.string(from: cob)
                }

                // Set override presets with their enabled status
                watchState.overridePresets = overridePresetObjects.map { override in
                    OverridePresetWatch(
                        name: override.name ?? "",
                        isEnabled: override.enabled
                    )
                }

                /// Color parameters, shared by the current glucose and the history
                let hardCodedLow = Decimal(55)
                let hardCodedHigh = Decimal(220)
                let isDynamicColorScheme = self.glucoseColorScheme == .dynamicColor

                let highGlucoseValue = isDynamicColorScheme ? hardCodedHigh : self.highGlucose
                let lowGlucoseValue = isDynamicColorScheme ? hardCodedLow : self.lowGlucose
                let highGlucoseColorValue = highGlucoseValue
                let lowGlucoseColorValue = lowGlucoseValue
                let targetGlucose = self.currentGlucoseTarget

                // Everything the history's values and colors depend on. The watch never mixes
                // readings with different signatures.
                watchState.glucoseWindowStart = glucoseWindowStart
                watchState.deletedGlucoseDates = deletedGlucoseDates
                watchState.glucoseSignature = [
                    self.units.rawValue,
                    self.glucoseColorScheme.rawValue,
                    "\(lowGlucoseColorValue)",
                    "\(highGlucoseColorValue)",
                    "\(targetGlucose)"
                ].joined(separator: "|")

                guard let latestGlucose = glucoseObjects.first else {
                    return watchState
                }

                // Assign currentGlucose and its color
                /// Set current glucose with proper formatting
                if self.units == .mgdL {
                    watchState.currentGlucose = "\(latestGlucose.glucose)"
                } else {
                    let mgdlValue = Decimal(latestGlucose.glucose)
                    let latestGlucoseValue = mgdlValue.formattedAsMmolL
                    watchState.currentGlucose = "\(latestGlucoseValue)"
                }

                /// Calculate latest color
                let currentGlucoseColor = Trio.getDynamicGlucoseColor(
                    glucoseValue: Decimal(latestGlucose.glucose),
                    highGlucoseColorValue: highGlucoseColorValue,
                    lowGlucoseColorValue: lowGlucoseColorValue,
                    targetGlucose: targetGlucose,
                    glucoseColorScheme: self.glucoseColorScheme
                )

                if Decimal(latestGlucose.glucose) <= self.lowGlucose || Decimal(latestGlucose.glucose) >= self.highGlucose {
                    watchState.currentGlucoseColorString = currentGlucoseColor.toHexString()
                } else {
                    watchState.currentGlucoseColorString = "#ffffff" // white when in range; colored when out of range
                }

                // Map glucose values
                watchState.glucoseValues = glucoseObjects.compactMap { glucose in
                    let glucoseValue = self.units == .mgdL
                        ? Double(glucose.glucose)
                        : Double(truncating: Decimal(glucose.glucose).asMmolL as NSNumber)

                    let glucoseColor = Trio.getDynamicGlucoseColor(
                        glucoseValue: Decimal(glucose.glucose),
                        highGlucoseColorValue: highGlucoseColorValue,
                        lowGlucoseColorValue: lowGlucoseColorValue,
                        targetGlucose: targetGlucose,
                        glucoseColorScheme: self.glucoseColorScheme
                    )

                    return WatchGlucoseObject(
                        date: glucose.date ?? Date(),
                        glucose: glucoseValue,
                        color: glucoseColor.toHexString()
                    )
                }
                .sorted { $0.date < $1.date }

                // Set axis domain: min and max Y-axis values
                // Apply unit parsing conditionally, if user uses mmol/L
                let maxGlucoseValue = Decimal(glucoseObjects.map { Int($0.glucose) }.max() ?? 200)
                var maxYValue = Decimal(200)

                if maxGlucoseValue > maxYValue, maxGlucoseValue <= 225 {
                    maxYValue = Decimal(250)
                } else if maxGlucoseValue > 225, maxGlucoseValue <= 275 {
                    maxYValue = Decimal(300)
                } else if maxGlucoseValue > 275, maxGlucoseValue <= 325 {
                    maxYValue = Decimal(350)
                } else if maxGlucoseValue > 325 {
                    maxYValue = Decimal(400)
                }

                if self.units == .mmolL {
                    maxYValue = Double(truncating: maxYValue as NSNumber).asMmolL
                }
                watchState.maxYAxisValue = maxYValue

                if self.units == .mmolL {
                    let minYValue = Double(truncating: watchState.minYAxisValue as NSNumber).asMmolL
                    watchState.minYAxisValue = minYValue
                }

                // Convert direction to trend string
                watchState.trend = latestGlucose.direction

                // Calculate delta if we have at least 2 readings
                if glucoseObjects.count >= 2 {
                    var glucoseLast = Decimal(glucoseObjects[0].glucose)
                    var glucoseSecondLast = Decimal(glucoseObjects[1].glucose)
                    if self.units == .mmolL {
                        glucoseLast = glucoseLast.asMmolL
                        glucoseSecondLast = glucoseSecondLast.asMmolL
                    }

                    let deltaValue = glucoseLast - glucoseSecondLast
                    let formattedDelta = Formatter.glucoseFormatter(for: self.units)
                        .string(from: deltaValue as NSNumber) ?? "0"
                    watchState.delta = deltaValue < 0 ? "\(formattedDelta)" : "+\(formattedDelta)"
                }

                // Set temp target presets with their enabled status
                watchState.tempTargetPresets = tempTargetPresetObjects.map { tempTarget in
                    TempTargetPresetWatch(
                        name: tempTarget.name ?? "",
                        isEnabled: tempTarget.enabled
                    )
                }

                // Set units
                watchState.units = self.units

                // Add limits and pump specific dosing increment settings values
                watchState.maxBolus = self.settingsManager.pumpSettings.maxBolus
                watchState.maxCarbs = self.settingsManager.settings.maxCarbs
                watchState.maxFat = self.settingsManager.settings.maxFat
                watchState.maxProtein = self.settingsManager.settings.maxProtein
                watchState.bolusIncrement = self.settingsManager.preferences.bolusIncrement
                watchState.confirmBolusFaster = self.settingsManager.settings.confirmBolusFaster

                watchState.showForecast = self.settingsManager.settings.showForecastWatch
                watchState.isForecastCone = self.settingsManager.settings.forecastDisplayType == .cone

                // Forecast data comes from OrefDetermination's `forecasts` CoreData
                // relationship (Set<Forecast>), NOT a `.predictions` property.
                if let latestDetermination = determinationObjects.first,
                   let forecastsSet = latestDetermination.forecasts,
                   !forecastsSet.isEmpty
                {
                    let anchorDate = latestDetermination.deliverAt ?? latestDetermination.timestamp ?? Date()
                    watchState.forecastStartDate = anchorDate

                    // Rebuild a [type: [Int]] dictionary from the CoreData relationship.
                    // Strictly cap to 24 points (2 hours of 5-minute forecasts)
                    var rawPredictions: [String: [Int]] = [:]
                    for forecast in forecastsSet {
                        guard let type = forecast.type else { continue }
                        let values = Array(forecast.forecastValuesArray.map { Int($0.value) }.prefix(24))
                        guard !values.isEmpty else { continue }
                        rawPredictions[type] = values
                    }

                    func convert(_ values: [Int]?) -> [Double] {
                        guard let values = values else { return [] }
                        return values.map { raw in
                            self.units == .mgdL ? Double(raw) : Double(truncating: Decimal(raw).asMmolL as NSNumber)
                        }
                    }

                    if watchState.isForecastCone {
                        let allSeries: [[Int]] = [
                            rawPredictions["iob"],
                            rawPredictions["zt"],
                            rawPredictions["cob"],
                            rawPredictions["uam"]
                        ].compactMap { $0 }

                        // Change .max() to .min() so the shortest prediction line cuts off the cone
                        let count = allSeries.map(\.count).min() ?? 0

                        var coneMin: [Double] = []
                        var coneMax: [Double] = []
                        for i in 0 ..< count {
                            let valuesAtIndex = allSeries.compactMap { $0.indices.contains(i) ? $0[i] : nil }
                            guard let minRaw = valuesAtIndex.min(), let maxRaw = valuesAtIndex.max() else { continue }
                            coneMin.append(convert([minRaw])[0])
                            coneMax.append(convert([maxRaw])[0])
                        }
                        watchState.forecastConeMin = coneMin
                        watchState.forecastConeMax = coneMax
                        watchState.forecastLines = [:]
                    } else {
                        var lines: [String: [Double]] = [:]
                        if let iob = rawPredictions["iob"] { lines["iob"] = convert(iob) }
                        if let cob = rawPredictions["cob"] { lines["cob"] = convert(cob) }
                        if let uam = rawPredictions["uam"] { lines["uam"] = convert(uam) }
                        if let zt = rawPredictions["zt"] { lines["zt"] = convert(zt) }
                        watchState.forecastLines = lines
                        watchState.forecastConeMin = []
                        watchState.forecastConeMax = []
                    }
                } else {
                    watchState.forecastStartDate = nil
                    watchState.forecastConeMin = []
                    watchState.forecastConeMax = []
                    watchState.forecastLines = [:]
                }

                debug(
                    .watchManager,

                    "📱 Setup WatchState - currentGlucose: \(watchState.currentGlucose ?? "nil"), trend: \(watchState.trend ?? "nil"), delta: \(watchState.delta ?? "nil"), values: \(watchState.glucoseValues.count)"
                )

                return watchState
            }

            // Peripheral (pump + CGM) data is gathered outside `context.perform`:
            // it reads Combine subjects and the live CGM manager, neither of
            // which belongs on a Core Data queue.
            await gatherPeripherals(into: &watchState)

            return watchState
        } catch {
            debug(
                .watchManager,
                "\(DebuggingIdentifiers.failed) Error setting up watch state: \(error)"
            )
            return nil
        }
    }

    /// Dates of glucose readings deleted inside the window. `deleteGlucose` keeps a `DeletedGlucoseStored` entry with
    /// the reading's exact date, so the watch can drop the same reading from its history.
    private func fetchDeletedGlucoseDates(since windowStart: Date) async -> [Date] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchDeletedGlucoseDates"
        return await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "DeletedGlucoseStored")
            request.predicate = NSPredicate(format: "date >= %@", windowStart as NSDate)
            request.propertiesToFetch = ["date"]
            request.resultType = .dictionaryResultType
            do {
                return try context.fetch(request).compactMap { $0["date"] as? Date }
            } catch {
                debug(.watchManager, "❌ Error fetching deleted glucose: \(error)")
                return []
            }
        }
    }

    /// Fetches recent glucose readings from CoreData
    /// - Parameter windowStart: Oldest reading date to include. Sent to the watch, which trims its history to it.
    /// - Returns: Array of NSManagedObjectIDs for glucose readings
    private func fetchGlucose(since windowStart: Date) async throws -> [NSManagedObjectID] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchGlucose"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.glucose(since: windowStart),
            key: "date",
            ascending: false
        )

        return try await context.perform {
            guard let fetchedResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return fetchedResults.map(\.objectID)
        }
    }

    /// Fetches last pump event that is a non-external bolus from CoreData
    /// - Returns: NSManagedObjectIDs for last bolus
    func fetchLastBolus() async throws -> NSManagedObjectID? {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchLastBolus"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate.lastPumpBolus,
            key: "timestamp",
            ascending: false,
            fetchLimit: 1,
            relationshipKeyPathsForPrefetching: ["bolus"]
        )

        return try await context.perform {
            guard let fetchedResults = results as? [PumpEventStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return fetchedResults.map(\.objectID).first
        }
    }

    /// Gets the active bolus amount by fetching last (active) bolus.
    @MainActor func getActiveBolusAmount() async {
        do {
            if let lastBolusObjectId = try await fetchLastBolus() {
                let lastBolusObject: [PumpEventStored] = try await CoreDataStack.shared
                    .getNSManagedObject(with: [lastBolusObjectId], context: viewContext)

                activeBolusAmount = lastBolusObject.first?.bolus?.amount?.doubleValue ?? 0.0
            }
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Error getting active bolus amount: \(error)"
            )
        }
    }

    // MARK: - Peripherals (pump + CGM device info)

    /// Fills in every pump and CGM lifecycle field the watch's Devices page needs.
    ///
    /// Deliberately leaves fields `nil` when the hardware can't report them:
    /// patch pumps have no battery, and several CGM sources (Eversense,
    /// Nightscout, xDrip) surface no sensor expiry at all. The watch renders
    /// nothing for a `nil` rather than a placeholder.
    private func gatherPeripherals(into state: inout WatchState) async {
        state.peripheralsUpdatedAt = Date()

        // Pump identity and patch lifetime
        let pumpName = apsManager.pumpName.value
        state.pumpName = pumpName.isEmpty ? nil : pumpName
        state.pumpExpiresAt = apsManager.pumpExpiresAtDate.value
        state.pumpActivatedAt = apsManager.pumpActivatedAtDate.value
        state.pumpStatusMessage = apsManager.pumpManager?.pumpStatusHighlight?.localizedMessage

        // Reservoir — same file the home header reads. The `0xDEAD_BEEF`
        // "50+ U" sentinel is passed through untouched; the watch view
        // interprets it exactly as `PumpView` does.
        state.pumpReservoir = await fileStorage.retrieveAsync(OpenAPS.Monitor.reservoir, as: Decimal.self)

        state.pumpBatteryPercent = await fetchPumpBatteryPercent()

        // CGM sensor lifecycle
        let cgmManager = fetchGlucoseManager.cgmManager
        let glucoseSource = fetchGlucoseManager.glucoseSource
        let progress = fetchGlucoseManager.cgmProgressHighlight.value

        state.cgmName = cgmManager?.localizedTitle
        state.cgmSensorExpiresAt = CGMSensorLifecycle.resolveSensorExpiresAt(
            manager: cgmManager,
            glucoseSource: glucoseSource,
            lifecycle: progress
        )
        state.cgmProgressPercent = progress?.percentComplete
        state.cgmProgressState = progress?.progressState.rawValue
        state.cgmStatusMessage = fetchGlucoseManager.cgmDisplayState.value?.localizedMessage
    }

    /// Most recent pump battery reading, or `nil` when the pump doesn't have one.
    ///
    /// `display == false` is how `APSManager` encodes "this pump reports no
    /// battery" — Omnipod and Medtrum both return `pumpBatteryChargeRemaining
    /// == nil`, so patch pumps never produce a battery row on the watch.
    private func fetchPumpBatteryPercent() async -> Int? {
        do {
            let context = CoreDataStack.shared.newTaskContext()
            context.name = "fetchPumpBattery"
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: OpenAPS_Battery.self,
                onContext: context,
                predicate: NSPredicate.predicateFor30MinAgo,
                key: "date",
                ascending: false,
                fetchLimit: 1
            )

            return await context.perform { () -> Int? in
                guard let battery = (results as? [OpenAPS_Battery])?.first, battery.display else { return nil }
                return Int(battery.percent)
            }
        } catch {
            debug(
                .watchManager,
                "\(DebuggingIdentifiers.failed) Error fetching pump battery for watch: \(error)"
            )
            return nil
        }
    }

    /// Serializes the peripheral fields into the wire sub-dictionary.
    ///
    /// Nil values are omitted rather than encoded, which lets the watch's
    /// `if let … as? T { … } else { nil }` parse clear a removed pod or sensor
    /// without needing a separate "absent" marker.
    private func peripheralsToDictionary(from state: WatchState) -> [String: Any] {
        var dictionary: [String: Any] = [:]

        if let updatedAt = state.peripheralsUpdatedAt {
            dictionary[WatchMessageKeys.peripheralsUpdatedAt] = updatedAt.timeIntervalSince1970
        }
        if let pumpName = state.pumpName {
            dictionary[WatchMessageKeys.pumpName] = pumpName
        }
        if let reservoir = state.pumpReservoir {
            dictionary[WatchMessageKeys.pumpReservoir] = reservoir
        }
        if let batteryPercent = state.pumpBatteryPercent {
            dictionary[WatchMessageKeys.pumpBatteryPercent] = batteryPercent
        }
        if let expiresAt = state.pumpExpiresAt {
            dictionary[WatchMessageKeys.pumpExpiresAt] = expiresAt.timeIntervalSince1970
        }
        if let activatedAt = state.pumpActivatedAt {
            dictionary[WatchMessageKeys.pumpActivatedAt] = activatedAt.timeIntervalSince1970
        }
        if let statusMessage = state.pumpStatusMessage {
            dictionary[WatchMessageKeys.pumpStatusMessage] = statusMessage
        }
        if let cgmName = state.cgmName {
            dictionary[WatchMessageKeys.cgmName] = cgmName
        }
        if let sensorExpiresAt = state.cgmSensorExpiresAt {
            dictionary[WatchMessageKeys.cgmSensorExpiresAt] = sensorExpiresAt.timeIntervalSince1970
        }
        if let progressPercent = state.cgmProgressPercent {
            dictionary[WatchMessageKeys.cgmProgressPercent] = progressPercent
        }
        if let progressState = state.cgmProgressState {
            dictionary[WatchMessageKeys.cgmProgressState] = progressState
        }
        if let cgmStatusMessage = state.cgmStatusMessage {
            dictionary[WatchMessageKeys.cgmStatusMessage] = cgmStatusMessage
        }

        return dictionary
    }

    /// Sends peripheral data on its own, without a surrounding watch state.
    ///
    /// Used for changes the watch must not miss even while it is out of range —
    /// a removed pump above all — so it falls back to `transferUserInfo` when
    /// the session isn't reachable, which the routine push cannot do.
    @MainActor func sendPeripheralUpdate() async {
        guard let session = session, session.isPaired, session.isWatchAppInstalled else { return }

        guard session.activationState == .activated else {
            debug(.watchManager, "⌚️ Watch session not activated for peripheral update. Reactivating...")
            session.activate()
            return
        }

        var state = WatchState(date: Date())
        await gatherPeripherals(into: &state)
        let payload = peripheralsToDictionary(from: state)

        if session.isReachable {
            session.sendMessage([WatchMessageKeys.peripheralData: payload], replyHandler: nil) { error in
                debug(.watchManager, "❌ Error sending peripheral data: \(error)")
            }
        } else {
            session.transferUserInfo([WatchMessageKeys.peripheralData: payload])
        }
    }

    // MARK: - Send to Watch

    func watchStateToDictionary(from state: WatchState) -> [String: Any] {
        var dictionary: [String: Any] = [
            WatchMessageKeys.date: state.date.timeIntervalSince1970,
            WatchMessageKeys.currentGlucose: state.currentGlucose ?? "--",
            WatchMessageKeys.currentGlucoseColorString: state.currentGlucoseColorString ?? "#ffffff",
            WatchMessageKeys.trend: state.trend ?? "",
            WatchMessageKeys.delta: state.delta ?? "",
            WatchMessageKeys.iob: state.iob ?? "",
            WatchMessageKeys.cob: state.cob ?? "",
            WatchMessageKeys.lastLoopTime: state.lastLoopTime ?? "",
            WatchMessageKeys.minYAxisValue: state.minYAxisValue,
            WatchMessageKeys.maxYAxisValue: state.maxYAxisValue,
            WatchMessageKeys.overridePresets: state.overridePresets.map { preset in
                [
                    "name": preset.name,
                    "isEnabled": preset.isEnabled
                ]
            },
            WatchMessageKeys.tempTargetPresets: state.tempTargetPresets.map { preset in
                [
                    "name": preset.name,
                    "isEnabled": preset.isEnabled
                ]
            },
            WatchMessageKeys.maxBolus: state.maxBolus,
            WatchMessageKeys.maxCarbs: state.maxCarbs,
            WatchMessageKeys.maxFat: state.maxFat,
            WatchMessageKeys.maxProtein: state.maxProtein,
            WatchMessageKeys.bolusIncrement: state.bolusIncrement,
            WatchMessageKeys.confirmBolusFaster: state.confirmBolusFaster,
            WatchMessageKeys.units: state.units.rawValue,
            WatchMessageKeys.showForecastWatch: state.showForecast,
            WatchMessageKeys.isForecastCone: state.isForecastCone
        ]

        // Assigned rather than inlined above: this literal is already at the
        // edge of the type checker's budget for a single expression.
        dictionary[WatchMessageKeys.peripheralData] = peripheralsToDictionary(from: state)

        // Always the full history here; `WatchGlucoseSync.delta` derives a delta from it.
        let glucoseReadings: [[String: Any]] = state.glucoseValues.map { value -> [String: Any] in
            [
                WatchGlucoseSync.readingGlucoseKey: value.glucose,
                WatchGlucoseSync.readingTimestampKey: value.date.timeIntervalSince1970,
                WatchGlucoseSync.readingColorKey: value.color
            ]
        }
        WatchGlucoseSync.annotateFullHistory(
            &dictionary,
            readings: glucoseReadings,
            windowStart: state.glucoseWindowStart?.timeIntervalSince1970,
            signature: state.glucoseSignature,
            deletedTimestamps: state.deletedGlucoseDates.map(\.timeIntervalSince1970)
        )

        var forecastData: [String: Any] = [
            WatchMessageKeys.forecastConeMin: state.forecastConeMin,
            WatchMessageKeys.forecastConeMax: state.forecastConeMax,
            WatchMessageKeys.forecastLines: state.forecastLines
        ]

        if let start = state.forecastStartDate?.timeIntervalSince1970 {
            forecastData[WatchMessageKeys.forecastStartDate] = start
        }

        dictionary[WatchMessageKeys.forecastData] = forecastData
        return dictionary
    }

    /// Sends the state of type WatchState to the connected Watch
    /// - Parameter state: Current WatchState containing glucose data to be sent
    @MainActor func sendDataToWatch(_ state: WatchState) async {
        guard let session = session else { return }

        // The previous payload is what the watch is expected to hold: the delta builds on it.
        let previousGlucoseNewest = lastSentGlucoseNewest
        let previousGlucoseSignature = lastSentGlucoseSignature

        guard let payload = prepareWatchStatePayload(state) else { return }

        // if session is reachable, it means watch App is in the foreground -> also send watchState as message for immediate delivery
        guard session.isReachable else { return }

        var message = payload
        if watchSupportsGlucoseDelta, let base = previousGlucoseNewest, previousGlucoseSignature == state.glucoseSignature {
            message = WatchGlucoseSync.delta(of: payload, since: base)
        }
        logTransfer("message", [WatchMessageKeys.watchState: message])

        session.sendMessage([WatchMessageKeys.watchState: message], replyHandler: nil) { error in
            debug(.watchManager, "❌ Error sending watch state: \(error)")
        }
    }

    /// The reply to a watch state request: only the readings newer than the newest one the watch holds when it
    /// can merge them, otherwise the full history.
    private func replyPayload(_ payload: [String: Any], for request: [String: Any], state: WatchState) -> [String: Any] {
        guard request[WatchMessageKeys.supportsGlucoseDelta] as? Bool == true,
              let since = request[WatchMessageKeys.glucoseSince] as? TimeInterval,
              request[WatchMessageKeys.glucoseSignature] as? String == state.glucoseSignature,
              let windowStart = state.glucoseWindowStart,
              since >= windowStart.timeIntervalSince1970
        else { return payload }

        return WatchGlucoseSync.delta(of: payload, since: since)
    }

    /// Forgets what the watch was sent, so the next payloads carry the full history.
    @MainActor private func resetGlucoseSync() {
        lastSentGlucoseNewest = nil
        lastSentGlucoseSignature = nil
        watchSupportsGlucoseDelta = false
        lastContextContent = nil
        lastContextUpdate = nil
    }

    /// A context's content without what changes with every build even when nothing visible does: the send
    /// stamp, the glucose window start and the peripherals' gather time.
    private static func contextContent(of context: [String: Any]) -> NSDictionary {
        var content = context
        content.removeValue(forKey: WatchMessageKeys.date)
        content.removeValue(forKey: WatchMessageKeys.glucoseWindowStart)
        if var peripherals = content[WatchMessageKeys.peripheralData] as? [String: Any] {
            peripherals.removeValue(forKey: WatchMessageKeys.peripheralsUpdatedAt)
            content[WatchMessageKeys.peripheralData] = peripherals
        }
        return content as NSDictionary
    }

    /// Logs the size of a payload handed to WatchConnectivity, with the total per route since launch.
    /// Sizes are those of a binary property list, close to what goes over the air.
    @MainActor private func logTransfer(_ route: String, _ payload: [String: Any]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        else {
            debug(.watchManager, "📦 \(route): size unknown")
            return
        }
        transferredBytes[route, default: 0] += data.count
        let watchState = payload[WatchMessageKeys.watchState] as? [String: Any]
        let readings = (watchState?[WatchMessageKeys.glucoseValues] as? [Any])?.count ?? 0
        debug(
            .watchManager,
            "📦 \(route): \(data.count) B, \(readings) glucose readings; since launch: \(transferredBytes[route] ?? 0) B"
        )
    }

    /// Stamps the state with the send time, stores it as the application context and returns the payload.
    /// Remembers the payload's newest glucose reading as the base of the next delta.
    /// - Returns: The watch state dictionary with the full glucose history, or `nil` if there is no usable watch session.
    @MainActor private func prepareWatchStatePayload(_ state: WatchState) -> [String: Any]? {
        guard let session = session else { return nil }

        guard session.isPaired else {
            debug(.watchManager, "⌚️❌ No Watch is paired")
            return nil
        }

        guard session.isWatchAppInstalled else {
            debug(.watchManager, "⌚️❌ Trio Watch app is not installed")
            return nil
        }

        guard session.activationState == .activated else {
            let activationStateString = "\(session.activationState)"
            debug(.watchManager, "⌚️ Watch session activationState = \(activationStateString). Reactivating...")
            session.activate()
            return nil
        }

        // Stamp the snapshot with send time. Each push gets a strictly newer
        // `date` than the previous one, which is what the watch's monotonicity
        // dedup relies on — including watch-requested re-pushes when no CGM
        // tick has bumped the build-time date.
        var state = state
        state.date = Date()

        let message: [String: Any] = watchStateToDictionary(from: state)

        // The application context always holds the latest state. It replaces the previous one instead of
        // queueing up like userInfo transfers, and the watch reads it on launch, so it has data even when
        // it was out of reach when the state was sent. A watch that merges deltas keeps its history saved,
        // so the context only carries the recent readings.
        var context = message
        if watchSupportsGlucoseDelta,
           let tail = WatchGlucoseSync.recentTail(
               of: message,
               after: state.date.timeIntervalSince1970 - Self.contextGlucoseTail
           )
        {
            context = tail
        }

        let content = Self.contextContent(of: context)
        if let lastContent = lastContextContent, lastContent.isEqual(content),
           let lastUpdate = lastContextUpdate, state.date.timeIntervalSince(lastUpdate) < Self.unchangedContextRefreshInterval
        {
            debug(.watchManager, "📦 Skipping unchanged watch application context")
        } else {
            do {
                try session.updateApplicationContext([WatchMessageKeys.watchState: context])
                lastContextContent = content
                lastContextUpdate = state.date
                logTransfer("context", [WatchMessageKeys.watchState: context])
            } catch {
                debug(.watchManager, "❌ Error updating watch application context: \(error)")
            }
        }

        lastSentGlucoseNewest = WatchGlucoseSync.newestTimestamp(in: message)
        lastSentGlucoseSignature = state.glucoseSignature

        return message
    }

    func sendAcknowledgment(toWatch success: Bool, message: String = "", ackCode: AcknowledgmentCode) {
        guard let session = session, session.isReachable else {
            debug(.watchManager, "⌚️ Watch not reachable for acknowledgment")
            return
        }

        let ackMessage: [String: Any] = [
            WatchMessageKeys.acknowledged: success,
            WatchMessageKeys.message: message,
            WatchMessageKeys.ackCode: ackCode.rawValue
        ]

        session.sendMessage(ackMessage, replyHandler: nil) { error in
            debug(.watchManager, "❌ Error sending acknowledgment: \(error)")
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            debug(.watchManager, "📱 Phone session activation failed: \(error)")
            return
        }

        debug(.watchManager, "📱 Phone session activated with state: \(activationState.rawValue)")
        debug(.watchManager, "📱 Phone isReachable after activation: \(session.isReachable)")

        // Try to send initial data after activation
        Task {
            await self.pushWatchState()
        }
    }

    /// Messages that expect a reply. The watch requests its state this way, so it learns
    /// whether the request was answered. Every path must call `replyHandler`, or the watch
    /// only finds out through a delivery timeout.
    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let requestWatchUpdate = message[WatchMessageKeys.requestWatchUpdate] as? String,
              requestWatchUpdate == WatchMessageKeys.watchState
        else {
            // Nothing else is sent with a reply handler today; handle it like a plain message.
            replyHandler([:])
            self.session(session, didReceiveMessage: message)
            return
        }

        debug(.watchManager, "📱 Watch requested watch state data update (with reply).")

        Task { @MainActor [weak self] in
            guard let self else {
                replyHandler([:])
                return
            }

            self.watchSupportsGlucoseDelta = message[WatchMessageKeys.supportsGlucoseDelta] as? Bool == true

            guard let state = await self.setupWatchState(),
                  let payload = self.prepareWatchStatePayload(state)
            else {
                replyHandler([:])
                return
            }
            let reply = [WatchMessageKeys.watchState: self.replyPayload(payload, for: message, state: state)]
            self.logTransfer("reply", reply)
            replyHandler(reply)
        }
    }

    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        // Handle logs first - doesn't need self, so it can run even during teardown
        if let logs = message["watchLogs"] as? String {
            SimpleLogReporter.appendToWatchLog(logs)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            if let requestWatchUpdate = message[WatchMessageKeys.requestWatchUpdate] as? String,
               requestWatchUpdate == WatchMessageKeys.watchState
            {
                debug(.watchManager, "📱 Watch requested watch state data update.")
                // Only watch builds without glucose delta support still send this request without a reply handler.
                self.watchSupportsGlucoseDelta = false
                // Skip if no watch is paired or app not installed
                guard let session = self.session, session.isPaired, session.isReachable,
                      session.isWatchAppInstalled else { return }
                Task {
                    await self.pushWatchState()
                }
                return
            }

            if let snoozeMinutes = message[WatchMessageKeys.snoozeDuration] as? Int {
                debug(.watchManager, "📱 Received snooze request from watch: \(snoozeMinutes) minutes")
                await self.notificationsManager.applySnooze(for: TimeInterval(snoozeMinutes * 60))
                return
            } else if let bolusAmount = message[WatchMessageKeys.bolus] as? Double,
                      message[WatchMessageKeys.carbs] == nil,
                      message[WatchMessageKeys.date] == nil
            {
                debug(.watchManager, "📱 Received bolus request from watch: \(bolusAmount)U")
                self.handleBolusRequest(Decimal(bolusAmount))
            } else if let carbsAmount = message[WatchMessageKeys.carbs] as? Int,
                      let timestamp = message[WatchMessageKeys.date] as? TimeInterval,
                      message[WatchMessageKeys.bolus] == nil
            {
                let date = Date(timeIntervalSince1970: timestamp)
                debug(.watchManager, "📱 Received carbs request from watch: \(carbsAmount)g at \(date)")
                self.handleCarbsRequest(carbsAmount, date)
            } else if let bolusAmount = message[WatchMessageKeys.bolus] as? Double,
                      let carbsAmount = message[WatchMessageKeys.carbs] as? Int,
                      let timestamp = message[WatchMessageKeys.date] as? TimeInterval
            {
                let date = Date(timeIntervalSince1970: timestamp)
                debug(
                    .watchManager,
                    "📱 Received meal bolus combo request from watch: \(bolusAmount)U, \(carbsAmount)g at \(date)"
                )
                self.handleCombinedRequest(bolusAmount: Decimal(bolusAmount), carbsAmount: Decimal(carbsAmount), date: date)
            } else if message[WatchMessageKeys.cancelOverride] == nil,
                      message[WatchMessageKeys.activateOverride] == nil,
                      message[WatchMessageKeys.cancelTempTarget] == nil,
                      message[WatchMessageKeys.activateTempTarget] == nil,
                      message[WatchMessageKeys.requestBolusRecommendation] == nil
            {
                debug(.watchManager, "📱 Invalid or incomplete data received from watch. Received:  \(message)")
                // Acknowledge failure
                self.sendAcknowledgment(
                    toWatch: false,
                    message: "Error! Invalid or incomplete data received from watch.",
                    ackCode: .genericFailure
                )
            }

            if message[WatchMessageKeys.cancelOverride] as? Bool == true {
                debug(.watchManager, "📱 Received cancel override request from watch")
                self.handleCancelOverride()
            }

            if let presetName = message[WatchMessageKeys.activateOverride] as? String {
                debug(.watchManager, "📱 Received activate override request from watch for preset: \(presetName)")
                self.handleActivateOverride(presetName)
            }

            if let presetName = message[WatchMessageKeys.activateTempTarget] as? String {
                debug(.watchManager, "📱 Received activate temp target request from watch for preset: \(presetName)")
                self.handleActivateTempTarget(presetName)
            }

            if message[WatchMessageKeys.cancelTempTarget] as? Bool == true {
                debug(.watchManager, "📱 Received cancel temp target request from watch")
                self.handleCancelTempTarget()
            }

            if message[WatchMessageKeys.requestBolusRecommendation] as? Bool == true {
                let carbs = message[WatchMessageKeys.carbs] as? Int ?? 0

                var minPredBG: Decimal = 54

                Task { [weak self] in
                    guard let self = self else { return }

                    do {
                        let context = CoreDataStack.shared.newTaskContext()
                        context.name = "requestBolusRecommendation"
                        // Fetch determination data
                        let determinationIds = try await determinationStorage.fetchLastDeterminationObjectID(
                            predicate: NSPredicate.predicateFor30MinAgoForDetermination
                        )
                        let determinationObjects: [OrefDetermination] = try await CoreDataStack.shared.getNSManagedObject(
                            with: determinationIds,
                            context: context
                        )

                        await MainActor.run {
                            minPredBG = determinationObjects.first?.minPredBGFromReason ?? 54
                        }

                    } catch let error as CoreDataError {
                        debug(.default, "Core Data error: \(error)")
                    } catch {
                        debug(.default, "Unexpected error: \(error)")
                    }

                    // Get recommendation from BolusCalculationManager
                    let result = await bolusCalculationManager.handleBolusCalculation(
                        carbs: Decimal(carbs),
                        useFattyMealCorrection: false,
                        useSuperBolus: false,
                        lastLoopDate: apsManager.lastLoopDate,
                        minPredBG: minPredBG,
                        simulatedCOB: nil,
                        isBackdated: false // we cannot backdate carbs via watch
                    )

                    // Send recommendation back to watch
                    let recommendationMessage: [String: Any] = [
                        WatchMessageKeys.recommendedBolus: NSDecimalNumber(decimal: result.insulinCalculated)
                    ]

                    if let session = self.session, session.isReachable {
                        debug(.watchManager, "📱 Sending recommendedBolus: \(result.insulinCalculated)")
                        session.sendMessage(recommendationMessage, replyHandler: nil)
                    }
                }
                return
            }
        }
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let logs = userInfo["watchLogs"] as? String {
            SimpleLogReporter.appendToWatchLog(logs)
        }

        if let snoozeMinutes = userInfo[WatchMessageKeys.snoozeDuration] as? Int {
            debug(.watchManager, "📱 Received snooze userInfo from watch: \(snoozeMinutes) minutes")
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.notificationsManager.applySnooze(for: TimeInterval(snoozeMinutes * 60))
            }
        }
    }

    #if os(iOS)
        func sessionDidBecomeInactive(_: WCSession) {}
        func sessionDidDeactivate(_ session: WCSession) {
            // The next active watch holds its own glucose history and may run another build.
            Task { @MainActor [weak self] in
                self?.resetGlucoseSync()
            }
            session.activate()
        }
    #endif

    func sessionReachabilityDidChange(_ session: WCSession) {
        debug(.watchManager, "📱 Phone reachability changed: \(session.isReachable)")

        if session.isReachable {
            // Try to send data when connection is established
            Task {
                await self.pushWatchState()
            }
        } else {
            // Try to reconnect after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.retryConnection()
            }
        }
    }

    /// Processes bolus requests received from the Watch
    /// - Parameter amount: The requested bolus amount in units
    private func handleBolusRequest(_ amount: Decimal) {
        Task {
            await apsManager.enactBolus(amount: Double(amount), isSMB: false) { success, message in
                // Acknowledge success or error of bolus
                self.sendAcknowledgment(
                    toWatch: success,
                    message: message,
                    ackCode: success == true ? .genericSuccess : .genericFailure
                )
            }
            debug(.watchManager, "📱 Enacted bolus via APS Manager: \(amount)U")
        }
    }

    /// Handles carbs entry requests received from the Watch
    /// - Parameters:
    ///   - amount: The carbs amount in grams
    ///   - date: Timestamp for the carbs entry
    private func handleCarbsRequest(_ amount: Int, _ date: Date) {
        Task {
            let context = CoreDataStack.shared.newTaskContext()

            await context.perform {
                let carbEntry = CarbEntryStored(context: context)
                carbEntry.id = UUID()
                carbEntry.carbs = Double(truncating: amount as NSNumber)
                carbEntry.date = date
                carbEntry.note = String(localized: "Via Watch", comment: "Note added to carb entry when entered via watch")
                carbEntry.isFPU = false // set this to false to ensure watch-entered carbs are displayed in main chart
                carbEntry.isUploadedToNS = false
                carbEntry.isUploadedToHealth = false
                carbEntry.isUploadedToTidepool = false

                do {
                    guard context.hasChanges else {
                        // Acknowledge failure
                        self.sendAcknowledgment(
                            toWatch: false,
                            message: "Error! Something went wrong when processing your request.",
                            ackCode: .genericFailure
                        )
                        return
                    }
                    try context.save()
                    debug(.watchManager, "📱 Saved carbs from watch: \(amount)g at \(date)")

                    // Acknowledge success
                    self.sendAcknowledgment(
                        toWatch: true,
                        message: String(
                            localized: "Carbs logged successfully.",
                            comment: "Success message sent to watch when carbs are logged successfully"
                        ),
                        ackCode: .carbsLogged
                    )
                } catch {
                    debug(.watchManager, "❌ Error saving carbs: \(error)")

                    // Acknowledge failure
                    self.sendAcknowledgment(toWatch: false, message: "Error logging carbs", ackCode: .genericFailure)
                }
            }
        }
    }

    /// Handles combined bolus and carbs entry requests received from the Watch.
    /// - Parameters:
    ///   - bolusAmount: The bolus amount in units
    ///   - carbsAmount: The carbs amount in grams
    ///   - date: Timestamp for the carbs entry
    private func handleCombinedRequest(bolusAmount: Decimal, carbsAmount: Decimal, date: Date) {
        Task {
            let context = CoreDataStack.shared.newTaskContext()

            do {
                // Notify Watch: "Saving carbs..."
                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Saving Carbs...",
                        comment: "Successful message sent to watch when saving carbs"
                    ),
                    ackCode: .savingCarbs
                )

                // Save carbs entry in Core Data
                try await context.perform {
                    let carbEntry = CarbEntryStored(context: context)
                    carbEntry.id = UUID()
                    carbEntry.carbs = NSDecimalNumber(decimal: carbsAmount).doubleValue
                    carbEntry.date = date
                    carbEntry.note = String(localized: "Via Watch", comment: "Note added to carb entry when entered via watch")
                    carbEntry.isFPU = false // set this to false to ensure watch-entered carbs are displayed in main chart
                    carbEntry.isUploadedToNS = false
                    carbEntry.isUploadedToHealth = false
                    carbEntry.isUploadedToTidepool = false

                    guard context.hasChanges else {
                        // Acknowledge failure
                        self.sendAcknowledgment(
                            toWatch: false,
                            message: "Error! Something went wrong when processing your request.",
                            ackCode: .genericFailure
                        )
                        return
                    }
                    try context.save()
                    debug(.watchManager, "📱 Saved carbs from watch: \(carbsAmount) g at \(date)")
                }

                // Notify Watch: "Enacting bolus..."
                sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Enacting bolus...",
                        comment: "Successful message sent to watch when enacting bolus"
                    ),
                    ackCode: .enactingBolus
                )

                // Enact bolus via APS Manager
                let bolusDouble = NSDecimalNumber(decimal: bolusAmount).doubleValue
                await apsManager.enactBolus(amount: bolusDouble, isSMB: false) { success, message in
                    // Acknowledge success or error of bolus
                    self.sendAcknowledgment(
                        toWatch: success,
                        message: message,
                        ackCode: success == true ? .genericSuccess : .genericFailure
                    )
                }
                debug(.watchManager, "📱 Enacted bolus from watch via APS Manager: \(bolusDouble) U")
                // Notify Watch: "Carbs and bolus logged successfully"
                sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Carbs and Bolus logged successfully.",
                        comment: "Successful message sent to watch when logging carbs and bolus"
                    ),
                    ackCode: .comboComplete
                )

            } catch {
                debug(.watchManager, "❌ Error processing combined request: \(error)")
                sendAcknowledgment(toWatch: false, message: "Failed to log carbs and bolus", ackCode: .genericFailure)
            }
        }
    }

    private func handleCancelOverride() {
        Task {
            do {
                let outcome = try await adjustmentManager.cancelOverride(source: .watch)
                debug(.watchManager, "📱 Successfully stopped override \"\(outcome.ended.first?.name ?? "Custom Override")\"")

                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Stopped Override successfully.",
                        comment: "Stopped Override successfully"
                    ),
                    ackCode: .overrideStopped
                )
            } catch {
                debug(.watchManager, "❌ Error cancelling override: \(error)")
                self.sendAcknowledgment(
                    toWatch: false,
                    message: (error as? AdjustmentError)?.errorDescription ?? "Error stopping Override.",
                    ackCode: .genericFailure
                )
            }
        }
    }

    private func handleActivateOverride(_ presetName: String) {
        Task {
            do {
                let outcome = try await adjustmentManager.activateOverride(.presetName(presetName), source: .watch)
                debug(.watchManager, "📱 Successfully activated override: \(presetName)")
                if let ended = outcome.ended.first {
                    debug(.watchManager, "📱 Recorded run for replaced override \"\(ended.name ?? "Custom Override")\"")
                }

                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Started Override \"\(presetName)\" successfully.",
                        comment: "Start override with override name"
                    ),
                    ackCode: .overrideStarted
                )
            } catch {
                debug(.watchManager, "❌ Error activating override: \(error)")
                self.sendAcknowledgment(
                    toWatch: false,
                    message: (error as? AdjustmentError)?.errorDescription ?? "Error activating Override \"\(presetName)\".",
                    ackCode: .genericFailure
                )
            }
        }
    }

    private func handleActivateTempTarget(_ presetName: String) {
        Task {
            do {
                let outcome = try await adjustmentManager.activateTempTarget(.presetName(presetName), source: .watch)
                debug(.watchManager, "📱 Successfully activated temp target: \(presetName)")
                if let ended = outcome.ended.first {
                    debug(.watchManager, "📱 Recorded run for replaced temp target \"\(ended.name ?? "Temp Target")\"")
                }

                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Started Temp Target \"\(presetName)\" successfully.",
                        comment: "Started Temp Target successfully."
                    ),
                    ackCode: .tempTargetStarted
                )
            } catch {
                debug(.watchManager, "❌ Error activating temp target: \(error)")
                self.sendAcknowledgment(
                    toWatch: false,
                    message: (error as? AdjustmentError)?.errorDescription ?? "Error activating Temp Target \"\(presetName)\".",
                    ackCode: .genericFailure
                )
            }
        }
    }

    private func handleCancelTempTarget() {
        Task {
            do {
                let outcome = try await adjustmentManager.cancelTempTarget(source: .watch)
                debug(.watchManager, "📱 Successfully cancelled temp target \"\(outcome.ended.first?.name ?? "Temp Target")\"")

                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Stopped Temp Target successfully.",
                        comment: "Stopped Temp Target successfully."
                    ),
                    ackCode: .tempTargetStopped
                )
            } catch {
                debug(.watchManager, "❌ Error stopping temp target: \(error)")
                self.sendAcknowledgment(
                    toWatch: false,
                    message: (error as? AdjustmentError)?.errorDescription ?? "Error stopping Temp Target.",
                    ackCode: .genericFailure
                )
            }
        }
    }
}

// TODO: - is there a better approach than setting up the watch state every time a setting has changed?
extension BaseWatchManager: SettingsObserver, PumpSettingsObserver {
    // to update maxBolus
    func pumpSettingsDidChange(_: PumpSettings) {
        scheduleWatchStatePush()
    }

    // to update the rest
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
        glucoseColorScheme = settingsManager.settings.glucoseColorScheme
        lowGlucose = settingsManager.settings.low
        highGlucose = settingsManager.settings.high

        scheduleWatchStatePush()
    }
}

extension BaseWatchManager: PumpReservoirObserver, PumpDeactivatedObserver {
    func pumpReservoirDidChange(_: Decimal) {
        pushPeripheralUpdate()
    }

    /// The pump was removed, so the watch has to clear its Pump card instead of
    /// showing a reservoir and pod countdown for hardware that is no longer
    /// attached. Goes out via the standalone path, which reaches a watch that
    /// is currently out of range.
    func pumpDeactivatedDidChange() {
        // No reachability check: an unreachable watch is exactly the case the
        // `transferUserInfo` fallback in `sendPeripheralUpdate` exists for.
        guard let session = session, session.isPaired, session.isWatchAppInstalled else { return }
        Task { @MainActor in
            await self.sendPeripheralUpdate()
        }
        // Also refresh the application context, so a relaunched watch app does
        // not show the removed pump from an older snapshot.
        scheduleWatchStatePush()
    }
}

extension BaseWatchManager {
    /// Retrieves the current glucose target based on the time of day.
    private func getCurrentGlucoseTarget() async -> Decimal? {
        let now = Date()
        let calendar = Calendar.current

        let bgTargets = await fileStorage.retrieveAsync(OpenAPS.Settings.bgTargets, as: BGTargets.self)
            ?? BGTargets(from: OpenAPS.defaults(for: OpenAPS.Settings.bgTargets))
            ?? BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: [])
        let entries: [(start: String, value: Decimal)] = bgTargets.targets.map { ($0.start, $0.low) }

        for (index, entry) in entries.enumerated() {
            guard let entryTime = TherapySettingsUtil.parseTime(entry.start) else {
                debug(.default, "Invalid entry start time: \(entry.start)")
                continue
            }

            let entryComponents = calendar.dateComponents([.hour, .minute, .second], from: entryTime)
            let entryStartTime = calendar.date(
                bySettingHour: entryComponents.hour!,
                minute: entryComponents.minute!,
                second: entryComponents.second!,
                of: now
            )!

            let entryEndTime: Date
            if index < entries.count - 1,
               let nextEntryTime = TherapySettingsUtil.parseTime(entries[index + 1].start)
            {
                let nextEntryComponents = calendar.dateComponents([.hour, .minute, .second], from: nextEntryTime)
                entryEndTime = calendar.date(
                    bySettingHour: nextEntryComponents.hour!,
                    minute: nextEntryComponents.minute!,
                    second: nextEntryComponents.second!,
                    of: now
                )!
            } else {
                entryEndTime = calendar.date(byAdding: .day, value: 1, to: entryStartTime)!
            }

            if now >= entryStartTime, now < entryEndTime {
                return entry.value
            }
        }

        return nil
    }
}

extension BaseWatchManager {
    enum AcknowledgmentCode: String, Codable {
        case savingCarbs = "saving_carbs"
        case enactingBolus = "enacting_bolus"
        case comboComplete = "combo_complete"
        case carbsLogged = "carbs_logged"
        case overrideStarted = "override_started"
        case overrideStopped = "override_stopped"
        case tempTargetStarted = "temp_target_started"
        case tempTargetStopped = "temp_target_stopped"
        case genericSuccess = "success"
        case genericFailure = "failure"
    }
}
