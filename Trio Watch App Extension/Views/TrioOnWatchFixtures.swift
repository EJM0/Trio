#if DEBUG
    import Foundation

    /// Screenshot harness: `-TrioOnWatchScreen <name>` shows one screen with a fixed status. UI only; the loan host
    /// and the pump are never touched. Debug builds only.
    struct TrioOnWatchFixture {
        enum Screen {
            case main
            case status
            case start(WatchLoanStartFacts?)
            case handOff(HandOffKind)
            case endConfirmation
            case bolus(Decimal, carbsSaved: Bool)
            case doses
            case carbsSaved
            case adjustment
        }

        var screen: Screen
        var status: TrioOnWatchStatus
        /// Row or section id the status page scrolls to: "+pump" or "+actions" after the name.
        var scrollTo: String?
        /// The tethered main page with a fresh phone snapshot.
        var tetheredFresh = false

        @MainActor static let current: TrioOnWatchFixture? = {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-TrioOnWatchScreen"), index + 1 < arguments.count else { return nil }
            let parts = arguments[index + 1].split(separator: "+").map(String.init)
            var fixture = named(parts[0], now: Date())
            fixture?.scrollTo = parts.dropFirst().first
            return fixture
        }()

        // swiftlint:disable:next function_body_length cyclomatic_complexity
        @MainActor static func named(_ name: String, now: Date) -> TrioOnWatchFixture? {
            func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
            func ahead(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

            var holding = TrioOnWatchStatus()
            holding.phase = .inControl
            holding.lastLoopAt = ago(2)
            holding.lastCycleAt = ago(2)
            holding.readings = [.init(date: ago(3), mgdl: 112), .init(date: ago(8), mgdl: 109)]
            holding.iob = 1.25
            holding.cob = 12
            holding.pumpLastContact = ago(2)
            holding.reservoir = 86
            holding.podEndsAt = ahead(27)
            holding.sensorEndsAt = ahead(52)
            holding.override = .init(name: "Exercise", endsAt: ahead(1.5))
            holding.recentDoses = [
                .init(date: ago(4), units: 1, isAutomatic: false, isUnconfirmed: true),
                .init(date: ago(35), units: 0.3, isAutomatic: true),
                .init(date: ago(95), units: 2.5, isAutomatic: false)
            ]

            var idle = TrioOnWatchStatus()
            var stopped = holding
            stopped.phase = .stopped(.superseded)
            stopped.lastLoopAt = ago(14)

            let facts = WatchLoanStartFacts(
                override: .init(name: "Exercise", startedAt: ago(30), endsAt: ahead(1.5)),
                tempTarget: nil,
                podEndsAt: ahead(3.2),
                sensorEndsAt: ahead(52)
            )

            switch name {
            case "main-phone": return .init(screen: .main, status: idle)
            case "main-phone-fresh": return .init(screen: .main, status: idle, tetheredFresh: true)
            case "main-pod-stopped":
                holding.podFaulted = true
                return .init(screen: .main, status: holding)
            case "main-suspended":
                holding.insulinSuspended = true
                return .init(screen: .main, status: holding)
            case "main-pod-unreachable":
                holding.podUnreachable = true
                return .init(screen: .main, status: holding)
            case "main-bolus-paused":
                holding.insulinPaused = true
                return .init(screen: .main, status: holding)
            case "main-starting":
                idle.phase = .starting
                return .init(screen: .main, status: idle)
            case "main-in-control": return .init(screen: .main, status: holding)
            case "main-no-loop-yet":
                holding.lastLoopAt = nil
                return .init(screen: .main, status: holding)
            case "main-loop-late":
                holding.lastLoopAt = ago(12)
                return .init(screen: .main, status: holding)
            case "main-ending":
                holding.phase = .ending
                return .init(screen: .main, status: holding)
            case "main-stopped": return .init(screen: .main, status: stopped)
            case "status-phone": return .init(screen: .status, status: idle)
            case "status-starting":
                idle.phase = .starting
                return .init(screen: .status, status: idle)
            case "status-waiting-reading":
                holding.phase = .waitingForReading
                holding.lastLoopAt = nil
                return .init(screen: .status, status: holding)
            case "status-in-control": return .init(screen: .status, status: holding)
            case "status-phone-away":
                holding.phoneReachable = false
                holding.battery = 0.22
                return .init(screen: .status, status: holding)
            case "status-pod-unreachable":
                holding.podUnreachable = true
                holding.lastCycleAt = ago(1)
                holding.lastLoopAt = ago(9)
                return .init(screen: .status, status: holding)
            case "status-suspended":
                holding.insulinSuspended = true
                return .init(screen: .status, status: holding)
            case "status-stopped": return .init(screen: .status, status: stopped)
            case "start-facts": return .init(screen: .start(facts), status: idle)
            case "start-indefinite-override":
                var indefinite = facts
                indefinite.override?.endsAt = nil
                return .init(screen: .start(indefinite), status: idle)
            case "start-no-answer": return .init(screen: .start(nil), status: idle)
            case "handoff-starting":
                idle.phase = .starting
                return .init(screen: .handOff(.start), status: idle)
            case "handoff-waiting-reading":
                holding.phase = .waitingForReading
                return .init(screen: .handOff(.start), status: holding)
            case "handoff-started": return .init(screen: .handOff(.start), status: holding)
            case "handoff-refused":
                idle.lastAlert = .startRefused(.indefiniteOverride)
                return .init(screen: .handOff(.start), status: idle)
            case "handoff-not-closed-loop":
                idle.lastAlert = .startRefused(.notClosedLoop)
                return .init(screen: .handOff(.start), status: idle)
            case "handoff-no-answer":
                idle.lastAlert = .phoneDidNotAnswer
                return .init(screen: .handOff(.start), status: idle)
            case "handoff-ending":
                holding.phase = .ending
                return .init(screen: .handOff(.end), status: holding)
            case "handoff-end-refused":
                holding.lastAlert = .endRefused(.bolusRunning)
                return .init(screen: .handOff(.end), status: holding)
            case "end-confirmation": return .init(screen: .endConfirmation, status: holding)
            case "bolus-sending":
                holding.bolus = .requested
                return .init(screen: .bolus(1, carbsSaved: false), status: holding)
            case "bolus-accepted":
                holding.bolus = .accepted
                return .init(screen: .bolus(1, carbsSaved: false), status: holding)
            case "bolus-delivering":
                holding.bolus = .delivering
                return .init(screen: .bolus(1, carbsSaved: false), status: holding)
            case "bolus-done":
                holding.bolus = .done
                return .init(screen: .bolus(1, carbsSaved: true), status: holding)
            case "bolus-cancelled":
                holding.bolus = .cancelled
                return .init(screen: .bolus(1, carbsSaved: false), status: holding)
            case "bolus-failed":
                holding.bolus = .failed(String(
                    localized: "This would go over your max IOB of \(TrioOnWatchRules.insulin(5)).",
                    comment: "Watch bolus refusal; the value is an amount of insulin with its unit"
                ))
                return .init(screen: .bolus(2, carbsSaved: false), status: holding)
            case "bolus-uncertain":
                holding.bolus = .uncertain
                return .init(screen: .bolus(1, carbsSaved: true), status: holding)
            case "recent-doses": return .init(screen: .doses, status: holding)
            case "carbs-saved": return .init(screen: .carbsSaved, status: holding)
            case "override-sheet": return .init(screen: .adjustment, status: holding)
            default: return nil
            }
        }
    }
#endif
