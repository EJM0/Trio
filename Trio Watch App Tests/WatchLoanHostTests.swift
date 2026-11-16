import Foundation
import LoopKit
import Testing
@testable import Trio

final class FakeTransport: WatchLoanTransport {
    var isReachable = true
    var sent: [[String: Any]] = []
    /// The phone's epoch in answer to a status query; nil stays silent.
    var phoneEpoch: Int64?

    func send(_ payload: [String: Any]) {
        sent.append(payload)
    }

    func sendLive(_ payload: [String: Any], reply: (([String: Any]) -> Void)?) -> Bool {
        guard isReachable else { return false }
        sent.append(payload)
        if let phoneEpoch { reply?([WatchLoanWireKey.phoneEpoch: NSNumber(value: phoneEpoch)]) }
        return true
    }

    var messages: [WatchLoanMessage] {
        sent.compactMap { $0[WatchLoanWireKey.message] as? Data }.compactMap {
            if case let .message(envelope) = WatchLoanWire.decode($0) { return envelope.message }
            return nil
        }
    }

    var stops: [WatchLoanStop] {
        sent.compactMap { $0[WatchLoanWireKey.message] as? Data }.compactMap {
            if case let .stop(stop) = WatchLoanWire.decode($0) { return stop }
            return nil
        }
    }

    var batches: [WatchLoanRecordBatch] {
        sent.compactMap { $0[WatchLoanWireKey.records] as? Data }.compactMap { try? WatchLoanRecordBatch.decode($0) }
    }
}

final class FakeNotifier: WatchLoanNotifier {
    var pending: [String: (title: String, date: Date?)] = [:]
    var posted: [String] = []

    func post(id: String, title: String, body _: String, at date: Date?, timeSensitive _: Bool, category _: String?) {
        pending[id] = (title, date)
        posted.append(id)
    }

    func cancel(ids: [String]) {
        for id in ids { pending[id] = nil }
    }

    var notLooping: [Date] {
        pending.filter { $0.key.hasPrefix(WatchLoanAlerts.notLoopingPrefix) }.compactMap(\.value.date).sorted()
    }
}

final class FakeActivity: LoanBackgroundActivity {
    var isExpired = false
    private(set) var ended = false
    func end() { ended = true }
}

/// Reads main-actor state from the kit's queues, as the double needs to.
func onMain<T>(_ read: @MainActor() -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated(read) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(read) }
}

/// A loan world for the host: one pod, a pump double per manager the factory builds, a fake phone link.
@MainActor final class LoanFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loan-\(UUID().uuidString)")
    let pod = PodModel()
    let transport = FakeTransport()
    let notifier = FakeNotifier()
    var foreground = false
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var battery: Float = 1
    var model = "Watch7,1"
    var notificationsAllowed = true
    var activity = FakeActivity()
    private(set) var adopted = 0
    private(set) var restored = 0
    private(set) var doubles: [LoanPumpDouble] = []
    var configure: (LoanPumpDouble) -> Void = { _ in }
    var host: WatchLoanHost!

    var files: WatchLoanFiles { WatchLoanFiles(directory: directory) }
    var pump: LoanPumpDouble? { host.pump as? LoanPumpDouble }

    init() {
        host = makeHost()
    }

    func makeHost() -> WatchLoanHost {
        let factory = LoanPumpFactory(
            adopt: { [unowned self] _, _ in
                adopted += 1
                return newDouble()
            },
            restore: { [unowned self] raw in
                restored += 1
                let double = newDouble()
                double.isControlReleased = raw["released"] as? Bool ?? false
                // the kit keeps its own session across a relaunch
                if !double.isControlReleased, case .watch = pod.holder { pod.holder = .watch(ObjectIdentifier(double)) }
                return double
            }
        )
        let created = WatchLoanHost(env: WatchLoanEnvironment(
            files: files,
            transport: transport,
            notifier: notifier,
            pumpFactory: factory,
            cgm: nil,
            now: { [unowned self] in clock },
            isForeground: { [unowned self] in foreground },
            batteryLevel: { [unowned self] in battery },
            notificationsAllowed: { [unowned self] in notificationsAllowed },
            modelIdentifier: { [unowned self] in model },
            appBuild: "1",
            beginActivity: { [unowned self] _ in activity },
            phoneAnswerTimeout: 0.2
        ))
        return created
    }

    private func newDouble() -> LoanPumpDouble {
        let double = LoanPumpDouble(pod: pod)
        double.now = { [unowned self] in onMain { clock } }
        // End cancels the temp after `returning` is saved, before the release
        double.hostMayCommand = { [unowned self] command in
            onMain {
                if case .returning = host.state { return command.hasPrefix("temp 0.0 U/h 0 min") }
                return host.state.mayCommandPump
            }
        }
        configure(double)
        doubles.append(double)
        return double
    }

    func relaunch() async {
        host = makeHost()
        await host.relaunch()
    }

    var violations: [String] { doubles.flatMap(\.violations) }

    // MARK: Phone

    nonisolated static func orefInputs(now: Date, glucose: Int, count: Int = 36) throws -> OrefInputs {
        var preferences = Preferences()
        preferences.maxIOB = 6
        preferences.enableSMBAlways = true
        preferences.enableUAM = true
        return try OrefInputs(
            pumpSettings: JSONBridge.from(string: #"{"insulin_action_curve": 10, "maxBolus": 10, "maxBasal": 3}"#),
            bgTargets: JSONBridge.from(
                string: #"{"units": "mg/dL", "user_preferred_units": "mg/dL", "targets": [{"low": 100, "high": 100, "start": "00:00:00", "offset": 0}]}"#
            ),
            basalProfile: JSONBridge.from(string: #"[{"start": "00:00:00", "minutes": 0, "rate": 1.0}]"#),
            insulinSensitivities: JSONBridge.from(
                string: #"{"units": "mg/dL", "user_preferred_units": "mg/dL", "sensitivities": [{"sensitivity": 50, "offset": 0, "start": "00:00:00"}]}"#
            ),
            carbRatios: JSONBridge
                .from(string: #"{"units": "grams", "schedule": [{"start": "00:00:00", "offset": 0, "ratio": 10}]}"#),
            tempTargets: [],
            preferences: preferences,
            dosingMode: .closed,
            microBolusAllowed: true,
            activeTempTarget: nil,
            activeOverride: nil,
            tddHistory: [],
            hasSufficientTDD: false,
            glucose: readings(now: now, count: count, value: glucose),
            pumpHistory: [],
            carbs: [],
            currentTemp: TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now),
            supportedBasalRates: (0 ... 60).map { Decimal($0) / 20 },
            autosens: nil,
            clock: now,
            timeZone: .current
        )
    }

    nonisolated static func readings(now: Date, count: Int, value: Int, newestAgo: TimeInterval = 120) -> [BloodGlucose] {
        (0 ..< count).map { index in
            OrefInputs.bloodGlucose(
                id: nil,
                date: now.addingTimeInterval(-newestAgo - Double(index * 300)),
                glucose: Int16(value),
                smoothedGlucose: nil,
                isManual: false,
                direction: "Flat",
                shouldSmoothGlucose: false,
                roundingBehavior: NSDecimalNumberHandler(
                    roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false,
                    raiseOnUnderflow: false, raiseOnDivideByZero: false
                )
            )
        }
    }

    func snapshot(
        requestID: UUID,
        epoch: Int64,
        now: Date,
        glucose: Int,
        alarms: [GlucoseAlert],
        count: Int = 36
    ) throws -> WatchLoanSnapshot {
        let export = try PropertyListSerialization.data(
            fromPropertyList: SharedDeviceConfiguration(managerIdentifier: "Double", asOf: now, state: ["pod": 1]).rawValue,
            format: .binary,
            options: 0
        )
        return WatchLoanSnapshot(
            versions: .init(schema: 1, protocolVersion: 1, appBuild: "1", pumpManager: "Double", cgmManager: "G7"),
            requestID: requestID,
            epoch: epoch,
            expiresAt: now.addingTimeInterval(30),
            phoneTime: now,
            timeZoneIdentifier: TimeZone.current.identifier,
            oref: try Self.orefInputs(now: now, glucose: glucose, count: count),
            overrideAtGrant: nil,
            tempTargetAtGrant: nil,
            bolusCalculator: .init(
                units: .mgdL,
                fraction: 1,
                fattyMealFactor: 0.7,
                sweetMealFactor: 1,
                maxCarbs: 250,
                supportedBolusVolumes: [0.05]
            ),
            glucoseAlarms: alarms,
            glucoseAlarmConfiguration: GlucoseAlertConfiguration(),
            pumpExport: export,
            cgmExport: export,
            deliveryPulseUnits: 0.05,
            releaseReading: .init(units: 10, at: now)
        )
    }

    func payload(_ message: WatchLoanMessage, snapshot: WatchLoanSnapshot? = nil) throws -> [String: Any] {
        let envelope = WatchLoanEnvelope(protocolVersion: 1, messageID: UUID(), sentAt: clock, message: message)
        var payload: [String: Any] = [WatchLoanWireKey.message: try WatchLoanWire.encode(envelope)]
        if let snapshot { payload[WatchLoanWireKey.snapshot] = try snapshot.encoded() }
        return payload
    }

    /// Start, then the phone's grant for epoch 1: the watch holds the pump.
    func startLoan(glucose: Int = 160, alarms: [GlucoseAlert] = [], count: Int = 36) async throws {
        await host.startTapped()
        guard case let .request(requestID) = transport.messages.last?.kind else {
            Issue.record("no request sent")
            return
        }
        pod.holder = .nobody // the phone released
        let now = clock
        let grant = WatchLoanMessage(epoch: 1, kind: .grant(requestID: requestID, expiresAt: now.addingTimeInterval(30)))
        await host.receive(try payload(
            grant,
            snapshot: snapshot(requestID: requestID, epoch: 1, now: now, glucose: glucose, alarms: alarms, count: count)
        ))
    }

    /// Five minutes later, a reading 10 s old.
    func reading(_ value: Int, after minutes: Double = 5) async {
        clock = clock.addingTimeInterval(minutes * 60)
        await host.receiveReadings(Self.readings(now: clock, count: 1, value: value, newestAgo: 10))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Watch loan host", .serialized) @MainActor struct WatchLoanHostTests {
    @Test("Start, adopt, loop on readings with a pump double that never sees a command while not owner") func simulatorLoop() async throws {
        let world = LoanFixture()
        try await world.startLoan()
        #expect(world.host.state == .holding(epoch: 1))
        #expect(world.adopted == 1)
        #expect(world.pump?.takeControlCalls == 1)
        #expect(world.pump?.heartbeatRequests == [nil] && world.pump?.mustProvideHeartbeat == [false])
        #expect(world.transport.messages.last?.kind == .holding)
        #expect(world.notifier.notLooping.count == 6)
        #expect(world.host.awaitingFirstReading && !world.host.isInControl)

        await world.reading(160)
        #expect(!world.host.awaitingFirstReading && world.host.isInControl)
        let commands = try #require(world.pump?.commands)
        #expect(commands.contains { $0.hasPrefix("temp") })
        #expect(!commands.contains { $0.contains("SMB") }, "a background wake runs oref without micro boluses")
        #expect(world.host.intent == nil)
        #expect(world.host.loop.lastConfirmedCycleAt != nil)
        #expect(world.transport.batches.last?.epoch == 1)
        #expect(world.activity.ended)

        // the phone takes the pump back: the revoke stops the watch, and nothing reaches the pod afterwards
        await world.host.receive([WatchLoanWireKey.message: try WatchLoanWire.encode(WatchLoanStop(kind: .revoke, epoch: 2))])
        #expect(world.host.state == .stopped(epoch: 1, reason: .superseded))
        #expect(world.pump?.isControlReleased == true)
        #expect(world.transport.stops.contains { $0.kind == .stop && $0.epoch == 1 && $0.released })
        let count = world.pump?.commands.count
        await world.reading(150)
        #expect(world.pump?.commands.count == count)
        #expect(world.violations.isEmpty, "\(world.violations)")
    }

    @Test("Micro boluses only in the foreground") func microBolusForeground() async throws {
        let world = LoanFixture()
        world.foreground = true
        try await world.startLoan(glucose: 180)
        await world.reading(185)
        let commands = try #require(world.pump?.commands)
        #expect(commands.contains { $0.contains("SMB") }, "\(commands)")
        #expect(world.violations.isEmpty)
    }

    @Test("A refused adopt is a foreign pod session: stopped, released, never a failed take") func refusedAdopt() async throws {
        let world = LoanFixture()
        await world.host.startTapped()
        guard case let .request(requestID) = world.transport.messages.last?.kind else {
            Issue.record("no request")
            return
        }
        // the phone took the pod back before the watch's adopt reached it
        world.pod.holder = .phone
        world.pod.phoneTookOver = true
        let now = world.clock
        let grant = WatchLoanMessage(epoch: 1, kind: .grant(requestID: requestID, expiresAt: now.addingTimeInterval(30)))
        await world.host.receive(try world.payload(grant, snapshot: world.snapshot(
            requestID: requestID,
            epoch: 1,
            now: now,
            glucose: 120,
            alarms: []
        )))
        try await Task.sleep(nanoseconds: 300_000_000)
        await world.host.serially {}
        #expect(world.host.state == .stopped(epoch: 1, reason: .foreignSession))
        #expect(world.pump?.releaseCalls == 1)
        #expect(world.transport.stops.contains { $0.kind == .stop && $0.epoch == 1 })
        #expect(world.notifier.notLooping.count == 6, "a stopped watch keeps its not-looping series")
        #expect(world.violations.isEmpty)
    }

    @Test("Relaunch while the kit holds the pod: no take, no adopt (W26)") func relaunchKitHolds() async throws {
        let world = LoanFixture()
        try await world.startLoan()
        await world.reading(160)
        // the phone is out of reach: a kit that holds the pod resumes without asking it
        world.transport.phoneEpoch = nil
        await world.relaunch()
        #expect(world.host.state == .holding(epoch: 1))
        #expect(world.restored == 1 && world.adopted == 1)
        #expect(world.pump?.takeControlCalls == 0)
        #expect(world.doubles.allSatisfy { $0.heartbeatRequests.allSatisfy { $0 == nil } }, "the pump heartbeat stays off")
        await world.reading(150)
        #expect(world.pump?.commands.isEmpty == false)
        #expect(world.violations.isEmpty)
    }

    @Test("Relaunch before the adopt: adopt only when the phone confirms the epoch (W36, W37)") func relaunchBeforeAdopt() async throws {
        for phoneEpoch in [Int64(1), nil] {
            let world = LoanFixture()
            try await world.startLoan()
            // a crash right after `holding` was saved: the kit's state never reached disk
            try FileManager.default.removeItem(at: world.files.url(.pumpState))
            world.pod.holder = .nobody
            world.transport.phoneEpoch = phoneEpoch
            await world.relaunch()
            if phoneEpoch == 1 {
                #expect(world.host.state == .holding(epoch: 1))
                #expect(world.adopted == 2)
            } else {
                #expect(world.host.state == .stopped(epoch: 1, reason: .unconfirmed))
                #expect(world.adopted == 1)
                #expect(world.doubles.last?.takeControlCalls == 1, "no take after the relaunch")
            }
            #expect(world.violations.isEmpty)
        }
    }

    @Test("Relaunch when the phone is ahead stops the watch (W27)") func relaunchSuperseded() async throws {
        let world = LoanFixture()
        try await world.startLoan()
        world.transport.phoneEpoch = 3
        await world.relaunch()
        #expect(world.host.state == .stopped(epoch: 1, reason: .superseded))
        #expect(world.pump?.takeControlCalls == 0)
        #expect(world.pump?.isControlReleased == true)
    }

    @Test("The phone took the pod while the watch slept: its next cycle sends nothing and stops") func foreignSessionInCycle() async throws {
        let world = LoanFixture()
        try await world.startLoan()
        await world.reading(160)
        let before = world.pump?.commands.count
        world.pod.holder = .phone
        await world.reading(150)
        try await Task.sleep(nanoseconds: 200_000_000)
        await world.host.serially {}
        #expect(world.host.state == .stopped(epoch: 1, reason: .foreignSession))
        #expect(world.pump?.commands.count == before)
        #expect(world.violations.isEmpty)
    }

    @Test("Cycle guards: stale pump status or too few readings enact nothing and don't move the series") func cycleGuards() async throws {
        let world = LoanFixture()
        try await world.startLoan()
        let series = world.notifier.notLooping
        world.pump?.statusIsFresh = false
        world.pump?.lastSync = Date().addingTimeInterval(-600)
        await world.reading(160)
        #expect(world.pump?.commands.isEmpty == true)
        #expect(world.notifier.notLooping == series)

        world.pump?.statusIsFresh = true
        world.pump?.basalDeliveryState = .suspended(Date())
        await world.reading(160)
        #expect(world.pump?.commands.isEmpty == true, "nothing while the pump is suspended")
    }

    @Test("Too few readings in the last hour enact nothing") func glucoseGuard() async throws {
        let world = LoanFixture()
        try await world.startLoan(count: 1)
        await world.reading(160)
        #expect(world.pump?.commands.isEmpty == true, "two readings in the last hour")
        await world.reading(160)
        #expect(world.pump?.commands.isEmpty == false, "three readings in the last hour")
    }

    @Test("A failed intent write sends no command and alerts") func intentWriteFails() async throws {
        let world = LoanFixture()
        try await world.startLoan()
        try FileManager.default.createDirectory(at: world.files.url(.intent), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: world.files.url(.intent).appendingPathComponent("blocker"),
            withIntermediateDirectories: true
        )
        await world.reading(160)
        #expect(world.pump?.commands.isEmpty == true)
        #expect(world.notifier.posted.contains("trio.loan.notSaved"))
    }

    @Test("An expired wake starts no command and leaves no intent") func expiredWake() async throws {
        let world = LoanFixture()
        try await world.startLoan()
        world.activity.isExpired = true
        await world.reading(160)
        #expect(world.pump?.commands.isEmpty == true)
        #expect(world.host.intent == nil)
        #expect(try world.files.read(.intent) == nil)
    }

    @Test(
        "An unconfirmed bolus is never retried, holds insulin back, and is booked as delivered once settled"
    ) func unresolvedIntent() async throws {
        let world = LoanFixture()
        try await world.startLoan(glucose: 120)
        await world.reading(120)
        world.pump?.commandError = .communication(nil)
        world.pump?.makesDeliveryUncertainOnError = true
        await world.host.requestBolus(units: 1)
        #expect(world.host.bolus == .uncertain)
        let intent = try #require(world.host.intent)
        #expect(try world.files.load(WatchDoseIntent.self, from: .intent) == intent)

        // still uncertain: no command that adds insulin
        let before = world.pump?.commands.count ?? 0
        await world.reading(220)
        let after = Array(world.pump?.commands.dropFirst(before) ?? [])
        #expect(!after.contains { $0.hasPrefix("bolus") })

        // the kit settles without a record of the dose: booked as delivered, counted as booked in the next batch
        world.pump?.deliveryIsUncertain = false
        world.pump?.commandError = nil
        world.pod.delivered += 1
        await world.host.runCycle(trigger: .user)
        #expect(world.host.intent == nil)
        let booked = world.host.records.snapshot.pumpEvents.values.filter(\.bookedIntent)
        #expect(booked.count == 1 && booked.first?.record.dose.deliveredUnits == 1)
        #expect(world.notifier.posted.contains("trio.loan.bookedIntent"))
        #expect(world.transport.batches.last?.pumpEvents.contains { $0.raw == booked.first?.record.raw } == true)
        #expect(world.violations.isEmpty)
    }

    @Test("Not-looping series: armed at holding, moved only by a confirmed cycle, removed at hand-back") func deadMan() async throws {
        let world = LoanFixture()
        let start = world.clock
        try await world.startLoan()
        let armed = world.notifier.notLooping
        #expect(armed.count == 6)
        #expect(abs(armed[0].timeIntervalSince(start) - 20 * 60) < 5)
        #expect(abs(armed[5].timeIntervalSince(start) - 120 * 60) < 5)

        await world.reading(160)
        let moved = world.notifier.notLooping
        #expect(moved[0] > armed[0])

        await world.host.endTapped()
        #expect(world.host.state == .returning(epoch: 1))
        #expect(world.transport.messages.last?.kind == .handBack)
        await world.host.receive(try world.payload(WatchLoanMessage(epoch: 1, kind: .handBackAck)))
        #expect(world.host.state == .idle(epoch: 1))
        #expect(world.notifier.notLooping.isEmpty)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(world.host.pump == nil)
        #expect(try world.files.read(.pumpState) == nil)
        #expect(world.violations.isEmpty)
    }

    @Test("Glucose alarms use the grant's list: fire on a low reading, retract on recovery") func glucoseAlarms() async throws {
        var low = GlucoseAlert(type: .low)
        low.thresholdMgDL = 70
        let world = LoanFixture()
        try await world.startLoan(glucose: 100, alarms: [low])
        let id = WatchLoanAlerts.glucosePrefix + low.id.uuidString
        await world.reading(62)
        #expect(world.notifier.pending[id] != nil)
        await world.reading(80)
        #expect(world.notifier.pending[id] == nil)
    }

    @Test("Bolus states: refused over max bolus, then requested to done") func bolusFlow() async throws {
        let world = LoanFixture()
        try await world.startLoan(glucose: 120)
        await world.reading(120)
        await world.host.requestBolus(units: 11)
        guard case .failed = world.host.bolus else {
            Issue.record("over max bolus not refused: \(world.host.bolus)")
            return
        }
        #expect(world.pump?.commands.contains { $0.hasPrefix("bolus 11") } == false)

        await world.host.requestBolus(units: 0.5, carbs: 10)
        #expect(world.host.bolus == .done)
        #expect(world.pump?.commands.contains("bolus 0.5 U") == true)
        #expect(world.host.records.snapshot.carbs.first?.carbs == 10)
        #expect(world.violations.isEmpty)
    }

    @Test("Suspend and resume, cancel the override and the temp target") func watchControls() async throws {
        let world = LoanFixture()
        try await world.startLoan()
        await world.host.suspendInsulin()
        #expect(world.pump?.commands.last == "suspend")
        await world.host.resumeInsulin()
        #expect(world.pump?.commands.contains("resume") == true)
        await world.host.cancelOverride()
        await world.host.cancelTempTarget()
        #expect(world.host.records.snapshot.overrideCancelledAt != nil)
        #expect(world.host.records.snapshot.tempTargetCancelledAt != nil)
        #expect(world.violations.isEmpty)
    }

    @Test("Start is refused on an older watch or without time-sensitive notifications") func startRefusals() async throws {
        let world = LoanFixture()
        world.model = "Watch5,9"
        await world.host.startTapped()
        #expect(world.host.state == .idle(epoch: 0))
        #expect(world.transport.messages.isEmpty)
        world.model = "Watch6,10"
        world.notificationsAllowed = false
        await world.host.startTapped()
        #expect(world.host.state == .idle(epoch: 0))
        world.notificationsAllowed = true
        world.battery = 0.25
        await world.host.startTapped()
        #expect(world.host.state == .idle(epoch: 0))
        world.battery = 0.9
        await world.host.startTapped()
        guard case .requesting = world.host.state else {
            Issue.record("a supported watch with alerts allowed starts")
            return
        }
    }

    @Test("A daily summary counts readings, cycles and wakes, and starts over each day") func dailySummary() async throws {
        let world = LoanFixture()
        try await world.startLoan()
        world.host.noteWake("WKBluetoothAlertRefreshBackgroundTask")
        await world.reading(160)
        await world.reading(160)
        var summary = world.host.cycleInfo.summary
        #expect(summary.readings == 2 && summary.cycles == 2 && summary.confirmed == 2)
        #expect(summary.wakes["WKBluetoothAlertRefreshBackgroundTask"] == 1)
        #expect(WatchLoanHost.summaryLine(summary, until: world.clock, battery: 1).contains("readings 2"))
        world.clock = world.clock.addingTimeInterval(24 * 3600)
        world.host.noteWake("WKApplicationRefreshBackgroundTask")
        summary = world.host.cycleInfo.summary
        #expect(summary.readings == 0 && summary.wakes == ["WKApplicationRefreshBackgroundTask": 1])
    }

    @Test("Duplicate messages are dropped by their persisted id, across a relaunch") func dedupe() async throws {
        let world = LoanFixture()
        let query = try world.payload(WatchLoanMessage(epoch: 0, kind: .statusQuery))
        await world.host.receive(query)
        await world.host.receive(query)
        await world.relaunch()
        await world.host.receive(query)
        #expect(world.transport.messages.filter { if case .status = $0.kind { true } else { false } }.count == 1)
    }
}

/// Fixed-width integers on the watch path: arm64_32 watches have a 32-bit `Int`.
@Suite("Watch loan integer widths") struct WatchLoanIntegerWidthTests {
    @Test("Epochs, timestamps and counters above 2^31 survive their codecs") func wideValues() throws {
        let epoch = Int64(1) << 40
        let state = WatchLoanState.stopped(epoch: epoch, reason: .unconfirmed)
        #expect(try JSONDecoder().decode(WatchLoanState.self, from: JSONEncoder().encode(state)) == state)

        let intent = WatchDoseIntent(
            id: UUID(),
            kind: .bolus(units: 1, automatic: false),
            createdAt: Date(),
            epoch: epoch,
            addsInsulin: true,
            deliveredBefore: 3_000_000_000
        )
        #expect(try JSONDecoder().decode(WatchDoseIntent.self, from: JSONEncoder().encode(intent)) == intent)

        let reading = LoanFixture.readings(now: Date(timeIntervalSince1970: 4_000_000_000), count: 1, value: 100)[0]
        #expect(reading.date > Decimal(Int64(Int32.max)))
        let decoded = try JSONDecoder().decode(BloodGlucose.self, from: JSONEncoder().encode(reading))
        #expect(decoded.date == reading.date)
    }

    @Test("Stored integers in the watch's loan types are Int64 or small counts") func storedWidths() {
        // Mirror sees the stored properties; any plain Int must be a small count, never a time, epoch or id
        let allowed: Set<String> = [
            "batteryNotice",
            "podContactFailures",
            "minutes",
            "readings",
            "cycles",
            "confirmed",
            "budgetErrors"
        ]
        let samples: [Any] = [
            WatchLoanCycleInfo(),
            WatchLoanCycleInfo.DailySummary(),
            WatchDoseIntent(id: UUID(), kind: .suspend, createdAt: Date(), epoch: 1, addsInsulin: false, deliveredBefore: nil),
            WatchLoanRecordStore.Contents(),
            WatchLoopRecords()
        ]
        for sample in samples {
            let narrow: [Any.Type] = [Int.self, Int?.self, UInt.self, Int32.self, Int32?.self]
            for child in Mirror(reflecting: sample).children where narrow.contains(where: { $0 == type(of: child.value) }) {
                #expect(allowed.contains(child.label ?? ""), "\(type(of: sample)).\(child.label ?? "?") is a plain Int")
            }
            for child in Mirror(reflecting: sample).children where child.label == "epoch" {
                #expect(child.value is Int64)
            }
        }
    }
}
