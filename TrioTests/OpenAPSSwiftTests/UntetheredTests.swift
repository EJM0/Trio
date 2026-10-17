import Foundation
import Testing
@testable import Trio

@Suite("Untethered watch mode") struct UntetheredTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func grant(lease: TimeInterval = 120, linked: String? = nil) -> UntetheredGrant {
        UntetheredGrant(
            leaseExpiresAt: t0.addingTimeInterval(lease),
            pumpConfiguration: Data([1]),
            cgmConfiguration: Data([2]),
            pumpSettings: PumpSettings(insulinActionCurve: 10, maxBolus: 10, maxBasal: 3),
            bgTargets: BGTargets(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                targets: [BGTargetEntry(low: 100, high: 100, start: "00:00", offset: 0)]
            ),
            basalProfile: [BasalProfileEntry(start: "00:00", minutes: 0, rate: 1)],
            insulinSensitivities: InsulinSensitivities(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                sensitivities: [InsulinSensitivityEntry(sensitivity: 50, offset: 0, start: "00:00")]
            ),
            carbRatios: CarbRatios(units: .grams, schedule: [CarbRatioEntry(start: "00:00", offset: 0, ratio: 10)]),
            preferences: Preferences(),
            dosingMode: .closed,
            smoothGlucose: false,
            units: .mgdL,
            tdd: OrefPipeline.TDDSummary(currentTDD: 40, averageLastTenDays: 38, averageLastTwoHours: 2),
            hasSufficientTDD: true,
            tddRecentRows: [],
            tddTenDaySum: 380,
            tddTenDayCount: 10,
            tddPumpHistory: [],
            autosens: Autosens(ratio: 1.1, newisf: nil),
            reservoir: 120,
            maxBolus: 10,
            maxCarbs: 100,
            bolusCalculator: UntetheredBolusCalculatorSettings(
                fraction: 0.8,
                fattyMeals: true,
                fattyMealFactor: 0.7,
                sweetMeals: false,
                sweetMealFactor: 1
            ),
            glucoseColorScheme: "staticColor",
            lastDetermination: nil,
            lastLoopDate: nil,
            lowGlucose: 70,
            highGlucose: 180,
            pumpHistory: [],
            glucose: [BloodGlucose(sgv: 120, date: 1_800_000_000_000, dateString: t0, glucose: 120)],
            smoothedGlucose: [:],
            carbs: [],
            activeOverride: nil,
            tempTargets: [],
            overridePresets: [],
            tempTargetPresets: [],
            linkedOverrideID: linked
        )
    }

    let podStatus = UntetheredPodStatus(date: Date(timeIntervalSince1970: 1_800_000_010), deliveredUnits: 42.5, reservoir: 80)

    /// Phone and watch both active on the same epoch.
    func started() -> (phone: UntetheredSession, watch: UntetheredSession) {
        var phone = UntetheredSession()
        var watch = UntetheredSession()
        let grant = grant()
        #expect(phone.phone(.start(grant), now: t0) == [.send(.prepare(grant))])
        let epoch = phone.epoch
        #expect(watch.watch(.received(.prepare(grant), epoch: epoch), now: t0) == [.send(.prepared)])
        #expect(phone.phone(.received(.prepared, epoch: epoch), now: t0) == [.releasePump, .send(.commit)])
        #expect(watch.watch(.received(.commit, epoch: epoch), now: t0) == [.takeover])
        #expect(watch.watch(.takeoverSucceeded(podStatus), now: t0 + 30) == [.send(.takeoverComplete(podStatus))])
        #expect(phone.phone(.received(.takeoverComplete(podStatus), epoch: epoch), now: t0 + 31) == [])
        return (phone, watch)
    }

    @Test("start: both sides active only after the full handshake") func handshake() {
        let (phone, watch) = started()
        #expect(phone.phase == .active)
        #expect(watch.phase == .active)
        #expect(phone.epoch == watch.epoch)
        #expect(phone.startStatus == podStatus)
    }

    @Test("start: a silent watch never gets the pump") func prepareTimeout() {
        var phone = UntetheredSession()
        _ = phone.phone(.start(grant()), now: t0)
        #expect(phone.phone(.tick, now: t0 + 10) == [])
        let effects = phone.phone(.tick, now: t0 + UntetheredSession.prepareTimeout + 1)
        #expect(effects.count == 1)
        #expect(phone.phase == .idle)
        #expect(!effects.contains(.releasePump))
    }

    @Test("start: a rejected grant leaves the phone in charge") func rejected() {
        var phone = UntetheredSession()
        _ = phone.phone(.start(grant()), now: t0)
        #expect(phone.phone(.received(.rejected(reason: "no G7"), epoch: phone.epoch), now: t0) == [.failed("no G7")])
        #expect(phone.phase == .idle)
    }

    @Test("start: the watch lets go when the lease runs out mid-takeover") func leaseExpiry() {
        var phone = UntetheredSession()
        var watch = UntetheredSession()
        let grant = grant(lease: 60)
        _ = phone.phone(.start(grant), now: t0)
        _ = watch.watch(.received(.prepare(grant), epoch: phone.epoch), now: t0)
        _ = phone.phone(.received(.prepared, epoch: phone.epoch), now: t0)
        _ = watch.watch(.received(.commit, epoch: phone.epoch), now: t0)

        let effects = watch.watch(.tick, now: t0 + 61)
        #expect(effects.first == .releasePump)
        #expect(watch.phase == .idle)
        guard case let .send(failure) = effects.last else { Issue.record("no failure sent")
            return }
        #expect(phone.phone(.received(failure, epoch: phone.epoch), now: t0 + 61).first == .takePump)
        #expect(phone.phase == .idle)

        // a late success from the pump read changes nothing
        #expect(watch.watch(.takeoverSucceeded(podStatus), now: t0 + 62) == [])
    }

    @Test("start: a commit after the lease is refused") func lateCommit() {
        var watch = UntetheredSession()
        _ = watch.watch(.received(.prepare(grant(lease: 60)), epoch: 7), now: t0)
        let effects = watch.watch(.received(.commit, epoch: 7), now: t0 + 61)
        #expect(watch.phase == .idle)
        #expect(!effects.contains(.takeover))
    }

    @Test("start: an expired grant is ignored") func expiredGrant() {
        var watch = UntetheredSession()
        #expect(watch.watch(.received(.prepare(grant(lease: 60)), epoch: 7), now: t0 + 61) == [])
        #expect(watch.phase == .idle)
    }

    @Test("start: the phone asks once after the lease and follows the answer") func statusQuery() {
        var phone = UntetheredSession()
        _ = phone.phone(.start(grant(lease: 60)), now: t0)
        _ = phone.phone(.received(.prepared, epoch: phone.epoch), now: t0)
        #expect(phone.phone(.tick, now: t0 + 65) == [])
        #expect(phone.phone(.tick, now: t0 + 71) == [.send(.statusQuery)])
        #expect(phone.phone(.tick, now: t0 + 90) == [])
        #expect(phone.phase == .starting)

        var holding = phone
        _ = holding.phone(.received(.statusReport(holding: podStatus), epoch: phone.epoch), now: t0 + 91)
        #expect(holding.phase == .active)

        var notHolding = phone
        #expect(notHolding.phone(.received(.statusReport(holding: nil), epoch: phone.epoch), now: t0 + 91).first == .takePump)
        #expect(notHolding.phase == .idle)
    }

    @Test("messages for another epoch are ignored") func wrongEpoch() {
        var (phone, watch) = started()
        #expect(phone.phone(.received(.handback(nil), epoch: phone.epoch - 1), now: t0) == [])
        #expect(watch.watch(.received(.revoke, epoch: watch.epoch + 1), now: t0) == [])
        #expect(phone.phase == .active)
        #expect(watch.phase == .active)
    }

    @Test("the watch refuses a new grant while it holds the pump") func busyWatch() {
        var (_, watch) = started()
        let effects = watch.watch(.received(.prepare(grant(lease: 500)), epoch: watch.epoch + 1), now: t0 + 40)
        guard case .send(.rejected) = effects.first else { Issue.record("not rejected")
            return }
        #expect(watch.phase == .active)
    }

    @Test("end: the watch hands back and the phone takes over") func normalEnd() {
        var (phone, watch) = started()
        #expect(phone.phone(.end, now: t0 + 100) == [.send(.endRequest)])
        #expect(watch.watch(.received(.endRequest, epoch: watch.epoch), now: t0 + 100) == [.handback])
        #expect(watch.watch(.handbackReady(podStatus), now: t0 + 100) == [.send(.handback(podStatus))])
        #expect(
            phone.phone(.received(.handback(podStatus), epoch: phone.epoch), now: t0 + 101) ==
                [.takePump, .send(.handbackAck), .reconcile]
        )
        #expect(watch.watch(.received(.handbackAck, epoch: watch.epoch), now: t0 + 101) == [])
        #expect(phone.phase == .idle)
        #expect(watch.phase == .idle)
        #expect(!phone.forced)
    }

    @Test("end: an unacknowledged handback is offered again, never taken back") func lostAck() {
        var (phone, watch) = started()
        _ = watch.watch(.end, now: t0 + 100)
        _ = watch.watch(.handbackReady(podStatus), now: t0 + 100)
        _ = phone.phone(.received(.handback(podStatus), epoch: phone.epoch), now: t0 + 101)
        // the acknowledgement is lost; the watch keeps offering and the phone acknowledges again
        #expect(watch.watch(.tick, now: t0 + 130) == [.send(.handback(podStatus))])
        #expect(watch.phase == .ending)
        #expect(phone.phone(.received(.handback(podStatus), epoch: phone.epoch), now: t0 + 131) == [.send(.handbackAck)])
        _ = watch.watch(.received(.handbackAck, epoch: watch.epoch), now: t0 + 131)
        #expect(watch.phase == .idle)
    }

    @Test("emergency: force take back from the phone") func forceTakeBack() {
        var (phone, watch) = started()
        #expect(phone.phone(.forceTakeBack, now: t0 + 100) == [.send(.revoke), .takePump, .reconcile])
        #expect(phone.forced)
        #expect(watch.watch(.received(.revoke, epoch: watch.epoch), now: t0 + 200) == [.releasePump])
        #expect(watch.phase == .idle)
        #expect(watch.forced)
    }

    @Test("emergency: stop on the watch") func watchEmergencyStop() {
        var (phone, watch) = started()
        #expect(watch.watch(.emergencyStop(podStatus), now: t0 + 100) == [.releasePump, .send(.released(podStatus))])
        #expect(phone.phone(.received(.released(podStatus), epoch: phone.epoch), now: t0 + 101) == [.takePump, .reconcile])
        #expect(phone.phase == .idle)
        #expect(phone.forced)
    }

    @Test("a relaunch restores the session") func persistence() throws {
        let (phone, _) = started()
        let data = try JSONEncoder().encode(phone)
        #expect(try JSONDecoder().decode(UntetheredSession.self, from: data) == phone)
    }

    @Test("wire: an envelope survives the transport") func transport() throws {
        let envelope = UntetheredEnvelope(epoch: 42, message: .prepare(grant(linked: "override-1")))
        let payload = try envelope.payload()
        #expect(try UntetheredEnvelope.decode(payload) == envelope)
        #expect(try UntetheredEnvelope.decode(["watchState": 1]) == nil)
    }

    @Test("sync: bucket repair converges, versions included") func reconcile() {
        func entry(_ key: String, _ minutes: Double) -> UntetheredSyncEntry {
            UntetheredSyncEntry(key: key, id: UUID(), date: t0.addingTimeInterval(minutes * 60))
        }
        let watch = [entry("bg:1", 0), entry("bg:2", 5), entry("pump:a", 7), entry("carbs:x", 40), entry("bg:9", 95)]
        // the phone missed one, holds an old version of another and knows nothing of the last bucket
        var phone = [watch[0], watch[1], UntetheredSyncEntry(key: "pump:a", id: UUID(), date: watch[2].date), watch[3]]

        for _ in 0 ..< 3 {
            let request = UntetheredSyncEntry.bucketChecksumList(of: phone)
            let differing = UntetheredSyncEntry.differingBuckets(
                local: watch,
                remoteStart: request.start,
                remoteChecksums: request.checksums
            )
            if differing.isEmpty { break }
            // the watch resends those buckets whole; the phone replaces them
            phone.removeAll { differing.contains($0.bucket) }
            phone += watch.filter { differing.contains($0.bucket) }
        }

        let request = UntetheredSyncEntry.bucketChecksumList(of: phone)
        #expect(
            UntetheredSyncEntry.differingBuckets(local: watch, remoteStart: request.start, remoteChecksums: request.checksums)
                .isEmpty
        )
        #expect(Set(phone.map(\.id)) == Set(watch.map(\.id)))
    }

    @Test("sync: hashing is stable across processes") func fnv() {
        #expect(UntetheredSyncEntry.fnv1a("") == 0xCBF2_9CE4_8422_2325)
        #expect(UntetheredSyncEntry.fnv1a("a") == 0xAF63_DC4C_8601_EC8C)
    }

    @Test("audit: boluses, temps, suspension and scheduled basal") func audit() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnight = utc.startOfDay(for: t0)
        let profile = [
            BasalProfileEntry(start: "00:00", minutes: 0, rate: 1),
            BasalProfileEntry(start: "01:00", minutes: 60, rate: 2)
        ]
        func at(_ minutes: Double) -> Date { midnight.addingTimeInterval(minutes * 60) }
        let history = [
            PumpHistoryEvent(id: "b", type: .bolus, timestamp: at(10), amount: 1.5),
            PumpHistoryEvent(id: "s", type: .smb, timestamp: at(20), amount: 0.3, deliveredUnits: 0.25),
            // 3 U/h for 30 min from 0:30, cut short by a suspend at 0:45 that resumes at 0:50
            PumpHistoryEvent(id: "t", type: .tempBasalDuration, timestamp: at(30), durationMin: 30),
            PumpHistoryEvent(id: "_t", type: .tempBasal, timestamp: at(30), rate: 3),
            PumpHistoryEvent(id: "p", type: .pumpSuspend, timestamp: at(45)),
            PumpHistoryEvent(id: "r", type: .pumpResume, timestamp: at(50)),
            PumpHistoryEvent(id: "old", type: .bolus, timestamp: at(-5), amount: 9)
        ]
        let expected = UntetheredAudit.expectedDelivery(
            from: at(0),
            to: at(90),
            history: history,
            basalProfile: profile,
            calendar: utc
        )
        // boluses 1.75; basal 0:00–0:30 at 1 = 0.5; temp 0:30–0:45 at 3 = 0.75; suspended 5 min;
        // temp 0:50–1:00 at 3 = 0.5; scheduled 1:00–1:30 at 2 = 1
        #expect(abs(NSDecimalNumber(decimal: expected - 4.5).doubleValue) < 0.0001)
    }

    @Test("smoothing: steady glucose stays put, a gap falls back to raw, 38 ends the window") func smoothing() {
        func series(_ values: [Int], every minutes: Double = 5) -> [(date: Date?, glucose: Int)] {
            values.enumerated().map { (date: t0.addingTimeInterval(Double($0.offset) * minutes * 60), glucose: $0.element) }
        }
        let steady = GlucoseSmoothing.smoothed(series(Array(repeating: 120, count: 10)))
        #expect(steady.dropFirst().allSatisfy { $0 == 120 })
        #expect(steady.first! == nil)

        // a 20-minute gap leaves only two recent readings: too few to smooth, so they take their raw values
        var gapped = series([100, 110, 120, 130, 140])
        gapped += [(date: t0.addingTimeInterval(45 * 60), glucose: 150), (date: t0.addingTimeInterval(50 * 60), glucose: 160)]
        let afterGap = GlucoseSmoothing.smoothed(gapped)
        #expect(afterGap.suffix(2) == [150, 160])
        #expect(afterGap.prefix(5).allSatisfy { $0 == nil })

        let rising = GlucoseSmoothing.smoothed(series([100, 104, 108, 112, 116, 120]))
        #expect(rising.last!! <= 120 && rising.last!! >= 110)
    }

    @Test("wire: a full day's grant fits an interactive message") func grantSize() throws {
        let base = grant()
        let readings = (0 ..< 288).map { index -> BloodGlucose in
            let date = t0.addingTimeInterval(Double(-index) * 300)
            return BloodGlucose(
                sgv: 100 + index % 80, direction: .flat, date: Decimal(Int(date.timeIntervalSince1970 * 1000)),
                dateString: date, unfiltered: Decimal(100 + index % 80), glucose: 100 + index % 80, type: "sgv"
            )
        }
        // an SMB and a temp basal every five minutes: a busy day
        let events = (0 ..< 288).flatMap { index -> [PumpHistoryEvent] in
            let date = t0.addingTimeInterval(Double(-index) * 300)
            return [
                PumpHistoryEvent(
                    id: UUID().uuidString,
                    type: .bolus,
                    timestamp: date,
                    amount: 0.35,
                    duration: 0,
                    isSMB: true,
                    isExternal: false
                ),
                PumpHistoryEvent(id: UUID().uuidString, type: .tempBasalDuration, timestamp: date, durationMin: 30),
                PumpHistoryEvent(id: UUID().uuidString, type: .tempBasal, timestamp: date, rate: 1.35, temp: .absolute)
            ]
        }
        let tddEvents = (0 ..< 288).flatMap { index -> [PumpHistoryEvent] in
            let date = t0.addingTimeInterval(Double(-index) * 300)
            return [
                PumpHistoryEvent(id: UUID().uuidString, type: .bolus, timestamp: date, amount: 0.35),
                PumpHistoryEvent(
                    id: UUID().uuidString,
                    type: .tempBasal,
                    timestamp: date,
                    amount: 1.35,
                    duration: 30,
                    isScheduledBasal: false,
                    deliveredUnits: 0.1
                )
            ]
        }
        let full = UntetheredGrant(
            leaseExpiresAt: base.leaseExpiresAt, pumpConfiguration: Data(count: 3000), cgmConfiguration: Data(count: 1500),
            pumpSettings: base.pumpSettings, bgTargets: base.bgTargets, basalProfile: base.basalProfile,
            insulinSensitivities: base.insulinSensitivities, carbRatios: base.carbRatios, preferences: base.preferences,
            dosingMode: base.dosingMode, smoothGlucose: true, units: base.units, tdd: base.tdd, hasSufficientTDD: true,
            tddRecentRows: (0 ..< 24).map { UntetheredTDD(
                date: t0.addingTimeInterval(Double(-$0) * 300),
                total: 42.5,
                bolus: 20,
                tempBasal: 12,
                scheduledBasal: 10.5,
                weightedAverage: 41.2
            ) },
            tddTenDaySum: 120_000, tddTenDayCount: 2880, tddPumpHistory: tddEvents,
            autosens: base.autosens, reservoir: base.reservoir, maxBolus: base.maxBolus, maxCarbs: base.maxCarbs,
            bolusCalculator: base.bolusCalculator, glucoseColorScheme: "dynamicColor", lastDetermination: nil,
            lastLoopDate: t0, lowGlucose: 70, highGlucose: 180,
            pumpHistory: events, glucose: readings,
            smoothedGlucose: Dictionary(uniqueKeysWithValues: readings.map { ($0.id, Decimal($0.glucose ?? 0)) }),
            carbs: (0 ..< 6).map { _ in CarbsEntry(
                id: UUID().uuidString,
                createdAt: t0,
                actualDate: t0,
                carbs: 40,
                fat: nil,
                protein: nil,
                note: nil,
                enteredBy: "Trio",
                isFPU: false,
                fpuID: nil
            ) },
            activeOverride: nil, tempTargets: [], overridePresets: [], tempTargetPresets: [], linkedOverrideID: nil
        )
        let size = (try UntetheredEnvelope(epoch: 1, message: .prepare(full)).payload()[UntetheredEnvelope.key] as! Data).count
        print("grant size: \(size) bytes")

        // too close to WatchConnectivity's limit to rely on one message: it travels in parts, in any order
        let payload = try UntetheredEnvelope(epoch: 1, message: .prepare(full)).payload()
        let parts = try #require(UntetheredChunks.split(payload))
        #expect(parts.count >= 2)
        let assembler = UntetheredChunks.Assembler()
        var assembled: [String: Any]?
        for part in parts.reversed() { assembled = assembler.add(part) ?? assembled }
        #expect(try UntetheredEnvelope.decode(try #require(assembled)) == UntetheredEnvelope(epoch: 1, message: .prepare(full)))
        #expect(UntetheredChunks.split(try UntetheredEnvelope(epoch: 1, message: .commit).payload()) == nil)
    }

    @Test("TDD summary matches the phone's averaging") func tdd() {
        let now = t0
        let entries: [(date: Date, total: Decimal)] = [
            (now.addingTimeInterval(-3 * 86400), 30),
            (now.addingTimeInterval(-3600), 40),
            (now.addingTimeInterval(-60), 50)
        ]
        let summary = OrefPipeline.tddSummary(entries, now: now)
        #expect(summary.currentTDD == 50)
        #expect(summary.averageLastTenDays == 40)
        #expect(summary.averageLastTwoHours == 45)

        let empty = OrefPipeline.customOrefVariables(
            override: nil,
            tdd: OrefPipeline.tddSummary([], now: now),
            preferences: nil,
            now: now
        )
        #expect(empty.weightedAverage == 1)
        #expect(empty.smbMinutes == 30)
        #expect(!empty.useOverride)
    }
}
