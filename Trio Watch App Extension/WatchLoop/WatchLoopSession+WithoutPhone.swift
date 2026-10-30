import Foundation
import LoopKit
import WatchKit

/// Starting without the phone: from the copy it leaves here, on the looper's tap (Allow Without iPhone) or by
/// itself when the phone has stopped looping (Fallback Loop), after LoopKit/Loop#2545's seize.
extension WatchLoopSession {
    var usableStandingCopy: WatchLoopGrant? {
        guard WatchState.shared.watchLoopWithoutPhone, let copy = state.standing,
              WatchLoopStanding.isUsable(copy, now: Date()) else { return nil }
        return copy
    }

    func keepStandingCopy(_ copy: WatchLoopGrant) {
        guard WatchState.shared.watchLoopWithoutPhone else {
            state.standing = nil
            return
        }
        guard copy.issuedAt > state.standing?.issuedAt ?? .distantPast else { return }
        state.standing = copy
    }

    /// From the copy, with a session of its own above any the watch knows. The pump's total is checked against the
    /// copy's records before the first loop; what they don't explain (the phone's doses since the copy) is counted
    /// as a bolus here, so the watch doses low rather than twice.
    func startWithoutPhone(byFallback: Bool = false) async {
        guard state.phase == .idle, !isBusy, let copy = usableStandingCopy else { return }
        guard let raw = try? PropertyListSerialization.propertyList(from: copy.pumpConfiguration, format: nil) as? [String: Any],
              let configuration = SharedDeviceConfiguration(rawValue: raw),
              let pump = watchPumpManager(
                  adopting: configuration,
                  localState: UserDefaults.standard.dictionary(forKey: Self.pumpLocalKey)
              ),
              let control = pump as? ExclusiveDeviceControl
        else { return refuse(String(localized: "This pump can't be run from the watch.")) }
        isBusy = true
        defer { isBusy = false }
        offersStartWithoutPhone = false
        note = String(localized: "Connecting to the pod…")
        install(pump)
        control.takeControl()
        let lease = Date().addingTimeInterval(WatchLoopControl.takeoverLease)
        while Date() < lease, !(control.isControlReady && !control.isControlReleased) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard control.isControlReady, !control.isControlReleased else {
            releasePump()
            return refuse(String(localized: "Watch Loop start expired before the pod answered."))
        }

        let session = max(state.session, copy.session) + 1
        state.begin(copy, at: Date())
        state.session = session
        state.startedWithoutPhone = true
        state.startedByFallback = byFallback
        await checkCopyAgainstPump(copy, pump: pump)
        note = byFallback ? String(localized: "Started by the Fallback Loop: your iPhone stopped looping.") : nil
        // a phone in reach stands aside for this session (control row 17)
        sendStatus(replyTo: nil)
        WKInterfaceDevice.current().play(.success)
        if byFallback {
            notify(
                String(localized: "Fallback Loop Started"),
                String(
                    localized: "Your iPhone stopped looping, so the watch took over the pod. It hands it back once the iPhone is back."
                )
            )
        }
        WatchLogger.shared.info(
            .treatments,
            "Watch Loop session \(session) started without the phone\(byFallback ? " by the fallback" : "")"
        )
        await runCycle(reason: "start")
    }

    private func checkCopyAgainstPump(_ copy: WatchLoopGrant, pump: PumpManager) async {
        guard let odometer = pump as? PumpDeliveryOdometer, await odometer.refreshDeliveredUnits(),
              let reading = odometer.deliveredUnits
        else {
            WatchLogger.shared.warning(.treatments, "Watch Loop: no pump total before the first loop")
            return
        }
        state.deliveredAtStart = reading.units
        state.deliveredAtStartReadAt = reading.at
        defer {
            state.verifiedDelivered = reading.units
            state.verifiedAt = reading.at
        }
        guard let copied = copy.deliveredUnits, let copiedAt = copy.deliveredUnitsAt else { return }
        let recorded = WatchLoopAudit.recordedInsulin(
            WatchLoopStanding.doses(copy.pumpHistory, now: reading.at) { pump.estimatedDuration(toBolus: $0) },
            basalProfile: copy.basalProfile,
            from: copiedAt,
            to: reading.at
        )
        guard case let .missing(units) = WatchLoopAudit.compare(delivered: reading.units - copied, recorded: recorded)
        else { return }
        bookPlaceholder(units, at: reading.at)
    }

    /// Insulin the watch's records don't explain, as a bolus in its own history: IOB errs high, so dosing errs low.
    /// Not a record: the phone has the doses themselves.
    func bookPlaceholder(_ units: Double, at date: Date) {
        let rounded = (units * 20).rounded(.down) / 20
        guard rounded > 0 else { return }
        state.history.append(PumpHistoryEvent(
            id: "watchLoop.placeholder.\(Int(date.timeIntervalSince1970))",
            type: .bolus,
            timestamp: date,
            amount: Decimal(rounded)
        ))
        state.history.sort { $0.timestamp < $1.timestamp }
        WatchLogger.shared.warning(.treatments, "Watch Loop: \(rounded) U the records don't explain, counted as a bolus")
    }

    /// At each pump reading of a session: insulin the watch's records don't explain means another controller dosed.
    /// The watch doses nothing in this cycle and waits for the phone's word before each dose, until it has it.
    func pumpTotalIsExplained(_ pump: PumpManager) async -> Bool {
        guard let odometer = pump as? PumpDeliveryOdometer, let reading = odometer.deliveredUnits,
              let baseline = state.verifiedDelivered, let since = state.verifiedAt, reading.at > since,
              let grant = state.grant
        else { return true }
        let recorded = WatchLoopAudit.recordedInsulin(
            WatchLoopStanding.doses(state.pumpHistory, now: reading.at) { pump.estimatedDuration(toBolus: $0) },
            basalProfile: grant.basalProfile,
            from: since,
            to: reading.at
        )
        state.verifiedDelivered = reading.units
        state.verifiedAt = reading.at
        guard case let .missing(units) = WatchLoopAudit.compare(delivered: reading.units - baseline, recorded: recorded)
        else { return true }
        bookPlaceholder(units, at: reading.at)
        state.checkWithPhoneBeforeDosing = true
        return false
    }

    /// After a hand-back nobody answered: a dose waits for the phone's word, which ends the session if the phone
    /// took the pod meanwhile. Silence carries on (control row 13).
    func checkWithPhoneIfNeeded() async {
        guard state.checkWithPhoneBeforeDosing else { return }
        note = String(localized: "Checking with your iPhone…")
        let asked = Date()
        sendStatus(replyTo: nil)
        let wait = WatchLoopControl.Wait.onScreen.seconds
        while Date().timeIntervalSince(asked) < wait, (lastHeardFromPhoneAt ?? .distantPast) < asked {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if (lastHeardFromPhoneAt ?? .distantPast) >= asked { state.checkWithPhoneBeforeDosing = false }
        if state.phase == .active { note = nil }
    }

    // MARK: - The fallback

    /// On each of the watch's own readings while no session runs (`WatchLoopFallback`).
    func checkFallback() async {
        let watchState = WatchState.shared
        guard state.phase == .idle, !isBusy, !isCheckingFallback, watchState.watchLoopEnabled,
              watchState.watchLoopWithoutPhone, watchState.watchLoopFallback
        else { return }
        var inputs = WatchLoopFallback.Inputs(
            ownReadings: liveReadings,
            phoneNewestReading: watchState.phoneNewestReading,
            phoneLastLoop: watchState.phoneLastLoopDate,
            phoneAnswered: false,
            sensorProblemNow: WatchCGMHost.shared.hasSensorProblem,
            lastSensorProblemAt: WatchCGMHost.shared.lastSensorProblemAt,
            copyUsable: usableStandingCopy != nil,
            now: Date()
        )
        guard WatchLoopFallback.shouldStart(inputs) else { return }
        // the health question: a phone that answers keeps the pod
        isCheckingFallback = true
        defer { isCheckingFallback = false }
        inputs.phoneAnswered = await askPhone()
        inputs.now = Date()
        guard WatchLoopFallback.shouldStart(inputs) else {
            WatchLogger.shared.info(.treatments, "Watch Loop fallback: the iPhone answered; it keeps the pod")
            return
        }
        WatchLogger.shared.warning(.treatments, "Watch Loop fallback: the iPhone stopped looping; starting on the watch")
        await startWithoutPhone(byFallback: true)
    }

    private func askPhone() async -> Bool {
        await withCheckedContinuation { continuation in
            let once = OnceGate()
            let sent = WatchState.shared.requestWatchStateUpdate { answered in
                if once.claim() { continuation.resume(returning: answered) }
            }
            guard sent else {
                if once.claim() { continuation.resume(returning: false) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + WatchLoopControl.Wait.inBackground.seconds) {
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }

    /// A session the fallback started goes back once the phone answers again with fresh readings of its own.
    func handBackIfPhoneIsBack() async {
        guard state.phase == .active, state.startedByFallback, !isBusy, WatchState.shared.isReachable,
              let newest = WatchState.shared.phoneNewestReading, Date().timeIntervalSince(newest) < WatchLoopFallback.phoneSilence
        else { return }
        WatchLogger.shared.info(.treatments, "Watch Loop fallback: the iPhone is back; handing the pod back")
        await end()
    }
}

/// Resumes a continuation once, from whichever path comes first.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
