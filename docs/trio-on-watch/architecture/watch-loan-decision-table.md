# Watch loan decision table (as implemented, M3)

Source: `Trio/Sources/APS/WatchLoan/WatchLoan.swift` (`WatchLoan.decide`). Tests: `TrioTests/WatchLoanTests/`. Status: implemented 2026-11-16 on `feat/tow-loan-core`, revised the same day after the M3 reviews (M3E-01 to M3E-10, M3C-03 to M3C-09).

`decide(state, event, context) -> (state, [effect])` is pure. The host (M4 phone coordinator, M5 watch host) runs the effects in list order and feeds pump results and timers back as events.

## Conventions

- **Epochs.** `e` is the current loan epoch, an `Int64` (M3E-06). Epochs only grow:
  - a Start bumps the epoch on the phone (`lending(e+1)`);
  - every take-back bumps it again (`takingBack(e+1)`), whether by End, Take Back, the automatic retake (N-4) or "Use the pod on this iPhone";
  - `home` keeps the take-back's epoch.
- **Who may command.** Only phone `home` and watch `holding`, and only while that device's kit would complete its next session. The invariant search counts a device as commanding unless its kit provably refuses (see Invariant).
- **Persist before act.** A list that changes state persists before any pump action. The exception is finishing a take-back (P20): the actions run under the persisted `takingBack`, and `home` is persisted last.
- **Alarms (V2-12).**
  - `phoneNotLooping` is armed in every phone state except `lent`, and `phoneNoWatchUpdates` only in `lent`.
  - `watchNotLooping` is armed in watch `holding`, `returning`, and `stopped` for any reason except `superseded`. A superseded watch disarms after the persist and the user alert (M3E-10): the phone has the pod at a higher epoch, so the phone's own alarm covers it.
  - On a transition, arms run before the persist and disarms after it. A relaunch re-asserts the full set for its state.
- **Take scope (M3E-05).** `.takeControl(supersedingUntil:)` is the phone's take and carries its window.
  - A user take (Take Back, "Use the pod on this iPhone") passes the loan's `supersededUntil`.
  - End and the automatic retake pass nil.
  - Retries and the relaunch redo pass the persisted value.
  - A take without a window never ends an existing one.
- **Adopt.** The watch never takes. It emits `.adoptControl`, which may resync only to the session the phone released. If the phone has taken the pod since, that newer session is foreign and the adopt is refused. This bounded adopt is a kit requirement the M3 re-search found. M4/M5 map both effects to the kit API (A2 may require explicit intent to lift a refusal).
- **Superseding window (C-1).** `LoanRecord(epoch, supersededUntil, takenAt)` names the loan the phone took back.
  - Only a Take Back from a known watch loan sets the window: now to now + 6 h (M3R-03).
  - It holds only while `takenAt ≤ now < supersededUntil`, so setting the clock back ends it (M3E-07).
  - It is cleared only by a watch `stop` with `released: true`, which the watch sends after its release succeeds (M3E-02).
  - `epoch` is nil when the peer is unknown: after "Use the pod on this iPhone" outside such a window, or a Take Back from an unreadable file. Those take without a window, so another session is refused again and the user can re-confirm.
- **Audit.** `.audit(.loan(epoch))` recomputes the tagged audit bolus of that loan from its release reading. `.audit(.podLifetime)` compares the pod's delivered total since activation with every booked dose and the scheduled basal (M3E-04). Both are idempotent: booked doses, including R-5 booked intents (C-4), count as expected. M4 implements the booking.
- `—` means no change; `[]` means no effects. Events not listed for a state are ignored: `(state, [])`.

## Phone

States: `home(epoch, lastLoan)`, `lending(epoch, requestID)`, `lent(epoch)`, `takingBack(epoch, loan)`, `unreadable` (file can't be read, never persisted). No file means `home(0, nil)`, which is today's behaviour.

Events:
- `received(message)`, `receivedStop(stop)`.
- `releaseResult(epoch)` and `takeControlResult(epoch)`. A result carries the epoch of the state that asked for it.
- `grantUnconfirmed` (timer, 60 s after the grant), `takeBackTapped(watchAnswer)`, `usePodOnThisPhoneConfirmed`, `foreignPodSession`, `relaunched`.

"Take back to n with L" below means: cancelOutstandingTransfers, arm phoneNotLooping (from `lent` only), persist `takingBack(n, L)`, disarm phoneNoWatchUpdates (from `lent` only), sendStop `revoke(n)`, then `takeControl(supersedingUntil: L.supersededUntil)`. "W(e)" is `LoanRecord.superseding(epoch: e, at: now)`.

| Row | State | Event | Next state | Effects | Test |
|---|---|---|---|---|---|
| P1 | `home(e)` | `request(id)` from epoch w, Start allowed | `lending(max(e,w)+1, id)` | persist, awaitPumpIdle, cancelTemp, refreshDeliveredUnits, releaseControl | `WatchLoanPhoneDecisionTests.p1` |
| P2 | `home(e)` | `request(id)`, Start refused (preconditions or flag off) | — | send `refused(id, reason)` | `p2` |
| P3 | `home(2)` | `request` from watch epoch 7 | `lending(8)` | as P1 | `p3` |
| P4 | `lending(e, id)` | `request(id)` again | — | [] | `p4` |
| P5 | `lending`/`lent`/`takingBack` | `request(other)` | — | send `refused(busy)` | `p5` |
| P6 | `lending(e, id)` | `releaseResult(e, true)` | — | send `grant(id, expiresAt: now+30 s)` | `p6` |
| P7 | `lending(e, id)` | `releaseResult(e, false)` | `home(e, nil)` | persist, send `refused(releaseRefused)` | `p7` |
| P8 | `lending(e)` | `holding(e)` | `lent(e)` | arm phoneNoWatchUpdates, persist, disarm phoneNotLooping | `p8` |
| P9 | `lending(e)` | `records(e)` (holding lost) | `lent(e)` | as P8 | `p9` |
| P10 | `lending(e)` | `holding(other epoch)` | — | [] | `p10` |
| P11 | `lending(e, id)` | `grantRejected(id)` (N-4) | `takingBack(e+1, loan(e))` | take back to e+1 with no window | `p11` |
| P12 | `lending(e, id)` | `grantRejected(other)` | — | [] | `p12` |
| P13 | `lending` | `grantUnconfirmed` | — | alert watchDidNotConfirm | `p13` |
| P14 | `lending(e)` | Take Back, watch answers `holding(e)` | `lent(e)` | as P8, alert takeBackUseEnd | `p14` |
| P15 | `lending(e)` | Take Back, watch silent or not holding | `takingBack(e+1, W(e))` | take back to e+1 with W(e) | `p15` |
| P16 | `lent(e)` | Take Back | `takingBack(e+1, W(e))` | take back to e+1 with W(e) | `p16` |
| P17 | `lent(e)` | `handBack(e)` | `takingBack(e+1, loan(e))` | arm phoneNotLooping, persist, disarm phoneNoWatchUpdates, send `handBackAck(e)`, takeControl(nil) | `p17` |
| P18 | `lending(e)` | `handBack(e)` (holding lost) | `takingBack(e+1, loan(e))` | persist, send `handBackAck(e)`, takeControl(nil) | `p18` |
| P19 | any with epoch > w | `handBack(w)` | — | send `handBackAck(w)` (idempotent) | `p19` |
| P20 | `takingBack(e, L)` | `takeControlResult(e, true)` | `home(e, L)` | cancelTemp, refreshDeliveredUnits, audit(L), persist | `p20` |
| P21 | `takingBack` | `takeControlResult(e, false)` | — | alert takeBackPodUnreachable | `p21` |
| P22 | `takingBack(e, L)` | Take Back again | — | takeControl(L.supersededUntil), never a plain take | `p22` |
| P23 | `takingBack(e, W(nil))` | `takeControlResult(e, true)` | `home(e, W(nil))` | cancelTemp, refreshDeliveredUnits, audit(podLifetime), persist | `p23` |
| P24 | `unreadable` | Take Back | `takingBack(Unix seconds, loan(nil))` | take back with no window; the result audits the pod lifetime | `p24`, `WatchLoanFlowTests.unreadableStateFile` |
| P25 | `home(_, L)`, window open | `foreignPodSession` | — | podSession(keepCommanding(until)), audit(L), alert watchContactedPodAfterTakeBack (on every report) | `p25` |
| P26 | `home(_, L)`, window closed | `foreignPodSession` | — | podSession(refuse), audit(L), alert unexpectedPodSession | `p26` |
| P27 | `home(_, loan(e))` without window (End, N-4) | `foreignPodSession` | — | podSession(refuse), audit(loan e), alert unexpectedPodSession | `p27` |
| P28 | `home(_, nil)` | `foreignPodSession` | — | podSession(refuse), audit(podLifetime), alert unexpectedPodSession | `p28` |
| P29 | `takingBack(_, L)`, window open | `foreignPodSession` | — | as P25 | `p29` |
| P30 | `lending`/`lent` | `foreignPodSession` | — | [] (released) | `p30` |
| P31 | `home(_, W(w))` | `stop(w, released: true)` | window cleared | persist; a stop without `released` changes nothing | `p31` |
| P32 | `takingBack(_, W(w))` | `stop(w, released: true)` | window cleared | persist | `p32` |
| P33 | `lending(e)`/`lent(e)` | `stop(e)` | — | alert watchStopped | `p33` |
| P34 | `home` | `relaunched` | — | arm phoneNotLooping, disarm phoneNoWatchUpdates | `p34` |
| P35 | `lending` | `relaunched` | — | alarms, alert startDidNotFinish | `p35` |
| P36 | `lent` | `relaunched` | — | arm phoneNoWatchUpdates, disarm phoneNotLooping | `p36` |
| P37 | `takingBack(e, L)` | `relaunched` (C-3) | — | alarms, takeControl(L.supersededUntil); its result is P20 (same audit input) | `p37` |
| P38 | `unreadable` | `relaunched` | — | alarms, alert loanStateUnreadable | `p38` |
| P39 | `lent`, flag off (D-2) | `relaunched`, then Take Back | `lent` → `takingBack` → `home` | gate closed until `home`; Start stays refused | `p39` |
| P40 | `home` | Take Back, results, timer, holding | — | [] | `p40` |
| P41 | `unreadable` | `foreignPodSession` | — | podSession(refuse), audit(podLifetime), alert unexpectedPodSession | `p41` |
| P42 | `lending(e)`/`takingBack(e)` | a result for another epoch | — | [] (late result from an earlier hand-off) | `p42` |
| P43 | `home(e, L)`, L nil, without window or window closed | `usePodOnThisPhoneConfirmed` (M3E-03, M3R-03) | `takingBack(e+1, loan(nil))` | take back to e+1 with no window, alert podTakenOnThisPhone; the result audits the pod lifetime; a further foreign session is refused again; `lending`, `lent`, `unreadable`: [] | `p43` |
| P44 | `home(_, W(w))`, clock set back before `takenAt` | `foreignPodSession` | — | podSession(refuse), … (window ended) | `p44` |
| P45 | `home(e, W(w))`, window open | `usePodOnThisPhoneConfirmed` | `takingBack(e+1, W(w))` | take back to e+1 keeping W(w), alert; the result audits loan w | `p45` |
| P46 | `takingBack(e, L)` (a plain take the kit keeps refusing, M4E-09) | `usePodOnThisPhoneConfirmed` | `takingBack(e+1, …)` | as P43/P45 with L in place of the last loan | `p46` |

## Watch

States: `idle(epoch)`, `requesting(epoch, requestID)`, `holding(epoch)`, `returning(epoch)`, `stopped(epoch, reason)` with reason `superseded`, `foreignSession`, `resumeWindowPassed` or `unconfirmed`. The epoch in `idle` and `requesting` is the last one the watch knows.

Events:
- `startTapped`, `requestTimedOut` (120 s), `received(message)`, `receivedStop(stop)`.
- `takeControlResult`, `endTapped`, `releaseResult`, `handBackUnacknowledged` (resend timer), `foreignPodSession` (reported by the kit), `stopAcknowledged`.
- `relaunched(lastCycleAt, phoneEpoch, podSessionForeign, kitHasControl)`. The last two are read from the kit's persisted state, never by taking control.

"Stop(r)" below means:
1. arm (when the new state needs it), persist `stopped(e, r)`, alert stopped(r);
2. disarm watchNotLooping (when r is `superseded`);
3. releaseControl, then sendStop `stop(e, released: false)`.

The release result then sends `stop(e, released: true)` (W35).

| Row | State | Event | Next state | Effects | Test |
|---|---|---|---|---|---|
| W1 | `idle(e)` | Start | `requesting(e, id)` | persist, send `request(id)` | `WatchLoanWatchDecisionTests.w1` |
| W2 | `idle` | Start refused | — | alert startRefused(reason) | `w2` |
| W3 | `requesting(e)` | `requestTimedOut` | `idle(e)` | persist, alert phoneDidNotAnswer | `w3` |
| W4 | `requesting(e, id)` | `grant(g > e, id)`, not expired, host checks pass | `holding(g)` | arm watchNotLooping, persist, adoptControl, send `holding(g)` | `w4` |
| W5 | `requesting(e, id)` | grant expired | `idle(e)` | persist, send `grantRejected(grantExpired)`, alert | `w5` |
| W6 | `requesting(e, id)` | grant fails host checks | `idle(e)` | persist, send `grantRejected(reason)`, alert | `w6` |
| W7 | `requesting(e, id)` | `grant(g ≤ e, id)` | `idle(e)` | persist, send `grantRejected(staleEpoch)`, alert | `w7` |
| W8 | `requesting(e, id)` | `grant(other id)` | — | send `grantRejected(unknownRequest)` | `w8` |
| W9 | `idle`, or `returning`/`stopped` of another loan | late grant | — | send `grantRejected(unknownRequest)` | `w9` |
| W10 | `holding(g)` | `grant(g)` again | — | send `holding(g)` | `w10` |
| W11 | `requesting(e, id)` | `refused(id, reason)` | `idle(e)` | persist, alert startRefused(reason) | `w11` |
| W12 | `holding` | `takeControlResult(false)` | — | alert podUnreachable | `w12` |
| W13 | `holding(e)` | End | `returning(e)` | persist, cancelTemp, refreshDeliveredUnits, releaseControl | `w13` |
| W14 | `holding` | End refused | — | alert endRefused(reason) | `w14` |
| W15 | `returning(e)` | `releaseResult(true)` | — | send `handBack(e)` | `w15` |
| W16 | `returning(e)` | `releaseResult(false)` | `holding(e)` | persist, alert endRefused(releaseRefused) | `w16` |
| W17 | `returning(e)` | `handBackUnacknowledged` | — | send `handBack(e)` | `w17` |
| W18 | `returning(e)` | `handBackAck(e)` | `idle(e)` | persist, disarm watchNotLooping | `w18` |
| W19 | `holding(e)` | `revoke(n > e)` | `stopped(e, superseded)` | Stop(superseded) | `w19` |
| W20 | `returning(e)` | `revoke(n > e)` | `stopped(e, superseded)` | Stop(superseded) | `w20` |
| W21 | `idle(e)` / `requesting(e, id)` | `revoke(n > e)` | `idle(n)` / `requesting(n, id)` | persist; the request stands, a grant at epoch ≤ n is stale | `w21` |
| W22 | `stopped(e)` | `revoke` | — | sendStop `stop(e)`, releaseControl | `w22` |
| W23 | `holding(e)` | `revoke(n ≤ e)` | — | [] | `w23` |
| W24 | `holding(e)` | `foreignPodSession` | `stopped(e, foreignSession)` | Stop(foreignSession) | `w24` |
| W25 | `stopped(e)` | user acknowledges | `idle(e)` | persist, disarm what is armed | `w25` |
| W26 | `holding(e)` | relaunch, kit holds, ≤ 6 h, phone not ahead, no refusal | — | arm watchNotLooping; **no take** (M3E-01) | `w26` |
| W27 | `holding(e)` | relaunch, phone epoch > e | `stopped(e, superseded)` | Stop(superseded) | `w27` |
| W28 | `holding(e)` | relaunch, kit refused a foreign session | `stopped(e, foreignSession)` | Stop(foreignSession) | `w28` |
| W29 | `holding(e)` | relaunch, > 6 h since last cycle | `stopped(e, resumeWindowPassed)` | Stop(resumeWindowPassed) | `w29` |
| W30 | `returning(e)` | relaunch | — | arm, releaseControl; its result is W15 | `w30` |
| W31 | `requesting(e)` | relaunch | `idle(e)` | disarm, persist | `w31` |
| W32 | `stopped`/`idle` | relaunch | — | re-assert alarms; `stopped` also releases again | `w32` |
| W33 | any | `statusQuery` | — | send `status(state)` | `w33` |
| W34 | `returning(e)`/`stopped(e)` | `grant(e)` again (M3E-08) | — | send `status(state)`, no rejection | `w34` |
| W35 | `stopped(e)` | `releaseResult(true)` / `(false)` | — | sendStop `stop(e, released: true)` / [] | `w35` |
| W36 | `holding(e)` | relaunch, kit never adopted, phone answers e | — | arm, adoptControl (bounded to the released session) | `w36` |
| W37 | `holding(e)` | relaunch, kit never adopted, phone silent or behind | `stopped(e, unconfirmed)` | Stop(unconfirmed); never takes | `w37` |
| W38 | state file can't be read (host, before `decide`) | launch | `stopped(0, unconfirmed)`, in memory only, never persisted | alert stopped(unconfirmed); the relaunch then runs W32: alarms re-asserted, releaseControl | `WatchLoanHostTests.unreadableState` |

## Wire format

- Every message carries `protocolVersion`, `epoch` (`Int64`), `messageID` and `sentAt`.
- `stop` and `revoke` use a frozen wrapper (`{"stop": {kind, epoch, released}}`) that any protocol version parses. Only optional keys may be added; a missing `released` decodes as false (M3R-02, `stopWithoutReleased`).
- `handBack` and `handBackAck` also decode across protocol versions, so End works through a version skew (M3E-09).
- Record batches across versions are left to M4, which defines their payload.

## Hand-off steps with loss and crash

`WatchLoanFlowTests` runs Start (S1–S6), End (E1–E5) and Take Back (T1–T6) through `LoanWorld`. `LoanWorld` joins the two `decide` functions with lossy, reorderable inboxes and one pod modelled after the kit review (see Invariant).

At each step a run either loses that step's message, crashes the acting device after each of its effects (0–6), or crashes the other device first. It then runs the documented recovery:
- the timers;
- Take Back on a stuck `lending`;
- the watch's next record batch;
- each kit's next pod contact;
- "Use the pod on this iPhone" when the phone's kit refuses.

Every run must end with one commander whose kit holds the pod, with alarms matching both states.

| Flow | Step | Loss | Crash, acting device | Crash, other device | Tests |
|---|---|---|---|---|---|
| Start | S1 watch requests | — | `startCrash` | `startOtherCrash` | |
| Start | S2 phone lends | request lost: watch times out, both unchanged | ✓ | ✓ | `startLoss` |
| Start | S3 phone sends grant | — | ✓ (`lending` relaunch alerts; Take Back) | ✓ | |
| Start | S4 watch adopts | grant lost: Take Back, `home(e+2)` | ✓ (relaunch before the take: take only if the phone answers e, else stop) | ✓ | `startLoss`, `startDocRows` |
| Start | S5 watch takes control | — | ✓ (kit holds: resume without a take) | ✓ | |
| Start | S6 phone lent | holding lost: record batch moves the phone to `lent` | ✓ | ✓ | `startLoss`, `startDocRows` |
| Start | late grant | rejected after the watch's timeout, phone retakes alone | | | `startLateGrant` |
| End | E1 watch returns | — | `endCrash` | `endOtherCrash` | |
| End | E2 watch hands back | — | ✓ (relaunch releases again) | ✓ | |
| End | E3 phone takes back | hand-back lost: resend | ✓ | ✓ | `endLoss` |
| End | E4 watch idle | ack lost: resend, re-ack | ✓ | ✓ | `endLoss` |
| End | E5 phone home | — | ✓ (relaunch redo) | ✓ | |
| Take Back | T1 phone takes back | — | `takeBackCrash` | | |
| Take Back | T2 phone home | — | ✓ (relaunch redo keeps the window) | | |
| Take Back | T3 watch stops | revoke lost: the stale watch's next pod contact is refused and stops it | ✓ | `takeBackWatchCrash` | `takeBackLoss` |
| Take Back | T4 watch releases | — | ✓ (relaunch releases again) | | |
| Take Back | T5 phone hears the stop | lost: the released stop still clears | ✓ | | `takeBackLoss` |
| Take Back | T6 phone clears the window | lost: the window stays until it closes | ✓ | | `takeBackLoss` |
| Take Back | watch off, relaunched with the phone unreachable | — | | | `takeBackWatchOffPhoneUnreachable` (M3E-01) |
| Start + Take Back | watch crashed before its adopt, phone took back, relaunch with the phone unreachable | — | | | `adoptCrashThenTakeBack` (M3E-01) |
| Start + Take Back | Take Back while the watch's adopt is still in flight; the late adopt is refused | — | | | `adoptRacesTakeBack` |
| Loan 2 | every late loan-1 message and stop, both directions, while loan 2 is `lending` or `lent`: no state change except the watch learning a newer epoch, no pump action (M3R-01) | | | | `lateLoanOneMessages` |
| Any | phone state file unreadable in `lending`, `lent` or `takingBack`: gate closed, Take Back recovers (M3R-05) | | | | `unreadableStateFile` |

## Invariant

`WatchLoanInvariantTests.noTwoCommandersNoSilentStop` searches the reachable states exhaustively within its bounds: epoch 2 (one loan and its take-back), at most two queued messages per inbox, with queues compared as multisets. The default run allows one Start (about 60 s). `noTwoCommandersNoSilentStopTwoRequests`, gated by `TRIO_STRESS=1`, allows a second Start (about 4 min); it passed on this revision. An epoch-3 bound with the kit model didn't finish in 15 min. It covers:
- every interleaving of user taps (including "Use the pod on this iPhone" when the phone is refused);
- timers, and message delivery, loss and reordering;
- pump results, success and failure;
- either kit talking to the pod at any time;
- a crash after any effect.

The pod is modelled after the kit review (M2b-05):
- A take handshakes at once, lifts any refusal, keeps an existing window when it has none, and moves the pod's session to that controller without a detection.
- Any other controller's next session sees a foreign session. Inside its window it keeps commanding; otherwise it refuses before sending anything.
- An adopt accepts only the session the phone released. If the phone has taken the pod since, the adopt is foreign.
- A device "commands" when its persisted state permits, its kit holds, isn't refusing, and either holds the pod's session or is inside its window. So `holding(e)` next to `home(n > e)` is illegal unless the watch's kit provably refuses.

In every reached state:
- at most one device commands;
- if no device commands, at least one not-looping alarm is armed;
- a watch in `holding` or `returning` has its own alarm armed.

It also requires that the pairs (`lent`, `returning`), (`lending`, `idle`), (`lent`, `stopped`) and (`takingBack`, `idle`) are reached with no commander.

`kitModelCatchesPlainTake` shows the model catches M3E-01: a watch take after the phone's Take Back is flagged as two commanders. The search also found two bugs, both fixed:
- a late release result from an earlier lend could complete a later lend (P42);
- once the kit was modelled, a watch adopt still in flight could complete after the phone's superseding Take Back and absorb the phone's session (fixed by `.adoptControl`).

## Phone gate (V2-27, C-05)

`WatchLoanGate.refusal(_:userInitiated:)` reads the phone file once per check:
- It returns nil only in `home`, and otherwise the reason to show.
- A file that can't be read raises one alert per process (M3C-04).
- User-initiated refusals log at `info`, periodic ones at `debug` (M3C-08).
- `permits` is the Boolean form.

Gate tests are in `WatchLoanGateTests`; each runs once as owner (no file, today's behaviour) and once as not owner (`lent`).

| C-05 # | Path | Where | Test |
|---|---|---|---|
| 1, 2, 3 | Loop entry (temp basal, SMB, re-entry after a manual temp) | `APSManager.loop()` before `loopGuard.tryStart`, no `processError` | `loop` |
| 1, 2 | Loop enactment (in-flight loop at lend) | `APSManager.enactDetermination()` | `enactDetermination` |
| 4 | Manual bolus (all callers: treatments, quick-pick, Shortcuts, remote, watch) | `APSManager.verifyStatus()` (used by `enactBolus`) | `bolus` |
| 5 | Cancel bolus | `APSManager.cancelBolus(_:)` | `cancelBolus` |
| 6 | Temp cancel on switch to basal testing | `APSManager.cancelAutomaticTempBasal()` | `cancelAutomaticTempBasal` |
| C-10 | TDD on a released pump | `APSManager.calculateAndStoreTDD()` | `tdd` |
| 7 | Pump refresh on each reading | `DeviceDataManager.heartbeat(date:)` | `heartbeat` |
| 8 | BLE heartbeat requests (pump set, CGM capability, CGM schedule) | `DeviceDataManager.sendBLEHeartbeatRequest(_:)` | `bleHeartbeat`, `pumpSet` |
| 9 | Delivery limits when the pump is set, including the launch restore | `DeviceDataManager.pumpManager` `didSet` | `pumpSet` |
| 10 | Delivery limits from settings | `UnitsLimitsSettings`, `AlgorithmAdvancedSettings`, `NightscoutConfig` providers | `deliveryLimitsFromSettings` |
| 11 | Basal schedule sync | `BasalProfileEditor.Provider.saveProfile` | `basalSchedule` |
| 12 | Pump alert acknowledgement | `BaseTrioAlertManager.acknowledgeOnDevice` (pump responders only) | `alertAcknowledgement` |
| 13, 14 | Kit settings and setup UI | `PumpConfig.PumpSettingsView`, `PumpSetupView` show the reason instead, using the injected gate (M3C-03) | `pumpScreens` |

The gate never sets `pumpManager` to nil, and nothing in it depends on `TRIO_ON_WATCH` (D-2).
