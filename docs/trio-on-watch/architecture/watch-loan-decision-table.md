# Watch loan decision table (as implemented, M3)

Source: `Trio/Sources/APS/WatchLoan/WatchLoan.swift` (`WatchLoan.decide`). Tests: `TrioTests/WatchLoanTests/`. Status: implemented 2026-11-16 on `feat/tow-loan-core`.

`decide(state, event, context) -> (state, [effect])` is pure. The host (M4 phone coordinator, M5 watch host) runs the effects in list order and feeds pump results and timers back as events.

## Conventions

- **Epochs.** `e` is the current loan epoch. Epochs only grow. A Start bumps the epoch on the phone (`lending(e+1)`); every take-back, by End, by Take Back or automatically (N-4), bumps it again (`takingBack(e+1)`), and `home` keeps the take-back's epoch.
- **Who may command.** Only phone `home` and watch `holding`. A watch `holding(e)` with `e` below the phone's epoch is stale. The kit's foreign-session rule (V2-6) stops it, and the decision table never treats it as a commander.
- **Persist before act.** A list that changes state persists before any pump action. The exception is finishing a take-back (P20): the actions run under the persisted `takingBack`, and `home` is persisted last.
- **Alarms (V2-12).** `phoneNotLooping` is armed in every phone state except `lent`, `phoneNoWatchUpdates` (V2-14) only in `lent`, and `watchNotLooping` in watch `holding`, `returning` and `stopped`. On a transition, arms run before the persist and disarms after it, so a crash in between leaves an extra alarm, never a missing one. A relaunch re-asserts the full set for its state.
- **Takeover context (C-1).** `LoanRecord(epoch, supersededUntil)` names the loan the phone took back. `supersededUntil` (now + 6 h) is set only by a user Take Back. It is cleared when the watch reports `stopped` for that loan. It is never set by End, by the N-4 retake, or by a Take Back from an unreadable state.
- **Audit.** `audit(loanEpoch:)` recomputes and replaces the tagged audit bolus of that loan (V2-8). It is idempotent: the loan's booked doses, including R-5 booked intents (C-4), count as expected, so repeating it never books twice. M4 implements the booking.
- `—` means no change; `[]` means no effects. Events not listed for a state are ignored: `(state, [])`.

## Phone

States: `home(epoch, lastLoan)`, `lending(epoch, requestID)`, `lent(epoch)`, `takingBack(epoch, loan)`, `unreadable` (file can't be read, never persisted). No file means `home(0, nil)`, which is today's behaviour.

Events: `received(message)`, `receivedStop(stop)`, `releaseResult(epoch)`, `takeControlResult(epoch)` (a result carries the epoch of the state that asked for it), `grantUnconfirmed` (timer, 60 s after the grant), `takeBackTapped(watchAnswer)`, `foreignPodSession`, `relaunched`.

| Row | State | Event | Next state | Effects | Test |
|---|---|---|---|---|---|
| P1 | `home(e)` | `request(id)` from epoch w, Start allowed | `lending(max(e,w)+1, id)` | persist, awaitPumpIdle, cancelTemp, refreshDeliveredUnits, releaseControl | `WatchLoanPhoneDecisionTests.p1` |
| P2 | `home(e)` | `request(id)`, Start refused (preconditions or `TRIO_ON_WATCH` off) | — | send `refused(id, reason)` | `p2` |
| P3 | `home(2)` | `request` from watch epoch 7 | `lending(8)` | as P1 | `p3` |
| P4 | `lending(e, id)` | `request(id)` again | — | [] | `p4` |
| P5 | `lending`/`lent`/`takingBack` | `request(other)` | — | send `refused(busy)` | `p5` |
| P6 | `lending(e, id)` | `releaseResult(true)` | — | send `grant(id, expiresAt: now+30 s)` | `p6` |
| P7 | `lending(e, id)` | `releaseResult(false)` | `home(e, nil)` | persist, send `refused(releaseRefused)` | `p7` |
| P8 | `lending(e)` | `holding(e)` | `lent(e)` | arm phoneNoWatchUpdates, persist, disarm phoneNotLooping | `p8` |
| P9 | `lending(e)` | `records(e)` (holding lost) | `lent(e)` | as P8 | `p9` |
| P10 | `lending(e)` | `holding(other epoch)` | — | [] | `p10` |
| P11 | `lending(e, id)` | `grantRejected(id)` (N-4) | `takingBack(e+1, loan(e))` | cancelOutstandingTransfers, persist, sendStop `revoke(e+1)`, takeControl | `p11` |
| P12 | `lending(e, id)` | `grantRejected(other)` | — | [] | `p12` |
| P13 | `lending` | `grantUnconfirmed` | — | alert watchDidNotConfirm | `p13` |
| P14 | `lending(e)` | Take Back, watch answers `holding(e)` | `lent(e)` | as P8, alert takeBackUseEnd | `p14` |
| P15 | `lending(e)` | Take Back, watch silent or not holding | `takingBack(e+1, loan(e, now+6 h))` | cancelOutstandingTransfers, persist, sendStop `revoke(e+1)`, takeControl | `p15` |
| P16 | `lent(e)` | Take Back | `takingBack(e+1, loan(e, now+6 h))` | cancelOutstandingTransfers, arm phoneNotLooping, persist, disarm phoneNoWatchUpdates, sendStop `revoke(e+1)`, takeControl | `p16` |
| P17 | `lent(e)` | `handBack(e)` | `takingBack(e+1, loan(e))` | arm phoneNotLooping, persist, disarm phoneNoWatchUpdates, send `handBackAck(e)`, takeControl | `p17` |
| P18 | `lending(e)` | `handBack(e)` (holding lost) | `takingBack(e+1, loan(e))` | persist, send `handBackAck(e)`, takeControl | `p18` |
| P19 | any with epoch > w | `handBack(w)` | — | send `handBackAck(w)` (idempotent) | `p19` |
| P20 | `takingBack(e, loan)` | `takeControlResult(true)` | `home(e, loan)` | cancelTemp (R-1), refreshDeliveredUnits, audit(loan) (R-2), persist | `p20` |
| P21 | `takingBack` | `takeControlResult(false)` | — | alert takeBackPodUnreachable | `p21` |
| P22 | `takingBack` | Take Back again | — | takeControl | `p22` |
| P23 | `takingBack(e, nil)` | `takeControlResult(true)` | `home(e, nil)` | cancelTemp, refreshDeliveredUnits, alert auditUnavailable, persist | `p23` |
| P24 | `unreadable` | Take Back | `takingBack(now in s since 1970, nil)` | cancelOutstandingTransfers, persist, sendStop revoke, takeControl | `p24` |
| P25 | `home(_, loan with window open)` | `foreignPodSession` | — | podSession(keepCommanding), audit, alert watchContactedPodAfterTakeBack (on every report) | `p25` |
| P26 | `home(_, loan with window closed)` | `foreignPodSession` | — | podSession(refuse), audit, alert unexpectedPodSession | `p26` |
| P27 | `home(_, loan without context)` (End, N-4) | `foreignPodSession` | — | podSession(refuse), audit, alert unexpectedPodSession | `p27` |
| P28 | `home(_, nil)` | `foreignPodSession` | — | podSession(refuse), alert unexpectedPodSession | `p28` |
| P29 | `takingBack(_, loan with window open)` | `foreignPodSession` | — | as P25 | `p29` |
| P30 | `lending`/`lent` | `foreignPodSession` | — | [] (released) | `p30` |
| P31 | `home(_, loan(w) with context)` | `stop(w)` | context cleared | persist | `p31` |
| P32 | `takingBack(_, loan(w) with context)` | `stop(w)` | context cleared | persist | `p32` |
| P33 | `lending(e)`/`lent(e)` | `stop(e)` | — | alert watchStopped | `p33` |
| P34 | `home` | `relaunched` | — | arm phoneNotLooping, disarm phoneNoWatchUpdates | `p34` |
| P35 | `lending` | `relaunched` | — | alarms, alert startDidNotFinish | `p35` |
| P36 | `lent` | `relaunched` | — | arm phoneNoWatchUpdates, disarm phoneNotLooping | `p36` |
| P37 | `takingBack` | `relaunched` (C-3) | — | alarms, takeControl; its result is P20 (same audit input) | `p37` |
| P38 | `unreadable` | `relaunched` | — | alarms, alert loanStateUnreadable | `p38` |
| P39 | `lent`, flag off (D-2) | `relaunched`, then Take Back | `lent` → `takingBack` → `home` | gate closed until `home`; Start stays refused | `p39` |
| P40 | `home` | Take Back, results, timer, holding | — | [] | `p40` |
| P41 | `unreadable` | `foreignPodSession` | — | podSession(refuse), alert unexpectedPodSession | `p41` |
| P42 | `lending(e)`/`takingBack(e)` | a release or take-control result for another epoch | — | [] (late result from an earlier hand-off) | `p42` |

## Watch

States: `idle(epoch)`, `requesting(epoch, requestID)`, `holding(epoch)`, `returning(epoch)`, `stopped(epoch, reason)`. The epoch in `idle` and `requesting` is the last one the watch knows.

Events: `startTapped`, `requestTimedOut` (120 s), `received(message)`, `receivedStop(stop)`, `takeControlResult`, `endTapped`, `releaseResult`, `handBackUnacknowledged` (resend timer), `foreignPodSession`, `stopAcknowledged`, `relaunched(lastCycleAt, phoneEpoch, podSessionForeign)`.

| Row | State | Event | Next state | Effects | Test |
|---|---|---|---|---|---|
| W1 | `idle(e)` | Start | `requesting(e, id)` | persist, send `request(id)` | `WatchLoanWatchDecisionTests.w1` |
| W2 | `idle` | Start refused | — | alert startRefused(reason) | `w2` |
| W3 | `requesting(e)` | `requestTimedOut` | `idle(e)` | persist, alert phoneDidNotAnswer | `w3` |
| W4 | `requesting(e, id)` | `grant(g > e, id)`, not expired, host checks pass | `holding(g)` | arm watchNotLooping, persist, takeControl, send `holding(g)` | `w4` |
| W5 | `requesting(e, id)` | grant expired | `idle(e)` | persist, send `grantRejected(grantExpired)`, alert | `w5` |
| W6 | `requesting(e, id)` | grant fails host checks | `idle(e)` | persist, send `grantRejected(reason)`, alert | `w6` |
| W7 | `requesting(e, id)` | `grant(g ≤ e, id)` | `idle(e)` | persist, send `grantRejected(staleEpoch)`, alert | `w7` |
| W8 | `requesting(e, id)` | `grant(other id)` | — | send `grantRejected(unknownRequest)` | `w8` |
| W9 | `idle`/`returning`/`stopped` | late grant (SB-1) | — | send `grantRejected(unknownRequest)` | `w9` |
| W10 | `holding(g)` | `grant(g)` again | — | send `holding(g)` | `w10` |
| W11 | `requesting(e, id)` | `refused(id, reason)` | `idle(e)` | persist, alert startRefused(reason) | `w11` |
| W12 | `holding` | `takeControlResult(false)` | — | alert podUnreachable | `w12` |
| W13 | `holding(e)` | End | `returning(e)` | persist, cancelTemp, refreshDeliveredUnits, releaseControl | `w13` |
| W14 | `holding` | End refused | — | alert endRefused(reason) | `w14` |
| W15 | `returning(e)` | `releaseResult(true)` | — | send `handBack(e)` | `w15` |
| W16 | `returning(e)` | `releaseResult(false)` | `holding(e)` | persist, alert endRefused(releaseRefused) | `w16` |
| W17 | `returning(e)` | `handBackUnacknowledged` | — | send `handBack(e)` | `w17` |
| W18 | `returning(e)` | `handBackAck(e)` | `idle(e)` | persist, disarm watchNotLooping | `w18` |
| W19 | `holding(e)` | `revoke(n > e)` | `stopped(e, superseded)` | arm, persist, alert, sendStop `stop(e)` | `w19` |
| W20 | `returning(e)` | `revoke(n > e)` | `stopped(e, superseded)` | as W19 | `w20` |
| W21 | `idle(e)`/`requesting(e)` | `revoke(n > e)` | `idle(n)` | persist | `w21` |
| W22 | `stopped(e)` | `revoke` | — | sendStop `stop(e)` | `w22` |
| W23 | `holding(e)` | `revoke(n ≤ e)` | — | [] | `w23` |
| W24 | `holding(e)` | `foreignPodSession` (V2-6) | `stopped(e, foreignSession)` | as W19 | `w24` |
| W25 | `stopped(e)` | user acknowledges | `idle(e)` | persist, disarm watchNotLooping | `w25` |
| W26 | `holding(e)` | relaunch, ≤ 6 h, phone epoch ≤ e or silent, no foreign session | — | arm watchNotLooping, takeControl | `w26` |
| W27 | `holding(e)` | relaunch, phone epoch > e | `stopped(e, superseded)` | as W19 | `w27` |
| W28 | `holding(e)` | relaunch, foreign session | `stopped(e, foreignSession)` | as W19 | `w28` |
| W29 | `holding(e)` | relaunch, > 6 h since last cycle | `stopped(e, resumeWindowPassed)` | as W19 | `w29` |
| W30 | `returning(e)` | relaunch (V2-3) | — | arm, releaseControl; its result is W15 | `w30` |
| W31 | `requesting(e)` | relaunch | `idle(e)` | disarm, persist | `w31` |
| W32 | `stopped`/`idle` | relaunch | — | re-assert alarms | `w32` |
| W33 | any | `statusQuery` | — | send `status(state)` | `w33` |

## Hand-off steps with loss and crash

`WatchLoanFlowTests` runs Start (S1–S6), End (E1–E5) and Take Back (T1–T4) through `LoanWorld`, which joins the two `decide` functions with lossy, reorderable inboxes. Cancelling transfers cancels nothing in the harness, so already-sent messages can still arrive. At each step it loses that step's message, crashes the acting device after each of its effects (0–6), or crashes the other device first. It then runs the documented recovery: timers, Take Back on a stuck `lending`, the watch's next record batch, and the stale watch's next pod contact. Every run must end with one commander and alarms matching both states, and no state on the way may lack an alarm or have two commanders at the same epoch.

| Flow | Step | Loss | Crash, acting device | Crash, other device | Tests |
|---|---|---|---|---|---|
| Start | S1 watch requests | — | `startCrash` | `startOtherCrash` | |
| Start | S2 phone lends | request lost: watch times out, both unchanged | ✓ | ✓ | `startLoss` |
| Start | S3 phone sends grant | — | ✓ (`lending` relaunch alerts; Take Back) | ✓ | |
| Start | S4 watch adopts | grant lost: Take Back, `home(e+2)` | ✓ | ✓ | `startLoss`, `startDocRows` |
| Start | S5 watch takes control | — | ✓ (relaunch takes control again) | ✓ | |
| Start | S6 phone lent | holding lost: record batch moves the phone to `lent` | ✓ | ✓ | `startLoss`, `startDocRows` |
| Start | N-4 | late grant after the watch's timeout: rejected, phone retakes alone | | | `startLateGrant` |
| End | E1 watch returns | — | `endCrash` | `endOtherCrash` | |
| End | E2 watch hands back | — | ✓ (relaunch releases again) | ✓ | |
| End | E3 phone takes back | hand-back lost: resend | ✓ | ✓ | `endLoss` |
| End | E4 watch idle | ack lost: resend, re-ack | ✓ | ✓ | `endLoss` |
| End | E5 phone home | — | ✓ (C-3 relaunch) | ✓ | |
| Take Back | T1 phone takes back | — | `takeBackCrash` | | |
| Take Back | T2 phone home | — | ✓ (C-3 relaunch) | | |
| Take Back | T3 watch stops | revoke lost: the stale watch's next pod contact stops it | ✓ | `takeBackWatchCrash` | `takeBackLoss` |
| Take Back | T4 phone clears context | stop lost: context stays until the window closes | ✓ | | `takeBackLoss` |

## Invariant (V2-12)

`WatchLoanInvariantTests.noSilentStop` searches every interleaving of user taps, timers, delivery, loss and reordering, pump results (success and failure) and a crash after any effect, up to epoch 3 and two requests. In every reached state:
- if no device may dose, at least one not-looping alarm is armed;
- the phone in `home(n)` and the watch in `holding(e)` never have `e ≥ n`;
- a watch in `holding` or `returning` has its own alarm armed.

The search found one bug during M3, now fixed by P42: a late `releaseResult(true)` from an earlier lend could send a grant in a later `lending(e)`, and that lend's own refusal then put the phone in `home(e)` while the watch adopted `holding(e)`.

It also requires that SM-5's pairs (`lent`, `returning`) and (`lending`, `idle`), plus (`lent`, `stopped`) and (`takingBack`, `idle`), are reached.

## Phone gate (V2-27, C-05)

`WatchLoanGate.permits(_:)` reads the phone file on every check. It answers false in every state except `home`, and false with a one-time alert when the file can't be read. Gate tests are in `WatchLoanGateTests`; each runs once as owner (no file, today's behaviour) and once as not owner (`lent`).

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
| 13, 14 | Kit settings and setup UI | `PumpConfig.PumpSettingsView`, `PumpSetupView` show the reason instead | `pumpScreens` |

The gate never sets `pumpManager` to nil, and nothing in it depends on `TRIO_ON_WATCH` (D-2).
