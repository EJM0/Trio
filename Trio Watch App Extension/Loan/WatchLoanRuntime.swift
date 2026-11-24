import Foundation
import os
import UserNotifications
import WatchConnectivity
import WatchKit

/// Wires the loan host into the app. The host exists only in builds with Trio on Watch.
@MainActor enum WatchLoanRuntime {
    private(set) static var host: WatchLoanHost?

    static func start() {
        #if TRIO_ON_WATCH
            guard host == nil else { return }
            let files = WatchLoanFiles.standard
            let cgm = WatchLoanCGM(files: files)
            WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
            let created = WatchLoanHost(env: WatchLoanEnvironment(
                files: files,
                transport: WCSessionLoanTransport(),
                notifier: UserNotificationLoanNotifier(),
                pumpFactory: .kits,
                cgm: cgm,
                isForeground: { WKApplication.shared().applicationState == .active },
                batteryLevel: {
                    let level = WKInterfaceDevice.current().batteryLevel
                    return level < 0 ? nil : level
                },
                notificationsAllowed: {
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    return settings.authorizationStatus == .authorized && settings.timeSensitiveSetting == .enabled
                },
                modelIdentifier: { WatchLoanRuntime.modelIdentifier },
                appBuild: WatchLoanSnapshot.appBuild(Bundle.main.infoDictionary),
                beginActivity: { ExpiringActivity(reason: $0) }
            ))
            cgm.host = created
            created.onCycleFinished = { WatchBackgroundTasks.shared.cycleFinished() }
            host = created
            WatchLogger.shared.info(
                .lifecycle,
                "Trio on Watch host started \(WKApplication.shared().applicationState == .background ? "in the background (system relaunch)" : "in front"), model \(modelIdentifier ?? "unknown"), watchOS \(WKInterfaceDevice.current().systemVersion), battery \(Int(max(0, WKInterfaceDevice.current().batteryLevel) * 100)) %"
            )
            Task {
                await created.relaunch()
                // a loan that ended while the app was gone left the sensor lent
                if !cgm.isActive { WatchCGMHost.shared.sensorReturned(localState: nil) }
            }
        #else
            WatchCGMHost.shared.sensorReturned(localState: nil)
        #endif
    }

    /// `hw.machine`, or the simulated model in the simulator.
    nonisolated static var modelIdentifier: String? {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Trio on Watch reads the sensor itself: from a grant until the loan ends.
    static var ownsSensor: Bool {
        host?.env.cgm?.isActive ?? false
    }

    /// A WatchConnectivity payload; true when it was a loan payload.
    nonisolated static func receive(_ payload: [String: Any]) -> Bool {
        guard WatchLoanWireKey.isLoanPayload(payload) else { return false }
        Task { @MainActor in
            guard let host else {
                WatchLogger.shared.debug(.connectivity, "Loan payload dropped: Trio on Watch is off in this build")
                return
            }
            await host.receive(payload)
        }
        return true
    }
}

/// Background time from `performExpiringActivity`, held until `end()` or until the system takes it back.
final class ExpiringActivity: LoanBackgroundActivity, @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let expired = OSAllocatedUnfairLock(initialState: false)
    private let reason: String
    private let start = Date()

    init(reason: String) {
        self.reason = reason
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { [self] expiring in
            if expiring {
                expired.withLock { $0 = true }
                WatchLogger.shared.warning(
                    .lifecycle,
                    "\(reason): background time expired after \(String(format: "%.1f", Date().timeIntervalSince(start))) s"
                )
                done.signal()
            } else {
                done.wait()
            }
        }
    }

    var isExpired: Bool { expired.withLock { $0 } }

    func end() {
        done.signal()
    }
}

/// Front or background, readable from the kits' queues for log lines.
enum WatchAppState {
    private static let value = OSAllocatedUnfairLock(initialState: "launching")

    static var current: String { value.withLock { $0 } }

    static func set(_ state: String) {
        value.withLock { $0 = state }
    }
}

/// When a device's link last changed, for the time between link events in the log.
final class LinkEventClock: @unchecked Sendable {
    private let last = OSAllocatedUnfairLock<Date?>(initialState: nil)

    /// Logs the event with the app state and the seconds since the previous one.
    func note(_ role: String, category: WatchLogEntry.Category) {
        let now = Date()
        let previous = last.withLock { previous -> Date? in
            defer { previous = now }
            return previous
        }
        WatchLogger.shared.info(
            category,
            "\(role) link event, app \(WatchAppState.current), \(previous.map { String(format: "%.1f s", now.timeIntervalSince($0)) } ?? "first") after the previous"
        )
    }
}

/// The app's one WatchConnectivity session, owned by `WatchState`.
final class WCSessionLoanTransport: WatchLoanTransport {
    var isReachable: Bool { WCSession.default.activationState == .activated && WCSession.default.isReachable }

    func send(_ payload: [String: Any]) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            WatchLogger.shared.warning(.connectivity, "Loan payload not sent: session not active")
            return
        }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                WatchLogger.shared.warning(.connectivity, "Live loan send failed; queued instead", error: error)
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    func sendLive(_ payload: [String: Any], reply: (([String: Any]) -> Void)?) -> Bool {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return false }
        session.sendMessage(payload, replyHandler: reply) { error in
            WatchLogger.shared.warning(.connectivity, "Live loan send failed", error: error)
        }
        return true
    }
}

final class UserNotificationLoanNotifier: WatchLoanNotifier {
    func post(id: String, title: String, body: String, at date: Date?, timeSensitive: Bool, category: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = timeSensitive ? .timeSensitive : .active
        if let category { content.categoryIdentifier = category }
        let trigger = date.map {
            UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0.timeIntervalSinceNow), repeats: false)
        }
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) { error in
                if let error {
                    WatchLogger.shared.error(.lifecycle, "Scheduling a notification failed", error: error)
                }
            }
    }

    func cancel(ids: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

/// Every background task the app is handed is completed: a Bluetooth wake when its cycle ends or after the hold,
/// any other once acquisition is rechecked. Without a host, each is completed at once.
@MainActor final class WatchBackgroundTasks {
    static let shared = WatchBackgroundTasks()
    static let bluetoothHold: TimeInterval = 25
    static let connectivityLimit: TimeInterval = 8

    private var held: [(task: WKRefreshBackgroundTask, since: Date)] = []

    func handle(_ tasks: Set<WKRefreshBackgroundTask>) {
        let counts = Dictionary(grouping: tasks, by: { String(describing: type(of: $0)) }).mapValues(\.count)
        WatchLogger.shared.info(
            .lifecycle,
            "Background tasks: \(counts.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))"
        )
        for task in tasks {
            if let host = WatchLoanRuntime.host {
                let name = String(describing: type(of: task))
                Task { await host.noteWake(name) }
            }
            guard let host = WatchLoanRuntime.host else {
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            if task is WKWatchConnectivityRefreshBackgroundTask {
                // its budget is short: done once the session has delivered, at the latest after 8 s
                completeWhenDelivered(task, deadline: Date().addingTimeInterval(Self.connectivityLimit))
                continue
            }
            guard task is WKBluetoothAlertRefreshBackgroundTask else {
                if task is WKApplicationRefreshBackgroundTask {
                    host.env.cgm?.recheckAcquisition()
                }
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            let since = Date()
            held.append((task, since))
            task.expirationHandler = { [weak self, weak task] in
                DispatchQueue.main.async {
                    guard let task else { return }
                    WatchLogger.shared.warning(
                        .lifecycle,
                        "Bluetooth wake expired after \(String(format: "%.1f", Date().timeIntervalSince(since))) s"
                    )
                    self?.complete(task, reason: "expired")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.bluetoothHold) { [weak self] in
                self?.complete(task, reason: "hold ended")
            }
        }
    }

    private func completeWhenDelivered(_ task: WKRefreshBackgroundTask, deadline: Date) {
        guard WCSession.default.hasContentPending, Date() < deadline else {
            task.setTaskCompletedWithSnapshot(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.completeWhenDelivered(task, deadline: deadline)
        }
    }

    func cycleFinished() {
        for entry in held {
            complete(entry.task, reason: "cycle finished")
        }
    }

    private func complete(_ task: WKRefreshBackgroundTask, reason: String) {
        if let index = held.firstIndex(where: { $0.task === task }) {
            let since = held[index].since
            held.remove(at: index)
            WatchLogger.shared.info(
                .lifecycle,
                "Bluetooth wake completed (\(reason)) after \(String(format: "%.1f", Date().timeIntervalSince(since))) s"
            )
            task.setTaskCompletedWithSnapshot(false)
        } else if !(task is WKBluetoothAlertRefreshBackgroundTask) {
            task.setTaskCompletedWithSnapshot(false)
        }
    }
}
