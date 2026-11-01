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
        install(pump)
        guard await takeControl(control, of: configuration, until: Date().addingTimeInterval(WatchLoopControl.takeoverLease))
        else {
            releasePump()
            return refuse(String(localized: "Watch Loop start expired before the pod answered."))
        }

        let session = max(state.session, copy.session) + 1
        state.begin(copy, at: Date())
        // the fallback starts on one of the watch's own readings: the first cycle uses it
        state.glucose = ownReadings
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

    /// False: no total yet, or insulin the copy doesn't explain was booked; the cycle doses nothing then.
    @discardableResult private func checkCopyAgainstPump(_ copy: WatchLoopGrant, pump: PumpManager) async -> Bool {
        guard let odometer = pump as? PumpDeliveryOdometer, await odometer.refreshDeliveredUnits(),
              let reading = odometer.deliveredUnits
        else {
            WatchLogger.shared.warning(.treatments, "Watch Loop: no pump total yet; no dose until there is one")
            return false
        }
        state.deliveredAtStart = reading.units
        state.deliveredAtStartReadAt = reading.at
        defer {
            state.verifiedDelivered = reading.units
            state.verifiedAt = reading.at
        }
        guard let copied = copy.deliveredUnits, let copiedAt = copy.deliveredUnitsAt else { return true }
        let recorded = WatchLoopAudit.recordedInsulin(
            WatchLoopAudit.doses(copy.pumpHistory, now: reading.at) { pump.estimatedDuration(toBolus: $0) },
            basalProfile: copy.basalProfile,
            from: copiedAt,
            to: reading.at,
            pulseUnits: odometer.deliveryPulseUnits
        )
        guard case let .missing(units) = WatchLoopAudit.compare(delivered: reading.units - copied, recorded: recorded)
        else { return true }
        bookPlaceholder(units, at: reading.at)
        return false
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
            amount: Decimal(rounded),
            // in IOB, but never the pump's delivery: it must not explain the next check's insulin
            isExternal: true
        ))
        state.history.sort { $0.timestamp < $1.timestamp }
        WatchLogger.shared.warning(.treatments, "Watch Loop: \(rounded) U the records don't explain, counted as a bolus")
    }

    /// At each pump reading of a session: insulin the watch's records don't explain means another controller dosed.
    /// The watch doses nothing in this cycle and waits for the phone's word before each dose, until it has it.
    func pumpTotalIsExplained(_ pump: PumpManager) async -> Bool {
        guard let grant = state.grant else { return false }
        guard let odometer = pump as? PumpDeliveryOdometer, let reading = odometer.deliveredUnits else {
            WatchLogger.shared.warning(.treatments, "Watch Loop: no pump total; no dose this cycle")
            return false
        }
        guard let baseline = state.verifiedDelivered, let since = state.verifiedAt else {
            // no total at the start: a start from the copy checks it now, a granted session starts here
            if state.startedWithoutPhone { return await checkCopyAgainstPump(grant, pump: pump) }
            state.verifiedDelivered = reading.units
            state.verifiedAt = reading.at
            return true
        }
        guard reading.at > since else { return true }
        let recorded = WatchLoopAudit.recordedInsulin(
            WatchLoopAudit.doses(state.pumpHistory, now: reading.at) { pump.estimatedDuration(toBolus: $0) },
            basalProfile: grant.basalProfile,
            from: since,
            to: reading.at,
            pulseUnits: odometer.deliveryPulseUnits
        )
        state.verifiedAt = reading.at
        switch WatchLoopAudit.compare(delivered: reading.units - baseline, recorded: recorded) {
        case .matches:
            // only what the records explain moves the baseline: differences under the band add up until they show
            state.verifiedDelivered = baseline + recorded
            return true
        case .overstated:
            state.verifiedDelivered = reading.units
            return true
        case let .missing(units):
            state.verifiedDelivered = reading.units
            bookPlaceholder(units, at: reading.at)
            state.checkWithPhoneBeforeDosing = true
            return false
        }
    }

    /// After a hand-back nobody answered: a dose waits for the phone's word, which ends the session if the phone
    /// took the pod meanwhile. Silence carries on (control row 13).
    func checkWithPhoneIfNeeded() async {
        guard state.checkWithPhoneBeforeDosing else { return }
        note = String(localized: "Checking with your iPhone…")
        sendStatus(replyTo: nil)
        // A live answer, not any message: one queued long ago says nothing about the phone now. A phone that holds
        // the pod answers the status with the stop, which ends the session before the dose.
        if await askPhone() {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            state.checkWithPhoneBeforeDosing = false
        }
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
