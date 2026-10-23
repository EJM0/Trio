import WatchConnectivity
import WatchKit

/// Receives the launches and background wakes SwiftUI does not surface. Its
/// one job beyond defaults: bring the watch's G7 reader up at every launch
/// (including the silent ones the system makes for a Bluetooth link) and hold
/// the Bluetooth wakes long enough for a reading to arrive.
/// While untethered mode runs, the pump and the sensor belong to it: its wakes
/// run a loop cycle instead, and the reader stays out of the sensor's way.
final class TrioWatchAppDelegate: NSObject, WKApplicationDelegate {
    /// Untethered wakes are held long enough for one loop cycle and the G7's re-connect.
    private static let untetheredBluetoothHold: TimeInterval = 25
    /// Kept, not just their identities: WatchKit can hand a task over again, and completing one twice crashes.
    private var completed: [WKRefreshBackgroundTask] = []
    /// Untethered: one task held per wake. WatchKit delivers one for every Bluetooth message, dozens a second
    /// while the sensor pairs; the rest are completed on arrival (EJM0 b644da1).
    private var heldUntetheredTask: WKRefreshBackgroundTask?
    private var heldSince: Date?
    /// A held task older than this is from an earlier wake.
    private static let wakeLength: TimeInterval = 60

    func applicationDidFinishLaunching() {
        // restores a running untethered session first, so the reader sees it and stays off
        _ = UntetheredWatchManager.shared
        WatchG7Reader.shared.bootstrap()
        WatchG7Reader.shared.scheduleBackgroundRefresh()
    }

    func applicationDidBecomeActive() {
        WatchG7Reader.shared.appBecameActive()   // before the recheck, so it holds in the app
        WatchG7Reader.shared.noteWake()
    }

    func applicationWillEnterForeground() {
        WatchG7Reader.shared.noteWake()
    }

    /// Implementing this makes every background task ours to complete.
    /// Extended Untethered Mode's workout outlived the last process.
    func handleActiveWorkoutRecovery() {
        UntetheredWatchManager.shared.recoverWorkout()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        // Not always on main (EJM0 f858f18): a Bluetooth task can arrive on CoreBluetooth's queue, and all below is
        // main-only. The reader's hold asserts main, so such a task ended the process right at the link-up (Trio
        // 2026-10-18: a new process 5 s after "link up" at 14:10, no reading for hours).
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.handle(backgroundTasks) }
            return
        }
        for task in backgroundTasks {
            switch task {
            case let bluetoothTask as WKBluetoothAlertRefreshBackgroundTask:
                if UntetheredWatchManager.shared.isActive {
                    if bluetoothTask === heldUntetheredTask { continue }
                    if heldUntetheredTask != nil, let since = heldSince, Date().timeIntervalSince(since) < Self.wakeLength {
                        completeOnce(bluetoothTask)
                        continue
                    }
                    heldUntetheredTask = bluetoothTask
                    let since = Date()
                    heldSince = since
                    // the system may grant less than the hold: the task ends then, not later, and the grant is logged
                    bluetoothTask.expirationHandler = { [weak self, weak bluetoothTask] in
                        let expire = {
                            let granted = Date().timeIntervalSince(since)
                            Task {
                                await WatchLogger.shared
                                    .log(String(format: "⌚️ Bluetooth wake expired by the system after %.1f s", granted))
                            }
                            if let bluetoothTask { self?.releaseUntethered(bluetoothTask) }
                        }
                        if Thread.isMainThread { expire() } else { DispatchQueue.main.sync(execute: expire) }
                    }
                    // a reading in this wake loops through the CGM delegate; the wake itself only checks (EJM0 cfbb364)
                    UntetheredWatchManager.shared.recheckCGM()
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.untetheredBluetoothHold) {
                        self.releaseUntethered(bluetoothTask)
                    }
                } else {
                    WatchG7Reader.shared.hold(bluetoothTask: bluetoothTask)
                }

            case let connectivityTask as WKWatchConnectivityRefreshBackgroundTask:
                // Keep the app awake until WatchConnectivity has delivered
                // what the phone queued, as Apple asks.
                WatchG7Reader.shared.noteWake()
                completeWhenConnectivityIsDelivered(connectivityTask, attempt: 0)

            case let refreshTask as WKApplicationRefreshBackgroundTask:
                if UntetheredWatchManager.shared.isActive {
                    UntetheredWatchManager.shared.recheckCGM()
                }
                WatchG7Reader.shared.noteWake()
                WatchG7Reader.shared.scheduleBackgroundRefresh()
                // the session's own wake, after the reader's: one refresh is pending at a time
                UntetheredWatchManager.shared.scheduleSessionRefresh()
                // A few seconds for the re-check to lodge its request before suspending.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    refreshTask.setTaskCompletedWithSnapshot(false)
                }

            case let snapshotTask as WKSnapshotRefreshBackgroundTask:
                snapshotTask.setTaskCompleted(
                    restoredDefaultState: true,
                    estimatedSnapshotExpiration: Date.distantFuture,
                    userInfo: nil
                )

            default:
                WatchG7Reader.shared.noteWake()
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    /// Ends a held untethered wake, by the hold or by the system's expiry, whichever comes first.
    private func releaseUntethered(_ task: WKRefreshBackgroundTask) {
        if heldUntetheredTask === task {
            heldUntetheredTask = nil
            heldSince = nil
        }
        completeOnce(task)
    }

    private func completeOnce(_ task: WKRefreshBackgroundTask) {
        guard !completed.contains(where: { $0 === task }) else { return }
        completed.append(task)
        if completed.count > 128 { completed.removeFirst(32) }
        task.setTaskCompletedWithSnapshot(false)
    }

    private func completeWhenConnectivityIsDelivered(_ task: WKWatchConnectivityRefreshBackgroundTask, attempt: Int) {
        let session = WCSession.default
        if session.activationState != .activated || !session.hasContentPending || attempt >= 15 {
            task.setTaskCompletedWithSnapshot(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.completeWhenConnectivityIsDelivered(task, attempt: attempt + 1)
        }
    }
}
