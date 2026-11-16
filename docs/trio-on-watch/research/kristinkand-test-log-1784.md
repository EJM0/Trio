# kristinkand field test log (nightscout/Trio#1784) versus Trio on Watch

Research note, 2026-11-16. Read-only. Sources: issue nightscout/Trio#1784 (body, no comments yet), the linked claude.ai test log (184 tests, 170 changes), and `kristinkand/feature/untethered-watch-mode` @ `f587d1f9b` (`DeveloperDocs/Untethered/README.md`, commits since `a56170dc0`). Compared against our docs at `docs/trio-on-watch/` (target architecture incl. v2 amendments and V2-7b, decision table, ADRs, requirements, safety review, roadmap, implementation status, A1 inventory).

Markers: **[V]** verified (I read the code, doc or text), **[R]** reported in her test log (I read her description; raw logs, builds and devices not seen), **[I]** inferred. Test ids are `#N` in her log, her change ids are `cN`. Health data, tester identities, device names and amounts tied to a person are left out.

## Executive summary

1. Her log is the only multi-week field data we have for a BLE-woken watch loop on DASH + G7: 184 tests, 18 Oct to 16 Nov, three testers. I recounted the verdicts in the log: 83 worked, 68 mostly or partly, 30 failed, 3 info [V]. Weight: tester A (Series 9) ran **water-filled pods** (DASH, one OP5 from 2 Nov), so A's dosing data is pod-accounting only. Testers B (Series 9, then Series 11 cellular) and C (SE 2nd gen, 32-bit) used insulin on DASH [V, log "Setup before testing"].
2. **ADR-002 is supported, not contradicted.** Without any workout session, BLE alert wakes carried 5-minute loops for 4 to 10 h at a time, with roughly 1 reading in 10 missed. With the optional workout, gaps stayed at 11 min or less over about 10 h, at about 40 % more battery [R #107, #109, #161, #105, #36]. Wakes per day far exceed "5 per rolling 24 h", so that cap evidently doesn't bound GATT notifications on a retained connection [I]. One confounder: her Trio complication was on the face [R #52]. Our E2 still decides.
3. **The open platform risk is the pod link, not CGM wakes.** Repeatedly, the pod dropped the watch's link 0.2 to 0.5 s after connect, or at the EAP login, **only while Trio was in the background**. Hundreds of tries failed while the phone reached the pod at once. Opening Trio reconnected within about 10 s [R #177, #181-#183, earlier stalls #3-#36]. The cause is unresolved. Her latest lead is pod placement, with the torso shadowing the link (unproven) [R #183, #184]. Our design tolerates it (temp expiry, dead-man), but we have no prompt that tells the user to open Trio.
4. Most of her safety incidents come from features we rejected: automatic start, pod "looks" beside a looping phone, offline start from a stale copy, auto-retake on lease expiry. The worst was about **3 h of phone and watch dosing the pod in turn**, after an automatic start beside a looping phone and a stop the sleeping watch never got [R #49]. Our O-3 (no automatic takeover), F-1 (no offline start) and V2-6/W24 (kit refuses after a foreign session) prevent the whole class [V].
5. Four lessons do apply to us and are not yet written down:
   - Records of a loan the phone gave up on must still be merged (her `f587d1f9b`; our "ignore lower epochs" rule conflicts).
   - Show a "pod link lost: open Trio" prompt.
   - Background-task hygiene: hold an expiring activity per cycle, a 10 s WatchConnectivity cap, no main-thread waits on the WC transfer lists.
   - 32-bit integer widths on SE 2.
6. Things we should not adopt: automatic start, automatic hand-back, watch Emergency Stop, the phone's pod check after a 10-min pause, bolus auto-retry and forwarding across a hand-back, Extended (workout) mode, and Nightscout or remote from the watch in v1. Her 0.2 U tolerance, retained-until-acked records and 32-bit checksum fix match what we already have, or are lessons for it.
7. Her procedures map well onto M8. A 12-case hardware plan is proposed below.

## Findings

Severity: **H** = could cause wrong insulin or lost insulin records, or a long silent no-loop. **M** = availability, or a misleading display. **L** = UX, process.

| # | Finding | Her evidence | Our status | Recommendation | Sev |
|---|---|---|---|---|---|
| F1 | BLE alert wakes alone sustain a 5-min loop for hours. About 10 % of readings missed without a workout, gaps ≤ 11 min with one | #107: 4 h 48, no workout, about 1 in 10 missed, 4 gaps of 10-15 min. #109: 6 h overnight, about 89 % of readings. #161: 10 h 20. #184: 44 loops, none failed. With the workout: #105 9 h 48 and #36 13 h 59 without a pod stall [R] | **Covered.** ADR-002 picks this model; missed cycles are designed for (§5, lifecycle "Missed readings") [V] | Keep ADR-002. Record this as supporting evidence and lower the "Known conflict" risk (P8). Set the E2 pass criterion against a realistic miss rate, not 288/288 | M |
| F2 | The 5/24 h budget doesn't show in practice. A complication was on the face | Hundreds of wakes a day across testers [R]. Complication on the face [R #52] | **Conflict in wording.** ADR-002 "Known conflict" and D's platform research present 5/24 h as the binding cap [V] | Amend the ADR-002 wording (P8). Run E2 both with and without a complication on the face (ADR-008 ships none) | M |
| F3 | The pod drops the watch's link in the background, while the foreground works | #177 (airport, then after landing), #181-#183 (about 0.4 s after connect, at login, in the background only; −69 dBm failed in the background, −83 worked in front), #178 (34 drops). Earlier stalls with "EAP AKA failures" #3, #6, #9-#11, #22, #23, #25, #27, #31, #36. The 15.11 drops vs the 16.11 night, when the pod was moved: clean, 30 of 30 background logins [R] | **Partly covered.** FM-03 lists placement tests but not the app's front/background state. The dead-man and temp expiry cover safety. There's no prompt [V] | P2 (pod-link prompt), P5 (per-connect logging), M8 cases T5/T6 | H (availability) |
| F4 | Opening Trio recovers the pod link | #182: "Pod Link Lost" then open, reconnected within 10 s, twice. #9: a stall went unnoticed for about 80 min until the app was opened [R] | **Gap.** V2-17 prompts only for Bluetooth budget errors [V] | P2 | M |
| F5 | A loop that didn't reach the pod but had nothing to send counted as success, which delayed stall handling | #182; fixed by c171 / `60f1ef66a` [V commit] | **Covered.** V2-13: the series moves forward only when a cycle confirms pump state [V] | Add an M5 test: a pump-status read failure with a no-op determination doesn't reschedule the dead-man | M |
| F6 | watchOS kills: WatchConnectivity wake over 15 s; scene-update watchdog at 10 s with the main thread blocked on the WC transfer lists; app suspended mid-wake when holding expected the main queue | #141, #149 (crash decoded), #1, #2 (0 s granted for 11 of 12 wakes), #8 (frozen inside a 35 s hold) [R] | **Partly covered.** V2-19 says "every background task is completed". Expiring-activity holds, the WC time cap and main-thread rules aren't stated [V] | P3 | H |
| F7 | watchOS ended or hung the app without a report; BLE state restoration relaunched it | #105 (ended about 04:26, relaunched for the sensor at 04:42), #175 (app update mid-session, relaunched for BLE, loop went on), #93 (watch app silent 8 h) [R] | **Covered.** Pre-scheduled dead-man fires without the app (§8, V2-13). W26 relaunch path [V] | M8 T7. Her data answers E3 in the positive [I] | M |
| F8 | 32-bit SE 2: overflow crashes from ms timestamps, a record checksum > 2^31, and pod SQNs | #110 (crash at every live reading), #117 (checksum), OmnipodKit #205 [R]. Fix `UntetheredRecord.swift:93` truncates to Int32 [V] | **Partly covered.** Epochs are Int64 (M3E-06). The OmnipodKit pin has #205 (`f5c3a15`) [V]. No general width rule [V] | P4 | H (crash = no loop) |
| F9 | G7 watch bonding needs Trio on screen. Stale bonds (an old sensor, an old watch) block it | #4, #17, #55, #66, #99, #106, #143, #159, #165 [R] | **Gap.** V2-5 adopts the watch-slot config but says nothing about the first bond on the watch [V] | P9: Start stays in front until the first watch reading | M |
| F10 | The session must take the watch display slot, and only one central per restore id | #81 (introduced itself as the phone, dropped), #82 (two G7 managers, one restore id, no link) [R] | **Covered.** V2-4 (never two managers), V2-5 (watch slot) [V] | M8 T1 confirms | M |
| F11 | A lost G7 connect request is only recovered by renewal or a backstop wake | #30, #31, #36, #37 (requests lodged without a link for 9-43 min); fixes c15, c110, c112 (a 7-min backstop refresh, some still pending) [R] | **Unclear.** G7SensorKit pin `08d4886` has "Watch acquisition: fixes from a week on a watch" and "Reconnect with a start delay; hold through readings" [V log subjects]. Renewal not verified. No backstop refresh by design (ADR-002 YAGNI) [V] | Open question Q3. Add a backstop only if M8 shows lodged-request gaps | M |
| F12 | Pod connect overlapping the G7 link correlated with stalls | #22, #25 (12 of 48 connects during the sensor link); c01 serialised them. #27 stalled with no overlap [R] | **Not specified.** §5 cycle order doesn't say [V] | No change now. M8 T6 logs overlap. Decide on data | L |
| F13 | Sensor on the opposite side of the body from the watch loses readings during runs | #72 (−98 dBm), #108 (moving the watch to the sensor side brought the readings back) [R] | **Gap (copy).** FM-03/04 testing mentions placement [V] | P10 user guidance | L |
| F14 | Apple's Workout app ends Trio's workout; a recording workout starves a passive watch app | #53, #57, #72 ("Another session is starting"), #50, #59 [R] | **Covered.** O-1: no workout, so nothing to lose. The BLE wakes kept going during user workouts once the session held the sensor (#54: 10 of 12) [R] | Confirms ADR-002's rejection of the workout | L |
| F15 | Battery | No workout: 2.5-4 %/h overnight or at rest (#109, #107, #161). Day: 3.4-10 %/h. Worst: about 12 %/h (#110 relaunch loop, #180 uploads over cellular) and 12-21 %/h on tester C's SE (#176). With the workout: about 5-6.6 %/h [R] | **Covered.** V2-18 (refuse below 30 %, warn at 20/10) [V] | Keep. M8 T9 measures per model. Consider showing an estimated time left at Start | L |
| F16 | Queued WatchConnectivity to a sleeping app arrives at the system's pace (minutes) | #83 (4 min 20 s), #95, #91, #98, #49 (phone's queued state never reached the sleeping watch), #102 (15 min of "Unknown WatchConnectivity error" after a phone restart) [R] | **Covered.** Grant and End use `sendMessage` (attended). A lost revoke is caught by the kit (W24, T3 in the decision table). V2-14 alarm at 30 min [V] | M8 T8 measures batch latency, so V2-14 isn't noisy | M |
| F17 | Flaky phone-watch link makes starts fail or need retries | #7 (commit lost in a 1 s flicker), #29 (73 large watch updates in 4 min starved WC), #32, #147, #153 (3-6 tries) [R] | **Covered (safe).** A lost grant leaves the phone `lending` with P13 and Take Back; watch W3 times out [V]. UX untested | M8 T1 counts start attempts. Don't let the phone push large watch-state updates during a lend | L |
| F18 | Phone restarted or locked mid-session; Core Data unreadable before first unlock | #96, #89, #171, #174, #164 [R]. Upstream #1672 is in our baseline (dev 1.0.2.66 < 1.0.2.72) [I] | **Covered.** `unreadable` (P24, P38), V2-15, V2-22 [V] | M8 T7 | M |
| F19 | Phone relaunch with Bluetooth off: neither device doses | #79, #80 [R] | **Covered.** P21 alert, zero commanders with alarms (V2-12) [V] | M8 T7 | M |
| F20 | App updates mid-session. Phone: fine. Watch: the update got stuck, the reinstall deleted the sensor bond | #87, #175 (phone), #66 and setup problem 8 (watch) [R] | **Partly covered.** Version-tolerant `stop` and `handBack` (M3E-09) [V]. Nothing on watch updates | User copy: end before updating Trio on the watch. M8 T10 | L |
| F21 | Time-zone change in flight | #177: 6 h 25 on the watch through the change [R] | **Covered.** ADR-004 pins the grant time zone [V] | Optional M8 case | L |
| F22 | Swimming | Only design claims in #1784; **no swim test in the log** [V, searched] | **Covered by design** (no readings, so no loop, temp expiry, dead-man) [V] | M8 T11 (water or shielding) | M |
| F23 | Alerts invisible: watch notifications off, alerts swallowed with Trio open | #5, #17 ("Source is not authorized"), #128 [R] | **Partly covered.** V2-18 refuses Start without notifications [V]. Foreground presentation not stated | Test foreground banner presentation in M5. M8 T12 | M |
| F24 | Nightscout followers saw a frozen phone IOB for 10 h during a session | #40, fixed by her c37 [R] | **Gap.** §6 says "Nightscout upload continues for what the phone has stored". The phone's own stale loop status would go up as current [V] | P7 | M |
| F25 | Nightscout and remote commands from the watch (APNs straight to the watch app) work, with caveats | #71, #74 (push woke the watch in 0-105 s), #130 (a remote bolus given 286 s late after "No confirmation"), setup problem 11 (a silent push never arrived), #75 (two remote boluses 43 s apart both given) [R] | **Out of scope (F-4)** [V] | Keep deferred. When F-4 opens: command expiry, idempotency, and a "may or may not have been given" answer | L (v1) |
| F26 | OP5 pod used by tester A (water) | From 2 Nov, #94 onwards [R] | **Out of scope** (SR-23, F-3) [V] | None | L |

## Safety incidents and design differences

### Incidents in her log, and whether our design prevents them

| Incident | Her evidence | Mechanism | Our design |
|---|---|---|---|
| Phone and watch dosed the pod in turn for about 3 h (temp basals) | #49 [R] | Automatic start beside a looping phone (its queued state never reached the sleeping watch); after the phone took back, the stop didn't reach the sleeping watch | **Prevented.** No automatic start (O-3). After Take Back, the watch's next pod session finds a foreign session and the kit refuses (V2-6, W24, decision-table T3). The phone keeps commanding inside its window (P25) [V] |
| Watch dosed from a copy 27 min old, 34 s after a phone SMB; its first loop didn't count that SMB (below 0.2 U) | #46 [R] | Offline start from a stale copy | **Prevented.** No offline start (F-1). The grant is built after the lend drain and release (V2-2) [V] |
| Pod "looks" refused phone commands. Phone dosing held up to 8 min; manual boluses refused | #98, #126, #139, #148, #169, #172, #176 [R] | Fallback looks take the pod session | **Prevented.** No looks [V] |
| Records of a start the phone gave up on (the watch had taken over, its answer was lost) were confirmed unstored, and the watch deleted them | c172 / `f587d1f9b` (found in review, not in the field) [V commit] | Auto-retake on lease silence, plus "late copy" dedupe | **Partly.** Take Back books the odometer excess, so IOB errs high (V2-7b). But state-and-synchronization §Messages says receivers "ignore lower epochs", which would drop the superseded loan's records [V]. P1 |
| False "Insulin From Elsewhere" from a pod count read before the SMB but dated later. Phantom bolus; the next loops dosed nothing | #76, c77 [R] | Per-loop odometer check on the watch | **Mostly n/a.** We audit only at take-back. P6 adds a test that compares by the pod's reading time |
| Audit against a faulted pod: the counter went back, giving a large false discrepancy | #26 [R] | No guard for a decreasing odometer | **Benign for dosing** (a shortfall only gives a notice, V2-8). P6 adds a guard and a test |
| Phone's running SMB and temp purged and rebooked as a gap bolus after a look (total right, history wrong) | #178, c153 [R] | Looks plus pending-event purge | **n/a.** No looks. Imports are finalized only (V2-9) [V] |
| Audit counted the phone's own running bolus as unexplained | #139 [R] | Bolus under way | **Covered.** V2-7b step 5 counts the undelivered remainder [V] |
| A meal bolus from the watch during the hand-back was refused and given 17 min later by hand | #118 [R]; her fix forwards it to the phone after 30 s | Bolus across a controller change | **Covered (refuse).** Keep the refusal, with copy saying to bolus on the iPhone once it's back. Don't forward |
| Watch app dead or hung for 8 h / killed | #93, #105, #86 (OmnipodKit "nonce prefix" on hand-off with no session keys) [R] | Platform, kit | **Covered.** Pre-scheduled dead-man. Our pin never trusts saved session keys on a new process (M2b C-2) [V]; the specific nonce fix is not verified in our pin (Q4) |

### Her deliberate differences: adopt, reject or equivalent

| Her mechanism | Code (at `f587d1f9b`) | Verdict | Why |
|---|---|---|---|
| Automatic start ("Start by Itself") | `UntetheredWatchManager.swift` fallback section; A1 §6 [V] | **Reject** (O-3 stands) | Her own log is the case against it: #49, #98, #148, #172 and the c118-c154 tuning churn. It needs looks that disturb a healthy phone loop. It's the root of the c150/c157 bolus-retry complexity in the phone's ordinary bolus path |
| Automatic hand-back after 20 min without readings, or when the phone is back | `+Loop.swift:1913` `sensorStallLimit` [V] | **Reject**, fold into copy | The phone is reachable by definition then, so End works. P2's alert says "End to let your iPhone loop". Automatic ownership changes are what O-3 rules out |
| Emergency Stop on the watch (release now) | `UntetheredWatchManager.swift:1607`, `UntetheredViews.swift:115` [V] | **Reject** | Releasing with the phone away gives zero commanders, and scheduled basal resumes after the temp, so it isn't a stop. Suspend (V2-25) stops insulin. Take Back covers a misbehaving watch |
| Phone checks the pod after any 10-min pause in its loops | `UntetheredPhoneManager.swift:1669` `podGapCheck` [V] | **Reject** (YAGNI) | It exists to catch an unannounced watch start. We have none. Foreign sessions are detected by the kit (P25-P28). #44 shows 16 such audits in one night, all noise |
| 0.2 U audit tolerance | `UntetheredAudit.swift:7` [V] | **Equivalent** | Ours is one pulse + 0.15 U = 0.20 U (V2-8). Her normal mismatches were a few hundredths of a unit, the largest about 0.1 U (#105, #161) [R], so the threshold fits |
| 2-min lease; phone retakes on silence | `UntetheredSession.swift:74`, `UntetheredPhoneManager.swift:157` [V] | **Reject**; we're stricter | Ours: grant `expiresAt` 30 s, alert at 60 s (P13), Take Back by user tap, auto-retake only on an explicit `grantRejected` (P11). Her `f587d1f9b` bug is a direct consequence of retaking on silence |
| Records kept until the phone confirms | `UntetheredMessage.swift:17` `recordsStored` [V] | **Equivalent** | state-and-synchronization §Messages: monotonic sequence, resent until acked, the phone acks after persisting [V] |
| 30-min bucket checksums for completeness | `UntetheredRecord.swift:85-115` [V] | **Not now** | Sequence plus ack, and End carrying all unsent records, give completeness. Revisit only if M8 shows incomplete histories. Keep her 32-bit lesson (F8) |
| Extended mode (workout keepalive) | watch `Info.plist` `WKBackgroundModes workout-processing` [V] | **Reject** (O-1) | Better coverage at a battery and Fitness cost, and Apple's Workout app ends it anyway (F14). F1 shows it isn't needed |
| End during a watch bolus hands back at once; the bolus continues | c120 [R] | **Keep ours** (End refused during a bolus, V2-3) | Simpler. Fix her #150 UX: W14 copy shows the remaining amount and when End becomes possible |
| Phone auto-retries a refused manual bolus | c150/c157; `APSManager.swift` (A1 §5) [V] | **Reject** | Violates at-most-once intent (SR-10) and only exists because of looks |
| Watch uses the phone's forwarded readings when its own link misses | c-ref 329081308, #111, #112 [R] | **Defer** | Only helps while the phone is nearby, when a loan matters least. Adds a second glucose path into the loop |
| "Pod Link Lost" early notice and open-Trio retry | c167 [R], `+Loop.swift:1967-2000` [V] | **Adopt the notice only** (P2) | Cheap, evidence-backed (#182). The retry happens anyway on the next foreground cycle |
| Watch logs persisted and resent until confirmed | c33 [R] | **Adopt for hardware runs** (P5) | Several of her diagnoses were blocked by lost watch logs (#41, #43) |

## Proposed changes to our architecture and scope (minimal)

1. **P1. Merge late records of a superseded loan.** In `state-and-synchronization.md` §Messages, "ignore lower epochs" applies to control messages only. Record batches of an earlier epoch are merged by sync id, and the loan's audit bolus is recomputed (V2-8). M4 test: Take Back from `lending` with a silent watch that did adopt and dose; its later `records(e)` are stored once and the audit drops by that amount. (H)
2. **P2. Pod-link prompt on the watch.** After 2 consecutive cycles fail at pod connect or session setup (status not confirmed), and 5 min without a confirming cycle, raise a time-sensitive local notification: "Can't reach your pod. Open Trio on your watch." When the phone is reachable, add "or End to let your iPhone loop". This extends V2-17. No automatic hand-back. (M)
3. **P3. Background-task rules in M5** (amend V2-19):
   - hold `ProcessInfo.performExpiringActivity` across each cycle;
   - on expiry, don't start a pump command, and a command already sent stays covered by the write-ahead intent;
   - complete `WKWatchConnectivityRefreshBackgroundTask` within 10 s;
   - never block the main thread on `WCSession` transfer lists.
   Test: a simulated expiry before the enact leaves no intent and sends no command. (H)
4. **P4. Integer widths on arm64_32.** Shared models and messages use Int64 or explicit widths for ms timestamps, counters and hashes. Add a codec test with values above 2^31, run on the watch target. M8 runs on an SE 2. (H)
5. **P5. Logging for hardware runs** (amend V2-31):
   - per pod connect and disconnect: app front/background, RSSI, disconnect reason, session step reached, and whether a G7 link was open at the time;
   - the watch log persisted to a file and resent until the phone confirms. (M)
6. **P6. Audit guards.** No excess booking when the odometer decreased or the pod is faulted; show a notice instead. Expected delivery is summed up to the odometer reading's pod time. Add a test for each. (M)
7. **P7. Nightscout while not `home`.** The phone doesn't upload its own loop status or IOB as current. It uploads watch determinations as they merge, or nothing; V2-26 already tells caregivers updates pause. (M)
8. **P8. ADR-002 evidence note.** Add this field data: multi-hour loops on alert wakes without a workout, with gaps from missed wakes and the background pod-link drops. Reword "Known conflict": the 5/24 h text is not observed as binding on a retained connection (Inferred), and E2 still decides. Add the complication on/off variant to E2. No decision change. (M)
9. **P9. Start waits for the first watch reading.** After adopt, the watch keeps Trio in front ("Waiting for the first reading on your watch…"), which allows the G7 bond prompt, with End offered while the phone is near. This avoids her readingless sessions (#85, #143). (M)
10. **P10. User copy.** At Start and in the docs: wear the watch on the sensor's side for sport, keep the pod where the body doesn't block it from the watch (unproven), and end before updating Trio on the watch. (L)

## M8 hardware test plan (proposal)

Prerequisites: build flag on, P5 logging, a fresh simulator untouched. Devices: one Series 6+ (or 9), one SE 2 (32-bit), G7, DASH. Start in-vitro (a water-filled pod on the body, as tester A did), then in-vivo only after review. Each run records: build SHA, watch model and OS, phone model and iOS, wrist side vs sensor and pod sites, battery start and end, and the exported phone and watch logs. Use only small amounts; this isn't medical advice, and testers should involve their care team.

| ID | Case (her source) | Procedure | Pass |
|---|---|---|---|
| T1 | Start and End, 10x (#13, #152, #153) | Start from the watch with the phone near; End from the watch; count attempts and time to `holding` and to `home` | 10/10 reach one commander; no stuck spinner; audit within tolerance; no second G7 or pod manager in the log |
| T2 (= E2) | 24 h without the phone, no workout, complication off then on (#107, #109, #161) | Phone off; watch on the wrist, screen off, overnight included | Report readings and cycles vs 288; longest gap; time to the first gap of 20 min or more. Pass: no gap over 30 min except during logged radio shadow; every 20-min gap raised the dead-man |
| T3 (= E5) | DASH exchange in the wake window (#20, #45) | Log wake → G7 close → pod connect → status → command → ack per cycle | Exchange completes before expiry in ≥ 99 % of cycles that connected; report background connect success separately |
| T4 | User workout during a loan (#54, #57, #72) | Start Apple's Workout app (outdoor run) for 30 min, sensor on the opposite and then the same side | Report the reading rate per side; no crash; the dead-man fires if a gap reaches 20 min |
| T5 | Pod placement and background link (#181-#184) | 2 h each: pod on the back opposite the watch, then the upper arm on the watch side; Trio in the background | Per-connect logs (P5). Report background vs foreground success per placement; P2 prompt seen if 2 cycles fail |
| T6 | Radio overlap (#22, #25, #27) | From T2/T3 logs: pod connects that overlapped an open G7 link | Count of stalls with vs without overlap (data for F12) |
| T7 | Restarts and relaunches (#96, #164, #171, #174, #79, #80, #105) | Mid-loan: (a) swipe-kill the phone app, (b) restart the phone and leave it locked, (c) restart the watch, (d) phone Bluetooth off then Take Back | (a)-(b) phone never doses while `lent`; (c) dead-man fires, relaunch per W26-W37; (d) P21 alert, nobody doses, alarms armed |
| T8 | Take Back with the watch asleep or unreachable (#49, #83) | Watch in airplane mode, Take Back on the phone, then watch back | Phone `home`; watch's next pod contact refused and it stops (W24); late records merged once (P1); audit recomputed |
| T9 | Battery per model (#36, #107, #176) | From T2 and a normal day | %/h per model; compare against the V2-18 thresholds |
| T10 | App update mid-loan (#87, #175, #66) | (a) install a phone build mid-loan; (b) attempt a watch build mid-loan | (a) the loan continues, End works across versions; (b) document behaviour; the copy warns |
| T11 | Water or shielding (swim claim, F22) | Watch and pod under water for 10-20 min (or shielded), then out | No commands while no readings; dead-man at 20 min; first good reading resumes; no catch-up dosing |
| T12 | Alerts (#5, #17, #79, #128) | Trigger low, no readings and not looping with Trio in front, in the background, with a Focus on and watch off-wrist | Every alert is presented (banner in front, notification otherwise); Focus behaviour recorded, not claimed |

Not covered by her log, so still ours alone: E4 (force-quit or reboot without unlock), E7 (locked or off-wrist watch), E9 (Low Power Mode), E12 (dead-man with the app killed and Low Power Mode on).

## Open questions

1. What causes the background pod-link drops? Is it body shadowing, BLE background connection parameters, or OmnipodKit timing? Her data can't separate them: placement and a watch restart changed together on 16.11 [R #184]. T5 is designed to separate them.
2. How binding is the 5/24 h budget with no Trio complication on the face? Her testers had one [R #52].
3. Does our G7SensorKit pin `08d4886` renew a connect request that stood through a burst (her c15/c112 class)? I read only commit subjects.
4. Does our OmnipodKit pin `e576b45` contain the fix for "missing session keys read back as empty" (her #86, "Nonce prefix should be 8 bytes")? The log says the same code is in #177; I didn't verify which commit.
5. Does our pin have the issue she found in review (c165): a command's connect is skipped right after an asynchronously cancelled heartbeat-probe connect, so the command waits out its timeout? The pin has `8259964` (one pending connect) and `0d361d6` (probe re-arm) [V]. The fix commit `a549f6813` is in her fork only [R].
6. watchOS versions under test aren't stated in the log. Results may not carry across releases.
7. A side note for #1616 reviewers, not ours: her c139 says clearing the meal-time reminder fell through to the global snooze introduced by `0439f82f0` (in our baseline). Unverified; worth a check when #1616 is reviewed.

## Evidence index

- Issue: https://github.com/nightscout/Trio/issues/1784 (body read 2026-11-16, 0 comments) [V].
- Test log: https://claude.ai/artifact/Ett2VxtWHbByCGLopPZ5vw, read 2026-11-16. Tests #1-#184, changes c01-c173, "Build and setup problems", "Setup before testing". Verdict counts recounted from the HTML: 83/68/30/3 [V]. The build SHAs cited in the log (for example `7df482d`, `4e152599b`) are not objects in the published branch, which was rebuilt [V].
- Branch `kristinkand/feature/untethered-watch-mode` @ `f587d1f9b` [V]:
  - Commits since `a56170dc0`: `60f1ef66a` (c171), `a0c015a61` (rename), `f587d1f9b` (c172), merge of dev 1.0.2.74;
  - `DeveloperDocs/Untethered/README.md`;
  - `Trio/Sources/Models/Untethered/UntetheredAudit.swift:7`, `UntetheredSession.swift:74`, `UntetheredMessage.swift:17-18`, `UntetheredRecord.swift:85-115`;
  - `Trio/Sources/Services/Untethered/UntetheredPhoneManager.swift:157, 1669`;
  - `Trio Watch App Extension/Untethered/UntetheredWatchManager.swift:1607`, `UntetheredViews.swift:115`, `UntetheredWatchManager+Loop.swift:1827, 1913, 1967-2000`;
  - `Trio Watch App Extension/Info.plist` (`bluetooth-central`, `workout-processing`, `self-care`), `TrioWatchApp.entitlements`;
  - `fastlane/Fastfile:230` (`upload_to_testflight`). Her log reports TestFlight uploads and installs with this plist (c28, c151), which is indirect evidence for E1 [I].
- Our docs [V]: `architecture/architecture-decisions.md` (ADR-002, ADR-004, ADR-007, ADR-008), `architecture/target-architecture.md` (§3-§6, §8, V2-2 to V2-31, V2-7b), `architecture/watch-loan-decision-table.md` (P11, P13, P21, P24-P28, P36-P38, W3, W14, W24, W26-W37, the Take Back flow table), `architecture/state-and-synchronization.md` (§Messages, Take Back), `architecture/lifecycle-and-execution.md`, `architecture/requirements-and-scope.md` (O-1, O-3, F-1, F-3, F-4), `safety/failure-mode-analysis.md` (FM-03, FM-26), `research/watchos-platform-research.md` (E1-E14, 5/24 h), `research/experimental-trio-inventory.md` (§5, §6), `implementation/implementation-status.md` (M2b pins and rule).
- Kit pins [V]: OmnipodKit `e576b45` contains `8259964`, `0d361d6`, `f5c3a15` (#205), `adf8773` (#211), `859215e` (#214), `033cb17` (keep-alive out of background). G7SensorKit `08d4886` log subjects as cited.
