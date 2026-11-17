import Foundation
import LoopKit
import OmnipodKit

/// Read-only values and the one query the Trio on Watch screens need. Nothing here commands the pump.
extension WatchLoanHost {
    var phoneIsReachable: Bool { env.transport.isReachable }

    /// The screens' view of the loan, read once per render.
    func uiStatus() -> TrioOnWatchStatus {
        var status = TrioOnWatchStatus()
        switch state {
        case .idle:
            status.phase = .phone
        case .requesting:
            status.phase = .starting
        case .holding:
            status.phase = awaitingFirstReading ? .waitingForReading : .inControl
        case .returning:
            status.phase = .ending
        case let .stopped(_, reason):
            status.phase = .stopped(reason)
        }
        status.phoneReachable = env.transport.isReachable
        status.lastLoopAt = loop.lastConfirmedCycleAt
        status.lastCycleAt = loop.lastCycleAt
        status.iob = loop.iob
        status.cob = loop.cob
        status.insulinSuspended = loop.pumpSuspended
        status.bolus = bolus
        status.lastAlert = lastAlert
        status.battery = env.batteryLevel()
        status.podUnreachable = cycleInfo.podLinkNoticeShown
        status.insulinPaused = !intents.isEmpty || pump?.status.deliveryIsUncertain == true
        if let snapshot {
            status.units = snapshot.bolusCalculator.units
            status.readings = (snapshot.oref.glucose + records.snapshot.glucose)
                .compactMap { reading in (reading.glucose ?? reading.sgv).map { .init(date: reading.dateString, mgdl: $0) } }
                .sorted { $0.date > $1.date }
                .prefix(2)
                .map { $0 }
            status.sensorEndsAt = snapshot.sensorEndsAt
            status.podEndsAt = snapshot.podEndsAt
            let now = env.now()
            let records = records.snapshot
            status.override = Self.running(snapshot.overrideAtGrant, cancelledAt: records.overrideCancelledAt, now: now)
            status.tempTarget = Self.running(snapshot.tempTargetAtGrant, cancelledAt: records.tempTargetCancelledAt, now: now)
            status.recentDoses = recentBoluses(snapshot: snapshot, now: now)
        }
        if let omnipod = pump as? OmniPumpManager {
            status.pumpLastContact = omnipod.lastSync
            status.reservoir = omnipod.state.podState?.lastInsulinMeasurements?.reservoirLevel
            status.podEndsAt = omnipod.state.podState?.expiresAt ?? status.podEndsAt
            status.podFaulted = omnipod.deliveredUnitsAreFinal
        }
        return status
    }

    private static func running(
        _ adjustment: WatchLoanSnapshot.Adjustment?,
        cancelledAt: Date?,
        now: Date
    ) -> TrioOnWatchStatus.Adjustment? {
        guard let adjustment, cancelledAt == nil, adjustment.endsAt.map({ $0 > now }) ?? true else { return nil }
        return .init(name: adjustment.name, endsAt: adjustment.endsAt)
    }

    /// Boluses of the last 6 hours: the phone's from the grant, then the watch's own, newest first.
    private func recentBoluses(snapshot: WatchLoanSnapshot, now: Date) -> [TrioOnWatchStatus.Dose] {
        let since = now.addingTimeInterval(-6 * 60 * 60)
        let phone = snapshot.oref.pumpHistory
            .filter { $0.type == .bolus && $0.timestamp > since }
            .map { TrioOnWatchStatus.Dose(date: $0.timestamp, units: $0.amount ?? 0, isAutomatic: $0.isSMB ?? false) }
        let watch = records.snapshot.pumpEvents.values
            .map(\.record.dose)
            .filter { $0.type == .bolus && $0.startDate > since }
            .map {
                TrioOnWatchStatus.Dose(
                    date: $0.startDate,
                    units: Decimal($0.deliveredUnits ?? $0.programmedUnits),
                    isAutomatic: $0.automatic ?? true,
                    isUnconfirmed: $0.isMutable
                )
            }
        return (phone + watch).sorted { $0.date > $1.date }
    }

    /// Asks the phone for the facts Start shows. Nil when it doesn't answer in time.
    func startFacts() async -> WatchLoanStartFacts? {
        let timeout = env.phoneAnswerTimeout
        return await withCheckedContinuation { (done: CheckedContinuation<WatchLoanStartFacts?, Never>) in
            let once = ResumeOnce(done)
            let sent = env.transport.sendLive([WatchLoanStartFacts.queryKey: true]) { reply in
                let facts = (reply[WatchLoanStartFacts.replyKey] as? Data)
                    .flatMap { try? JSONDecoder().decode(WatchLoanStartFacts.self, from: $0) }
                once.resume(facts)
            }
            guard sent else { return once.resume(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }

    /// The watch's limits for manual entry while it holds the pump.
    var bolusLimits: (maxBolus: Decimal, increment: Decimal)? {
        guard let snapshot else { return nil }
        let preferences = snapshot.oref.preferences ?? Preferences()
        return (snapshot.oref.pumpSettings.maxBolus, preferences.bolusIncrement)
    }

    func carbsSaved(since date: Date) -> Bool {
        records.snapshot.carbs.contains { $0.createdAt >= date }
    }
}
