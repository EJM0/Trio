# Target architecture (v1)

Status: proposed 2026-11-16, pending review. Scope: `requirements-and-scope.md`. Decisions: `architecture-decisions.md`. Details: `state-and-synchronization.md`, `lifecycle-and-execution.md`.

## 1. Shape in one paragraph

The phone lends the pod and the G7 to the watch: a **loan**. One shared, pure state machine decides every loan transition on both devices. Each device persists its loan state before it acts on it. The watch compiles Trio's existing oref Swift code and runs it each G7 reading, through the same pure entry point the phone uses (`OrefRun`), on inputs it holds locally (grant snapshot plus its own records). Pump and CGM drivers move between devices through LoopKit's existing `ExclusiveDeviceControl` / `DeviceConfigurationSharing` (LoopKit#626, already in Trio's pin). OmnipodKit gets those through loopandlearn/OmnipodKit#177. There is no parallel architecture on the phone: APSManager, DeviceDataManager and the stores stay as they are, plus one gate and one coordinator.

## 2. Components

| Component | Where | New or changed | Responsibility |
|---|---|---|---|
| `OrefInputs` + `OrefRun` | `Trio/Sources/APS/OpenAPSSwift/` (shared: phone, watch, AlgorithmPackage) | New, extracted from `OpenAPS.determineBasal` / `createProfiles` / `autosense` | Pure function: inputs → profile → autosens → IOB → meal → determination. The phone's `OpenAPS` gathers the inputs from Core Data and JSON as today, then calls it. Parity goldens stay byte-exact. |
| `WatchLoan` (state machine, messages, records) | `Trio/Sources/APS/WatchLoan/` (shared) | New | `WatchLoan.decide(state, event, context) -> (state, [Effect])`. No IO. Codable messages with protocol version, epoch and message id. Record types: dose, carb, glucose, pump event, with stable sync identifiers. |
| `WatchLoanGate` | phone, `Trio/Sources/APS/` | New, small | `phoneMayCommandPump` from the persisted phone loan state. It fails closed: if the state is unreadable, it answers false. Checked by `APSManager.loop`, `enactBolus`, `enactTempBasal`, `cancelBolus`, and every DeviceDataManager path that commands the pump. |
| `WatchLoanCoordinator` (phone) | `Trio/Sources/Services/WatchManager/` | New | Lend: preconditions, cancel the running temp, release control, export, snapshot, grant. Take back: merge records, take control, odometer audit, resume. Uses `AppleWatchManager`'s WCSession, with no second session. |
| Watch loan host | `Trio Watch App Extension/Loan/` | New | Adopts the pump and CGM managers from the grant. Persists the loan state and records (JSON files, atomic writes). Runs the loop on each reading. Schedules dead-man notifications. Streams records. |
| Watch UI | `Trio Watch App Extension/Views/` | Changed (F's G1–G11) | Control indicator, Start/End, status page, bolus progress, hand-off confirmation. |
| Phone UI | Home + Settings | Changed, minimal | "Apple Watch is in control" banner with Take Back. Pump actions disabled with a reason. |

## 3. Device ownership (SR-1..SR-3)

- **Phone states:** `home(epoch)`, `lending(epoch)`, `lent(epoch)`, `takingBack(epoch)`. **Watch states:** `idle`, `requesting`, `holding(epoch)`, `returning(epoch)`, `stopped(epoch, reason)`.
- **Who may command:** only phone `home` and watch `holding` with the current epoch. Every other state means zero commanders.
- **Release before acquire:** the phone persists `lending(e+1)`, cancels the running temp, calls `releaseControl()` and verifies `isControlReleased`, then exports and sends the grant. The watch persists `holding(e+1)` and only then calls `takeControl()`.
- **Hand-back:** the watch releases first and persists `returning`. The phone takes control only after it has persisted the records.
- **No autonomous takeover.** Timeouts produce messages to the user, never ownership.
  - A grant the watch never confirms leaves the phone in `lending`. It shows "Apple Watch didn't confirm" with Take Back.
  - Take Back is a user tap. It bumps the epoch, takes control (a fresh EAP handshake on the pod), audits the odometer, and resumes.
- **Stale watch:** a watch that sees a higher epoch (message) or a foreign pod session (OmnipodKit#177 SQN-resync detection) stops all pump commands at once, persists `stopped`, and alerts.

## 4. Grant snapshot (SR-5, SR-19, SR-20)

The grant contains:
- the protocol version, app build and per-kit state schema identifiers;
- phone time and time zone;
- the pump `rawState` export and the G7 `SharedDeviceConfiguration`;
- the `OrefInputs` sources: settings, preferences, profile inputs, basal, ISF, CR and targets, active override and temp target with their end times, TDD history for DynISF, and 24 h of glucose, pump events and carbs (with deletions excluded);
- the pod odometer reading at release.

The watch refuses the grant if any part is missing, the versions differ, the clock offset is over 60 s, or the time zone differs.

## 5. Loop cycle on the watch (SR-7, SR-11, SR-12, SR-14, SR-24)

On each G7 reading (wake: `WKBluetoothAlertRefreshBackgroundTask`, ADR-002):
1. Restore checklist: `holding` with the current epoch, no unresolved dose intent, pump status fresh, glucose fresh (12 min, same rule as `APSManager`).
2. Read pump status through the kit (`ensureCurrentPumpData` equivalent).
3. Build `OrefInputs` from the snapshot plus local records. Run `OrefRun`.
4. Refuse insulin-adding commands while delivery is uncertain or a write-ahead intent is unresolved (Trio-level gate, SR-11). Suspends and reductions stay allowed.
5. Persist the dose intent, then enact the temp basal and SMB through the `PumpManager`.
6. Persist the outcome and the pump events. Reschedule the dead-man notifications. Queue a record batch to the phone.
7. Complete the background task.

Manual bolus and carbs on the watch go through `BolusSafetyValidator` with the watch's own IOB. They carry an id and are persisted as an intent before transmit.

## 6. Phone during a loan

- `WatchLoanGate` blocks every pump command path, Take Back excepted. The UI shows why.
- The phone keeps reading the G7 and keeps its glucose alarms.
- `NotLoopingMonitor` doesn't fire for the phone's own loop. Instead the phone alerts when the watch is reachable but has sent no record for 20 min (SR-15).
- Overrides, temp targets, settings, remote commands, Shortcuts and watch-remote boluses are refused with a reason (F-5).
- Records from the watch are merged by sync identifier (SR-6). Nightscout upload continues for what the phone has stored.

## 7. Platform seams (only what the watch build needs)

- The watch target compiles `OpenAPSSwift` and its models, `WatchLoan`, and the record types. It links `LoopKit-watchOS`, `OmnipodKit-watchOS` (#177) and `G7SensorKit-watchOS`.
- Watch Info.plist: `bluetooth-central`. Entitlements: time-sensitive notifications. Deployment target watchOS 10.6 (the LoopKit-watchOS requirement).
- No UIKit is moved and no iOS service is ported. The watch does not compile `APSManager`, `DeviceDataManager`, `CoreDataStack` or Swinject assemblies. Its host is small, and the shared pieces are pure.

## 8. Alerts on the watch (SR-15, SR-16)

- **Dead-man:** pre-scheduled local notifications at +20 and +40 min after the last successful cycle, moved forward every cycle. They fire even if the app never wakes again.
- **Glucose:** urgent low and low, using the phone's alarm thresholds from the snapshot. Time-sensitive level (the watch has no critical alerts, as in Loop).
- **Kit alerts:** pump and CGM alerts issued by the kits, through a minimal watch `AlertIssuer`.

## 9. What this deliberately does not do

It does not add an offline start, a forced takeover from the watch, watch-side Nightscout, settings sync, a Core Data stack on the watch, workout sessions, or support for more than one pump or CGM. See `requirements-and-scope.md`.

## 10. Testing

- **Unit (Swift Testing, TrioTests):** `WatchLoan.decide` decision table, with one test per transition and a crash or message loss at each hand-off step. Also: snapshot completeness, merge by identifier, the gate on every phone pump path, the clock and version gates, and the uncertain-delivery gate.
- **Parity:** existing goldens through `OrefRun` (phone). The same fixture through the watch input builder gives an identical determination.
- **Build:** the watch target for the watchOS simulator and `arm64_32` device.
- **Simulator:** the watch host with a test pump double that fails the test if two commanders exist.
- **Hardware (owner: maintainer):** D's E1 (TestFlight upload), E2 (24 h G7 wake count), E5 (a DASH exchange fits the wake window), and in-vitro DASH hand-off tests. Untethered use stays disabled behind a build flag until E2 passes (SR-17).

## 11. Build flag

`TRIO_ON_WATCH` (xcconfig, off by default). When it's off, no loan UI is shown and the phone never lends. This keeps experimental code from reaching users who build `dev`.

---

## v2 amendments (2026-11-16, after the review round)

These amendments take precedence over §1–§11 wherever they conflict. Superseded text is kept above for the record. Source findings: `reviews/arch-review-{C,D,A2-kits}.md`, `safety/safety-review.md` (SB/SM), `reviews/design-reviews.md` (G), `design/ux-guidelines.md` (A-n). Maintainer decisions: ADR-004 to ADR-008.

### A. Hand-off and ownership

| # | Amendment | Resolves |
|---|---|---|
| V2-1 | `request` carries a `requestID`. The grant echoes it and carries `expiresAt` (phone time + 30 s, checked against the measured clock offset). The grant goes by `sendMessage` only, so a reachable session is required. The watch accepts a grant only while `requesting` with a matching id and before it expires. Otherwise it answers `grantRejected` and never adopts. Take Back cancels all outstanding WatchConnectivity transfers. | SB-1 |
| V2-2 | Lend order: the phone persists `lending` (gate closes), waits for any in-flight loop, pump-event storage and bolus to finish, cancels the temp, calls `refreshDeliveredUnits()`, then `releaseControl()`. It then reads `isControlReleased` at once; `false` means refused, back to `home`, and the reason is shown. A running bolus refuses Start. | A2-2/3, SM-12 |
| V2-3 | End order on the watch: persist `returning`, cancel the temp, `refreshDeliveredUnits()`, `releaseControl()`, check `isControlReleased`, send `handBack`. On relaunch, `returning` calls `releaseControl()` again before anything else. End preconditions: as Start's (no bolus, no unconfirmed command, delivery certain). | SM-20, A2-3 |
| V2-4 | Watch adoption: `OmniPumpManager(adopting:localState:)` once. After that, persist the manager's `rawState` and rebuild only from it, never from the grant again. Never keep two Omnipod or two G7 managers alive at once, and let the old one deinit first. No CGMBLEKit on the watch. | A2-3/5, D-13 |
| V2-5 | G7 is **shared**, not lent. The phone keeps reading it, and the watch adopts the configuration in the watch slot. The watch calls `recheckAcquisition()` on wakes the sensor didn't cause. | A2-4 |
| V2-6 | Kit layer: a Trio-local OmnipodKit branch on #177 @ `3d21d9c` adds one rule. After an unexpected foreign session (SQN resync not caused by this device's own adopt or take), refuse insulin-adding commands and report it to the host through the pump manager status or delegate. The watch host then persists `stopped(foreignSession)` and alerts. The change is proposed upstream to #177 (ADR-007). | A2-6 (blocker) |
| V2-7 | Take Back (phone, user tap): cancel outstanding WC transfers, persist `takingBack(e+1)`, `takeControl()`, audit, persist `home(e+1)`. Until the watch acknowledges `stopped`, or 6 h pass: re-audit the odometer every cycle. Any unexplained insulin above tolerance switches the phone to reductions-only (the existing dosing-mode clamps, derived at call sites), and the user is alerted "Apple Watch may still be dosing". In `lending`, Take Back first asks the watch over `sendMessage`. If the watch answers, the dialog points to End. | SB-2, A-8 |
| V2-8 | Odometer audit: expected = scheduled basal over the interval (basal profile, minus suspended spans) + booked temps (replacing scheduled during their span) + booked boluses, all since the release reading. Excess above one pulse + 0.15 U is booked as an audit bolus, tagged, and shown in History with a notice. The audit bolus is **recomputed** whenever late records arrive. A shortfall gets a notice only. | SM-3, SM-4, Q-1 |
| V2-9 | Imported watch doses are stored as finalized events only. A running temp is reported as status and stored once it ends, so the phone driver's `replacePendingEvents` can't purge it. Merge goes through the existing `storePumpEvents` / glucose / carbs stores (no second merge path). Records reuse `NewPumpEvent`, `BloodGlucose`, `CarbsEntry`. | SM-11, C-08 |
| V2-10 | Stop and revoke use a minimal envelope that is parsed regardless of protocol version. | SM-9 |
| V2-11 | Watch relaunch in `holding`: run the restore checklist, ask the phone over `sendMessage` if it's reachable. Resume only if within 6 h of the last cycle and the pod session shows no foreign controller (V2-6). Otherwise persist `stopped` and alert. | SM-10, A-6 |

### B. Alerts and no-dosing states

| # | Amendment | Resolves |
|---|---|---|
| V2-12 | Invariant, with a test: every state in which no device may dose has a not-looping alarm pending on at least one device. The phone's `NotLoopingMonitor` stays armed in every phone state except `lent`. The watch arms its not-looping series as it persists `holding`, before the first cycle. | G-1, SM-5 |
| V2-13 | Watch not-looping series: 20, 40, 60, 80, 100 and 120 min, the same as the phone's. Moved forward only when a cycle confirms pump state. Time-sensitive level. Copy doesn't claim it breaks through Silent or Focus. | A-2, D-9, SM-7, G-6 |
| V2-14 | In `lent` the phone alerts when no record batch has arrived for 30 min, keyed on the last batch received, not on `isReachable`. Title: "No updates from Apple Watch". | D-10, SM-6, G-6 |
| V2-15 | Unreadable loan state on the phone closes the gate and raises an alert. | SM-16 |
| V2-16 | Glucose alarms on the watch: the grant carries the user's configured glucose alarm settings. The watch evaluates them with the same shared, pure alarm evaluation as the phone (ADR-006). Snooze is not the first notification action. | G-11, G-5 |
| V2-17 | Bluetooth budget errors ("near limit" or "exceeded") raise "Open Trio on your watch to keep it looping". | D-4 |
| V2-18 | Watch battery below 20 % raises a warning; below 10 % raises a time-sensitive "Trio on Watch will stop soon" with End or Take Back guidance. Below 30 %, Start is refused. Start is also refused when watch notifications aren't allowed, or on a model older than Series 6 or SE 2. | A-3, A-7, D-12 |

### C. Watch loop

| # | Amendment | Resolves |
|---|---|---|
| V2-19 | The cycle is driven by the CGM manager's new-reading callback. Every background task the app receives is completed. One handler style is used. | D-3 |
| V2-20 | Watch guards are the phone's: at least 3 readings in the last hour, latest reading 12 min old at most, pump not suspended, F8 handled as on the phone (fallback not enacted). Write-ahead intent and kit `rawState` are written synchronously with `.atomic`. A write failure means no command and an alert. | SM-18, SM-19, SR-13 |
| V2-21 | No SMB from a background wake until hardware run E5 shows a command fits the wake window. Temp basals only; SMB is allowed while the app is in the foreground. Implemented as a constant, not a user setting. | D-5 |
| V2-22 | Watch file protection: `completeUntilFirstUserAuthentication` for the loan files and kit keychain items. | D-8 |
| V2-23 | Time zone: oref inputs carry an explicit `timeZone`. The phone passes `TimeZone.current`, which is identical to today; the parity goldens prove it. The watch passes the grant's time zone for the whole loan (ADR-004). | SM-22 |
| V2-24 | Manual bolus on the watch: a pure bolus calculator, extracted from `BolusCalculationManager` like `OrefRun` (ADR-005). Then `BolusSafetyEvaluator` (pure) runs with IOB recomputed at confirmation. Shown states: requested, accepted, delivering, done, cancelled, failed, uncertain. Uncertain offers no retry and links to a small recent-doses list. | C-07, SM-13, A-4, G-3 |
| V2-25 | Watch controls while in control: Suspend and Resume insulin, and Cancel the active override or temp target. Creating or editing them stays phone-only, after End. | SM-8, A-1 |
| V2-26 | Start shows the active override and temp target, and refuses an indefinite override. It warns when the pod or sensor ends within 6 h. It tells caregivers that Nightscout updates and remote commands pause until End. | A-1, A-5, G-8 |

### D. Phone gate (three layers)

V2-27 replaces §2's gate row and resolves C-05 and C-10:
1. **Trio code:** `WatchLoanGate` is checked in `APSManager` (loop, `enactBolus`, `enactTempBasal`, `cancelBolus`, `cancelAutomaticTempBasal`) and in `DeviceDataManager` (heartbeat pump refresh and BLE heartbeat, `syncDeliveryLimits` at launch and from settings, basal schedule sync, pump alert acknowledgement). TDD calculation skips a released pump.
2. **UI:** pump settings and setup screens can't be opened while the phone isn't owner.
3. **Kit:** OmnipodKit refuses every session while released (A2, verified in #177).

The gate never sets `pumpManager` to nil. The gate, the persisted loan state and Take Back compile and run whether or not `TRIO_ON_WATCH` is set (D-2).

### E. Platform and process

| # | Amendment | Resolves |
|---|---|---|
| V2-28 | `bluetooth-central` and the watch entitlements are added only when `TRIO_ON_WATCH` is set, through a separate xcconfig/plist variant, until E1 shows TestFlight accepts them. | D-1 |
| V2-29 | Kit pins: LoopKit = `babddf04` + LoopKit#687 only. OmnipodKit = #177 @ `3d21d9c` + the V2-6 patch. G7SensorKit unchanged. These are local branches in the submodules, to be mirrored to loopandlearn by the maintainer (ADR-003 amended). | A2-1 |
| V2-30 | Overlap with open PR #1749 (watch target, LoopKit and G7 on the watch, Info.plist): implement the minimum here and rebase onto #1749 if it merges first. #1648 and #1775 ideas are reused by design, not by code. The complication comes from #1723 once merged (ADR-008). | C-06, G-9 |
| V2-31 | Logging for hardware runs: process and launch state, every background task (start, expiry, completion), BLE events and error codes per role, CGM latency and gaps, cycle phase timings, command state and wake-to-command time, dead-man reschedules, WC sends, and a daily summary. Per CONTRIBUTING, with no health data. | D (instrumentation), SR-26 |
| V2-32 | Hardware milestone M8 (maintainer): E1, E2, E5 and in-vitro DASH hand-off. The flag stays off for users until E2 passes (SR-17). | SM-27, D-16 |

### V2-7b (2026-11-16, maintainer review). Supersedes V2-7

V2-7's per-cycle re-audit and the switch to reductions-only are dropped. They put a mode switch on top of oref, which Trio doesn't do. Unexplained insulin is a history problem: book it, and oref's IOB handles it. The kit (V2-6/R-4) is what stops a stale watch, not a phone mode.

Take Back (phone, user tap):
1. Cancel the outstanding WatchConnectivity transfers. Persist `takingBack(e+1)`.
2. `takeControl()`.
3. Cancel the running temp (R-1).
4. `refreshDeliveredUnits()`.
5. Run one audit, which counts the undelivered remainder of a bolus under way (R-2). Book the excess as a tagged audit bolus.
6. Persist `home(e+1)` and resume normal looping.

The audit bolus is recomputed whenever late watch records arrive (V2-8).

Stale watch: with V2-6/R-4, a watch that contacts the pod after Take Back sees the foreign session and refuses every program command. If the phone's kit later sees a foreign session itself (the stale watch's handshake), the phone treats it as follows:
- It alerts: "Apple Watch contacted your pod after you took it back".
- It runs the audit again and books any excess.
- It keeps looping. Its own commands are not blocked by a peer session it has already superseded with a higher epoch.

**Open, for A2 (M2b):** the kit rule must tell "foreign session after I took control by a deliberate takeover" (phone: audit + alert, keep commanding) apart from "foreign session while I believed I was the only holder" (refuse). The host passes that context.

R-5 / N-3, same principle: a write-ahead intent the kit has no record of is resolved through the odometer. If it can't be resolved, the intended dose is booked as delivered (IOB errs high) and the user is alerted. There is no reductions-only mode.

### v3 amendments (2026-11-16, after issue #1784 field evidence)

Source: `research/kristinkand-test-log-1784.md` (184 field tests on a different implementation; treated as evidence, not specification).

| # | Amendment | Resolves |
|---|---|---|
| V3-1 | Record batches and hand-back records from an earlier epoch (for example a loan the phone gave up on) are still merged by sync identifier. Only control messages are ignored by epoch. The odometer audit stays the backstop. | P1 |
| V3-2 | watchOS runtime rules for the watch host. No work on the main thread. Complete every background task within its budget, and never stretch a WatchConnectivity refresh task. Hold background time for each whole cycle and release it on every path. | P3 |
| V3-3 | Fixed-width integers (Int64) for every timestamp, epoch, sequence, counter and checksum on the watch path. Build and test for `arm64_32`. | P4 |
| V3-4 | Holding with no pod contact for about 5 min triggers a time-sensitive "Can't reach your pod. Open Trio on your watch." notice, deduplicated. | P2 |
| V3-5 | Every pod and CGM connect attempt is logged with the app state, the time until the drop, and the error. | P5 |
| V3-6 | Audit guards: if the pod is faulted, or its counter goes down, the audit books nothing and raises an alert. | P6 |
| V3-7 | During a loan the phone doesn't upload its stale pre-loan IOB or loop status to Nightscout. | P7 |
| V3-8 | Start keeps the watch app in front until the first watch-side G7 reading after adoption. | P9 |
| V3-9 | ADR-002's "Known conflict" is reworded: field evidence shows hundreds of Bluetooth wakes a day with no workout session, but a Trio complication was on the watch face in those tests. E2 runs with and without a complication. The decision stands. | ADR-002 |
