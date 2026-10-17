import WatchKit

/// The pump and the CGM wake the app through Bluetooth; each wake is held long enough for one loop
/// cycle and for the G7's re-connect, which keeps the process past the sensor's advertising tail.
final class TrioWatchAppDelegate: NSObject, WKApplicationDelegate {
    /// Kept, not just their identities: WatchKit can hand a task over again, and completing one twice crashes.
    private var completed: [WKRefreshBackgroundTask] = []
    private static let bluetoothHold: TimeInterval = 25

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if task is WKBluetoothAlertRefreshBackgroundTask {
                UntetheredWatchManager.shared.recheckCGM()
                UntetheredWatchManager.shared.runLoop(.fallback)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.bluetoothHold) { self.complete(task) }
            } else {
                complete(task)
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
