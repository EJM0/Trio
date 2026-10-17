import WatchKit

/// The pump and the CGM wake the app through Bluetooth; each wake is held long enough for one loop
/// cycle and for the G7's re-connect, which keeps the process past the sensor's advertising tail.
final class TrioWatchAppDelegate: NSObject, WKApplicationDelegate {
    /// Kept, not just their identities: WatchKit can hand a task over again, and completing one twice crashes.
    private var completed: [WKRefreshBackgroundTask] = []
    private static let bluetoothHold: TimeInterval = 25
    /// A held task older than this is from an earlier wake.
    private static let wakeLength: TimeInterval = 60
    /// One task held per wake: WatchKit delivers one for every Bluetooth message, dozens a second while the sensor
    /// pairs. The rest are completed on arrival.
    private var heldBluetoothTask: WKRefreshBackgroundTask?
    private var heldSince: Date?

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard task is WKBluetoothAlertRefreshBackgroundTask else {
                complete(task)
                continue
            }
            if task === heldBluetoothTask { continue }
            if heldBluetoothTask != nil, let since = heldSince, Date().timeIntervalSince(since) < Self.wakeLength {
                complete(task)
                continue
            }
            heldBluetoothTask = task
            heldSince = Date()
            UntetheredWatchManager.shared.recheckCGM()
            UntetheredWatchManager.shared.runLoop(.fallback)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.bluetoothHold) {
                if self.heldBluetoothTask === task {
                    self.heldBluetoothTask = nil
                    self.heldSince = nil
                }
                self.complete(task)
            }
        }
    }

    private func complete(_ task: WKRefreshBackgroundTask) {
        guard !completed.contains(where: { $0 === task }) else { return }
        completed.append(task)
        if completed.count > 128 { completed.removeFirst(32) }
        task.setTaskCompletedWithSnapshot(false)
    }
}
