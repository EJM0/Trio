import Foundation

/// The untethered watch mode handshake as a pure state machine, one per device, persisted by each.
/// Neither side doses with the pump unless its own state says so; every transition that hands the
/// pump over waits for the other side's answer, except the two emergency stops.
struct UntetheredSession: Codable, Equatable {
    enum Phase: String, Codable {
        case idle
        /// Phone: grant sent. Watch: grant accepted, waiting for the commit.
        case preparing
        /// Phone: pump released, waiting for the takeover. Watch: taking the pump.
        case starting
        case active
        case ending
    }

    enum Effect: Equatable {
        case send(UntetheredMessage)
        /// Phone: release the pump, then send the commit with it as released.
        case commit
        case releasePump
        /// Phone: take the pump back, read it and audit. Watch: retake it after a refused handback.
        case takePump
        /// Watch: take control and read the pump until it answers or the lease runs out.
        case takeover
        /// Watch: finish the cycle, read the pump, release it, then report `handbackReady`.
        case handback
        /// Phone: ask the watch for the records it hasn't got.
        case reconcile
        case failed(String)
    }

    enum PhoneEvent: Equatable {
        case start(UntetheredGrant)
        case received(UntetheredMessage, epoch: Int)
        case end
        case forceTakeBack
        case tick
        /// The watch reports the pump for a newer session the phone never granted: it started without the phone.
        case watchHoldsPump(epoch: Int, status: UntetheredPodStatus?)
    }

    enum WatchEvent: Equatable {
        case received(UntetheredMessage, epoch: Int)
        case takeoverSucceeded(UntetheredPodStatus)
        case takeoverFailed(String)
        /// On the wrist, or the linked override is over. Only sent while the phone is reachable.
        case end
        /// The pump is released for the handback; offered until the phone acknowledges it.
        case handbackReady(UntetheredPodStatus?)
        case emergencyStop(UntetheredPodStatus?)
        case tick
        /// From the standing grant, with the phone out of reach.
        case startWithoutPhone
    }

    static let prepareTimeout: TimeInterval = 15
    /// A start without the phone has this long to reach the pump.
    static let takeoverWithoutPhoneLease: TimeInterval = 5 * 60
    /// After the lease the phone asks once whether the watch holds the pump.
    static let statusQueryGrace: TimeInterval = 10

    private(set) var phase = Phase.idle
    private(set) var epoch = 0
    private(set) var leaseExpiresAt: Date?
    private(set) var prepareDeadline: Date?
    private(set) var statusQueried = false
    /// The pump as the watch found it at takeover; the insulin audit counts from here.
    private(set) var startStatus: UntetheredPodStatus?
    /// Phone: the temp basal the watch cancelled at its hand-back, set again once the pump is read.
    private(set) var returnedTempBasal: UntetheredTempBasal?
    /// Phone: a high temp the watch left running at its hand-back, cancelled once the pump is read.
    private(set) var returnedHighTemp: UntetheredTempBasal?
    private(set) var linkedOverrideID: String?
    /// The last session ended by an emergency stop or a take-back.
    private(set) var forced = false
    /// The watch started it from the standing grant, without the phone.
    private(set) var startedWithoutPhone = false
    /// Watch: the pump as offered to the phone, resent until acknowledged.
    private(set) var handbackStatus: UntetheredPodStatus??
    /// Watch: when the hand-back was offered; the pod is held until the phone acknowledges, or this long at most.
    private(set) var handbackOfferedAt: Date?
    /// Watch: let go of the pod although no acknowledgement came, offered still.
    private(set) var handbackLetGo = false

    /// Without an acknowledgement the pod is let go anyway, and runs its schedule until the phone takes it.
    static let handbackAckWait: TimeInterval = 60

    var isIdle: Bool { phase == .idle }

    // MARK: - Phone

    mutating func phone(_ event: PhoneEvent, now: Date) -> [Effect] {
        switch (phase, event) {
        case let (.idle, .start(grant)):
            // seconds since 1970: unique across reinstalls without anyone remembering a counter
            self = UntetheredSession(phase: .preparing, epoch: max(epoch + 1, Int(now.timeIntervalSince1970)))
            leaseExpiresAt = grant.leaseExpiresAt
            prepareDeadline = now.addingTimeInterval(Self.prepareTimeout)
            linkedOverrideID = grant.linkedOverrideID
            return [.send(.prepare(grant))]

        // the phone stands aside on the watch's word, never on evidence from the pod (LoopKit/Loop#2545)
        case let (.idle, .watchHoldsPump(watchEpoch, status)) where watchEpoch > epoch:
            self = UntetheredSession(phase: .active, epoch: watchEpoch)
            startStatus = status
            startedWithoutPhone = true
            return [.releasePump]

        case let (_, .received(_, messageEpoch)) where messageEpoch != epoch:
            return []

        // adopted from the watch's records before its takeover report: the audit counts from that report
        case let (.active, .received(.takeoverComplete(status), _)) where startStatus == nil:
            startStatus = status
            return []

        case (.preparing, .received(.prepared, _)):
            phase = .starting
            return [.commit]

        case let (.preparing, .received(.rejected(reason), _)):
            phase = .idle
            return [.failed(reason)]

        case (.preparing, .end):
            phase = .idle
            return []

        case let (.starting, .received(.statusReport(holding: .some(status)), _)),
             let (.starting, .received(.takeoverComplete(status), _)):
            phase = .active
            startStatus = status
            return []

        case let (.starting, .received(.takeoverFailed(reason), _)):
            phase = .idle
            return [.takePump, .failed(reason)]

        case (.starting, .received(.statusReport(holding: nil), _)):
            phase = .idle
            return [.takePump, .failed(String(localized: "The watch did not take over the pump."))]

        case (.active, .end):
            phase = .ending
            return [.send(.endRequest)]

        case let (.active, .received(.handback(status), _)),
             let (.ending, .received(.handback(status), _)):
            phase = .idle
            forced = false
            returnedTempBasal = status?.tempBasal
            returnedHighTemp = status?.runningHighTemp
            return [.takePump, .send(.handbackAck), .reconcile]

        case (.idle, .received(.handback, _)):
            // our acknowledgement got lost; the pump is ours already
            return [.send(.handbackAck)]

        case (.active, .received(.released, _)),
             (.ending, .received(.released, _)),
             (.starting, .received(.released, _)):
            phase = .idle
            forced = true
            return [.takePump, .reconcile]

        case (.active, .forceTakeBack),
             (.ending, .forceTakeBack),
             (.starting, .forceTakeBack):
            phase = .idle
            forced = true
            return [.send(.revoke), .takePump, .reconcile]

        case (.preparing, .tick):
            guard let prepareDeadline, now > prepareDeadline else { return [] }
            phase = .idle
            return [.failed(String(localized: "The watch did not answer. Open Trio on the watch and try again."))]

        case (.starting, .tick):
            guard !statusQueried, let leaseExpiresAt, now > leaseExpiresAt.addingTimeInterval(Self.statusQueryGrace)
            else { return [] }
            statusQueried = true
            return [.send(.statusQuery)]

        default:
            return []
        }
    }

    // MARK: - Watch

    mutating func watch(_ event: WatchEvent, now: Date) -> [Effect] {
        switch (phase, event) {
        case let (.idle, .received(.prepare(grant), messageEpoch)),
             let (.preparing, .received(.prepare(grant), messageEpoch)):
            guard now < grant.leaseExpiresAt else { return [] }
            self = UntetheredSession(phase: .preparing, epoch: messageEpoch)
            leaseExpiresAt = grant.leaseExpiresAt
            linkedOverrideID = grant.linkedOverrideID
            return [.send(.prepared)]

        case (_, .received(.prepare, _)):
            return [.send(.rejected(reason: String(localized: "The watch is still running an earlier untethered session.")))]

        case (.idle, .startWithoutPhone):
            // seconds since 1970, as the phone's: newer than any session it granted
            self = UntetheredSession(phase: .starting, epoch: max(epoch + 1, Int(now.timeIntervalSince1970)))
            leaseExpiresAt = now.addingTimeInterval(Self.takeoverWithoutPhoneLease)
            startedWithoutPhone = true
            return [.takeover]

        case let (_, .received(_, messageEpoch)) where messageEpoch != epoch:
            return []

        case (.preparing, .received(.commit, _)):
            guard let leaseExpiresAt, now < leaseExpiresAt else {
                phase = .idle
                return [.send(.takeoverFailed(reason: String(localized: "The start took too long.")))]
            }
            phase = .starting
            return [.takeover]

        case let (.starting, .takeoverSucceeded(status)):
            guard let leaseExpiresAt, now < leaseExpiresAt else {
                phase = .idle
                return [.releasePump, .send(.takeoverFailed(reason: String(localized: "The watch reached the pump too late.")))]
            }
            phase = .active
            startStatus = status
            return [.send(.takeoverComplete(status))]

        case let (.starting, .takeoverFailed(reason)):
            phase = .idle
            return [.releasePump, .send(.takeoverFailed(reason: reason))]

        case (_, .received(.statusQuery, _)):
            return [.send(.statusReport(holding: phase == .active || phase == .ending ? startStatus : nil))]

        case (.active, .end),
             (.active, .received(.endRequest, _)):
            phase = .ending
            handbackStatus = nil
            handbackOfferedAt = nil
            handbackLetGo = false
            return [.handback]

        // The pod is held until the phone acknowledges, so its standing connect lands as the watch lets go
        // (LoopKit/Loop#2545). Once let go the watch never takes the pump back on its own: a lost
        // acknowledgement must not leave both devices dosing. A free pump runs its scheduled basal.
        case let (.ending, .handbackReady(status)):
            handbackStatus = .some(status)
            handbackOfferedAt = now
            return [.send(.handback(status))]

        case (.ending, .tick):
            guard let status = handbackStatus else { return [] }
            if !handbackLetGo, let offered = handbackOfferedAt, now > offered.addingTimeInterval(Self.handbackAckWait) {
                handbackLetGo = true
                return [.releasePump, .send(.handback(status))]
            }
            return [.send(.handback(status))]

        case (.ending, .received(.handbackAck, _)):
            phase = .idle
            forced = false
            return handbackLetGo ? [] : [.releasePump]

        case (.preparing, .received(.revoke, _)):
            phase = .idle
            return []

        case (.active, .received(.revoke, _)),
             (.ending, .received(.revoke, _)),
             (.starting, .received(.revoke, _)):
            phase = .idle
            forced = true
            return [.releasePump]

        case let (.active, .emergencyStop(status)),
             let (.ending, .emergencyStop(status)),
             let (.starting, .emergencyStop(status)):
            phase = .idle
            forced = true
            return [.releasePump, .send(.released(status))]

        case (.preparing, .tick):
            guard let leaseExpiresAt, now >= leaseExpiresAt else { return [] }
            phase = .idle
            return []

        case (.starting, .tick):
            guard let leaseExpiresAt, now >= leaseExpiresAt else { return [] }
            phase = .idle
            return [.releasePump, .send(.takeoverFailed(reason: String(localized: "The watch could not reach the pump.")))]

        default:
            return []
        }
    }

    private init(phase: Phase, epoch: Int) {
        self.phase = phase
        self.epoch = epoch
    }

    init() {}
}
