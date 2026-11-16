import Foundation
import LoopKit
import Swinject
import Testing
@testable import Trio
import UserNotifications

/// Goldens for which glucose alarms `GlucoseAlertCoordinator` issues and retracts, step by step, for a
/// sequence of readings and determinations. Reading steps run at fixed Europe/Berlin times; determination
/// steps use the coordinator's own `Date()`, so their alarms are active day and night and never snoozed.
@Suite(
    "Glucose alarm characterization goldens",
    .serialized,
    .enabled(if: TimeZone.current.identifier == "Europe/Berlin", "day and night windows are recorded in Europe/Berlin")
) struct GlucoseAlarmCharacterizationTests {
    enum Step {
        /// A reading at a fixed time (ISO8601).
        case reading(Decimal, at: String)
        /// A determination with these IOB / ZT predictions and carbs required.
        case determination(iob: [Int]?, zt: [Int]?, carbsReq: Decimal?)
    }

    struct Scenario {
        var alarms: [GlucoseAlert]
        var configuration = GlucoseAlertConfiguration()
        var steps: [Step]
    }

    static func alarm(
        _ number: Int,
        _ type: GlucoseAlertType,
        _ threshold: Decimal,
        enabled: Bool = true,
        active: ActiveOption = .always,
        snoozedUntil: String? = nil,
        overridesSilence: Bool? = nil,
        playsSound: Bool = true
    ) -> GlucoseAlert {
        var alarm = GlucoseAlert(type: type)
        alarm.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
        alarm.name = "alarm-\(number)"
        alarm.thresholdMgDL = threshold
        alarm.isEnabled = enabled
        alarm.activeOption = active
        alarm.snoozedUntil = snoozedUntil.map { ISO8601DateFormatter().date(from: $0)! }
        alarm.overridesSilenceAndDND = overridesSilence ?? type.defaultOverridesSilenceAndDND
        alarm.playsSound = playsSound
        alarm.soundFilename = "sound-\(number).caf"
        return alarm
    }

    /// 12:00 CEST on 2026-06-15 plus `minutes`.
    static func noon(plus minutes: Int) -> String {
        ISO8601DateFormatter()
            .string(from: ISO8601DateFormatter().date(from: "2026-06-15T10:00:00Z")!.addingTimeInterval(Double(minutes) * 60))
    }

    static func predictions(_ value20min: Int) -> [Int] {
        [110, 100, 92, 85, value20min, value20min - 4, value20min - 7]
    }

    static let scenarios: [String: Scenario] = [
        "low-urgent-low-high-sequence": Scenario(
            alarms: [alarm(1, .urgentLow, 54), alarm(2, .low, 72), alarm(3, .high, 270)],
            steps: [80, 72, 70, 76, 77, 53, 58, 59, 60, 300, 266, 265].enumerated().map { index, value in
                .reading(Decimal(value), at: noon(plus: index * 5))
            }
        ),
        "urgent-low-retracts-firing-low": Scenario(
            alarms: [alarm(1, .low, 72), alarm(2, .urgentLow, 55)],
            steps: [.reading(65, at: noon(plus: 0)), .reading(50, at: noon(plus: 5)), .reading(64, at: noon(plus: 10))]
        ),
        "disabled-alarms-and-urgent-low-floor": Scenario(
            alarms: [
                alarm(1, .urgentLow, 54, enabled: false),
                alarm(2, .low, 72, enabled: false),
                alarm(3, .high, 180, enabled: false)
            ],
            steps: [.reading(50, at: noon(plus: 0)), .reading(200, at: noon(plus: 5))]
        ),
        "per-alarm-snooze": Scenario(
            alarms: [alarm(1, .low, 72, snoozedUntil: noon(plus: 10)), alarm(2, .high, 180, snoozedUntil: noon(plus: 10))],
            steps: [
                .reading(60, at: noon(plus: 0)),
                .reading(60, at: noon(plus: 10)),
                .reading(60, at: noon(plus: 15)),
                .reading(200, at: noon(plus: 20))
            ]
        ),
        "day-and-night-windows": Scenario(
            alarms: [alarm(1, .low, 80, active: .day), alarm(2, .low, 70, active: .night), alarm(3, .high, 250, active: .night)],
            steps: [
                .reading(75, at: "2026-06-15T19:50:00Z"), // 21:50 day
                .reading(75, at: "2026-06-15T20:00:00Z"), // 22:00 night
                .reading(69, at: "2026-06-15T20:05:00Z"),
                .reading(255, at: "2026-06-16T03:55:00Z"), // 05:55 night
                .reading(255, at: "2026-06-16T04:00:00Z"), // 06:00 day
                .reading(78, at: "2026-06-16T04:05:00Z")
            ]
        ),
        "night-inside-the-day": Scenario(
            alarms: [alarm(1, .high, 200, active: .night)],
            configuration: GlucoseAlertConfiguration(
                dayStart: TimeOfDay(hour: 7, minute: 0),
                nightStart: TimeOfDay(hour: 1, minute: 30)
            ),
            steps: [
                .reading(210, at: "2026-06-14T23:20:00Z"), // 01:20 day
                .reading(210, at: "2026-06-14T23:30:00Z"), // 01:30 night
                .reading(210, at: "2026-06-15T05:00:00Z") // 07:00 day
            ]
        ),
        "several-alarms-of-one-type": Scenario(
            alarms: [alarm(1, .high, 180), alarm(2, .high, 250), alarm(3, .low, 80), alarm(4, .low, 65)],
            steps: [180, 249, 260, 244, 176, 79, 60, 70, 85].enumerated().map { index, value in
                .reading(Decimal(value), at: noon(plus: index * 5))
            }
        ),
        "interruption-level-and-sound": Scenario(
            alarms: [
                alarm(1, .high, 180, overridesSilence: true, playsSound: false),
                alarm(2, .low, 72, overridesSilence: false)
            ],
            steps: [.reading(190, at: noon(plus: 0)), .reading(70, at: noon(plus: 5))]
        ),
        "forecasted-low": Scenario(
            alarms: [alarm(1, .forecastedLow, 72), alarm(2, .low, 70)],
            steps: [
                .determination(iob: predictions(80), zt: nil, carbsReq: nil),
                .determination(iob: predictions(72), zt: nil, carbsReq: nil),
                .determination(iob: predictions(76), zt: nil, carbsReq: nil),
                .determination(iob: predictions(77), zt: nil, carbsReq: nil),
                .determination(iob: predictions(90), zt: predictions(70), carbsReq: nil),
                .determination(iob: nil, zt: nil, carbsReq: nil),
                .determination(iob: [100, 90], zt: nil, carbsReq: nil),
                .determination(iob: predictions(60), zt: nil, carbsReq: nil),
                .reading(65, at: noon(plus: 0)),
                .determination(iob: predictions(60), zt: nil, carbsReq: nil),
                .reading(76, at: noon(plus: 5)),
                .determination(iob: predictions(60), zt: nil, carbsReq: nil)
            ]
        ),
        "carbs-required": Scenario(
            alarms: [alarm(1, .carbsRequired, 10), alarm(2, .carbsRequired, 20, enabled: false)],
            steps: [
                .determination(iob: nil, zt: nil, carbsReq: 9),
                .determination(iob: nil, zt: nil, carbsReq: 10),
                .determination(iob: nil, zt: nil, carbsReq: 25),
                .determination(iob: nil, zt: nil, carbsReq: 9.5),
                .determination(iob: nil, zt: nil, carbsReq: 30),
                .determination(iob: nil, zt: nil, carbsReq: nil)
            ]
        )
    ]

    static func determination(iob: [Int]?, zt: [Int]?, carbsReq: Decimal?) -> Determination {
        Determination(
            id: nil,
            reason: "",
            units: nil,
            insulinReq: nil,
            eventualBG: nil,
            sensitivityRatio: nil,
            rate: nil,
            duration: nil,
            iob: nil,
            cob: nil,
            predictions: iob == nil && zt == nil ? nil : Predictions(iob: iob, zt: zt, cob: nil, uam: nil),
            deliverAt: nil,
            carbsReq: carbsReq,
            temp: nil,
            bg: nil,
            reservoir: nil,
            isf: nil,
            timestamp: nil,
            tdd: nil,
            current_target: nil,
            minDelta: nil,
            expectedDelta: nil,
            minGuardBG: nil,
            minPredBG: nil,
            threshold: nil,
            carbRatio: nil,
            received: nil
        )
    }

    @Test("coordinator matches the golden") func coordinatorMatchesGolden() throws {
        var actual: [String: [String]] = [:]
        for (name, scenario) in Self.scenarios {
            actual[name] = run(scenario)
        }
        try GoldenFile.check(
            actual,
            at: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("GlucoseAlarmGoldens/glucose-alarms.json")
        )
    }

    @Test("GlucoseAlarmEvaluation matches the golden") func pureEvaluationMatchesGolden() throws {
        var actual: [String: [String]] = [:]
        for (name, scenario) in Self.scenarios {
            actual[name] = evaluate(scenario)
        }
        try GoldenFile.check(
            actual,
            at: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("GlucoseAlarmGoldens/glucose-alarms.json")
        )
    }

    /// The same log as `run`, with the coordinator's alert identifier, interruption level and sound.
    private func evaluate(_ scenario: Scenario) -> [String] {
        func describe(_ actions: [GlucoseAlarmEvaluation.Action]) -> String {
            actions.map { action in
                switch action {
                case let .fire(alarm, _):
                    let level = alarm.overridesSilenceAndDND ? "critical" : "timeSensitive"
                    let sound = alarm.playsSound ? alarm.soundFilename : "none"
                    return "issue glucose.\(alarm.type.rawValue).\(alarm.id.uuidString) \(level) \(sound)"
                case let .retract(alarm):
                    return "retract glucose.\(alarm.type.rawValue).\(alarm.id.uuidString)"
                }
            }.joined(separator: ", ")
        }

        var firing: Set<UUID> = []
        var log: [String] = []
        for step in scenario.steps {
            switch step {
            case let .reading(value, at):
                let actions = GlucoseAlarmEvaluation.evaluateReading(
                    latestMgDL: value,
                    alarms: scenario.alarms,
                    configuration: scenario.configuration,
                    firing: &firing,
                    now: ISO8601DateFormatter().date(from: at)!
                )
                log.append("reading \(value) at \(at): " + describe(actions))
            case let .determination(iob, zt, carbsReq):
                let determination = Self.determination(iob: iob, zt: zt, carbsReq: carbsReq)
                let actions = GlucoseAlarmEvaluation.evaluateForecast(
                    determination,
                    alarms: scenario.alarms,
                    configuration: scenario.configuration,
                    firing: &firing,
                    now: Date()
                ) + GlucoseAlarmEvaluation.evaluateCarbsRequired(
                    determination.carbsReq,
                    alarms: scenario.alarms,
                    configuration: scenario.configuration,
                    firing: &firing,
                    now: Date()
                )
                let iobText = iob.map { "\($0)" } ?? "nil"
                let ztText = zt.map { "\($0)" } ?? "nil"
                log.append(
                    "determination iob \(iobText) zt \(ztText) carbsReq \(carbsReq.map { "\($0)" } ?? "nil"): " +
                        describe(actions)
                )
            }
        }
        return log
    }

    /// One line per step: the step, then every issue and retract it caused, in order.
    private func run(_ scenario: Scenario) -> [String] {
        let resolver = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly()
        ]).resolver
        let spy = AlertManagerSpy()
        (resolver as! Container).register(TrioAlertManager.self) { _ in spy }
        let coordinator = GlucoseAlertCoordinator(resolver: resolver)
        coordinator.launchedAt = .distantPast
        coordinator.alertsSnapshot = scenario.alarms
        coordinator.configurationSnapshot = scenario.configuration

        var log: [String] = []
        for step in scenario.steps {
            switch step {
            case let .reading(value, at):
                let now = ISO8601DateFormatter().date(from: at)!
                coordinator.evaluationQueue.sync {
                    coordinator.applyReadingBasedEvaluation(
                        latestValue: value,
                        snapshot: scenario.alarms,
                        configuration: scenario.configuration,
                        now: now
                    )
                }
                log.append("reading \(value) at \(at): " + spy.drain().joined(separator: ", "))
            case let .determination(iob, zt, carbsReq):
                coordinator.determinationDidUpdate(Self.determination(iob: iob, zt: zt, carbsReq: carbsReq))
                coordinator.evaluationQueue.sync {}
                let iobText = iob.map { "\($0)" } ?? "nil"
                let ztText = zt.map { "\($0)" } ?? "nil"
                log.append(
                    "determination iob \(iobText) zt \(ztText) carbsReq \(carbsReq.map { "\($0)" } ?? "nil"): " + spy.drain()
                        .joined(separator: ", ")
                )
            }
        }
        return log
    }
}

/// Records what the coordinator issues and retracts; nothing else is used.
final class AlertManagerSpy: TrioAlertManager {
    private let lock = NSLock()
    private var events: [String] = []

    func drain() -> [String] {
        lock.withLock {
            defer { events = [] }
            return events
        }
    }

    func issueAlert(_ alert: Alert) {
        let sound: String
        switch alert.sound {
        case let .sound(name): sound = name
        case .vibrate: sound = "vibrate"
        case nil: sound = "none"
        }
        lock.withLock {
            events.append("issue \(alert.identifier.alertIdentifier) \(alert.interruptionLevel.rawValue) \(sound)")
        }
    }

    func retractAlert(identifier: Alert.Identifier) {
        lock.withLock { events.append("retract \(identifier.alertIdentifier)") }
    }

    func replayUnacknowledgedAlerts() {}
    func register(responder _: AlertResponder, for _: String) {}
    func register(soundVendor _: AlertSoundVendor, for _: String) {}
    func unregister(managerIdentifier _: String) {}
    func handleAcknowledgement(identifier _: Alert.Identifier) {}
    func handleNotificationResponse(_: UNNotificationResponse) {}
    func acknowledgeAllOutstanding() {}
    @MainActor func applySnooze(for _: TimeInterval) async {}
    func clearPendingNonCriticalNotifications() {}
    var muter: AlertMuter { preconditionFailure("unused") }
    var modalScheduler: TrioModalAlertScheduler { preconditionFailure("unused") }
    func soundURL(for _: Alert) -> URL? { nil }
}
