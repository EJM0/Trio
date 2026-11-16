# Upstream kit state, 2026-11-16: LoopKit, OmnipodKit, G7SensorKit

Research for Trio on Watch. Read-only on our worktrees; clones and builds in a session scratch directory. Subject: the
kit claims in nightscout/Trio#1784 (kristinkand, "untethered" watch mode) checked against the real upstream branches,
and what they mean for our pins on `feat/trio-on-watch` @ `8b5227851`. Claims are marked **Verified** (read in code,
git or GitHub), **Inferred** (reasoned from verified code, not exercised) or **Unverified** (stated by someone, not
checked). This is insulin-dosing code: no claim here is evidence of safe behaviour on hardware.

## Executive summary

1. Most of the issue's "upstream" kit list is not upstream. It describes kristinkand's personal forks
   (`kristinkand/LoopKit untethered-next-dev`, `kristinkand/OmnipodKit untethered-personal(-podtest)`,
   `kristinkand/G7SensorKit untethered-personal`), which the experimental branch pins. (Verified)
2. LoopKit: loopandlearn `trio-next-dev` is still `babddf04` (2026-11-04), the nightscout/Trio dev pin. The hand-off
   protocols have been in it since LoopKit/LoopKit#626. There is **no** upstream foreign-session refusal in LoopKit;
   the "2 commits" are kristinkand fork commits, and loopandlearn/LoopKit#8 (EJM0) was closed unmerged. (Verified)
3. OmnipodKit: loopandlearn `dev` and `next-dev` contain **no** hand-off code and no watchOS target. #177 is **open**
   (head `e8216cd`, 2026-11-12). #203 (EJM0, #177 on `dev`) was closed unmerged. #205, #211 and #214 are merged and
   already in our pin. (Verified)
4. None of our M2b kit safety rules exists upstream, in #177 or in any fork in an equivalent form. #177's author
   prefers host-side resolution (phone reads, asks the watch, stands down). Our patch stays necessary in full. (Verified)
5. #177 moved past our base `3d21d9c` only by merging next-dev #216 (`doseId`) and #220 (async delegates) and one
   `await`. Those need LoopKit #695/#696, which our kit set (Dana, Medtrum, Minimed, Libre) can't take today. Our patch
   merges textually clean onto `e8216cd`; one test call needs `decisionId:` → `doseId:`. (Verified)
6. G7SensorKit: our pin `08d48863` already has #80 including the rebond and restored-mid-disconnect fixes (Pete
   Schwamb's `651c2a4`, `5db6301`). New on next-dev: #113, #115, #117, #119 (useful) and #118 (needs LoopKit #696).
   loopandlearn/G7SensorKit#20 (open) is exactly next-dev minus #118. (Verified)
7. Built in scratch: Trio iOS app with G7 `e3adb3b` (#20) on our LoopKit/OmnipodKit pins, exit 0; G7SensorKit-watchOS
   simulator and device, exit 0; G7SensorKit tests 207/0 failed; OmniTests 271/0 failed (`DeviceHandoffTests` 53/0).
   #177 head against our LoopKit fails to compile (`doseId`). (Verified)
8. Recommendation: stay on LoopKit `7fd4d1a7` and OmnipodKit `c23daca`. Move G7SensorKit to #20's content (`e3adb3b`)
   once #20 merges, ideally as a normal Trio dev bump. Rebase our OmnipodKit patch only when Trio moves the whole kit
   set to LoopKit #695/#696. Carry nothing from the kristinkand forks.

## 1. Heads and pins (as of 2026-11-16)

| Repo / ref | Head | Date | Notes |
|---|---|---|---|
| nightscout/Trio `dev` | `e6a9259e2` | 2026-11-16 | Pins LoopKit `babddf04`, OmnipodKit `6fdf0e0e`, G7SensorKit `08d48863`; unchanged since our baseline `ad6c66876` |
| Ours `feat/trio-on-watch` | `8b5227851` | | LoopKit `7fd4d1a7`, OmnipodKit `c23daca`, G7SensorKit `08d48863` |
| loopandlearn/LoopKit `trio-next-dev` | `babddf04` | 2026-11-04 | No commits since. Open #9 (mountrcg) syncs it to next-dev through #695/#696/#699 |
| LoopKit/LoopKit `next-dev` | `8c3b9ee2` | 2026-11-16 | 8 commits past our `7fd4d1a7`, incl. #696, #695, #699, #700 |
| loopandlearn/OmnipodKit `next-dev` | `dc8b923` | 2026-11-12 | #216, #220 past our base; no hand-off code |
| loopandlearn/OmnipodKit `dev` | `8df3d7b` | 2026-11-11 | #221 translations; no hand-off code |
| loopandlearn/OmnipodKit#177 (jeremybarnum `sportmode/next-dev`) | `e8216cd` | 2026-11-12 | OPEN, MERGEABLE, no review decision, 40 commits |
| LoopKit/G7SensorKit `next-dev` | `26d6da0` | 2026-11-16 | #113, #115, #117, #118, #119 past our pin |
| loopandlearn/G7SensorKit `trio-next-dev` | `08d48863` | 2026-11-02 | = our pin = Trio dev pin |
| loopandlearn/G7SensorKit#20 (EJM0) | `e3adb3b` | 2026-11-16 | OPEN, MERGEABLE: next-dev minus #118 (#119 cherry-picked) |
| kristinkand/Trio `feature/untethered-watch-mode` | `f587d1f9b` | | Moved past the `a56170dc0` we inventoried; kit pins unchanged: LoopKit `8e8607db`, OmnipodKit `9432ad4f`, G7 `48158d8c`, all on kristinkand forks |

Verified: `git ls-remote`, `git ls-tree`, `gh pr view`, GitHub contents API for the kristinkand pins.

## 2. Issue #1784's kit claims, checked

### LoopKit

| Claim | Where it actually is | Status |
|---|---|---|
| "2 commits on loopandlearn trio-next-dev": hand-off protocols `ExclusiveDeviceControl`, `DeviceConfigurationSharing`, `PumpDeliveryOdometer` | The protocols are LoopKit/LoopKit#626 (jeremybarnum, merged 2026-10-24, `dee2a369`), already in `babddf04` (`DeviceManager.swift:101,127`, `PumpManager.swift:349`) | Protocols: upstream, already pinned. The 2 commits (`825bb3a9`, `8e8607db`) are on kristinkand/LoopKit `untethered-next-dev` only |
| "the foreign-session refusal" | kristinkand/LoopKit `825bb3a9`: `ExclusiveDeviceControl.refusesForeignSessionsSince { get set }`, `lastForeignSessionAt`, plus 4 more members and 3 `PumpDeliveryOdometer` members | Fork only. Not on any LoopKit or loopandlearn branch. loopandlearn/LoopKit#8 (EJM0 → `trio`) closed 2026-11-07 unmerged. Upstream removed `lastForeignSessionAt` in `2aecef07` ("As suggested in review … the unused last-foreign-session date are dropped") |

### OmnipodKit

| Claim (issue wording) | Author | Where it actually is | In our `c23daca`? |
|---|---|---|---|
| Pod hand-off and a watchOS target, "on loopandlearn dev" | EJM0 | #177 (open); kristinkand fork `11017f5`; #203 (EJM0 → `dev`) closed 2026-11-07 unmerged. Not on `dev` or `next-dev` | Yes, via #177 @ `3d21d9c` |
| Deactivating a pod on the watch | EJM0 | `deactivateAndForgetPod` / `discardPod` in kristinkand fork `94422b1` and closed #203. #177 has only `deactivateFailedDevice()` for a faulted pod (`2a2f0207`) | Faulted pod only |
| Refusing commands after foreign control | EJM0 | kristinkand fork `b22886a` (host-set `refusesForeignSessionsSince`) | We have our own, stronger rule (section 3) |
| Export only the pod in use | EJM0 | kristinkand fork `34f016b` (4 lines: `previousPodState = nil` in export and adopt) | No |
| A release waits only for a live exchange | jeremybarnum | #177 `b1175325` | Yes |
| No session on a handed-over pod before a handshake | jeremybarnum | #177 `8f2b4db` | Yes, plus our wider C-2 rule |
| Dropping an unconfirmed command after a resync on a shared pod | jeremybarnum | #177 `a96f5d0a` | Yes |
| Escalation search | jeremybarnum | #177 `488f927`, `f35bad5` | Yes |
| One pending connect per pod (#177) | jeremybarnum | #177 `82599646` | Yes |
| #205 Int64 SQNs | ps2 | Merged to `next-dev` 2026-11-08 (`f5c3a15d`) | Yes |
| #211 bolus cut short by a pod fault | ps2 | Merged to `dev` 2026-11-08, `next-dev` via #215 | Yes |
| #214 unhook a replaced PeripheralManager | ps2 | Merged to `dev` 2026-11-10, `next-dev` via #219 | Yes |
| "Smaller fixes for the watch": a released manager fails at once, link logging, no turn-taking with the G7's link | kristinkand | kristinkand fork only: `9432ad4`, `983df0e`, `be108d5`, `2ba66a2` | No |

All Verified by `git merge-base --is-ancestor` of each PR's merge commit against `3d21d9c8`, `c23dacac`, #177 head,
`next-dev`, `dev`, and by `git grep` for the symbols.

### G7SensorKit

| Claim | Where it actually is | In our pin `08d48863`? |
|---|---|---|
| Watch display slot (#80) | LoopKit/G7SensorKit#80, merged to `next-dev` 2026-10-24 (`0c43b91e`) | Yes |
| Rebonding, and reconnecting a sensor restored mid-disconnect (EJM0) | Landed through #80 as Pete Schwamb's `651c2a4` ("Rebond a reconnect …", co-authored EJM0, kristinkand) and `5db6301` ("Watch acquisition: fixes from a week on a watch": restored connecting/disconnecting peripheral cancelled and replaced). EJM0's originals `7263b91`, `850f9a1` are only on kristinkand `untethered-pr` | Yes |
| Watch acquisition holds and renewals | kristinkand fork only: `fd60465` (hold granted synchronously), `e99e30b` (renew a lodged request after 1.5 bursts), `cf67d77` | No |
| Damon Bayer's alert-marker fix (#112) | #112 **closed** unmerged. Its intent is in #115 (`9f278b7`, "its issued marker survives the forget (as in LoopKit/G7SensorKit#112)") | No (#115 is in #20) |
| Calibration advice (ETolboom) | #113, merged to `next-dev` 2026-11-11 | No (in #20) |
| Sensor-issue flag (dnzxy) | `e99d631` "Flag any unusable reading as a sensor issue" is on loopandlearn `feat/trio-g7-direct` (a stale branch) and the kristinkand fork; not on `next-dev` or `trio-next-dev`. Upstream chose #90/#99 (ps2) instead | No |

## 3. Our M2b rules vs. upstream and the forks

Our rule: `c23daca` = #177 @ `3d21d9c` + 7 local commits, +826/−11 in 6 files (`OmniTests/DeviceHandoffTests.swift`
+537). Contract in `implementation/omnipodkit-177-proposal.md`.

| Rule | Ours (`c23daca`) | #177 head (`e8216cd`) | kristinkand fork (`9432ad4f`) |
|---|---|---|---|
| Detect another controller's session | Every unexpected resync on a shared pod, after accounting for the expected one (adopt, take-back after own release) and own counter (`handshakeResynced`, `+DeviceHandoff.swift:184`) | Resync drops an unconfirmed command, books nothing, logs (`BlePodComms.swift:384`, `resolveAfterSessionResync`). Session continues | Every resync recorded in memory (`lastSqnResync`, `BlePodComms.swift:70,390`) |
| Refusal trigger | Kit decides; persisted `PodState.refusesSessions` (`PodState.swift:167`) | None | Host opts in by setting `refusesForeignSessionsSince` (persisted); compared with the in-memory `lastSqnResync` |
| Refusal scope | Every session: boluses, temps incl. zero, suspend, resume, schedule, alert acks, status reads (`OmniPumpManager.swift:1776`, `bleRunSession`). No handshake at all (`nextHandshakeSqn` nil), no retry handshake | n/a | Every session after the handshake (`BlePodComms.swift:826`), so reductions and reads too. The handshake itself still runs, and `fc903e3` restores the second handshake after a resync |
| Survives relaunch | Yes (persisted flag; refused manager releases the link at init, `OmniPumpManager.swift:139`) | n/a | **No** (Inferred): `lastSqnResync` is not persisted, so after a relaunch the guard has nothing to compare until the next resync, and the pod's counter was already adopted |
| Takeover / superseding scope | `takeControl(supersedingAnotherControllerUntil:)`, scope on `CLOCK_MONOTONIC_RAW` (`+DeviceHandoff.swift:206-233,356`); only the phone makes it | None; author's model: phone reads, sees the foreign session, asks the watch, stands down if it answers | None. `takeControl()` clears the refusal (`resumeControl`) |
| Accepted-SQN high-water mark | `AcceptedEapSqn` in local `UserDefaults` (`BlePodComms.swift:972`) | None | None: its own late-saved counter counts as foreign (fails closed) (Inferred) |
| Restored-link handshake | Any shared pod in a new process handshakes even with saved keys (`BlePodComms.swift:45-48`) | Handshake only when session keys are missing (`8f2b4db`) | Same as #177 (`02782f9`) |
| Bounded adopt | `releasedEapSqn` (`PodState.swift:157`) | None | None |
| Refused-adopt signal to host | `refusesSessions`, `foreignSessionDetectedAt` (persisted, via `pumpManagerDidUpdateState`), typed `PodCommsError.podUsedByAnotherController` (`PodCommsSession.swift:46`) | None (device log only) | `lastForeignSessionAt` (in memory, protocol), untyped `diagnosticMessage("Another controller has used this pod")` |
| No release while a command is unconfirmed | Yes, from #177 `8fe606c` (`mayReleaseControl`) | Yes | **No** (`mayReleaseControl` absent at `9432ad4f`) |

Verified by reading each ref. The relaunch row for the fork is Inferred from the code (not exercised).

Upstream stance (Verified, #177 comments): jeremybarnum (2026-11-03) says the second handshake is intended, because
"reading the pod is how the phone finds out another controller has run it … pings the watch to confirm. If the watch
replies, the phone stands down; if not, the phone keeps the pod". On EJM0's request to add the refusal (2026-10-26) he
said he would look at "which of these address proven problems". kristinkand replied on 2026-11-03 that her fork
"will drop that rule"; at `9432ad4f` it is still there.

**Equivalence verdict.** No upstream or fork rule is equivalent to any of ours. The fork's refusal is weaker on
relaunch, has no takeover scope, no own-counter guard and no adopt bound, and lacks #177's unconfirmed-command release
guard. #177 has no refusal at all.

### What upstream or the forks have that we lack

| Item | Where | Need for v1 | Why |
|---|---|---|---|
| Deactivate a non-faulted pod on the watch | kristinkand fork `94422b1`, closed #203 | No (YAGNI) | Pod change during a loan is out of scope (UX limit A-5). A faulted pod is covered by #177's `deactivateFailedDevice()` |
| Export only the pod in use | kristinkand fork `34f016b` | Optional | Leaves `previousPodState` (the previous pod's history) on the phone. Not dosing-relevant as far as we can see (Inferred). 4 lines; better raised on #177 than carried |
| Escalation search; release waits only for a live exchange | #177 | Already have | In `3d21d9c` |
| Command connect right after a probe cancel | kristinkand fork `983df0e` | Raise on #177 | Same `connectForCommand` code in our base (`BluetoothManager.swift:1308-1316`). Liveness only: the command waits out its connect timeout. Unverified on hardware; from a kristinkand fork, so verify before use |
| Released manager fails queued sessions at once | kristinkand fork `9432ad4` | No | Our `runSession` already refuses at once while released (`OmniPumpManager.swift:1771`); the fork's change is in its own escalation path |
| No turn-taking with the G7 link | kristinkand fork `be108d5`, `2ba66a2` | No | The #177 author declined a radio arbiter without evidence (comment 2026-11-03) |

## 4. LoopKit: where the refusal lives (question 2)

- Upstream LoopKit has no foreign-session refusal, in the protocol or anywhere. `refusesForeignSessionsSince` and
  `lastForeignSessionAt` exist only in kristinkand/LoopKit `825bb3a9`, as protocol members of `ExclusiveDeviceControl`
  with no-op defaults (Verified).
- A2 flagged that placement as risky, and the diff confirms why (Inferred): the default setter does nothing, so a host
  that sets the refusal on a kit without support gets no refusal and no error. That fails open. The same commit also
  adds `bolusDeliveryRate` and `supportedTempBasalDurations` to `PumpDeliveryOdometer` with no default, a source break
  for any other conformer (today only OmniPumpManager conforms in our kit set).
- Interaction with our contract: none today, because we don't take the fork. If we did, the two models would conflict.
  Ours is kit-decided, read-only to the host (`refusesSessions`, `foreignSessionDetectedAt`), lifted only by a dated
  superseding take or `takeControlLiftingRefusal()`. The fork's is host-written and is cleared by a plain
  `takeControl()`, which our contract (M2b-05) forbids. Keep the rule kit-internal and the LoopKit protocol unchanged.

## 5. G7SensorKit: `08d48863` → next-dev / #20 (question 3)

| Change | PR | Phone | Watch reader | API |
|---|---|---|---|---|
| Don't adopt a failed or ended sensor again; Sensor Failed alert stays until a different sensor; marker survives forget | #115 (`9f278b7`, fixes #111) | Yes: while eavesdropping, stops a critical alarm every 5 minutes and the lost failure record | Yes, same discovery path | `G7SensorRecord.EndReason.isFinal` (additive) |
| Don't crash logging a GATT error (six-argument OSLog read garbage memory) | #117 (`9370992`, fixes #116) | Yes | Yes | None |
| Clear "searching" and "code needed" flags at link-up and on radio drop | #119 (`26d6da0`; `e3adb3b` in #20) | No (watch acquisition only) | Yes: stale status flags while readings arrive | None |
| Calibration advice redesign | #113 | UI only | No | `calibrationAdviceSeen`, `markCalibrationAdviceSeen()` (additive, persisted with a default) |
| Await async `CGMManagerDelegate` calls, drop `delegateQueue` | #118 (`8882a64`) | Needs LoopKit #696 | Same | **Breaking**: needs LoopKit #696; excluded from #20 |

- Rebond and restored-mid-disconnect: already in our pin (section 2). Nothing to do.
- Watch acquisition holds/renewals: fork only, one tester's logs as evidence. The upstream `5db6301` explicitly
  declined lodging into the advertising tail and the start-delay option on the watch. Not needed for v1 unless M8
  hardware runs show missed bursts (then raise upstream).
- Sensor-issue flag: Trio-side surfacing already merged (nightscout/Trio#1659). The kit-side widening is not upstream.
- API the M5 watch host must follow: with #20, nothing new. When Trio takes LoopKit #696, #118 removes
  `delegateQueue` and makes delegate calls async; the host must not set `delegateQueue` and must handle async
  delegate methods. LoopKit/G7SensorKit#110 (open) would add a watch plugin (`G7SensorWatchPlugin`,
  `DirectReadCGMManager` on LoopKit#687); until it merges, M5 constructs `G7CGMManager` directly, as #1749 does.
- Build against our LoopKit pin: next-dev tip does not (it needs #696); #20 (`e3adb3b`) does (section 6).

## 6. Builds and tests in scratch

Setup: a scratch clone of `feat/trio-on-watch` @ `8b5227851` with submodules cloned from the local worktree (same
SHAs). Only change: G7SensorKit at `e3adb3b` (loopandlearn/G7SensorKit#20). LoopKit `7fd4d1a7`, OmnipodKit `c23daca`,
all other kits as pinned. Xcode 27.2, `CI=true`, `CODE_SIGNING_ALLOWED=NO`, fresh simulators "TOW-upstream-kits
iPhone 17" (iOS 27.2) and "TOW-upstream-kits Watch" (Series 11 46 mm, watchOS 27.2), deleted afterwards.

| # | Step | Result |
|---|---|---|
| B1 | `-scheme Trio`, iOS simulator build | Exit 0. G7SensorKit, DanaKit, MedtrumKit, MinimedKit, LibreTransmitter, LibreLoop, OmnipodKit, LoopKit compiled |
| B2 | `-scheme G7SensorKit-watchOS`, watchOS simulator | Exit 0 |
| B3 | `-scheme G7SensorKit-watchOS`, `generic/platform=watchOS` (device) | Exit 0 |
| T1 | `-scheme G7SensorKit test` | 207 run, 0 failed (includes #115's new `G7LifecycleAlertTests`) |
| T2 | `-scheme OmniTests test` | 271 run, 0 failed, 3 skipped; `DeviceHandoffTests` 53 run, 0 failed (= M2b BB3) |
| B4 | `-scheme OmnipodKit-watchOS`, watchOS simulator | Exit 0 |
| B5 | OmniTests `build-for-testing` with OmnipodKit at #177 head `e8216cd`, LoopKit `7fd4d1a7` | **Exit 65**: `UnfinalizedDose.swift:387,400` "extra argument 'doseId' in call" (#216 needs LoopKit #695). Confirms #177 head can't be pinned on our LoopKit |

Not run: hardware of any kind; the Trio test suite with the G7 bump; a rebase of our patch onto `e8216cd` with LoopKit
#696 (needs every pump and CGM kit ported first).

## 7. Recommendation (question 4)

**Smallest pin strategy now:**

| Kit | Action | Why |
|---|---|---|
| LoopKit | Stay `7fd4d1a7` (`babddf04` + #687) | Upstream `trio-next-dev` hasn't moved. Next-dev tip brings #695/#696, which need every pump/CGM kit ported (DanaKit, MedtrumKit, MinimedKit and LibreTransmitter each still use `delegateQueue`, 1-5 files each, and the three pump kits `decisionId`, 4-5 files each; Verified by grep). Don't take the kristinkand protocol additions |
| OmnipodKit | Stay `c23daca` (#177 @ `3d21d9c` + our 7 commits) | #177 since `3d21d9c` only adapts to LoopKit #695/#696. No upstream rule supersedes any of ours |
| G7SensorKit | Move to #20's content (`e3adb3b`) once #20 merges into loopandlearn `trio-next-dev` | #115 and #117 matter on the phone today; #119 for the watch reader. It is a Trio-wide pin bump, best done as a normal dev submodule PR, then inherited |

**What of our patch stays necessary (all of it):**
- Refusal after an unexpected resync, persisted, before any handshake, for every command including reductions,
  suspend/resume and status reads.
- Superseding take with its monotonic-clock scope, and `takeControlLiftingRefusal()`.
- `AcceptedEapSqn` own-counter guard.
- Shared-pod handshake in a new process (C-2), which is wider than #177's missing-keys rule.
- Bounded adopt (`releasedEapSqn`) with the fixed handshake SQN.
- Typed error and persisted host signals (`refusesSessions`, `foreignSessionDetectedAt`).
- The tests (53 in `DeviceHandoffTests` at `c23daca`).

Nothing in it duplicates #177 or upstream. The proposal (`omnipodkit-177-proposal.md`) is still unposted.

**Later, when Trio moves to LoopKit #695/#696** (loopandlearn/LoopKit#9 and the per-kit PRs): rebase onto #177 head.
`git merge-tree c23dacac e8216cd` is clean; change `DeviceHandoffTests` `enactTempBasal(decisionId:` → `doseId:` and
check our code for any `pumpDelegate.notify` call that now needs `await` (none found in our diff). Re-run
`DeviceHandoffTests` and the mutation set.

**Risks:**
- Pinning on an unmerged PR (#177) and on local-only commits. Nobody else can build `feat/trio-on-watch` until the
  commits are mirrored (as M2b notes). If #177 merges in a different form, our patch needs re-review, not just a
  rebase.
- Upstream's design resolves dual control on the host (phone asks the watch). Ours refuses in the kit. Until
  maintainers agree, we diverge from Loop's SportMode model; the proposal should go up before M5 builds on it.
- G7 #20 is unmerged. If Trio dev bumps G7 differently (for example straight to next-dev with #696), our pin follows
  that instead.
- Everything here is build- and unit-level. No pod or watch hardware was involved.

## Open questions

1. Does the maintainer want the G7 #20 bump on Trio `dev` now, independent of watch mode? It fixes a 5-minute
   repeating critical alarm (#115) and a logging crash (#117) on the phone.
2. Post `omnipodkit-177-proposal.md` on #177 now, or after M5 shows the host side? Upstream's host-side model is the
   main design disagreement.
3. Should "export only the pod in use" and the post-probe-cancel connect be raised on #177 (small, reviewable), rather
   than carried locally?
4. When does Trio plan the LoopKit #695/#696 move (loopandlearn/LoopKit#9)? It gates the rebase onto #177 head and
   G7 #118.

## Evidence index

- nightscout/Trio#1784 (issue text); nightscout/Trio `dev` `e6a9259e2` `git ls-tree` for LoopKit, OmnipodKit,
  G7SensorKit; `.gitmodules` @ `e6a9259e2`.
- kristinkand/Trio `feature/untethered-watch-mode` @ `f587d1f9b`: submodule SHAs and URLs via GitHub contents API.
- LoopKit: loopandlearn `trio-next-dev` @ `babddf04`; LoopKit/LoopKit#626 (`dee2a369`, ancestor of `babddf04`),
  #687, #695, #696, #699, #700; `2aecef07` (removal of `lastForeignSessionAt`); loopandlearn/LoopKit#8 (closed),
  #9 (open); kristinkand/LoopKit `825bb3a9`, `8e8607db` (diff vs `babddf04`: `DeviceManager.swift` +33,
  `PumpManager.swift` +16); `7fd4d1a7` vs `next-dev`: `delegateQueue` at `CGMManager.swift:168`,
  `PumpManager.swift:112`; `enactTempBasal(decisionId:` vs `(doseId:` at `PumpManager.swift:228/232`.
- OmnipodKit: #177 (head `e8216cd`, commits `8fe606c`, `a96f5d0`, `b117532`, `8f2b4db`, `488f927`, `2a2f020`,
  `8259964`, `3d21d9c`, `b6fd18d`, `e8216cd`; comments 2026-10-26 and 2026-11-03); #203 (closed); merged #201,
  #205, #209, #211, #214, #215, #216, #219, #220, #221; ours `c23dacac` (`+DeviceHandoff.swift:172-233,302,356,
  403-422`, `PodState.swift:157-167`, `BlePodComms.swift:45-48,116,972`, `OmniPumpManager.swift:139,1771-1779`,
  `PodCommsSession.swift:46`); kristinkand/OmnipodKit `9432ad4f` (`BlePodComms.swift:70-73,390,826`,
  `+DeviceHandoff.swift:95-105,175-257`), commits `11017f5`, `94422b1`, `b22886a`, `34f016b`, `983df0e`, `9432ad4`,
  `be108d5`, `2ba66a2`, `fc903e3`.
- G7SensorKit: LoopKit/G7SensorKit #80 (`0c43b91e`), #110 (open), #112 (closed), #113, #115 (`9f278b7`), #117
  (`9370992`), #118 (`8882a64`), #119 (`26d6da0`); commits `651c2a4`, `5db6301` (in `08d48863`); kristinkand fork
  `fd60465`, `e99e30b`, `cf67d77`, `e1b1e18`; loopandlearn/G7SensorKit#20 (`e3adb3b`, diff vs next-dev: 3 files,
  #118 only), `e99d631` on `feat/trio-g7-direct`.
- Trio: nightscout/Trio#1659 (sensor-issue surfacing), #1749 (G7 Direct-to-Watch, open).
- Our docs: `implementation/implementation-status.md` (M2b), `implementation/omnipodkit-177-proposal.md`,
  `reviews/arch-review-A2-kits.md` (A2-03), `research/experimental-kit-forks-inventory.md`, `design/ux-guidelines.md`
  (A-5).
- Scratch build logs (temporary, may be cleared): `/private/tmp/claude-501/-Users-dnzxy-workspaces-Trio/3f8cbd66-3ec5-4539-8f2f-f9e5df9ae9dc/scratchpad/upstream-kits/logs/` (b1, b2, b3, t1, t2, b4, b5).
