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
    var bodies: [String: String] = [:]

    func post(id: String, title: String, body: String, at date: Date?, timeSensitive _: Bool, category _: String?) {
        pending[id] = (title, date)
        posted.append(id)
        bodies[id] = body
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
    var requestTimeout = WatchLoan.watchRequestTimeout
    var handBackResend: TimeInterval = 60
    var adoptTimeout: TimeInterval = 60
    var tempTargetPresets: [WatchLoanSnapshot.TempTargetPreset] = []
    var overridePresets: [WatchLoanSnapshot.OverridePreset] = []
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
            adopt: { [weak self] _, _ in
                guard let self else { return nil }
                adopted += 1
                return newDouble()
            },
            restore: { [weak self] raw in
                guard let self else { return nil }
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
            now: { [weak self] in self?.clock ?? Date() },
            isForeground: { [weak self] in self?.foreground ?? false },
            batteryLevel: { [weak self] in self?.battery },
            notificationsAllowed: { [weak self] in self?.notificationsAllowed ?? false },
            modelIdentifier: { [weak self] in self?.model },
            appBuild: "1",
            beginActivity: { [weak self] _ in self?.activity ?? FakeActivity() },
            adoptTimeout: adoptTimeout,
            requestTimeout: requestTimeout,
            handBackResendInterval: handBackResend,
            phoneAnswerTimeout: 0.2,
            grantPartsWait: 0.3
        ))
        return created
    }

    private func newDouble() -> LoanPumpDouble {
        let double = LoanPumpDouble(pod: pod)
        double.now = { [weak self] in onMain { self?.clock ?? Date() } }
        // End cancels the temp after `returning` is saved, before the release
        double.hostMayCommand = { [weak self] command in
            onMain {
                guard let state = self?.host?.state else { return false }
                if case .returning = state { return command.hasPrefix("temp 0.0 U/h 0 min") }
                return state.mayCommandPump
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
        count: Int = 36,
        dosingMode: DosingMode = .closed
    ) throws -> WatchLoanSnapshot {
        let export = try PropertyListSerialization.data(
            fromPropertyList: SharedDeviceConfiguration(managerIdentifier: "Double", asOf: now, state: ["pod": 1]).rawValue,
            format: .binary,
            options: 0
        )
        var oref = try Self.orefInputs(now: now, glucose: glucose, count: count)
        oref.dosingMode = dosingMode
        var snapshot = WatchLoanSnapshot(
            versions: .init(schema: 1, protocolVersion: 1, appBuild: "1", pumpManager: "Double", cgmManager: "G7"),
            requestID: requestID,
            epoch: epoch,
            expiresAt: now.addingTimeInterval(30),
            phoneTime: now,
            timeZoneIdentifier: TimeZone.current.identifier,
            oref: oref,
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
        snapshot.tempTargetPresets = tempTargetPresets
        snapshot.overridePresets = overridePresets
        return snapshot
    }

    func payload(_ message: WatchLoanMessage, snapshot: WatchLoanSnapshot? = nil) throws -> [String: Any] {
        let envelope = WatchLoanEnvelope(protocolVersion: 1, messageID: UUID(), sentAt: clock, message: message)
        var payload: [String: Any] = [WatchLoanWireKey.message: try WatchLoanWire.encode(envelope)]
        if let snapshot { payload[WatchLoanWireKey.snapshot] = try snapshot.encoded() }
        return payload
    }

    func partPayloads(_ message: WatchLoanMessage, snapshot data: Data, requestID: UUID, epoch: Int64) throws
        -> [[String: Any]]
    {
        let envelope = WatchLoanEnvelope(protocolVersion: 1, messageID: UUID(), sentAt: clock, message: message)
        let messageData = try WatchLoanWire.encode(envelope)
        let pieces = WatchLoanSnapshot.split(data, requestID: requestID, epoch: epoch)
        return try pieces.enumerated().map { offset, piece in
            var payload: [String: Any] = [
                WatchLoanWireKey.snapshotPartHeader: try JSONEncoder().encode(piece.header),
                WatchLoanWireKey.snapshotPart: piece.bytes
            ]
            if offset == pieces.count - 1 { payload[WatchLoanWireKey.message] = messageData }
            return payload
        }
    }

    /// Start, then the phone's grant for epoch 1: the watch holds the pump.
    func startLoan(
        glucose: Int = 160,
        alarms: [GlucoseAlert] = [],
        count: Int = 36,
        dosingMode: DosingMode = .closed
    ) async throws {
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
            snapshot: snapshot(
                requestID: requestID,
                epoch: 1,
                now: now,
                glucose: glucose,
                alarms: alarms,
                count: count,
                dosingMode: dosingMode
            )
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
        #expect(world.notifier.notLooping.count == 10)
        #expect(world.host.awaitingFirstReading && !world.host.isInControl)

        await world.reading(160)
        #expect(!world.host.awaitingFirstReading && world.host.isInControl)
        let commands = try #require(world.pump?.commands)
        #expect(commands.contains { $0.hasPrefix("temp") })
        #expect(!commands.contains { $0.contains("SMB") }, "a background wake runs oref without micro boluses")
        #expect(world.host.intents.isEmpty)
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

    private func splitGrant(_ world: LoanFixture) async throws -> (grant: WatchLoanMessage, payloads: [[String: Any]])? {
        await world.host.startTapped()
        guard case let .request(requestID) = world.transport.messages.last?.kind else {
            Issue.record("no request sent")
            return nil
        }
        world.pod.holder = .nobody
        let now = world.clock
        var snapshot = try world.snapshot(requestID: requestID, epoch: 1, now: now, glucose: 160, alarms: [])
        // random ids don't compress, so the snapshot needs more than one piece
        snapshot.smoothingWindow = (0 ..< 5000).map { index in
            WatchLoanSnapshot.RawReading(id: UUID(), date: now.addingTimeInterval(-Double(index) * 17), glucose: 100)
        }
        let data = try snapshot.encoded()
        #expect(data.count > WatchLoanSnapshot.partBytes)
        let grant = WatchLoanMessage(epoch: 1, kind: .grant(requestID: requestID, expiresAt: now.addingTimeInterval(30)))
        let payloads = try world.partPayloads(grant, snapshot: data, requestID: requestID, epoch: 1)
        #expect(payloads.count >= 2)
        return (grant, payloads)
    }

    @Test("A grant in pieces is adopted once every piece arrived, also when the grant comes first") func grantInParts(
    ) async throws {
        for grantFirst in [false, true] {
            let world = LoanFixture()
            let (_, payloads) = try #require(try await splitGrant(world))
            if grantFirst {
                let last = try #require(payloads.last)
                let grantDone = Task { @MainActor in await world.host.receive(last) }
                try await Task.sleep(nanoseconds: 50_000_000)
                for payload in payloads.dropLast() { await world.host.receive(payload) }
                _ = await grantDone.value
            } else {
                for payload in payloads { await world.host.receive(payload) }
            }
            #expect(world.host.state == .holding(epoch: 1), "grant first: \(grantFirst)")
            #expect(world.adopted == 1)
            #expect(world.host.snapshot?.smoothingWindow.count == 5000)
        }
    }

    @Test(
        "A grant missing a piece, or with a corrupted one, is rejected as incomplete; nothing is adopted"
    ) func grantInPartsIncomplete() async throws {
        for corrupt in [false, true] {
            let world = LoanFixture()
            let (_, payloads) = try #require(try await splitGrant(world))
            if corrupt {
                var first = payloads[0]
                var bytes = try #require(first[WatchLoanWireKey.snapshotPart] as? Data)
                bytes[bytes.startIndex] ^= 0xFF
                first[WatchLoanWireKey.snapshotPart] = bytes
                await world.host.receive(first)
                for payload in payloads.dropFirst() { await world.host.receive(payload) }
            } else {
                for payload in payloads.dropFirst() { await world.host.receive(payload) }
            }
            #expect(world.host.state == .idle(epoch: 0), "corrupt: \(corrupt)")
            #expect(world.adopted == 0)
            guard case let .grantRejected(_, reason) = world.transport.messages.last?.kind else {
                Issue.record("no rejection sent, corrupt: \(corrupt)")
                continue
            }
            #expect(reason == .snapshotIncomplete)
        }
    }

    @Test("A new loan doesn't show the previous loan's last loop or values") func newLoanStartsBlank() async throws {
        let world = LoanFixture()
        world.host.loop.lastConfirmedCycleAt = world.clock.addingTimeInterval(-3 * 3600)
        world.host.loop.lastCycleAt = world.clock.addingTimeInterval(-3 * 3600)
        world.host.loop.iob = 2
        try await world.startLoan()
        #expect(world.host.loop == WatchLoanHost.LoopStatus())
        #expect(world.host.uiStatus().lastLoopAt == nil)
    }

    @Test("A pump that answered and then dropped its idle link is not reported unreachable") func idleLinkAfterAnswer() async throws {
        for answered in [true, false] {
            let world = LoanFixture()
            world.adoptTimeout = 0.2
            world.host = world.makeHost()
            try await world.startLoan()
            let pump = try #require(world.pump)
            if answered { world.host.pumpControlBecameReady(pump) }
            pump.linkUp = false
            try await Task.sleep(nanoseconds: 500_000_000)
            #expect((world.host.lastAlert == .podUnreachable) == !answered, "answered: \(answered)")
        }
    }

    @Test("A grant that isn't Closed Loop is rejected: no adopt, nothing reaches the pump") func grantNotClosedLoop() async throws {
        for mode in [DosingMode.open, .lowGlucoseSuspend, .basalTesting] {
            let world = LoanFixture()
            try await world.startLoan(dosingMode: mode)
            #expect(world.host.state == .idle(epoch: 0), "\(mode)")
            #expect(world.adopted == 0)
            guard case let .grantRejected(_, reason) = world.transport.messages.last?.kind else {
                Issue.record("no rejection sent for \(mode)")
                continue
            }
            #expect(reason == .notClosedLoop)
            await world.reading(180)
            #expect(world.doubles.allSatisfy { $0.commands.isEmpty }, "\(mode)")
            #expect(world.violations.isEmpty)
        }
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
        #expect(world.notifier.notLooping.count == 10, "a stopped watch keeps its not-looping series")
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

    @Test(
        "A held loan whose snapshot isn't Closed Loop: Open Loop sends nothing, the others never add insulin"
    ) func cycleDosingMode() async throws {
        for mode in [DosingMode.open, .lowGlucoseSuspend, .basalTesting] {
            let world = LoanFixture()
            world.foreground = true
            try await world.startLoan(glucose: 180)
            // the grant refuses these modes, so the saved snapshot is the only way in
            var saved = try #require(world.host.snapshot)
            saved.oref.dosingMode = mode
            let data = try saved.encoded()
            let files = world.files
            try await WatchLoanFiles.io { try files.write(data, to: .snapshot) }
            world.transport.phoneEpoch = nil
            await world.relaunch()
            #expect(world.host.state == .holding(epoch: 1))
            await world.reading(185)
            await world.reading(190)
            let commands = world.pump?.commands ?? []
            if mode == .open {
                #expect(commands.isEmpty, "\(commands)")
            } else {
                #expect(!commands.contains { $0.hasPrefix("bolus") }, "\(mode): \(commands)")
                let rates = commands.filter { $0.hasPrefix("temp") }
                    .compactMap { Decimal(string: String($0.dropFirst(5).prefix { $0 != " " })) }
                #expect(rates.allSatisfy { $0 <= 1 }, "\(mode): \(commands)")
            }
            #expect(world.violations.isEmpty)
        }
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
        #expect(world.host.intents.isEmpty)
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
        let intent = try #require(world.host.intents.first)
        #expect(try world.files.load([WatchDoseIntent].self, from: .intent) == [intent])

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
        #expect(world.host.intents.isEmpty)
        let booked = world.host.records.snapshot.pumpEvents.values.filter(\.bookedIntent)
        #expect(booked.count == 1 && booked.first?.record.dose.deliveredUnits == 1)
        #expect(world.notifier.posted.contains("trio.loan.bookedIntent"))
        #expect(world.transport.batches.last?.pumpEvents.contains { $0.raw == booked.first?.record.raw } == true)
        #expect(world.violations.isEmpty)
    }

    @Test("Each command adds its own intent: a pending bolus survives a reduction, a suspend and a relaunch") func intentList(
    ) async throws {
        let world = LoanFixture()
        try await world.startLoan(glucose: 100)
        await world.reading(100)
        world.pump?.commandError = .communication(nil)
        world.pump?.makesDeliveryUncertainOnError = true
        await world.host.requestBolus(units: 1)
        #expect(world.host.intents.count == 1)

        // falling glucose: the reduction still goes out, and adds its own intent when it isn't confirmed either
        await world.reading(70)
        await world.reading(55)
        #expect(world.pump?.commands.contains { $0.hasPrefix("temp 0.0") } == true)
        await world.host.suspendInsulin()
        let kinds = world.host.intents.map(\.kind)
        #expect(kinds.first == .bolus(units: 1, automatic: false))
        #expect(kinds.contains(.suspend) && kinds.contains { if case .tempBasal = $0 { true } else { false } })
        #expect(try world.files.load([WatchDoseIntent].self, from: .intent)?.count == kinds.count)

        // a relaunch keeps all of them; once the kit is certain the bolus is booked and the reductions settle
        world.transport.phoneEpoch = 1
        await world.relaunch()
        #expect(world.host.intents.map(\.kind) == kinds)
        world.pump?.deliveryIsUncertain = false
        world.pump?.commandError = nil
        world.pod.delivered += 1
        await world.host.runCycle(trigger: .user)
        #expect(world.host.intents.isEmpty)
        let booked = world.host.records.snapshot.pumpEvents.values.filter(\.bookedIntent)
        #expect(booked.map(\.record.dose.type) == [.bolus])
        #expect(world.violations.isEmpty)
    }

    @Test("A recovered bolus is booked once, whether the kit's record comes before or after the booking", arguments: [
        true,
        false
    ]) func recoveredBolus(kitFirst: Bool) async throws {
        let world = LoanFixture()
        try await world.startLoan(glucose: 120)
        await world.reading(120)
        world.pump?.commandError = .communication(nil)
        world.pump?.makesDeliveryUncertainOnError = true
        await world.host.requestBolus(units: 1)
        let intent = try #require(world.host.intents.first)
        world.pump?.commandError = nil
        let dose = DoseEntry(
            type: .bolus,
            startDate: intent.createdAt.addingTimeInterval(2),
            endDate: intent.createdAt.addingTimeInterval(42),
            value: 1,
            unit: .units,
            decisionId: nil,
            deliveredUnits: 1,
            automatic: false
        )
        world.pod.delivered += 1
        if kitFirst {
            // the kit recovers the dose at the status read and reports it on its queue, after the read returns
            world.pump?.recoverOnStatus = dose
            await world.host.runCycle(trigger: .user)
        } else {
            world.pump?.deliveryIsUncertain = false
            await world.host.runCycle(trigger: .user)
            #expect(world.host.records.snapshot.pumpEvents.values.contains { $0.bookedIntent })
            world.pump?.reportLater(dose)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(world.host.intents.isEmpty)
        let boluses = world.host.records.snapshot.pumpEvents.values.filter { $0.record.dose.type == .bolus }
        #expect(boluses.count == 1, "\(boluses.map(\.record.dose.programmedUnits))")
        #expect(boluses.first?.bookedIntent == false)
    }

    @Test("Resume goes out while a bolus is unconfirmed; another bolus doesn't") func resumeWhilePending() async throws {
        let world = LoanFixture()
        try await world.startLoan(glucose: 120)
        await world.reading(120)
        world.pump?.commandError = .communication(nil)
        world.pump?.makesDeliveryUncertainOnError = true
        await world.host.requestBolus(units: 1)
        #expect(world.host.intents.count == 1)
        world.pump?.commandError = nil
        await world.host.suspendInsulin()
        await world.host.resumeInsulin()
        let commands = world.pump?.commands ?? []
        #expect((commands.lastIndex(of: "suspend") ?? .max) < (commands.lastIndex(of: "resume") ?? -1))
        #expect(world.host.intents.count == 1, "the bolus intent stays; suspend and resume settled")
        let outcome = await world.host.command(.bolus(units: 0.5, automatic: false))
        #expect(outcome == .notSent)
    }

    @Test("A stopped watch keeps reading the sensor and keeps its glucose alarms, unless superseded") func stoppedAlarms() async throws {
        var low = GlucoseAlert(type: .low)
        low.thresholdMgDL = 70
        let world = LoanFixture()
        try await world.startLoan(glucose: 100, alarms: [low])
        await world.reading(100)
        world.pod.holder = .phone
        await world.reading(95)
        try await Task.sleep(nanoseconds: 200_000_000)
        await world.host.serially {}
        #expect(world.host.state == .stopped(epoch: 1, reason: .foreignSession))
        let commands = world.pump?.commands.count
        await world.reading(62)
        #expect(world.notifier.pending[WatchLoanAlerts.glucosePrefix + low.id.uuidString] != nil)
        #expect(world.pump?.commands.count == commands, "alarms only, no commands")
    }

    @Test("Sensor and pod alerts show on the watch with the iPhone line, at the kit's time; none once superseded") func kitAlerts(
    ) async throws {
        func alert(_ name: String, manager: String, trigger: Alert.Trigger) -> Alert {
            let content = Alert.Content(title: name, body: "Kit text.", acknowledgeActionButtonLabel: "OK")
            return Alert(
                identifier: Alert.Identifier(managerIdentifier: manager, alertIdentifier: name),
                foregroundContent: content,
                backgroundContent: content,
                trigger: trigger
            )
        }
        let world = LoanFixture()
        try await world.startLoan()
        let cgm = WatchLoanCGM(files: world.files)
        cgm.host = world.host
        let failed = alert("sensorFailed", manager: "G7", trigger: .immediate)
        let expiring = alert("sensorExpiringImminently", manager: "G7", trigger: .delayed(interval: 3600))
        let podExpiring = alert("podExpiring", manager: "Omnipod", trigger: .delayed(interval: 600))
        await cgm.issueAlert(failed)
        await cgm.issueAlert(expiring)
        await world.host.issueKitAlert(podExpiring)

        let failedID = WatchLoanAlerts.kitPrefix + failed.identifier.value
        let expiringID = WatchLoanAlerts.kitPrefix + expiring.identifier.value
        let podID = WatchLoanAlerts.kitPrefix + podExpiring.identifier.value
        #expect(world.notifier.pending[failedID]?.date == nil, "shown at once")
        #expect(world.notifier.bodies[failedID] == "Kit text.\n" + WatchLoanAlerts.sensorNeedsPhone)
        #expect(world.notifier.pending[expiringID]?.date == world.clock.addingTimeInterval(3600))
        #expect(world.notifier.pending[podID]?.date == world.clock.addingTimeInterval(600))
        #expect(world.notifier.bodies[podID] == "Kit text.\n" + WatchLoanAlerts.podNeedsPhone)

        await cgm.retractAlert(identifier: failed.identifier)
        #expect(world.notifier.pending[failedID] == nil)
        await cgm.retire()
        #expect(world.notifier.pending[expiringID] == nil, "the phone keeps the sensor's alerts after the loan")

        await world.host.receive([WatchLoanWireKey.message: try WatchLoanWire.encode(WatchLoanStop(kind: .revoke, epoch: 2))])
        #expect(world.host.state == .stopped(epoch: 1, reason: .superseded))
        await cgm.issueAlert(failed)
        #expect(world.notifier.pending[failedID] == nil, "superseded: the phone has the sensor and its alerts")
    }

    @Test("G-1: every watch state that may not dose has a notice pending or shown on the watch") func alarmCoverage() async throws {
        let unanswered = LoanFixture()
        unanswered.requestTimeout = 0.3
        unanswered.host = unanswered.makeHost()
        await unanswered.host.startTapped()
        guard case .requesting = unanswered.host.state else {
            Issue.record("Start didn't request")
            return
        }
        #expect(unanswered.notifier.pending[WatchLoanAlerts.requestTimeoutID]?.date == unanswered.clock.addingTimeInterval(0.3))
        try await Task.sleep(nanoseconds: 700_000_000)
        await unanswered.host.serially {}
        #expect(unanswered.host.state == .idle(epoch: 0))
        #expect(unanswered.notifier.pending[WatchLoanAlerts.requestTimeoutID] == nil, "replaced by the notice shown now")
        #expect(unanswered.notifier.posted.contains { $0.hasPrefix("trio.loan.alert.") })

        let world = LoanFixture()
        try await world.startLoan()
        #expect(world.notifier.pending[WatchLoanAlerts.requestTimeoutID] == nil, "the grant came: no notice")
        await world.reading(160)
        await world.host.endTapped()
        #expect(world.host.state == .returning(epoch: 1))
        #expect(!world.notifier.notLooping.isEmpty)

        let stopped = LoanFixture()
        try await stopped.startLoan()
        await stopped.reading(160)
        stopped.pod.holder = .phone
        await stopped.reading(160)
        try await Task.sleep(nanoseconds: 200_000_000)
        await stopped.host.serially {}
        #expect(stopped.host.state == .stopped(epoch: 1, reason: .foreignSession))
        #expect(!stopped.notifier.notLooping.isEmpty)

        try Data("not json".utf8).write(to: stopped.files.url(.state))
        await stopped.relaunch()
        #expect(stopped.host.state == .stopped(epoch: 0, reason: .unconfirmed))
        #expect(!stopped.notifier.notLooping.isEmpty)
    }

    @Test(
        "An unreadable state file is a stop: nothing is commanded, the user is told, the pod released (W38)"
    ) func unreadableState() async throws {
        let world = LoanFixture()
        try await world.startLoan()
        try Data("not json".utf8).write(to: world.files.url(.state))
        await world.relaunch()
        #expect(world.host.state == .stopped(epoch: 0, reason: .unconfirmed))
        #expect(world.pump?.releaseCalls == 1)
        #expect(world.notifier.posted.contains { $0.hasPrefix("trio.loan.alert.") })
        #expect(world.violations.isEmpty)
    }

    @Test("Acknowledging a stop books an unsettled bolus and sends it before forgetting it") func retireBooks() async throws {
        let world = LoanFixture()
        try await world.startLoan(glucose: 120)
        await world.reading(120)
        world.pump?.commandError = .communication(nil)
        world.pump?.makesDeliveryUncertainOnError = true
        await world.host.requestBolus(units: 1)
        #expect(world.host.intents.count == 1)
        await world.host.receive([WatchLoanWireKey.message: try WatchLoanWire.encode(WatchLoanStop(kind: .revoke, epoch: 2))])
        await world.host.stopAcknowledged()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(world.host.state == .idle(epoch: 1))
        #expect(world.host.intents.isEmpty)
        let lastBatch = try #require(world.transport.batches.last)
        #expect(lastBatch.pumpEvents.contains { $0.dose.type == .bolus && $0.dose.deliveredUnits == 1 })
        #expect(world.notifier.posted.contains("trio.loan.bookedIntent"))
    }

    @Test("Not-looping series: armed at holding, moved only by a confirmed cycle, removed at hand-back") func deadMan() async throws {
        let world = LoanFixture()
        let start = world.clock
        try await world.startLoan()
        let armed = world.notifier.notLooping
        #expect(armed.count == 10)
        #expect(abs(armed[0].timeIntervalSince(start) - 20 * 60) < 5)
        #expect(abs(armed[5].timeIntervalSince(start) - 120 * 60) < 5)
        #expect(abs(armed[9].timeIntervalSince(start) - 6 * 3600) < 5, "hourly to the 6-hour resume horizon")

        await world.reading(160)
        let moved = world.notifier.notLooping
        #expect(moved[0] > armed[0])
        // the phone's pill shows this loop's age, not the batch's (G-2)
        #expect(world.host.loop.lastConfirmedCycleAt != nil)
        #expect(world.transport.batches.last?.lastLoopAt == world.host.loop.lastConfirmedCycleAt)

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
        #expect(world.host.records.snapshot.overrideChange?.presetID == nil)
        #expect(world.host.records.snapshot.overrideChange != nil)
        #expect(world.host.records.snapshot.tempTargetChange != nil)
        #expect(world.transport.batches.last?.adjustmentChanges?.count == 2, "the phone hears about both stops")
        #expect(world.violations.isEmpty)
    }

    @Test("A temp target preset started on the watch runs there and goes to the phone") func startTempTargetPreset() async throws {
        let world = LoanFixture()
        let preset = WatchLoanSnapshot.TempTargetPreset(id: UUID().uuidString, name: "Activity", target: 150, duration: 60)
        world.tempTargetPresets = [preset]
        try await world.startLoan()
        #expect(world.host.uiStatus().tempTargetPresets.map(\.name) == ["Activity"])

        #expect(await world.host.startAdjustmentConfirmed(.tempTarget, presetID: preset.id))
        #expect(world.host.uiStatus().tempTarget?.name == "Activity")
        let change = try #require(world.transport.batches.last?.adjustmentChanges?.first { $0.kind == .tempTarget })
        #expect(change.presetID == preset.id)
        #expect(!(await world.host.startAdjustmentConfirmed(.tempTarget, presetID: "unknown")))
    }

    @Test("An override preset started on the watch shows as running and goes to the phone") func startOverridePreset() async throws {
        let world = LoanFixture()
        world.overridePresets = [.init(
            id: "gym",
            name: "Gym",
            state: OrefInputs.OverrideState(
                enabled: false, percentage: 80, indefinite: true, smbIsOff: false, target: nil, duration: nil,
                advancedSettings: false, isfAndCr: true, isf: true, cr: true, smbIsScheduledOff: false,
                start: nil, end: nil, smbMinutes: nil, uamMinutes: nil
            ),
            indefinite: true,
            duration: nil
        )]
        try await world.startLoan()

        #expect(await world.host.startAdjustmentConfirmed(.override, presetID: "gym"))
        let running = try #require(world.host.uiStatus().override)
        #expect(running.name == "Gym" && running.endsAt == nil)
        #expect(world.transport.batches.last?.adjustmentChanges?.contains { $0.kind == .override && $0.presetID == "gym" } == true)
    }

    @Test("An unacknowledged hand-back goes again while the phone is reachable, and stops at the ack (W17)") func handBackResend(
    ) async throws {
        let world = LoanFixture()
        world.handBackResend = 0.1
        world.host = world.makeHost()
        try await world.startLoan()
        await world.reading(160)
        func handBacks() -> Int { world.transport.messages.filter { $0.kind == .handBack }.count }
        world.transport.isReachable = false
        await world.host.endTapped()
        #expect(world.host.state == .returning(epoch: 1))
        #expect(handBacks() == 1)
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(handBacks() == 1, "unreachable: the queued copy is enough")
        world.transport.isReachable = true
        try await Task.sleep(nanoseconds: 350_000_000)
        await world.host.serially {}
        #expect(handBacks() >= 2)
        await world.host.receive(try world.payload(WatchLoanMessage(epoch: 1, kind: .handBackAck)))
        #expect(world.host.state == .idle(epoch: 1))
        let acked = handBacks()
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(handBacks() == acked)
    }

    @Test(
        "Suspend reminders: every 30 min for 4 h; gone when a cycle reads insulin running, at End, Take Back or a stop"
    ) func suspendReminders() async throws {
        func reminders(_ world: LoanFixture) -> [Date] {
            world.notifier.pending.filter { $0.key.hasPrefix(WatchLoanHost.suspendReminderPrefix) }.compactMap(\.value.date)
                .sorted()
        }
        func suspended() async throws -> LoanFixture {
            let world = LoanFixture()
            try await world.startLoan()
            await world.reading(160)
            let confirmed = await world.host.suspendInsulinConfirmed()
            #expect(confirmed)
            let pending = reminders(world)
            #expect(pending.count == 8)
            #expect(pending.first == world.clock.addingTimeInterval(30 * 60))
            #expect(pending.last == world.clock.addingTimeInterval(4 * 3600), "no reminder after 4 h")
            return world
        }

        let resumedElsewhere = try await suspended()
        await resumedElsewhere.reading(160)
        #expect(reminders(resumedElsewhere).count == 8, "still suspended: kept")
        resumedElsewhere.pump?.resumeDelivery { _ in }
        await resumedElsewhere.reading(160)
        #expect(reminders(resumedElsewhere).isEmpty, "the pump read shows insulin running")

        let resumedHere = try await suspended()
        let resumed = await resumedHere.host.resumeInsulinConfirmed()
        #expect(resumed)
        #expect(reminders(resumedHere).isEmpty)

        let ended = try await suspended()
        await ended.host.endTapped()
        #expect(ended.host.state == .returning(epoch: 1))
        #expect(reminders(ended).isEmpty)

        let takenBack = try await suspended()
        await takenBack.host.receive([WatchLoanWireKey.message: try WatchLoanWire.encode(WatchLoanStop(kind: .revoke, epoch: 2))])
        #expect(takenBack.host.state == .stopped(epoch: 1, reason: .superseded))
        #expect(reminders(takenBack).isEmpty)

        let stopped = try await suspended()
        stopped.pod.holder = .phone
        await stopped.reading(160)
        try await Task.sleep(nanoseconds: 200_000_000)
        await stopped.host.serially {}
        #expect(stopped.host.state == .stopped(epoch: 1, reason: .foreignSession))
        #expect(reminders(stopped).isEmpty)
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
        await world.host.noteWake("WKBluetoothAlertRefreshBackgroundTask")
        await world.reading(160)
        await world.reading(160)
        var summary = world.host.cycleInfo.summary
        #expect(summary.readings == 2 && summary.cycles == 2 && summary.confirmed == 2)
        #expect(summary.wakes["WKBluetoothAlertRefreshBackgroundTask"] == 1)
        #expect(WatchLoanHost.summaryLine(summary, until: world.clock, battery: 1).contains("readings 2"))
        world.clock = world.clock.addingTimeInterval(24 * 3600)
        await world.host.noteWake("WKApplicationRefreshBackgroundTask")
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
