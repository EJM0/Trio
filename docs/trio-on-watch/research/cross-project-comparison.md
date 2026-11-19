# Cross-project comparison

Phase 2 consolidation, 2026-11-16. Sources: the six research deliverables in this folder plus `../safety/failure-mode-analysis.md` and `../design/trio-design-language.md`. Claims carry the evidence of the source doc; orchestrator checks are marked **[O-verified]**.

## Executive summary

1. **The platform is the deciding constraint, not the code.** Apple documents a hard budget of five background-scan or timely-alert (GATT notification) wakes per rolling 24 h for watch apps, refreshed only when the user opens the app **[O-verified, Apple doc "Using background tasks", section "Communicate over Bluetooth"]**. A 5-min CGM loop needs 288 wakes a day. On the public platform, a 24/7 unattended watch loop is only plausible inside an `HKWorkoutSession`, which the brief wants to avoid, which Apple calls a review risk, and which ends when the user starts a real workout.
2. Loop's Sport Mode (LoopKit/Loop#2545, draft) removed its workout keepalive in Oct 2026 and relies on Bluetooth alert wakes **[O-verified: no `HKWorkoutSession` / `WKExtendedRuntimeSession` at `jeremybarnum/Loop` 5aeb4703; `WKBluetoothAlertRefreshBackgroundTask` in `WatchApp Extension/ExtensionDelegate.swift:158-220`]**. That conflicts with Apple's documented budget. Either the budget is not enforced as written for retained connections, or Sport Mode works only in bounded or user-touched sessions. No source has data that settles this; a 24 h hardware run (D's E2) does.
3. Every source agrees on the hand-off safety core: one pump owner, release before acquire, no hand-off while a pod command is unconfirmed, the pod's delivered-units odometer books unexplained insulin so IOB errs high, and no silent takeover. The experimental branch breaks the last rule (phone retakes after lease expiry) and the "unconfirmed" rule (kit fork releases unconditionally).
4. Most of the kit groundwork is upstream already: LoopKit#626 (hand-off protocols, `LoopKit-watchOS`) and G7SensorKit#80 (watch acquisition) are in Trio's current pins. The missing piece is OmnipodKit: loopandlearn/OmnipodKit#177 (jeremybarnum, open) adds the watchOS target and pod lending. Kristin's kit forks are not needed.
5. On the Trio side, the oref Swift port compiles for watchOS as is (C, scratch build). The iOS coupling in the loop path is small and named. No parallel architecture is required.
6. Independent of the watch: the baseline has dosing defects that should be fixed first (repeat-SMB path, watch bolus without max-bolus/idempotency checks, uncertain delivery not gated in Trio). See "Upstream issues".

## Comparison

| Area | Upstream Trio (ad6c66876) | Experimental Trio (a56170dc0) | Loop Sport Mode (#2545 @ 5aeb4703) | Consequence / recommendation |
|---|---|---|---|---|
| Application architecture | Watch app is a remote; all logic on phone. 28 watch files, no frameworks, no App Group, no background modes (C §targets) | Two watch god-object files (5.4k lines) + 2.3k-line phone manager; second G7 BLE stack copied into the watch (A1 §7, A2 §3) | Loan engine in Loop + watch extension; phone stays the data home (B) | Compile Trio's existing APS, storage and algorithm code for watchOS behind small platform seams. No copied stacks, no god objects. |
| Algorithm execution | Swift oref (`OpenAPSSwift`), Foundation only; compiles for watchOS (C §4) | Shared `OrefPipeline` refactor of phone dosing code, no old-vs-new parity test (A1 §9) | LoopAlgorithm on watchOS; not reusable by Trio (B) | Reuse oref unchanged. Any extraction needs the parity harness (`TrioTests/OpenAPSSwiftTests/Parity`). |
| State / authority | Single device; one-loop-at-a-time actor (E FM-07) | `UntetheredSession` state machine: epochs, 120 s lease, prepare/commit; phone retakes ~3 min after silent lease (A1 §2-3) | `LoanControl.decide`, 27 documented cases, one test each; watch never takes from a dead phone without a tap (B) | Adopt Loop's rule set as the reference design (E SR list matches it independently). Reject automatic retake. |
| Persistence | Core Data in app container; settings JSON; `PumpManagerState.plist` via rawState (C §6) | 24 h history in one JSON file on watch; versioned records + 30-min bucket checksums (A1 §1) | Watch uses its own LoopKit stores; loan history returned as one file (B) | Watch reuses Trio's Core Data stack. Persist ownership state before acting; fail closed when unreadable (A1 §12, E). |
| Pump connectivity | Phone only. No pump kit has a watchOS target (C §7) | Forked OmnipodKit; unconditional `releaseControl()`, drops `unacknowledgedCommand` on export (A2 §2) | OmnipodKit#177: refuses release while a command is unconfirmed; DASH tested, O5 untested (B, A2) | Track OmnipodKit#177. DASH only for v1. No Trio-side kit fork. |
| CGM connectivity | Phone; G7SensorKit pin has watchOS target and `G7WatchAcquisition` (B) | Framework + copied G7 stack on one watch (A2 §3) | G7 read in the watch display slot (B) | Build on #1749's framework approach (open PR). G7 only for v1. |
| Bluetooth background | iOS BLE background modes | `bluetooth-central` wakes + `performExpiringActivity` + 7-min refresh backstop; optional workout; branch reports pod-link stalls 26-311 min (A1 §5) | `bluetooth-central` + state restoration + held `WKBluetoothAlertRefreshBackgroundTask` (B) | Both rely on alert wakes that Apple caps at 5/24 h (D, O-verified). The branch's own stall reports fit the cap. Blocking risk BR-1. |
| Synchronization | Phone → watch state push; watch commands without request ID (C §8) | Idempotent record sync (A1 §12) | Odometer audit + history file at loan end (B) | Idempotent, ID-carrying commands. Reuse open #1775 ideas (idempotency, freshness window). |
| WatchConnectivity | `sendMessage` / application context; writes refused when phone unreachable | Extended message set | `sendMessage` when reachable, else `transferUserInfo`; no WC over cellular per author (B) | Keep WC for hand-off only; never assume delivery. |
| Background execution | n/a on watch | Bluetooth wakes, refresh backstop, optional workout ("Extended Untethered Mode") | Bluetooth alert wakes; workout removed Oct 2026 | See BR-1. Only workout is documented to run continuously. |
| Lifecycle / recovery | Phone-side rawState restore on launch | Sessions without max duration; heuristic auto-start from a grant up to 60 min old (A1 §6) | Phone home; loan ends on handshake | No auto-start heuristics. A loan has a bounded lifetime and a dead-man alarm (D, E SR-16). |
| Battery | n/a | Not measured | One tester's anecdotes only (B, D) | Unknown. Must be measured (D E8). |
| Safety | Guards single-device; uncertain delivery only logged (E) | Phone alarms disabled for the whole session; manual bolus silently capped to max bolus; no uncertain-delivery handling on watch (A1 §4) | Hand-off refused mid-bolus and on unconfirmed command; odometer threshold 0.20 U | E's SR-1..SR-26 are the acceptance bar. Alarms must exist on whichever device owns the pump. |
| UX | Watch shows no pump/CGM/mode state; bolus success = pump accepted (F) | ~8 new screens + complication (F) | Not assessed in detail | F's G1-G11: control indicator, separate freshness clocks, request/accept/deliver distinction; one status page, bolus progress, hand-off confirmation. |
| Accessibility | iOS good; watch VoiceOver only on snooze page, fixed font sizes (F) | Not assessed | Not assessed | Watch accessibility work is part of any new watch UI. |
| Testing | Watch tests and watchOS kit targets not in CI (C §9) | Weak "parity" tests (A1 §9) | 27 decision tests + `sportmode-sim` harness (B) | Port the decision-table testing approach; add watchOS targets to CI. Hardware runs required for BR-1. |
| Dependencies | Upstream kit pins | Personal kit forks; OmnipodKit pin not on its named branch (A2) | Open PRs across Loop/LoopKit/OmnipodKit | Depend only on upstream kit PRs. OmnipodKit#177 is a hard dependency. |
| Maintainability | — | +29.7k lines, 318/382 commits with a Claude co-author trailer (A1 §7) | +30k lines, many commits marked as Claude Code (B) | Trio's own diff must stay small; reuse is at the design level. |

## Conflicts resolved

| Conflict | Resolution | Evidence |
|---|---|---|
| D: "Loop #2545 uses a workout session" vs B: "current code uses none" | B is correct for the current head; D read stale PR text and tester reports | O-verified grep at `jeremybarnum/Loop` 5aeb4703 |
| B: Loop works via Bluetooth alert wakes vs D: wakes capped at 5/24 h | Unresolved by documents. Apple's doc states the cap; Loop's code relies on wakes. Recorded as BR-1. | O-verified Apple doc text; B evidence |
| A1: experimental phone retakes after lease vs E: never auto-takeover | E's rule stands; Loop agrees (tap required) | A1 §3, B, E |

## Blocking risks and open questions

- **BR-1 (blocking): continuous watch execution.** Without a workout, the documented budget is 5 Bluetooth alert/scan wakes per 24 h. Settle with D's E2 (24 h unattended G7 run, phone off, count wakes) and E8 (workout cost over 24 h) on physical hardware before committing to an architecture.
- **BR-2 (blocking): TestFlight upload.** Older reports say App Store Connect rejected watch apps declaring Bluetooth background mode without a restricted entitlement (D, unverified). Settle with D's E1.
- **BR-3: OmnipodKit#177 is open and moving.** Trio cannot dose from the watch without it or an equivalent.
- **Q-1:** What does a placeholder bolus booked "now" do to oref's SMB interval and most-recent-bolus logic? Safe direction for IOB; untested for SMB timing.
- **Q-2:** Critical alerts on the watch: Loop maps them down to time-sensitive; #1749 adds a critical-alerts switch.
- **Q-3:** Does the pod really accept only one BLE connection at a time? Source is a kit comment (A2).
- **Q-4:** Shared `com.OmnipodKit` restore identifier for several managers on the watch (A2).

## Upstream issues found (not watch work)

| ID | Issue | Evidence | Status |
|---|---|---|---|
| U-1 | `enactDetermination` enacts the newest determination of the last 30 min without checking `enacted`; a failed save of the new determination is swallowed, so the previous SMB can be re-sent | `APSManager.swift:783-816`, `NSPredicates.swift:102-105`, `DeterminationStorage.swift:28-37`, `OpenAPS.swift:93-101` | O-verified mechanism; failure frequency unknown |
| U-2 | Watch bolus calls `enactBolus` directly: no max bolus clamp, no `BolusSafetyValidator`, no idempotency key | `APSManager.swift:635-676`, `AppleWatchManager.swift:814, 934` | O-verified; #1648 covers part |
| U-3 | `deliveryIsUncertain` only logged in Trio | `DeviceDataManager.swift:457-459` | From E, not re-checked |
| U-4 | Stale-glucose fallback computed by oref but not enacted | `APSManager.swift:550-552` | From E, not re-checked |
