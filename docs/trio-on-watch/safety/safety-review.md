# Trio on Watch: safety review of the proposed architecture (Phase 3 gate)

Agent E, independent safety reviewer. Read-only. Reviewed `architecture/{requirements-and-scope, target-architecture, state-and-synchronization, lifecycle-and-execution, architecture-decisions}.md` and `implementation/roadmap.md` (all dated 2026-11-16). I measured them against `failure-mode-analysis.md` (SR-1 to SR-26, Q-1 to Q-28) and against code at baseline `ad6c66876`.
Contributor-facing engineering review. Not clinical guidance.

## Verdict

**Not approved as written. Approvable after the changes below.** The overall shape is right: a loan, release before acquire, no autonomous takeover, a pure decision function, oref unchanged through `OrefRun`, an odometer audit, the hand-off refused mid-bolus or on an unconfirmed command, a build flag, and a hardware gate on SR-17. It matches my independent requirements closely. But it has:

- one confirmed path to two commanders: a late grant (SB-1);
- a group of paths where insulin is lost or never booked, all around Take Back and the audit (SB-2, SM-1 to SM-4);
- several silent stops of automation (SM-5 to SM-7);
- no way to stop insulin from the watch while the phone is away (SM-8).

None of these needs a new component; each is a rule or a step-table change. BR-1, the 5-per-24-h wake budget, stays the gating platform risk. The flag must stay off until E2 passes, as ADR-002 already says.

Basis: design-document review plus code reading at the baseline. I ran nothing. The F1 fix branch (`fix/repeat-smb-on-save-failure`) was not reviewed here.

## Findings

Severity: **blocker** = a path to two commanders or unbounded insulin; must change before M3 or M4. **major** = lost or uncounted insulin, a silent automation stop, or a gate that can fail open; must change before the flag is enabled. **minor** = should change.

### Two commanders

| ID | Sev | Finding | Evidence | Required change |
|---|---|---|---|---|
| SB-1 | **blocker** | **A late grant can make a second commander.** On the watch, a request times out after 20 s and "nothing changed" (lend step 1). The phone may take longer than that before it even sends the grant: preconditions, temp cancel, and `releaseControl()`, which waits up to 20 s. Grants may also travel by `transferUserInfo` (Messages section), which delivers later with no deadline. The watch validates a grant only for completeness, versions, clock and time zone (step 6). There is no request-id match, no expiry, and no check that the watch is still `requesting`. Sequence: the phone shows "didn't confirm", the user taps Take Back (epoch e+2), then the queued grant(e+1) arrives. The watch knows only epoch e, so e+1 is "higher" and accepted. It persists `holding(e+1)` and calls `takeControl()`. Two commanders until #177 resync detection fires, if it fires before a command. | state-and-synchronization.md lend steps 1, 5, 6, Messages; loop-implementation-inventory.md §2.7 (Loop's 60 s lease); research on #177 race (experimental-kit-forks-inventory.md §4.4) | (1) A grant is valid only as the answer to the watch's own pending request: it echoes the request's `messageID`, and the watch must still be in `requesting` for that id. (2) A grant carries an expiry and is refused after it. Use a short window (for example 60 s) measured as phone `sentAt` plus the offset measured in the request round trip, not raw wall clock. (3) Grants and other control messages (grant, holding, handBack ack, revoke) go by `sendMessage` only, never `transferUserInfo`. (4) On Take Back or abandon, the phone cancels any outstanding user-info transfers. (5) Decision-table rows for "grant after timeout", "grant after Take Back" and "duplicate grant". |
| SB-2 | **blocker** | **Take Back while the watch is alive.** The "didn't confirm" state in lend step 5 offers Take Back directly, and the phone resumes looping right after the audit (Take Back step 2). If the watch is in fact holding and looping, which is exactly what a lost `holding` message produces, both devices command the pod in turn until the watch's next handshake detects the foreign session. The kit research records a race in which the watch's command still gets through, and Loop's tester hit "phone took control from a watch that was apparently looping". Any watch dose after the audit is never booked, because the audit has already run. | state-and-synchronization.md Take Back 1-3, lend 5; loop-implementation-inventory.md §2.7 and `c491bf7f`; experimental-kit-forks-inventory.md §4.3-4.4 | After a Take Back that the watch has not acknowledged: (1) the phone re-runs the odometer audit at every cycle until the watch confirms `stopped` with its records, and any new unexplained delivery means Stop of insulin-adding automation plus an alert (SR-21); (2) the phone runs reductions-only until that confirmation arrives, or until a stated bound passes; (3) in `lending` with a grant already sent, the phone first queries the watch and shows the "watch off or lost" confirmation, not a one-tap Take Back. |
| SM-9 | major | **Stop messages must not depend on the version check.** "Version mismatch in any message → no new loan" (lifecycle). If a revoke or higher-epoch message from a newer build cannot be parsed by an older watch, the watch keeps commanding. | lifecycle-and-execution.md "App upgrade" row | Keep a minimal, frozen envelope (`protocolVersion`, `epoch`, `kind`, `messageID`, `sentAt`). Revoke, stop and any higher epoch are honoured whatever the version. Add a unit test that decodes a future-version revoke. |
| SM-10 | major | **Watch relaunch in `holding` does not ask the phone.** The restore checklist uses the watch's own (possibly stale) epoch, so the only thing that catches a Take Back made while the watch was off is the #177 resync. | lifecycle-and-execution.md relaunch row; Loop asks the phone first (loop-implementation-inventory.md §2.9) | On relaunch: query the phone if it is reachable. The first pod contact must be a status read, with no command in that session. Any resync means `stopped` plus an alert. Verify on #177 that foreign-session refusal is on for an adopted pod before the first command. |

### Lost or double-counted insulin

| ID | Sev | Finding | Evidence | Required change |
|---|---|---|---|---|
| SM-1 | major | **Take Back does not cancel the watch's running temp.** The phone's driver has no record of it; the kit does not synthesize an untracked temp. So oref sees `currentTemp` as none, and with no change needed it leaves the watch's high temp running for up to 30 min. That insulin is delivered after the audit and never booked. | state-and-synchronization.md Take Back 2; APSManager.swift:739-780 (currentTemp from `basalDeliveryState`, falling back to history); experimental-kit-forks-inventory.md §4.4 (`PodState.swift:428-430`) | After `takeControl()`: cancel the temp unconditionally, then audit, then resume. This is Loop's "no program crosses a transfer". |
| SM-2 | major | **Take Back during a watch bolus.** The audit reads the odometer mid-delivery and books only the units delivered so far. The rest of the bolus is delivered after the audit and never booked. | Odometer audit section; `PumpDeliveryOdometer.bolusUnderWayEndsAt` exists (experimental-kit-forks-inventory.md) | Read the bolus under way. Either wait for it to end before auditing, or book the remaining amount as well. If the pod reports a bolus under way, cancel it only by explicit user choice. |
| SM-3 | major | **Expected delivery is undefined.** "Sum of booked doses since release" leaves out scheduled basal (Trio stores scheduled basal as open-ended rows and excludes it from the `notScheduledBasal` predicates), suspends, partial temps, and cancelled boluses. Every audit would then book scheduled basal as a phantom bolus. That overstates IOB and causes under-delivery. | state-and-synchronization.md Odometer audit; PumpHistoryStorage.swift:226-240 (open-ended scheduled basal); PumpEvent+helper.swift:88-118 | Define expected delivery = boluses at delivered units, plus temps at delivered pulses, plus scheduled basal from the snapshot schedule for every uncovered interval (pod schedule time zone), minus suspended intervals. Specify it in code with unit tests. Loop's reconciler counts temps in whole pulses. |
| SM-4 | major | **Replacing the audit placeholder can lose insulin.** "A placeholder audit bolus is replaced only by records covering the same interval." If late records explain only part of the excess and the placeholder is removed wholesale, the unexplained part disappears from IOB. If records arrive and the placeholder is kept, insulin is double-counted (safe direction, but hidden). | state-and-synchronization.md Take Back 3 | Recompute instead of replacing: placeholder = max(0, odometer delta − all records in the window − band). Re-run after every merge. |
| SM-11 | major | **The phone's own driver can purge imported watch rows.** Trio deletes every mutable pump event that the local driver did not assert when it reports `replacePendingEvents: true`. Watch records imported as mutable, such as a temp that was still running at Take Back, vanish on the phone's first kit report after `takeControl()`. | PumpHistoryStorage.swift:196-209 [V] | Import watch records as finalized (immutable), or tag them by origin and exclude them from the purge. Hold a running temp until it ends, as Loop does. Add a unit test. |
| SM-12 | major | **Snapshot taken while the phone loop or pump-event storage is still in flight.** The gate is checked at loop entry. A loop already past the gate can send an SMB between step 3 (temp cancel) and step 4 (release). Pump events reach Core Data through `pumpEventsTask` asynchronously, so the snapshot built at step 5 can miss that SMB. The watch then under-counts IOB and has the wrong `lastBolusTime`, and the SMB-interval guard does not hold. | APSManager.swift:313-358 (loop), 783-816 (enact); DeviceDataManager.swift:568-601 (`pumpEventsTask`) | Lend precondition: `loopGuard.waitForLoop()`, then gate closed, then drain `pumpEventsTask` and any standalone determination, then cancel temp, release, export. The gate also sits at the `PumpManager` enactment call sites (`performBasal` / `performBolus`), not only `APSManager.enact*`. |
| SM-13 | major | **Watch IOB for a manual bolus may be one SMB stale.** `BolusSafetyValidator` takes `currentIOB` from the IOB service (the last cycle's file) and recent boluses from Core Data. The watch has neither. If it uses IOB from the cycle that preceded an SMB, it misses that SMB. | BolusSafetyValidator.swift:71-81; target-architecture.md §5 | On the watch, call the pure `BolusSafetyEvaluator` with IOB recomputed from current records at confirm time, plus the recent-bolus sum from records. Reject when IOB cannot be computed (`iobUnavailable`). |
| SM-14 | minor | **Odometer baseline read after `releaseControl()`.** Lend step 5 reads the odometer after release, and the kit refuses sessions while released, so the value is cached. A stale baseline books phantom insulin at the audit. | state-and-synchronization.md lend 5; kit `runSession` refuses while released (experimental-kit-forks-inventory.md §table) | Take the baseline from the status response of the temp cancel in step 3, before release, and store it in the snapshot. |
| SM-15 | minor | **Glucose dedupe by identifier assumes both devices compute identical sensor timestamps.** G7 timestamps derive from sensor time plus each device's activation-date estimate [I]. | state-and-synchronization.md Authoritative state | When merging glucose, also apply the existing 3.5-min `filterTime` dedupe (GlucoseStorage.swift:45, 414-425). |

### Silent stop of automation

| ID | Sev | Finding | Evidence | Required change |
|---|---|---|---|---|
| SM-5 | major | **Zero commanders with no alert in `lending` / `takingBack`.** The phone shows "didn't confirm" or "Start didn't finish" as UI only. The watch has gone back to `idle`, so it has no dead-man. The phone's NotLoopingMonitor is suppressed during a loan (§6). Nobody loops and nobody alerts. | target-architecture.md §6; state-and-synchronization.md lend 3, 5, End 4 | The phone keeps the full NotLoopingMonitor ladder active in every state except `lent`. In `lent`, see SM-6. |
| SM-6 | major | **The phone stays silent when the watch dies nearby.** The phone alerts only when the watch is "reachable but silent". A watch with a dead battery is unreachable, and its pre-scheduled dead-man notifications cannot fire on a dead watch. Asleep at home with the phone on the nightstand: nobody alerts. | requirements-and-scope.md R-10; target-architecture.md §6, §8 | In `lent`, the phone alerts on watch silence (no record batch) after 20 min **regardless of reachability**. If the user is away from the phone, the alert costs nothing. Escalate like NotLoopingMonitor. |
| SM-7 | major | **The watch dead-man ladder is too short and may be muted.** It fires at 20 and 40 min only, at time-sensitive level (no critical alerts on the watch), and Sleep or Focus can silence it. After two notifications, automation can stop silently for hours: the resume horizon is 6 h, and BR-1 makes nightly stalls likely. | target-architecture.md §8; watchos-platform-research.md §3.13 | Use a ladder of at least 20, 40, 60, 90, 120 min, then hourly to the resume horizon. At Start, check notification authorization and the time-sensitive setting, and refuse Start if they are off. Tell the user once at Start to allow Trio in Sleep and Focus. Keep the ladder in `returning` until the ack (End not confirmed). |
| SM-16 | major | **A fail-closed gate on the phone stops looping silently.** `WatchLoanGate` answers false when the loan state is unreadable. That is right for dosing. But if the monitor treats that state like a loan, the phone stops looping with no not-looping alert. | target-architecture.md §2 | An unreadable loan state raises an explicit error alert, and the not-looping ladder stays armed. |
| SM-17 | minor | **End not confirmed.** The watch is `returning` and released, the phone is unreachable and still `lent`. The design only says "relaunch resends". | state-and-synchronization.md End 2-3 | State the user message (Loop: "End Not Confirmed") and how to recover. Keep the dead-man active (SM-7). |

### Gates that can fail open, or are missing

| ID | Sev | Finding | Evidence | Required change |
|---|---|---|---|---|
| SM-8 | major | **No way to stop insulin from the watch while the phone is away.** The R-list has bolus and carbs but no suspend or resume, no cancel temp, no cancel override, no open loop. End is refused without the phone. An active override, including an aggressive one, cannot be ended (F-5). With an Omnipod there is no pump UI to fall back on. | requirements-and-scope.md R-3, R-4, F-5, "Behaviour with the iPhone completely unavailable" | Required for safety in v1: suspend and resume insulin on the watch; switch to a "reductions only" or open-loop mode on the watch (SR-22, using the existing `DosingMode` clamps derived at call sites); cancel the active override or temp target (a reduction-only edit). |
| SM-18 | major | **Persisting the intent or the kit state can fail open.** Step 5 says "persist the dose intent, then enact", but not what happens when the write fails. Kit state reaches the host through an async delegate (F4), and the host writes JSON. A command can transmit before the pending-command state is on disk. | target-architecture.md §5; failure-mode-analysis.md F4 | If the intent write fails, the cycle does not enact (SR-13). The watch host persists kit `rawState` synchronously inside `pumpManagerDidUpdateState`, before returning. Add kill-at-every-step tests on the pump double that model "received but not acked". |
| SM-19 | major | **Watch glucose and enactment guards are only partly replicated.** The checklist has "glucose fresh, 12 min" but not the ≥3-readings-in-1-h rule. It also lacks APSManager's "pump suspended → don't enact" and "manual temp → don't enact" guards. F8 (the oref stale-glucose fallback is never enacted) is not decided. | APSManager.swift:512-528, 794-802; failure-mode-analysis.md F8 | Share one guard function between the phone and the watch (part of `OrefRun` or next to it) and unit-test both callers against it. Decide F8 explicitly, the same on both devices. |
| SM-20 | major | **End preconditions are incomplete.** End checks only "no bolus running, no unconfirmed command". It does not check `deliveryIsUncertain` or pump-status freshness (SR-4). #177 covers unconfirmed commands for Omnipod only. | state-and-synchronization.md End 1 | Use the same precondition set as Lend (SR-4) in both directions. Also persist `returning` **before** `releaseControl()` (write-ahead), so a crash between the two never leaves `holding` with a released kit. |
| SM-21 | minor | **Phone-side uncertainty gate.** U-3 / F3: when the phone is `home`, Trio still does not gate on `deliveryIsUncertain`. | DeviceDataManager.swift:457-459 | Fix upstream alongside F1. Lend already checks it at request time. |

### Profile generation and autosens on the watch from a frozen snapshot

| ID | Sev | Finding | Evidence | Required change |
|---|---|---|---|---|
| SM-22 | major | **The time-zone statement is wrong.** Lifecycle says a time-zone change "doesn't change the snapshot's profile (oref uses the profile's own schedule)". oref looks up basal, ISF, CR and targets with `Calendar.current` / `TimeZone.current`, so a watch time-zone change shifts which schedule entry applies. Trio does the same on the phone today, while the pod keeps its own time zone until the user syncs it. | Profile+TherapySettingGetter.swift:10, 42, 68; Date+MinutesFromMidnight.swift:40-67 [V]; OmniPumpManager.swift:3061-3070 | Choose one rule and test it. Recommended: pin the loan to the grant's time zone. The watch runs oref with that time zone, logs and alerts on a device time-zone change, and refuses End or Take Back until the zones match, or re-checks. Fix the doc text. |
| SM-23 | minor | **Generating the profile on the watch is necessary, not optional.** `createProfiles` runs every loop on the phone because current basal, ISF and target depend on the time of day (APSManager.swift:531). Running it per cycle on the watch from the frozen schedules is correct. Reusing a profile generated at grant time would be wrong. | APSManager.swift:528-533; OpenAPS.swift:485-590 | Make "profile generated every cycle from snapshot inputs with the watch clock" an explicit requirement and a parity test: the same snapshot at several times of day gives the same profile on phone and watch. |
| SM-24 | minor | **Autosens on the watch: cost and cadence.** Autosens is the heaviest step: 24 h of deviations, rerun when older than 30 min (APSManager.swift:458-468). On the watch it competes with the DASH exchange inside one alert-task window (~25 s in Loop). If the task expires mid-command, delivery becomes uncertain. Frozen inputs are fine: the 24 h window is snapshot plus watch records. | APSManager.swift:458-468; loop-implementation-inventory.md §2.8 | Keep the 30-min cadence. Run autosens only after enactment, or in a separate wake, never before a command in a tight window. Measure with D's E5 on target watches. If time is short, use the last autosens result rather than skip dosing. |
| SM-25 | minor | **Parity through serialization.** The snapshot crosses JSON. Date and Decimal round-trips (for example ISO8601 without fractional seconds) can change determinations. | target-architecture.md §10 | The watch input-builder parity test must use an actual encode/decode round trip of the snapshot, not in-memory structs. |
| SM-26 | minor | **TDD on the watch.** DynISF needs today's TDD, including scheduled basal. If watch records lack scheduled basal, TDD drops and DynISF ISF rises (less insulin): a silent behavior change. | OpenAPS.swift:472-486 / TDDStorage; SM-3 | Same scheduled-basal inference as SM-3. Add a parity fixture that spans a loan. |

### Cross-project Q-1: the odometer placeholder bolus versus SMB interval and `lastBolusTime`

Traced in OpenAPSSwift [V]:
- `IobGenerator.generate` sets `lastBolusTime` to the newest treatment with non-zero insulin that is not a temp bolus (IobGenerator.swift:22-24, 40). A placeholder booked as a bolus "now" becomes `lastBolusTime`.
- `DosingEngine.determineSMBDelivery` allows an SMB only if `lastBolusAge > smbInterval`, where `smbInterval` is clamped to 1-10 min, default 3 (DosingEngine.swift:818-850). Result: **SMBs are blocked for one SMB interval after the audit**. That is the conservative direction, it is transient, and it is harmless.
- `isSMB` and `isExternal` are carried in `ComputedPumpHistoryEvent` but no OpenAPSSwift code reads them. How the placeholder is flagged does not change dosing math.
- **IOB is overstated** (good for hypo safety), because a dose booked now has full IOB. The **activity** of that dose at "now" is about zero while the real insulin is already acting. Effects:
  - Predictions add the placeholder's full future effect, so the forecast drops more and oref reduces basal. That leans toward hyperglycemia if the placeholder is large.
  - Deviations, which are the observed delta minus a BGI that is too small, read negative, so autosens leans toward "more sensitive". That is the safe direction.
  - With negative deviations, carb absorption falls to the minimum carb impact, so COB may stay higher than real. COB pushes insulin up, but the IOB overstatement and Max IOB cap it [I]. I recommend a unit test for this interaction.
- Max IOB (DosingEngine.swift:637-648) and `BolusSafetyValidator` both see the inflated IOB, so SMB, high temps and manual boluses are capped further. That is conservative.

**Conclusion:** the placeholder is safe for over-delivery. It is acceptable with three conditions:
1. it is recomputed, not replaced (SM-4);
2. its size is bounded by a correct expected-delivery definition (SM-3);
3. the user sees "IOB may be overstated after taking back the pump" while it is in effect.

Add Swift Testing cases: (a) SMB blocked for exactly `smbInterval` after the placeholder; (b) eventualBG and insulinReq with a placeholder versus the same insulin booked at its true time, to show the direction; (c) a COB fixture.

### Other

| ID | Sev | Finding | Required change |
|---|---|---|---|
| SM-27 | major | The roadmap has no hardware or in-vitro milestone. E2, E5 and the in-vitro DASH hand-off tests appear only in target-architecture §10. M7 acceptance is "reviews filed". | Add an M8 hardware gate (E1, E2, E5, E8, in-vitro hand-off and Take Back including SM-1/SM-2 scenarios), with written results, as the precondition for enabling `TRIO_ON_WATCH` for anyone else. |
| SM-28 | minor | Watch alerts (R-6, required for safety) sit in M6 "UI". | Move dead-man, glucose and kit alert scheduling into M5 acceptance. UI polish stays in M6. |
| SM-29 | minor | No observability requirement (SR-26). | Log loan transitions, epochs, gate decisions and audit results per the CONTRIBUTING rules, with no health data. Give a maintainer-readable hand-off trace. |
| SM-30 | minor | The architecture relies on "one BLE session at a time" (kit claim, cross-project Q-3) and on #177 refusal semantics, while #177 is still moving. | Pin a reviewed #177 SHA. Make Q-3 an E-series hardware test. Add a kit-behavior test list for release, take, resync and refusal. |

## SR coverage

| SR | Status | Gap |
|---|---|---|
| SR-1 Single commander | Partial | SB-1, SB-2. Otherwise good: phone gate plus kit release. |
| SR-2 Release before acquire | Partial | SB-1; End writes `returning` after release (SM-20). |
| SR-3 No autonomous takeover | Partial | No timeouts lead to ownership (good). Gaps: post-Take-Back phone dosing (SB-2), relaunch query (SM-10). |
| SR-4 Hand-off preconditions | Partial | Lend list good apart from loop and event drain (SM-12). End list incomplete (SM-20). |
| SR-5 Complete transfer | Mostly met | Odometer baseline timing (SM-14). Delivery limits and alarm thresholds should be named explicitly. |
| SR-6 Identity merge | Partial | Purge of imported rows (SM-11), placeholder (SM-4), glucose (SM-15). |
| SR-7 Dose locally | Met | – |
| SR-8 Bind enactment | Met | In-memory `OrefRun` result on the watch. F1 is fixed separately (not re-verified here). |
| SR-9 One bolus gate | Partial | Validator inputs on the watch (SM-13). |
| SR-10 At-most-once | Partial | Message ids are deduped. No expiry (SB-1). Watch UI for an "unknown outcome" not specified. |
| SR-11 Uncertainty gate | Partial | Watch: yes. Phone: no (SM-21). |
| SR-12 Write-ahead | Partial | Intent: yes. Kit state: no (SM-18). |
| SR-13 Persistence faults block | Not answered | SM-18. |
| SR-14 Glucose guards | Partial | SM-19, F8. |
| SR-15 Dead-man | Partial | SM-5, SM-6, SM-7. |
| SR-16 Alert parity | Partial | Time-sensitive only, Focus not addressed (SM-7). No high alert (minor). |
| SR-17 Proven runtime | Met | Flag stays off until E2 passes. Needs an M8 milestone (SM-27). |
| SR-18 Battery | Mostly met | No "critical → Degrade/Stop" step. |
| SR-19 Version gate | Partial | SM-9. |
| SR-20 Clock discipline | Partial | Checked at grant. Mid-loan time zone wrong (SM-22). |
| SR-21 Peer detection | Partial | Audit runs only once at Take Back (SB-2). #177 resync handling unverified (SM-10, SM-30). |
| SR-22 Degrade ladder | Not answered | SM-8. |
| SR-23 Per-kit qualification | Met | DASH and G7 only. |
| SR-24 Restore checklist | Partial | No phone query. First pod contact must be status-only (SM-10). |
| SR-25 Settings authority | Partial | Frozen settings are fine. No override cancel (SM-8). |
| SR-26 Observability | Not answered | SM-29. |

## Q-1 to Q-28 coverage

| Q | Status | Gap or note |
|---|---|---|
| Q-1 Token storage, durable before command | Partial | The watch writes JSON atomically. The phone's store and write-before-act are implied, not stated. |
| Q-2 State machine with loss and crash per step | Answered | Step tables exist. Defects: SB-1, SM-20. |
| Q-3 Non-owner inert | Partial | Relies on #177 refusing sessions while released. The phone's heartbeat and kit UI still call the kit. Verify the refusal covers them (SM-30). |
| Q-4 Who refuses insulin-adding commands while uncertain | Partial | Watch only (SM-21). |
| Q-5 Forced takeover and the old owner's return | Partial | SB-2, SM-10. |
| Q-6 Ownership across relaunch and reboot | Partial | Resumes `holding` within 6 h without asking the phone (SM-10). |
| Q-7 Snapshot contents, size, completeness | Partial | Contents listed. Size not estimated. "Refuse if any part is missing" is good. |
| Q-8 Merge and `replacePendingEvents` | Not answered | SM-11. |
| Q-9 Omnipod odometer reconciliation | Partial | Present. Definition and timing gaps (SM-1 to SM-4, SM-14). |
| Q-10 F1 | Answered | Fixed on a separate branch (not re-reviewed). |
| Q-11 Transport guarantees, expiry, dedupe | Partial | Dedupe yes. No expiry, and `transferUserInfo` for control messages (SB-1). |
| Q-12 All boluses through the owner's validator | Partial | The phone refuses everything during a loan. Watch inputs: SM-13. |
| Q-13 Wake source evidence | Answered (as risk) | ADR-002, BR-1, E2 gate. |
| Q-14 CGM path | Answered | G7 display slot via `DeviceConfigurationSharing`. The phone keeps its own slot. |
| Q-15 Kit state persisted synchronously | Not answered | SM-18. |
| Q-16 Watch alerts under Focus or lock | Partial | Time-sensitive only. Focus and authorization not handled (SM-7). |
| Q-17 Phone monitor versus watch status | Partial | SM-5, SM-6. |
| Q-18 Battery thresholds and measured cost | Partial | Thresholds set. Cost unmeasured (D E8). |
| Q-19 Version skew | Answered | Except stop messages (SM-9). |
| Q-20 Kits in scope | Answered | DASH and G7. |
| Q-21 Clock and time zone | Partial | SM-22. |
| Q-22 Edits from the non-owner | Answered | Refused or frozen. Override cancel missing (SM-8). |
| Q-23 Zero-owner UX and alert speed | Partial | UI only (SM-5). |
| Q-24 Logs and diagnostics | Not answered | SM-29. |
| Q-25 v1 versus speculative | Answered | R/F/O table. Automatic takeover and shadow loops rejected. |
| Q-26 Does the non-owner compute determinations | Partial | "No loop while lent". Say whether the phone shows a forecast (Loop hides it as "fake") and that no enact path exists. |
| Q-27 F8 decision | Not answered | SM-19. |
| Q-28 Fault-injection and hardware test plan | Partial | Unit and simulator plan good. Hardware not a milestone (SM-27). |

## Required-change checklist (ordered)

1. SB-1: grant bound to the request, expiry, `sendMessage` only, cancel queued transfers.
2. SB-2: after an unacknowledged Take Back, continuous re-audit, reductions-only, query before Take Back while in `lending`.
3. SM-1 to SM-4, SM-11, SM-12: temp cancel at Take Back, bolus under way, expected-delivery definition, placeholder recompute, merge purge, lend drain.
4. SM-5 to SM-7, SM-16, SM-17: no silent zero-owner states; longer dead-man ladder; phone alerts regardless of reachability while `lent`.
5. SM-8: suspend, resume, reductions-only and override cancel on the watch.
6. SM-9, SM-10, SM-18 to SM-20, SM-22: version-independent stop, relaunch query, synchronous kit persistence, shared guards, End preconditions, time-zone rule.
7. SM-27: hardware milestone before enabling the flag.

## Evidence index

- Architecture documents as listed above (2026-11-16). Research: `research/cross-project-comparison.md`, `research/loop-implementation-inventory.md` §2.7-2.12, `research/experimental-kit-forks-inventory.md` §3-4, `research/watchos-platform-research.md` §3.13-3.14.
- Trio baseline `ad6c66876`:
  - `APSManager.swift` 313-358, 458-468, 512-533, 739-780, 783-816;
  - `DeviceDataManager.swift` 457-459, 568-601;
  - `PumpHistoryStorage.swift` 196-209, 226-240;
  - `GlucoseStorage.swift` 45, 414-425;
  - `BolusSafetyValidator.swift` 71-81;
  - `OpenAPSSwift/Iob/IobGenerator.swift` 22-24, 40;
  - `OpenAPSSwift/DetermineBasal/DosingEngine.swift` 637-648, 818-850;
  - `OpenAPSSwift/Extensions/Profile+TherapySettingGetter.swift` 10, 42, 68;
  - `OpenAPSSwift/Extensions/Date+MinutesFromMidnight.swift` 40-67;
  - `OpenAPSSwift/Models/ComputedPumpHistoryEvent.swift` 16-17, 61-62 (`isSMB` / `isExternal` unused in the algorithm).
- OmnipodKit `6fdf0e0`: `OmniPumpManager.swift` 3061-3070.

## v2 re-review (2026-11-16)

Scope: `target-architecture.md` "v2 amendments" (V2-1 to V2-32), ADR-003 to ADR-008, and `implementation/roadmap.md` v2. I checked only the status of SB-1, SB-2 and the major SM findings, and looked for new paths to two commanders, silent stops and fail-open gates. Design-document review only; nothing was run.

### Status of earlier findings

| ID | Status | By | Note or remaining change |
|---|---|---|---|
| SB-1 | **Resolved** | V2-1 | The request-id echo, the 30 s expiry, `sendMessage` only, "accept only in `requesting`" and the transfer cancel at Take Back together close the late-grant path. Remaining minor point: see N-4. |
| SB-2 | **Resolved, conditionally** | V2-6, V2-7, V2-8 | See the "V2-7 versus SB-2 intent" section below. Conditions: R-1 to R-4. |
| SM-1 Take Back temp cancel | **Not resolved** | – | V2-7 has no temp cancel, while V2-2 (lend) and V2-3 (end) do. Required as R-1. |
| SM-2 Bolus under way at Take Back | **Not resolved** | – | The per-cycle re-audit catches it one cycle late. Meanwhile the phone's first cycle runs on IOB that misses the undelivered remainder, possibly several units of a manual bolus. Required as R-2. |
| SM-3 Expected delivery | Resolved | V2-8 | The schedule has to be read in the pod's (grant) time zone. That is consistent with ADR-004. |
| SM-4 Placeholder recompute | Resolved | V2-8 | Also see R-3. |
| SM-5 No alert in no-dosing states | Resolved | V2-12 | The invariant test must cover (watch `returning`, phone `lent`) and (watch `idle` after `grantRejected`, phone `lending`). |
| SM-6 Dead watch next to the phone | Resolved | V2-14 | – |
| SM-7 Dead-man ladder | Resolved (minor left) | V2-13, V2-18 | The ladder ends at 120 min, and the watch has no critical level. Repeat hourly up to the 6 h resume horizon, and check `timeSensitiveSetting`, not only general authorization (minor). |
| SM-8 No stop on the watch | Resolved | V2-25, V2-26 | Suspend, Resume and Cancel override/TT are enough for v1. |
| SM-9 Version-independent stop | Resolved | V2-10 | – |
| SM-10 Relaunch query | Resolved | V2-11 + V2-6 | – |
| SM-11 Purge of imported rows | Resolved | V2-9 | – |
| SM-12 Lend drain | Resolved | V2-2 | – |
| SM-13 Watch bolus IOB | Resolved | V2-24 | – |
| SM-16 Unreadable state | Resolved | V2-15 | – |
| SM-17 End not confirmed | Resolved | V2-3, V2-12, V2-14 | – |
| SM-18 Write-ahead and kit persistence | **Partially resolved** | V2-20 | The host writes synchronously, but OmnipodKit notifies the host through an async delegate after it sets `unacknowledgedCommand` (F4; WeakSynchronizedDelegate.swift:55). The window between transmit and persist stays open in the kit. Required as R-5. |
| SM-19 Shared guards, F8 | Resolved | V2-20 | – |
| SM-20 End preconditions and order | Resolved | V2-3 | – |
| SM-22 Time zone | Resolved | V2-23, ADR-004 | – |
| SM-27 Hardware milestone | Resolved | V2-32, M8 | – |

### V2-7 versus the SB-2 intent

The aim of SB-2 was that no unbooked insulin from a still-running watch can reach a phone that is dosing on full automation. With V2-6, the watch's kit refuses insulin-adding commands once its handshake sees the phone's session. The remaining exposures are:

- **Watch doses between the phone's `takeControl()` and the phone's first handshake.** These are delivered before the Take Back audit's status read, so the audit books them as an excess, which overstates IOB and is conservative. Covered.
- **A watch bolus still delivering at take time.** The remainder lands after the audit. This is SM-2, and R-2 closes it.
- **Reduction commands from the stale watch.** V2-6 refuses only insulin-adding commands, so a stale watch can still set a zero or low temp, up to 120 min (DosingEngine.swift:481-497), in the session that detected the foreign controller. The phone's driver does not know that temp, and an audit shortfall gives only a notice. This is bounded hyperglycemia, not hypo. R-4 closes it.

**Conclusion.** Full looping after Take Back with the per-cycle re-audit is acceptable, and reductions-only until the watch acknowledges is **not** required, provided that:
- R-1: Take Back cancels the running temp;
- R-2: the audit accounts for a bolus still under way;
- R-3: the per-cycle re-audit also recomputes and books the audit bolus, not only switches the mode;
- R-4: after an unexpected foreign session, the V2-6 kit rule refuses **all** program commands, not only insulin-adding ones, and there is a pump-double test that the stale watch's next command of any kind fails.

Without R-2 the phone's first post-take cycle can dose on under-counted IOB. In that case, reductions-only until the watch acknowledges, or until one re-audit cycle has passed, would be required instead.

### New findings from the amendments

| ID | Sev | Finding | Evidence | Required change |
|---|---|---|---|---|
| N-1 | **major** | **V2-21, "no SMB from a background wake; temp basals only", must not be done by dropping `units` from a determination.** When oref chooses an SMB, it pairs it with a compensating low or zero temp of up to 60 min (`smbLowTempRequired`). Enacting that temp without the SMB under-delivers while glucose is high. This is the same trap as the repo's open-loop rule. | DosingEngine.swift:786-857; OpenAPS.swift:338 (`microBolusAllowed: true` hard-coded) | Pass `microBolusAllowed = false` through `OrefInputs` on background wakes, so oref runs its temp-only logic. Add a parity or behavior test that a background determination never contains an SMB-paired low temp. |
| N-2 (= R-4) | **major** | V2-6 refuses only insulin-adding commands after a foreign session. That leaves stale reduction temps, and a stale suspend, that the new owner does not know about. | V2-6 text; experimental-kit-forks-inventory.md §4.4 (kit does not synthesize untracked temps) | Refuse all program commands; status reads are allowed. As belt and braces, the phone re-cancels or re-asserts the temp every cycle during the V2-7 re-audit window. |
| N-3 (= R-5) | **major** | **Orphaned intent.** A journaled Trio intent with no kit `unacknowledgedCommand` (lost in the F4 window) cannot be resolved by the kit's `getStatus`. It either blocks forever, or someone resolves it by assuming it was not delivered. | V2-20; PodCommsSession.swift:1086-1100 | Resolve an orphaned intent by reading the odometer: book any excess as in V2-8, never assume not delivered. If the intent cannot be resolved, the mode is reductions-only plus an alert, not a silent permanent block. |
| N-4 | minor | **The watch request timeout (20 s) can be shorter than a worst-case lend.** V2-2 waits for the loop, pump events, a bolus, and a release of up to 20 s. Late grants are then refused correctly, but what the phone does on `grantRejected` is unspecified. | V2-1, V2-2; state-and-synchronization.md lend 1 | On `grantRejected` (or Take Back while in `lending` with the watch answering `idle`), the phone calls `takeControl()` and persists `home(e+2)` automatically. That is safe because the watch never adopted. Set the watch timeout above the phone's worst-case lend time. In V2-7, "points to End" applies only when the watch answers `holding`. |
| N-5 | minor | Reductions-only after unexplained insulin (V2-7) clamps only the oref call sites. Manual boluses stay allowed (`BolusSafetyValidator` uses the stored Max IOB). | Repo rule on DosingMode clamps | Keep this behavior, but the alert copy must not say "insulin delivery paused". |
| N-6 | minor | V2-7 ends the re-audit after 6 h even without an acknowledgment. That is acceptable because of V2-11 (no watch resume past 6 h) and V2-6. | – | Log and notify when the window closes without an acknowledgment. |

I found no other new path to two commanders. V2-1, V2-4 (single manager instance), V2-11 and V2-27 (three-layer gate, `pumpManager` never set to nil) together tighten SR-1 to SR-3.

### Verdict

**Gate passed for M3, M4 and M5, with required changes. No re-architecture is needed.**
- **M3 (loan core): yes.** Add decision-table rows for N-4 (`grantRejected` leads to automatic retake) and for the Take Back temp cancel (R-1). Add the V2-12 invariant cases listed under SM-5.
- **M4 (phone): yes, if** its acceptance tests cover R-1 (temp cancel at Take Back), R-2 (`bolusNotDelivered` / bolus under way booked in the audit; StatusResponse.swift:20), and R-3 (re-audit recomputes the audit bolus), plus N-5 copy.
- **M5 (watch loop): yes, if** N-1 (`microBolusAllowed = false`, never stripped SMB) and R-5 (orphaned-intent odometer resolution) are in its acceptance tests, and **M2b**, which M5 depends on, implements R-4 (V2-6 refuses all program commands) with the pump-double test.

BR-1 is unchanged. The flag stays off for users until M8/E2 passes.

## V2-7b check (2026-11-16)

Reviewed: V2-7b in `target-architecture.md` @ `f059f1809`, which supersedes V2-7. Design review only; nothing was run.

**SB-2 stays closed.** The per-cycle re-audit and the reductions-only mode were needed only as a fallback in case R-2 was missing (see "V2-7 versus the SB-2 intent" above). V2-7b includes R-1, R-2, R-3, R-4 and R-5. Going through the exposures again:
- **Watch doses before the phone's first session.** They are delivered before step 4 (`refreshDeliveredUnits()`), so the step 5 audit books them. Covered.
- **Watch bolus still delivering.** The undelivered remainder is booked in step 5 (R-2). Covered.
- **Stale watch after the phone's session.** The watch's next session sees the foreign controller and refuses every program command (R-4). The phone sees the resulting foreign session, alerts and audits again. No unbooked insulin, and no silent stop.
- **Unresolvable intent.** It is booked as delivered, so IOB errs high, and the user is alerted (R-5). This is conservative and acceptable without a mode switch.

Booking unexplained insulin into history and letting oref's IOB and Max IOB act on it fits the repo rule of no layer on top of oref. The Q-1 trace above shows that a booked audit bolus is conservative for SMB timing and for IOB.

### Conditions to add

| ID | Sev | Condition |
|---|---|---|
| C-1 | major | **Scope the takeover context, or it becomes a fail-open gate.** The phone keeps commanding through a foreign session only while all of these hold: the session is attributable to the superseded holder (epoch e+1 Take Back); the watch has not yet acknowledged `stopped`; and the watch's 6 h resume horizon (V2-11) has not passed. Outside that window, the phone treats any foreign session as "I believed I was the only holder", so the kit refuses commands, the host alerts and audits. The context is never set after a normal End (the watch's release was acknowledged) or after a lend. The phone audits and alerts on **every** foreign session it sees, not only the first. Pump-double tests: (a) after Take Back, the stale watch's next command of any kind fails; (b) a foreign session after the window closes makes the phone refuse and alert. |
| C-2 | major | **No session reuse by a stale watch.** R-4 only works if every watch pod contact after the phone's takeover hits the foreign-session check. In M2b, verify (test with #177 @ `3d21d9c` plus the patch) that a watch reconnecting with session keys from before the takeover either re-handshakes, which triggers the check, or has its commands rejected by the pod. It must never send a program on a resumed stale session. Repeat this as an in-vitro M8 case. |
| C-3 | minor | **Interrupted Take Back.** On relaunch in `takingBack`, redo steps 2-5 before `home`: take control, cancel the temp, refresh, then recompute the audit (it must be idempotent). The not-looping alarm stays armed (V2-12). |
| C-4 | minor | **No double count for a booked intent.** An R-5 booked intent counts as "booked" in the V2-8 expected-delivery sum, so a later audit does not book it again. It is tagged and replaced only through the recompute rule. A later shortfall gives the existing notice. |

**Verdict:** V2-7b keeps SB-2 closed. The M4 gate stands if C-1 and C-3 are in M4's acceptance tests. The M5 gate stands if C-1 (kit side) and C-2 are in M2b's acceptance tests and C-4 is in M5's.
