import Foundation

/// Who controls the pump: the decisions of Documentation/WatchLoop/Control.md, as one function, after
/// LoopKit/Loop#2545's LoanControl. Both apps describe the situation at each decision point, call `decide`, and
/// carry out what it returns; the mechanisms (take back, stand aside, query, hand back) decide nothing. One case per
/// row, in the document's order; each case's comment is the row's reason. A different ruling for a row is a change to
/// its case and to its test in WatchLoopControlTests.
///
/// Where a device is and whether it is alive are not inputs: no device can know them. The inputs are the control
/// state and what the acting device can see; the physical configurations become the tests' scenarios.
enum WatchLoopControl {
    // MARK: - Inputs

    enum Device: Equatable {
        case phone
        case watch
    }

    /// The phone's part in control, as it knows it.
    enum PhoneRole: String, Codable, Equatable {
        /// The resting state: it holds the pump and loops.
        case holdsPump
        /// It handed the pump to the watch (a grant, or a session it adopted).
        case lending
        /// It stands aside for a session the watch started without it.
        case standingAside
        /// Mid-transfer (a grant out, a hand-back being written, a take-back reaching for the pump): transfers
        /// decide for themselves.
        case transferring
    }

    /// How the session the watch claims relates to the phone's own record.
    enum ClaimedSession: Equatable {
        /// One the phone has ended.
        case closed
        /// The phone's live session.
        case current
        /// One newer than any the phone knows: started on the watch without it.
        case newer
    }

    /// The watch saying it holds the pump: a status report, or records.
    struct Claim: Equatable {
        var session: ClaimedSession
        /// When the session started, or the latest it could have.
        var startedAt: Date?
        /// Whether the watch reached the pump within its last cycle; nil when not said.
        var pumpReachable: Bool?
        /// The phone already refused this session as a revived claim.
        var refusedBefore: Bool

        init(session: ClaimedSession, startedAt: Date? = nil, pumpReachable: Bool? = nil, refusedBefore: Bool = false) {
            self.session = session
            self.startedAt = startedAt
            self.pumpReachable = pumpReachable
            self.refusedBefore = refusedBefore
        }
    }

    /// What just happened, as the acting device sees it.
    enum Trigger: Equatable {
        // The watch's taps and events
        case startTapped
        case endTapped
        /// The watch app is back from being off (dead, or relaunched) with a session saved.
        case backFromOff
        /// A message from the phone while no session runs.
        case phoneHeardWithNoSession

        // The phone's observations and taps
        /// A pump reading: whether it shows a difference from the phone's records beyond the band.
        case pumpReading(differenceBeyondBand: Bool)
        /// No report from the watch for longer than a cycle.
        case watchReportOverdue
        case watchClaims(Claim)
        case takeBackTapped
    }

    struct Situation: Equatable {
        var device: Device
        var trigger: Trigger
        /// The phone's role; ignored on the watch.
        var phoneRole: PhoneRole
        /// When the phone last took control on silence.
        var tookOverOnSilenceAt: Date?
        /// The phone sees the sensor, so it is near the body (and the pump).
        var sensorFresh: Bool
        /// The phone left a standing copy with the watch, so the watch could have started without it.
        var standingCopyOut: Bool
        /// The watch holds a standing copy.
        var watchHasStandingCopy: Bool
        /// The watch reads the CGM itself (the CGM's Read on Apple Watch setting).
        var watchReadsCGM: Bool

        init(
            device: Device,
            trigger: Trigger,
            phoneRole: PhoneRole = .holdsPump,
            tookOverOnSilenceAt: Date? = nil,
            sensorFresh: Bool = true,
            standingCopyOut: Bool = false,
            watchHasStandingCopy: Bool = false,
            watchReadsCGM: Bool = true
        ) {
            self.device = device
            self.trigger = trigger
            self.phoneRole = phoneRole
            self.tookOverOnSilenceAt = tookOverOnSilenceAt
            self.sensorFresh = sensorFresh
            self.standingCopyOut = standingCopyOut
            self.watchHasStandingCopy = watchHasStandingCopy
            self.watchReadsCGM = watchReadsCGM
        }
    }

    // MARK: - Outputs

    /// How long a query waits for its answer before silence counts.
    enum Wait: Equatable {
        /// The looper waits on screen (Start, End): the watch app is in front and its live path usually works; a
        /// late answer costs a second tap.
        case onScreen
        /// In the background a question and its answer may each travel queued; the slowest one-way delivery Loop
        /// measured was 15 s. A late answer here moves control wrongly, so the wait covers twice that.
        case inBackground

        var seconds: TimeInterval {
            switch self {
            case .onScreen: return 10
            case .inBackground: return 30
            }
        }
    }

    /// What the looper is told.
    enum Tell: Equatable {
        case watchNotResponding
        /// The watch never reported after a grant.
        case watchDidNotTake
        case phoneAwayCannotHandBack
        case noResponseFromPhone
        /// No answer, and the watch has no CGM reading of its own to dose from.
        case noResponseFromPhoneAndNoCGM
        case notHearingFromPhone
    }

    enum Prompt: Equatable {
        case startWithoutPhone
    }

    indirect enum Decision: Equatable {
        case nothing
        /// Ask the other device whether it holds the pump. An answer that says it does is acted on where it
        /// lands; silence, or "I hold it but cannot reach it", leads to `onSilence` (`afterQuery`).
        case query(Wait, onSilence: Decision)
        /// Phone: it already holds the pump and keeps it; remember the takeover on silence.
        case keepPumpOnSilence
        /// Phone: take the pump back after silence; remember the takeover; tell.
        case takeOnSilence(Tell)
        /// Phone: take the pump back because the looper tapped.
        case takeOnTap
        /// Phone: stand aside for the watch's session.
        case standAside
        /// Phone: send the stop for the claimed session.
        case sendStop
        /// Phone: the watch is still there; renew its hold.
        case renewHold
        /// Watch: carry on with what it was last told.
        case carryOn
        /// Watch: refuse the looper's tap and say why.
        case refuse(Tell)
        case prompt(Prompt)
        case tell(Tell)
        /// Watch: tell the looper if nothing more is heard within `after`; each new word pushes it out.
        case tellIfSilent(Tell, after: TimeInterval)
    }

    /// What came back to a query.
    enum Answer: Equatable {
        case silence
        case holdsPumpButCannotReach
        /// The other device says it does not hold the pump.
        case holdsNothing
        /// Anything else: the other device is there, and its message is acted on where it lands.
        case answered
    }

    /// The one rule for answers. Silence means the other device is not looping; so does "I hold it but cannot reach
    /// it" and "I hold nothing" (without the last, a phone would leave the pump with nobody).
    static func afterQuery(_ answer: Answer, onSilence: Decision) -> Decision {
        switch answer {
        case .holdsNothing,
             .holdsPumpButCannotReach,
             .silence: return onSilence
        case .answered: return .nothing
        }
    }

    /// The watch's report is overdue after this long without one: one loop cycle and a margin.
    static let watchReportOverdue: TimeInterval = 6 * 60

    /// How long a takeover has to reach the pump, for a grant and for a start without the phone alike.
    static let takeoverLease: TimeInterval = 60

    /// With no session running, the watch warns when it has heard nothing from the phone for this long: after the
    /// phone's own Not Looping alert (20 min), as the backup for a dead phone.
    static let notHearingFromPhoneWarning: TimeInterval = 25 * 60

    // MARK: - The decisions, row by row

    static func decide(_ s: Situation) -> Decision {
        switch (s.device, s.trigger) {
        // Rows 1 and 2 · Start tapped on the watch. The request is the query. The phone answers with a grant.
        // With no answer, the phone is away or dead; starting from the standing copy enters Watch Loop, which needs
        // the looper's tap, so it is offered. Without a CGM reading of its own there is nothing to dose from.
        case (.watch, .startTapped):
            guard s.watchReadsCGM else { return .query(.onScreen, onSilence: .tell(.noResponseFromPhoneAndNoCGM)) }
            return .query(
                .onScreen,
                onSilence: s.watchHasStandingCopy ? .prompt(.startWithoutPhone) : .tell(.noResponseFromPhone)
            )

        // Row 3 · The phone is dead or away and no session runs. Taking the pump would enter Watch Loop without a
        // tap, and the watch cannot tell a dead phone from one left at home: the looper is told once the phone has
        // been silent for 25 minutes. Each word from the phone pushes the warning out.
        case (.watch, .phoneHeardWithNoSession):
            return .tellIfSilent(.notHearingFromPhone, after: notHearingFromPhoneWarning)

        // Row 4 · A clean reading: the resting state carries on.
        // Rows 5 and 18 · A reading shows insulin the phone's records cannot explain, so another device controlled
        // the pump. The insulin is booked regardless (in the ledger). The phone already holds the pump, so asking
        // can only end with it standing aside (the watch says it holds a session, row 17) or keeping the pump.
        case let (.phone, .pumpReading(beyondBand)):
            guard beyondBand, s.phoneRole == .holdsPump, s.standingCopyOut else { return .nothing }
            return .query(.inBackground, onSilence: .keepPumpOnSilence)

        // Rows 6, 12, 16, 17 and 19 · The watch says it holds the pump.
        case let (.phone, .watchClaims(claim)):
            switch claim.session {
            // Rows 6 and 12 · A session the phone has ended: the watch missed the stop, so it gets it again.
            case .closed:
                return s.phoneRole == .holdsPump ? .sendStop : .nothing
            // Row 16 · The watch reporting on the live session is still there, unless it says it cannot reach the
            // pump (row 14), which is not renewed. A session the phone stood aside for (row 17) is renewed alike.
            case .current:
                let holds = s.phoneRole == .lending || s.phoneRole == .standingAside
                return holds && claim.pumpReachable != false ? .renewHold : .nothing
            case .newer:
                guard s.phoneRole == .holdsPump else { return .nothing }
                // Row 19 · A watch back from off claiming a session started before this phone took over on silence.
                // The watch was out of the conversation: standing aside would move control, silently, to a device
                // the looper stopped using. The takeover stands; a session started after it is a fresh Start.
                if claim.refusedBefore || startedBefore(claim.startedAt, s.tookOverOnSilenceAt) {
                    return .sendStop
                }
                // Row 17 · A watch that started without the phone and is alive: the looper's latest decision was
                // that Start; the phone's return is not a decision.
                return s.standingCopyOut ? .standAside : .nothing
            }

        // Rows 7, 8 and 21 · End tapped on the watch. The hand-back offer is the query. With no answer the End is
        // refused: it names an action that needs the phone.
        case (.watch, .endTapped):
            return .query(.onScreen, onSilence: .refuse(.phoneAwayCannotHandBack))

        // Row 9 · Take Back tapped on the phone: the looper's latest decision; no query needed.
        case (.phone, .takeBackTapped):
            return .takeOnTap

        // Rows 10 and 14 · No report from the watch for longer than a cycle, with the phone beside the body. A live
        // watch answers within seconds; silence (or "cannot reach the pump") means it is not looping, and looping
        // conservatively is safer than not looping.
        // Rows 11 and 15 · The phone does not see the sensor: the body is elsewhere, nothing to act on.
        case (.phone, .watchReportOverdue):
            guard s.sensorFresh, s.phoneRole == .lending || s.phoneRole == .standingAside else { return .nothing }
            return .query(.inBackground, onSilence: .takeOnSilence(.watchNotResponding))

        // Rows 12, 13 and 19 · The watch back from off asks before touching the pump. A phone that holds the pump
        // answers with the stop. With no answer it is the only device there and carries on.
        case (.watch, .backFromOff):
            return .query(.inBackground, onSilence: .carryOn)

        default:
            return .nothing
        }
    }

    /// Row 19's test: a session started before this phone took over on silence. No start time: not refused.
    static func startedBefore(_ started: Date?, _ tookOver: Date?) -> Bool {
        guard let started, let tookOver else { return false }
        return started < tookOver
    }

    // MARK: - Nobody takes the pump while it is giving a bolus

    /// When a bolus under way ends, once the pump has accepted it; nil while it is being sent or cancelled.
    struct BolusUnderWay: Equatable {
        let endsAt: Date?
    }

    /// What the looper is told when the pump driver keeps the pump at a Start or an End because a command to it is
    /// unconfirmed (it refuses `releaseControl()`).
    static var unconfirmedCommandRefusal: String {
        String(localized: "The pod hasn't confirmed the last command yet. Try again in a minute.")
    }

    /// What the looper is told when a Start, an End or a Take Back meets a bolus under way.
    static func bolusRefusal(_ bolus: BolusUnderWay, now: Date) -> String {
        guard let endsAt = bolus.endsAt else {
            return String(localized: "A bolus is still being given. Try again when it has finished.")
        }
        let left = Int(max(1, endsAt.timeIntervalSince(now)).rounded(.up))
        return String(localized: "A bolus is still being given. Try again in \(left) seconds.")
    }
}
