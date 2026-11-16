# Experimental kit forks: inventory (LoopKit, G7SensorKit, OmnipodKit)

Research material for Trio on Watch, phase 1. Read-only. Subject: the three kit submodules the experimental branch
`kristinkand/feature/untethered-watch-mode` @ `a56170dc0` repoints to kristinkand forks. All fork code is treated as
unverified until shown otherwise. Claims are marked **Verified** (read in code or git), **Inferred** (reasoned from
verified code, not exercised), or **Unverified** (stated by someone, not checked).

## Executive summary

1. Most of the "watch" machinery is already upstream. LoopKit `trio-next-dev` (the Trio baseline) already ships the
   hand-off protocols (`SharedDeviceConfiguration`, `DeviceConfigurationSharing`, `ExclusiveDeviceControl`,
   `PumpDeliveryOdometer`) and a `LoopKit-watchOS` target (LoopKit/LoopKit#626, merged). G7SensorKit already has a
   watchOS target, watch display slot and `G7WatchAcquisition` (LoopKit/G7SensorKit#80, merged).
2. The LoopKit fork is +49 lines: it re-adds six `ExclusiveDeviceControl` members upstream review explicitly removed
   (2aecef07, "As suggested in review"), plus three `PumpDeliveryOdometer` members. Two are required (no default).
3. The OmnipodKit fork is the real change: +2833/-198 over the baseline. It is a hand port of the still-open
   loopandlearn/OmnipodKit#177 (jeremybarnum, "SportMode"), plus fork-only rules, plus merged upstream fixes. It adds
   an `OmnipodKit-watchOS` target, export/adopt of pod state, release/take of the BLE link, a delivered-units odometer,
   and EAP-SQN-resync-based detection of "another controller used this pod".
4. Pod ownership is a convention between two controllers, not a lock. Mutual exclusion rests on the pod accepting one
   BLE connection at a time; detection rests on the EAP SQN resync seen at the next handshake; refusal is opt-in per
   controller (`refusesForeignSessionsSince`). Detection happens only after a handshake that itself bumps the counter.
5. Highest-risk gap (Verified): the fork's `releaseControl()` releases unconditionally, and the export drops
   `unacknowledgedCommand`. #177 refuses the release while a command is unconfirmed (8fe606c); the fork lacks that.
   An uncertain dose at hand-off is then booked by neither controller until the host's odometer "gap" audit.
6. The experimental host's own code records a test night where phone and watch both dosed the same pod in turn
   (UntetheredWatchManager.swift:665-669 @ a56170dc0). The refusal rule was added after that.
7. G7: the fork is LoopKit/G7SensorKit `next-dev` plus small watch-acquisition tweaks, a migration hack, and a
   widened "Sensor Issue" highlight that contradicts the upstream choice. Trio's branch additionally vendors 26 G7
   files into the watch extension and links the real framework too: two copies, two CoreBluetooth centrals.
8. All three forks build for watchOS as pinned (OmnipodKit-watchOS and G7SensorKit-watchOS, simulator and arm64_32
   device, built in scratch). Building is not evidence of correct dosing behaviour.

## 1. Pins, branches, merge bases

| Kit | Baseline (dev pin) | Fork pin | Declared fork branch | Pin actually on | Merge base | Fork ahead / behind |
|---|---|---|---|---|---|---|
| LoopKit | loopandlearn `trio-next-dev` @ `babddf04` | `8e8607db` | `untethered-next-dev` | `untethered-next-dev` (head) | `babddf04` (baseline) | 7 ahead (2 merges), 0 behind |
| G7SensorKit | loopandlearn `trio-next-dev` @ `08d48863` (= its head) | `48158d8c` | `untethered-personal` | `untethered-personal` (head) | `08d48863` | 34 ahead (6 merges), 0 behind |
| OmnipodKit | loopandlearn `next-dev` @ `6fdf0e0e` | `9432ad4f` | `untethered-personal` | `untethered-personal-podtest` only | `6fdf0e0e` | 58 ahead (7 merges), 0 behind |

Verified: `git ls-tree a56170dc0 LoopKit G7SensorKit OmnipodKit` and `.gitmodules` diff vs `3f6b238b4`; merge bases
and counts from clones of the forks with loopandlearn and LoopKit remotes.

Notes:
- OmnipodKit: the gitlink `9432ad4f` is 3 commits past the declared branch `untethered-personal` (`c978d41`) and lives
  only on `untethered-personal-podtest`. A `git submodule update --remote` would move it backwards. (Verified)
- All three forks are fast-forwards of their baselines; none rewrites history. (Verified)
- The baseline OmnipodKit `6fdf0e0e` is 19 commits behind current loopandlearn `next-dev` (`dc8b923`, 2026-11-12).
  The fork lacks #216 (`doseId`) and #220 (async delegates), so it still uses `decisionId`. (Verified)
- G7: the fork lacks one LoopKit/G7SensorKit `next-dev` commit, #118 (async CGM delegates). (Verified)

### Upstream commits mixed into the forks (Verified)

- LoopKit: merges of LoopKit `e11ca0d` (Trio #1726) and loopandlearn `trio-next-dev`; content-wise they add nothing
  over the baseline. Three old 2024 commits (MockKit Dana config, 80 U mock bolus, clang module verification) show as
  fork-only by ref but are not in the net diff. Net diff = 2 files.
- G7SensorKit: merges LoopKit/G7SensorKit `next-dev` up to `48158d8` (calibration advice #113, #115 ended-sensor
  rediscovery, #117 OSLog crash, #104 reconnect refusal window removal). 13 upstream commits in `base..fork`.
- OmnipodKit: merges loopandlearn `dev` and `next-dev` up to 2026-11-10 (#205 Int64 SQNs, #209 unresponsive-pod
  disconnect, #211/#212 bolus cut short by a fault, #214 unhook replaced PeripheralManager, #221 translations).
  `DisconnectPolicy.swift` and the fault-time bolus changes in `PodCommsSession.swift`/`PodState.swift` are upstream
  content; vs current `next-dev` the fork's `PodCommsSession.swift` differs only in `decisionId`/`doseId`.

## 2. LoopKit fork (`babddf04..8e8607db`)

Net diff: `LoopKit/DeviceManager/DeviceManager.swift` +33, `LoopKit/DeviceManager/PumpManager.swift` +16. Single
authored commit `825bb3a9` ("the hand-off parts Trio's watch uses", ported from EJM0's untethered LoopKit), plus
`8e8607db` dropping `hostRadioNeedsReset`. (Verified)

What upstream already has at the baseline (Verified, `babddf04:LoopKit/DeviceManager/DeviceManager.swift:60-147`,
`PumpManager.swift:347-361`; origin `b209fdc9`, LoopKit/LoopKit#626 by jeremybarnum, merged):
- `SharedDeviceConfiguration` (managerIdentifier, asOf, deliveredUnits, opaque state).
- `DeviceConfigurationSharing`: `exportConfiguration()`, `init?(adopting:localState:)`, `localState`,
  `isConfigurationSharingEnabled`.
- `ExclusiveDeviceControl`: `isControlReleased`, `releaseControl()`, `takeControl()`, `isControlReady`,
  static `takeControlNeedsSearch(adopting:localState:)`.
- `PumpDeliveryOdometer`: `deliveredUnits`, `deliveryPulseUnits`, `refreshDeliveredUnits()`, `bolusUnderWayEndsAt`.
- `LoopKit-watchOS` target compiling `PumpManager.swift`, `SettingsStore` and dependencies.

What the fork adds (Verified, `8e8607db:LoopKit/DeviceManager/DeviceManager.swift:145-182`, `PumpManager.swift:363-378`):

| Member | Protocol | Default | Upstream history |
|---|---|---|---|
| `takeControlNeedsSearch` (instance) | ExclusiveDeviceControl | false | removed upstream in `2aecef07` |
| `escalateTakeControl() -> String?` | ExclusiveDeviceControl | nil | removed in `2aecef07` ("moves into the device kit") |
| `endTakeEscalation()` | ExclusiveDeviceControl | no-op | added `f18a0b07`, removed `2aecef07` |
| `connectionDiagnostics() -> String?` | ExclusiveDeviceControl | nil | removed in `2aecef07` ("goes to the kit's own device log") |
| `lastForeignSessionAt: Date?` | ExclusiveDeviceControl | nil | removed in `2aecef07` ("unused") |
| `refusesForeignSessionsSince: Date? {get set}` | ExclusiveDeviceControl | no-op | never upstream; fork-only |
| `bolusDeliveryRate: Double` | PumpDeliveryOdometer | **none (required)** | never upstream |
| `supportedTempBasalDurations: [TimeInterval]` | PumpDeliveryOdometer | **none (required)** | never upstream |
| `untrackedBolusRemaining: Double` | PumpDeliveryOdometer | 0 | never upstream |

Assessment:
- No watchOS target or platform-conditional change is needed in LoopKit; upstream already did it. (Verified)
- The fork reverses an upstream review decision (2aecef07 commit message: "As suggested in review: ... Escalating a
  stalled take moves into the device kit, as Bluetooth behaviour; the diagnostics text goes to the kit's own device
  log; the instance search check and the unused last-foreign-session date are dropped."). (Verified)
- `refusesForeignSessionsSince` / `lastForeignSessionAt` are the protocol surface of the fork's dual-control rule
  (section 4). Whether that rule belongs in the protocol or inside the kit is an open design question; #177 kept it
  in the kit. (Verified for #177's API surface; design judgement Inferred)
- The two required odometer members break source compatibility for any other `PumpDeliveryOdometer` conformer. In
  the Trio dev tree today there are none outside LoopKit (grep of the baseline checkout), so impact is nil now and
  non-zero for any future kit. `bolusDeliveryRate`/`supportedTempBasalDurations` are generic pump facts that could
  arguably live on `PumpManager` instead. (Verified grep; judgement Inferred)

## 3. OmnipodKit fork (`6fdf0e0e..9432ad4f`)

### 3.1 Lineage (Verified)

- `11017f5` (EJM0, 2026-10-17): "Ported from jeremybarnum/OmnipodKit (OmnipodKit #177) onto my-dev ... Conflicts
  resolved toward my-dev's connect-on-demand path." Then cherry-picked onto loopandlearn `dev`.
- 37 further fork-only commits (kristinkand), several of them later superseded by or aligned to #177 commits
  ("Second handshake after a resync again, as #177 intends", "No turn-taking with the G7's link", "One pending
  connect per pod" mirrors #177's `8259964`).
- loopandlearn/OmnipodKit#177 (OPEN, jeremybarnum, `sportmode/next-dev`, head `e8216cd`, 40 commits) is **not** an
  ancestor of the fork. 44 commits on #177 are absent from the fork, including `8fe606c` (keep the pod while a command
  is unconfirmed), `0af1bb3` (a connect clock per manager), `6766e62` (simulator fakes only for a mocked pod),
  `a002df5` (principled missing-key fix), `2a2f020`/`b6d251a` (faulted pod deactivation, final delivered total),
  `d2ea4ba` (watch loads OmnipodKit at run time).
- loopandlearn/OmnipodKit#203 (EJM0, "SportMode ... on dev for Trio (#177)") was CLOSED on 2026-11-07.
- On #177, kristinkand reported four findings from fork testing; jeremybarnum answered: (1) empty-key crash, fixed
  upstream in `a002df5`; (2) second handshake after resync is intended; (3) relaunched phone sending an SMB while the
  watch held the pod, addressed host-side in LoopKit/Loop#2545 `c491bf7f`; (4) G7/pod radio contention: unproven,
  arbiter deliberately not carried. The fork has since dropped its turn-taking (`be108d5`).
  (Verified, PR #177 comments)

### 3.2 Changes by area

| Area | Files | What | Classification |
|---|---|---|---|
| watchOS target | `project.pbxproj`, `OmnipodKit-watchOS.xcscheme`, `Common/UIDevice+watchOS.swift` | New framework target `OmnipodKit-watchOS` (SDKROOT watchos, watchOS 10.6, links LoopKit, RileyLinkKit, RileyLinkBLEKit), 57 UI/UIKit files excluded, `#if os(iOS)` around `UIApplication` lifecycle, SilentTune and `reservoirLevelHighlightState`; a `UIDevice` stub on watchOS | Necessary concept; mirrors #177 |
| Hand-off (sharing) | `OmniPumpManager+DeviceHandoff.swift:22-169` (new) | `exportConfiguration()` marks the pod shared and exports `OmniPumpManagerState` minus previous pod, flags, RileyLink state; `PodState.sharedFacts` strips BLE handle, unacknowledged command, last delivery status, session keys (`ck`, `noncePrefix`), keeps `eapSeq` and `messageNumber`. `adopted(handle:)` marks `untrackedDeliveryIsForeign`, `sharedWithAnotherController`, `configuredByAnotherController` | Necessary concept; ported from #177 |
| Exclusive control | `+DeviceHandoff.swift:173-286`, `OmniPumpManager.swift:1792-1797`, `BluetoothManager.swift:210-268` | `releaseControl()` persists `podConnectionReleased`, sets `refusesForeignSessionsSince`, drops the link (waits up to 20 s for a live exchange), blocks new dials; `takeControl()` lifts the release, resolves "foreign control", re-dials or starts a takeover scan; every `runSession` refuses while released | Necessary concept; release-without-guard is a regression vs #177 (see 4.3) |
| Foreign-session rule | `BlePodComms.swift:72-74,382-403,825-830` | Records `lastSqnResync` on every EAP SQN resync; on a shared pod drops the unconfirmed command with nothing booked; refuses any session after a resync newer than `refusesForeignSessionsSince` | Fork-only policy on top of #177's resync handling; risky (section 4) |
| Odometer | `+DeviceHandoff.swift:290-341`, `PodState.swift:138-152,413-427` | `deliveredUnits` from `lastInsulinMeasurements`; forced status read; `bolusUnderWayEndsAt`, `untrackedBolusRemaining`, `bolusDeliveryRate`, `supportedTempBasalDurations` | Necessary concept (it is the audit figure) |
| Untracked delivery | `PodState.swift:413-422` | A running bolus the controller doesn't track is no longer turned into an `UnfinalizedDose` when `untrackedDeliveryIsForeign` | Necessary concept; changes phone behaviour after any take-back |
| Session safety | `BleMessageTransport.swift:49-53,189-216`, `BlePodComms.swift:41-49`, `EapSqn.swift`, `Nonce.swift`, `SessionEstablisher.swift` | Missing keys read back as nil; no transport without 8-byte prefix; `sendMessage` refuses while released; adopted pod needs a handshake first; Int64 SQN encoding (also upstream #205) | Upstreamable fixes; partly already upstream |
| BLE takeover | `BluetoothManager.swift` (+373 vs next-dev), `PeripheralManager.swift`, `PodAdvertisement.swift` | Takeover/escalation scan by pod address; stale-handle hygiene; one pending connect per pod; cancel reasons; O5 attention-suffix advert accepted during discovery/takeover (`52d8302`) | Mixed: takeover needed; extensive diagnostics are fork noise; the O5 discovery filter change also alters phone pairing |
| Phone-only behaviour | `+PodKeepAlive.swift`, `OmniPumpManager.swift:119-143` | No timer keep-alives and no held connection for an adopted pod; honour persisted release at init | Necessary concept |
| Watch-only end of pod | `OmniPumpManager.swift:1273-1300` | `deactivateAndForgetPod`, `discardPod`, `forgetPodEndedElsewhere` (forgets with no pump event) | Needed in some form; #177 has its own (`2a2f020`) |
| Simulator shortcuts | `OmniPumpManager.swift:2748-2762,2982-2988`, `+DeviceHandoff.swift:315-331` | `#if targetEnvironment(simulator)`: fake status reads and temp cancels for **any** pod | Test hack; #177 restricts it to a mocked pod (`6766e62`) |
| Diagnostics | `ConnectClock` (`+DeviceHandoff.swift:347-430`), many `omnipodLogDeviceEvent` lines | Process-global static clock and trail | Personal debugging aid; global state is wrong with several managers (4.6) |

## 4. OmnipodKit: pod ownership and dual-control protection (highest risk)

### 4.1 What travels, what does not (Verified)

`PodState.sharedFacts` (`+DeviceHandoff.swift:116-126`) and `OmniPumpManagerState.sharedConfiguration`
(`:66-81`):

| Travels in the export | Stays with the exporting controller |
|---|---|
| Pod address, LTK and (O5) signing key, pod setup and alerts, `unfinalizedBolus`, `unfinalizedTempBasal`, `eapSeq`, `messageNumber`, `lastInsulinMeasurements` (also as header `deliveredUnits`) | CoreBluetooth handle (`bleIdentifier`, travels only as the receiver's own `localState`), session keys `ck`/`noncePrefix`, `msgSeq`/`nonceSeq` (zeroed), **`unacknowledgedCommand`**, `lastDeliveryStatusReceived`, previous pod, release/refusal flags |

Consequences:
- The pod's long-term key leaves the phone (via the host's WatchConnectivity transfer) and is persisted on the watch.
  Inherent to the design and to #177. (Verified that LTK is not stripped; transport security is host-side, Inferred)
- In-flight doses move with the pod: the adopter owns `unfinalizedBolus`/`unfinalizedTempBasal` under the exporter's
  identities; the exporter sets `inFlightDosesInheritedAway` and drops its copies at take-back
  (`:102-109`, `:205-215`). (Verified)
- A command whose outcome is unknown (`unacknowledgedCommand`) does **not** move. (Verified, `:119`)

### 4.2 Hand-off sequence as wired by the experimental host (Verified in code, not exercised)

Phone to watch (`UntetheredPhoneManager.swift @ a56170dc0`):
1. Preconditions at request time (`:1212-1225`): no bolus running, `!status.deliveryIsUncertain`, no manual temp, pump
   operable.
2. `releasePump()` (`:1365-1381`): wait up to 30 s (60 x 0.5 s) for a running loop, then cancel a running temp basal
   (`handOverTempBasal`, `UntetheredMessage.swift:193-203`), then `exportConfiguration()`, then `releaseControl()`.
   No re-check of `deliveryIsUncertain` after the temp cancel. The export goes to the watch in the `commit` message.
3. Watch: `init(adopting:localState:)`, `takeControl()`; the adopted manager needs a fresh EAP handshake before any
   session (`BlePodComms.swift:41-49`). At session start the watch sets `refusesForeignSessionsSince = Date()`
   (`UntetheredWatchManager.swift:665-669`).

"Start without the phone" (standing grant): while the phone still holds the pod, it periodically exports the pod
into a grant and sets its own `refusesForeignSessionsSince` (`UntetheredPhoneManager.swift:438-456`). The watch may
later adopt from that stale copy without any release by the phone. (Verified)

Watch to phone: phone `takeControl()` clears its refusal and resolves "foreign control" (drops last delivery status,
marks untracked delivery foreign, drops in-flight copies if it handed them away); it then reads the odometer and the
host books any unexplained delivered-total difference as an "Untethered gap" bolus
(`UntetheredPhoneManager.swift:1680-1722`). (Verified that the booking exists; audit correctness not reviewed here)

### 4.3 Protection mechanisms and their limits

| Mechanism | Where | What it does | Limit |
|---|---|---|---|
| Single BLE connection | pod behaviour, `BluetoothManager.releaseConnectionForLoan` | A connected controller blocks the other | Not a lock: both controllers connect on demand and drop idle links within seconds; whoever dials first wins. Pod behaviour per kit comments, Unverified here |
| Release flag | `OmniPumpManagerState.podConnectionReleased` (persisted), `BluetoothManager.loanReleased` (memory, re-applied at init), `OmniPumpManager.runSession` refusal, `sendMessage` guard | A released controller dials and sends nothing | Only works if the controller was told to release. In "start without phone" and in a phone relaunch that missed the stop, it was not |
| Release waits for a live exchange | `BluetoothManager.swift:219-252` | A release during a command waits up to 20 s for it to finish | After 20 s it disconnects mid-exchange anyway. Does not cover a command whose answer was already lost |
| **No release while a command is unconfirmed** | #177 `8fe606c` (`mayReleaseControl`) | Keeps the pod until the controller settles its own uncertain command | **Missing in the fork.** `releaseControl()` is unconditional (`+DeviceHandoff.swift:181-192`). The host's precondition is checked before the temp cancel in `releasePump()`, not after |
| Handshake before session on adopted pod | `BlePodComms.swift:41-49`, `:813-817` | No session runs on exported (keyless) state | Good; matches #177 `8f2b4db` |
| EAP SQN resync detection | `BlePodComms.swift:382-403` | A controller whose stored SQN is behind the pod's sees a resync and records `lastSqnResync` | Detection only at the next handshake, and the detecting handshake (plus the retry in `establishNewSession`, `:441-448`) itself advances the pod's counter, so the other controller will in turn see a resync. `lastSqnResync` is in memory only |
| Drop unconfirmed command after resync on a shared pod | `PodState.resolveAfterSessionResync` (`+DeviceHandoff.swift:146-150`) | Avoids misreading the other controller's `lastProgrammingMessageSeqNum` as confirmation of our own pending command (4-bit sequence collision) | Books nothing for a command that may have been delivered. Also triggers when the controller's own SQN was merely saved late, because a pod becomes "shared" for life once exported, and the phone exports on every standing grant |
| Foreign-session refusal | `BlePodComms.swift:825-830`, host sets `refusesForeignSessionsSince` | After a resync newer than the refusal date, every session fails with "Another controller has used this pod" | Refusal comes after the handshake (counter already bumped). If both sides have refusal set, both can end up refusing: no double dosing, but also no loop until the host's WatchConnectivity exchange resolves it (Inferred) |
| Odometer audit | host, `refreshDeliveredUnits` + gap booking | Books unexplained delivered units as one bolus | After the fact: IOB on the controller in charge is understated until the audit runs; timing and attribution of the gap are approximate |

### 4.4 Answers to the specific questions

- **Nonce / message-sequence desync.** DASH/O5 session keys and nonces are per handshake, so a fresh handshake
  re-keys and nothing stale is reused (Verified, `sharedFacts` + `needsSessionEstablishment`). The 4-bit Omnipod
  `messageNumber` travels and the kit comment claims "the pod resynchronizes both" (Unverified; not traced into
  pod-side behaviour). The real desync hazard is `lastProgrammingMessageSeqNum` matching across controllers; the
  fork's answer is to drop the pending command with nothing booked (Verified).
- **Duplicate commands.** Nothing in the kit prevents two controllers each sending a dose in turn if both believe
  they hold the pod and neither has refusal set. The host's own comment documents exactly that during testing:
  "the phone took the pod back, its stop didn't reach the sleeping watch, and both dosed it in turn until the watch
  app was opened" (`UntetheredWatchManager.swift:665-669` @ a56170dc0). The refusal rule now closes the "watch kept
  going" half once the watch's next handshake sees the phone's session (Verified code; effectiveness Inferred). The
  race where the watch handshakes first after the phone's `takeControl()` still lets the watch's command through,
  with the phone (refusal cleared by `resumeControl()`) then continuing to dose; the phone learns only via resync and
  the odometer (Inferred).
- **Unacknowledged commands.** Stay with the exporter, are not exported, and the fork lets the exporter release
  anyway. At take-back the exporter drops them (`resolveAfterForeignControl` clears `unacknowledgedCommand`) with
  nothing booked (Verified). Only the host odometer audit can account for the delivery (Inferred).
- **Uncertain delivery.** Host blocks a hand-off when `deliveryIsUncertain` at request time only (Verified). A failed
  temp-basal cancel during `releasePump()` returns `(nil, nil)` and the release proceeds (Verified), so a pod may be
  handed over with an unconfirmed cancel; for a high temp that means a temp the watch does not resume and may not
  know is running (the kit does not synthesize an untracked temp, `PodState.swift:428-430`) (Inferred).
- **Requested / accepted / executed / confirmed.** The kit reports confirmation through the pod's status response
  for the controller that sent the command. For the other controller, a dose is at best "observed" (bolus under way,
  `untrackedBolusRemaining`, delivered total) and never booked as its own. Attribution to a controller and time is
  the host's audit job. (Verified for the kit side)

### 4.5 Risky or personal fork-only behaviours

- `releaseControl()` without the unconfirmed-command guard (above). Highest priority.
- Resync-as-foreign on any pod ever exported: with standing grants the phone's pod is "shared" for its whole life
  (`exportConfiguration` marks it, `+DeviceHandoff.swift:25-29`), so a phone's own late-saved SQN drops its
  unconfirmed command with nothing booked, a behaviour change on the phone even when the watch never ran. (Inferred)
- `untrackedDeliveryIsForeign` suppresses the existing "create an `UnfinalizedDose` for an untracked bolus" safety
  net after any adopt, take-back or foreign session, until the pod shows no bolus. (Verified, `PodState.swift:416-422`)
- Process-global `ConnectClock` (static) and `com.OmnipodKit` restore identifier for every `BluetoothManager`
  (`BluetoothManager.swift:812`). The experimental watch host creates several managers for the same pod ("witness",
  "meeting", takeover) and its comments record a second manager that "never connected"
  (`UntetheredWatchManager.swift:817-860`). #177 moved the clock per manager (`0af1bb3`). (Verified code; CoreBluetooth
  duplicate-restore-ID behaviour Inferred)
- Simulator shortcuts apply to any pod, not just a mocked one. Low risk on hardware, but it makes simulator tests
  of dosing paths meaningless. (Verified)
- O5 discovery/takeover scan filter accepts the attention-suffix advertisement while unpaired (`52d8302`); upstream
  #204 is still only logging it. A phone pairing change riding along in a watch fork. (Verified diff; impact Unverified)
- Some pre-existing doc comment placement broken (`OmniPumpManager.swift:1272-1273`, "Reports the end of a pod's life"
  now sits above the new MARK). Cosmetic. (Verified)

## 5. G7SensorKit fork (`08d48863..48158d8c`)

### 5.1 What is upstream already (Verified)

- `G7SensorKit-watchOS` target exists at the baseline (`08d48863`), from LoopKit/G7SensorKit#80 (jeremybarnum,
  merged): watch display slot, `G7WatchAcquisition`, faster P-256, `DeviceConfigurationSharing` on `G7CGMManager`
  (`G7CGMManager.swift:1477`), `configuredByAnotherController`, `recheckAcquisition()`.
- No pump, no dosing; display and alerts only.

### 5.2 Fork-only content vs LoopKit/G7SensorKit `next-dev` (Verified, `git diff lk/next-dev 48158d8c`)

| Change | Where | Assessment |
|---|---|---|
| Adopted state always uses `displayType = .watch` | `G7CGMManagerState.swift:200-207` | Migration hack for state saved by an earlier fork (comment cites a 1 November test). Personal; not needed on a clean install |
| Renew a "lodged" connect request that missed a burst by > period + 90 s | `G7WatchAcquisition.swift:129-164` | Plausible watch fix, one tester's log as evidence; needs maintainer review |
| `holdProcess` waits up to 0.5 s for `performExpiringActivity` to begin | `G7WatchAcquisition.swift:348-362` | Plausible; blocks the caller's queue up to 0.5 s; one log as evidence |
| "Sensor Issue" highlight for any `!hasReliableGlucose` | `G7SensorKitUI/G7CGMManager/G7CGMManager+UI.swift:121-141` | Contradicts upstream's deliberate `hasTemporaryError` check (#99, #90; maintainer guidance). User-visible on the phone too. Not upstreamable as is |
| Settings split into Sensor/Session, identity rows, previous-sensor view | `G7SettingsView.swift`, `G7SensorIdentityRows.swift`, `G7PreviousSensorView.swift` | Mirrors open upstream PR LoopKit/G7SensorKit#114 (ETolboom). Unrelated to the watch |
| Failure-alert marker during replacement scans | `6477e93`, `7b86106` | From closed LoopKit/G7SensorKit#112; nets out against next-dev |
| Missing #118 (async delegates) | `G7CGMManager.swift` | Lag, not a change |

### 5.3 Relation to Trio's vendored G7 copy and to nightscout/Trio#1749

- The experimental Trio branch vendors 26 files into `Trio Watch App Extension/G7Direct/G7SensorKit/` (plus
  `WatchG7Session`, `WatchG7Messages`, `WatchG7Reader`, `WatchG7View`, `TrioWatchAppDelegate`). Its README says
  they are copied from LoopKit/G7SensorKit#80 commit `1353226` with six local `Trio:` changes. (Verified)
- Compared with the fork pin: 19 files are byte-identical, 6 differ (`G7WatchAcquisition.swift` by 292 lines,
  `G7BluetoothManager.swift` 84, `TimeInterval.swift` 34, `G7Authenticator.swift` 29, `G7PeripheralManager.swift` 7,
  `OSLog.swift` 2). (Verified, file diff)
- The same watch target also links and embeds the real `G7SensorKit.framework` for untethered mode
  (`Trio.xcodeproj/project.pbxproj` @ a56170dc0, build files `4F6DEEA0…`, `546709CF…`). The README states that this
  runs a second CoreBluetooth central against the same sensor slot, and the vendored reader "stands aside" during a
  session. So yes: **two copies of the G7 BLE stack, two acquisition implementations, two centrals, one sensor slot.**
  (Verified)
- nightscout/Trio#1749 (EJM0, OPEN, head `b97b55c9`, "Add G7 Direct-to-Watch (D2W) Support") takes the opposite
  approach: the watch builds a `G7CGMManager` from the phone's export via `DeviceConfigurationSharing`
  (`WatchCGMHost`, `WatchDeviceManagers`) and pins G7SensorKit to Trio dev's commit. No vendored copy. #1749's head is
  not in the experimental branch. (Verified, PR metadata and `merge-base --is-ancestor`)
- Inference: #1749's approach (one framework, one manager, upstream kit) is the right base; the vendored copy is
  redundant once the watch uses the kit, and running both is a source of slot and central contention. (Inferred)

## 6. Classification

| Item | Upstreamable / necessary concept | Personal hack | Risky |
|---|---|---|---|
| LoopKit hand-off protocols, `LoopKit-watchOS` | Already upstream | | |
| LoopKit fork's re-added escalation/diagnostics members | Rejected upstream; keep in kit | | Low |
| LoopKit `refusesForeignSessionsSince`/`lastForeignSessionAt` | Concept needed somewhere; protocol placement open | | Medium (policy in protocol) |
| LoopKit required odometer members | Concept fine; should have defaults or live elsewhere | | Low |
| OmnipodKit watchOS target, `#if os(iOS)` guards, `UIDevice` stub | Yes (#177 has it) | | |
| OmnipodKit export/adopt, handshake-before-session, missing-key fixes, Int64 SQN | Yes (in or aligned with #177/#201/#205) | | |
| OmnipodKit release without unconfirmed-command guard | | | **High** |
| OmnipodKit resync-drops-unconfirmed with nothing booked | Same as #177 `a96f5d0` | | High (depends on host audit) |
| OmnipodKit foreign-session refusal | Concept useful; #177 author handles it host-side instead | | Medium |
| OmnipodKit global `ConnectClock`, simulator fakes for any pod, verbose device-log trail | | Yes | Medium (global state) |
| OmnipodKit O5 attention-suffix discovery | Separate PR (#204) | | Unknown |
| G7 renew-lodged-request, hold-begun wait | Maybe, with maintainer | | Low |
| G7 `displayType = .watch` on restore | | Yes (migration of fork state) | Low |
| G7 widened Sensor Issue highlight | Contradicts upstream | | Low (UX), but user-facing |
| G7 settings split | Upstream PR #114, unrelated | | |
| Vendored G7 copy in the watch extension | | Yes | Medium (duplicate stack) |

## 7. Do the forks build for watchOS as pinned?

Built in a scratch workspace (`LoopKit` @ `8e8607db`, `G7SensorKit` @ `48158d8c`, `OmnipodKit` @ `9432ad4f`,
`RileyLinkKit` @ `52a652c9`, the Trio dev and experimental-branch pin), Xcode 27.2, `CODE_SIGNING_ALLOWED=NO`:

| Scheme | Destination | Result | Dependencies built |
|---|---|---|---|
| `OmnipodKit-watchOS` | generic watchOS Simulator | BUILD SUCCEEDED | LoopKit-watchOS, RileyLinkKit-watchOS, RileyLinkBLEKit-watchOS, CryptoSwift |
| `OmnipodKit-watchOS` | generic watchOS device (`arm64_32-apple-watchos10.6`) | BUILD SUCCEEDED | same |
| `G7SensorKit-watchOS` | generic watchOS Simulator | BUILD SUCCEEDED | LoopKit-watchOS |

(Verified; logs at the scratch path in the evidence index.) Not run: unit tests (`OmniTests/DeviceHandoffTests.swift`
has 24 tests at the pin), any device or pod test. Baseline OmnipodKit (`6fdf0e0e`) and current loopandlearn `next-dev`
have no watchOS target at all, so stock OmnipodKit cannot be linked into a watch target. (Verified)

## Open questions

1. Will Trio build on loopandlearn/OmnipodKit#177 (open, 44 commits the fork lacks) instead of the fork? Its
   `mayReleaseControl` guard, per-manager clock and mocked-only simulator fakes address three of the risks above.
2. Does the DASH/O5 pod really accept a stale 4-bit `messageNumber` from an adopting controller and resynchronize?
   Needs a pod-protocol reference or an in-vitro trace; the kit comment is the only source found.
3. Where should the foreign-session refusal live: in `ExclusiveDeviceControl` (fork), inside the kit, or in the host
   (#177 author's choice via LoopKit/Loop#2545 `c491bf7f`)?
4. Is booking nothing for an unconfirmed command after a resync acceptable when the only backstop is a host-side
   delivered-total audit? What is the worst-case IOB understatement and for how long?
5. What does CoreBluetooth do with several `CBCentralManager`s sharing the `com.OmnipodKit` restore identifier in one
   watch process? The host's comments suggest connect failures; not verified.
6. Is the "start without the phone" path (standing grant, watch adopts while the phone never released) needed at all
   for a first version? It is the path with no release and the weakest guarantees. (YAGNI candidate)
7. The vendored G7 copy plus framework: is any of the vendored reader needed once #1749 lands?
8. One tester log per G7 acquisition tweak: can ps2 confirm or reject them upstream?

## Evidence index

Clones (scratch, read-only research): `/private/tmp/claude-501/-Users-dnzxy-workspaces-Trio/3f8cbd66-3ec5-4539-8f2f-f9e5df9ae9dc/scratchpad/A2/{LoopKit,G7SensorKit,OmnipodKit,RileyLinkKit}`,
remotes `origin` = kristinkand fork, `up` = loopandlearn, `lk` = LoopKit. Build logs: same directory,
`build-OmnipodKit-watchOS.log`, `build-OmnipodKit-watchOS-device.log`, `build-G7SensorKit-watchOS.log`.

Trio experimental branch `kristinkand/feature/untethered-watch-mode` @ `a56170dc020a1d1b7ce4490514027c6ae6c297a4`:
- `.gitmodules` (diff vs `3f6b238b4`); gitlinks `LoopKit 8e8607db`, `G7SensorKit 48158d8c`, `OmnipodKit 9432ad4f`.
- `Trio/Sources/Services/Untethered/UntetheredPhoneManager.swift:438-456` (standing grant sets refusal),
  `:875`, `:1212-1225` (preconditions), `:1365-1381` (`releasePump`), `:984-995` (foreign session check),
  `:1680-1722` (gap booking).
- `Trio/Sources/Models/Untethered/UntetheredMessage.swift:193-203` (`handOverTempBasal`).
- `Trio Watch App Extension/Untethered/UntetheredWatchManager.swift:665-669` (dual dosing note, refusal set),
  `:817-860` (takeover, multiple managers), `:1565-1580` (`yieldIfPhoneTookPod`).
- `Trio Watch App Extension/G7Direct/README.md`; `Trio Watch App Extension/G7Direct/G7SensorKit/*` (26 files).
- `Trio.xcodeproj/project.pbxproj` (watch target embeds G7SensorKit, OmnipodKit, LoopKit, RileyLink frameworks).

LoopKit:
- Baseline `babddf04:LoopKit/DeviceManager/DeviceManager.swift:60-147`, `PumpManager.swift:347-361`.
- Fork `8e8607db` (net diff), commits `825bb3a9`, `8e8607db`.
- Upstream `b209fdc9` (hand-off protocols, LoopKit-watchOS), `f18a0b07`, `2aecef07` (slimmed protocol, review),
  `5bf5d82c`; LoopKit/LoopKit#626 (merged), #686, #687 (open).

OmnipodKit (fork pin `9432ad4f`):
- `OmnipodKit/PumpManager/OmniPumpManager+DeviceHandoff.swift:22-430`.
- `OmnipodKit/Bluetooth/BlePodComms.swift:41-49, 64-133, 382-403, 433-448, 763-841`.
- `OmnipodKit/Bluetooth/BluetoothManager.swift:210-300, 630-650, 812, 865-905`.
- `OmnipodKit/Bluetooth/BleMessageTransport.swift:46-57, 186-216`.
- `OmnipodKit/PumpManager/PodState.swift:138-152, 245-250, 413-427`; `OmniPumpManagerState.swift:25-38, 347-420`.
- `OmnipodKit/PumpManager/OmniPumpManager.swift:119-143, 199-205, 1273-1300, 1792-1797, 2748-2762, 3560-3566`.
- `OmnipodKit.xcodeproj/project.pbxproj` (`OmnipodKit-watchOS`, `FADE…0102`).
- Fork commits `11017f5`, `84f77e0`, `8edb3d2`, `fc903e3`, `b22886a`, `be108d5`, `4d7ed35`, `9432ad4`.
- loopandlearn/OmnipodKit#177 (open; head `e8216cd`; commits `8fe606c`, `a96f5d0`, `0af1bb3`, `6766e62`, `a002df5`,
  `8f2b4db`), #203 (closed), #201, #204, #205, #209, #211, #214, #216, #220.
- LoopKit/Loop#2545 commit `c491bf7f` (cited by jeremybarnum on #177; not read here).

G7SensorKit (fork pin `48158d8c`):
- `G7SensorKit/G7CGMManager/G7CGMManagerState.swift:200-207`; `G7WatchAcquisition.swift:129-164, 348-362`;
  `G7SensorKitUI/G7CGMManager/G7CGMManager+UI.swift:121-141`; `G7CGMManager.swift:528, 1477`.
- LoopKit/G7SensorKit#80 (merged), #90, #99, #104, #112 (closed), #113, #114 (open), #115, #117, #118, #120.
- nightscout/Trio#1749 (open, head `b97b55c91a35139c8498bd8685c2bcebd1647796`).
