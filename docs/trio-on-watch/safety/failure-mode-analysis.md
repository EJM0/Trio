# Trio on Watch: failure-mode analysis (safety baseline)

Agent E, independent safety reviewer. Phase 1, read-only. Baseline `nightscout/Trio` dev @ `ad6c66876e5ccca8b0a6e1c5b7626ed4caa65926`.
Contributor-facing engineering analysis. It is not clinical guidance and makes no dosing recommendation for any person.

## Executive summary

1. Every dosing guard in Trio today assumes **one process, one pump manager instance, one Core Data store holding the complete pump history**. None of them coordinates across devices. An untethered watch breaks that assumption, so the guards have to be re-established at the ownership layer, not patched one by one.
2. The worst failure is **two commanders**. Each device then computes IOB, the SMB interval and Max IOB from a partial dose history, and the two pump driver states (nonce, message sequence, pending command) drift apart. The pump cannot stop this for Omnipod: the pod keeps no dose log a second device could read back, and both nonce and EAP-SQN resyncs succeed without user involvement.
3. The protocol has to release before it acquires: having no owner is acceptable, two owners never is. Temp basals expire on their own (high temps at most 30 min, zero temps at most 120 min in oref), so "nobody is commanding" falls back to the pump's scheduled basal. That is the system's built-in fail-safe.
4. Loss of contact must never lead to an automatic takeover. A device that cannot reach its peer cannot tell "peer is dead" from "peer is alive and talking to the pump".
5. Handoff has to be blocked while a bolus is in flight, a dose is unfinalized, a command is unacknowledged, or delivery is uncertain. Trio itself does not gate on `deliveryIsUncertain` today. It only logs it and relies on the driver to refuse.
6. Upstream findings that apply even without a watch: `enactDetermination` enacts the newest determination from the last 30 min, not the one the current run produced, and a failed determination save is swallowed. Together these can re-send an already-enacted SMB (F1). The watch bolus path skips `BolusSafetyValidator` and carries no idempotency key (F5). The stale-glucose fallback determinations from oref are computed but never enacted (F8).
7. Pump state is persisted asynchronously after the driver changes it. A process kill between radio transmit and the plist write can lose the record of a pending Omnipod command (F4). On a watch, which suspends and terminates processes more aggressively (Inferred), this window matters more.
8. With the phone away, alerting (low glucose, pump faults, not looping) currently lives only on the phone. The watch would need its own alerting as a safety function. It cannot be treated as a nice-to-have.
9. Whether watchOS keeps an app running enough to loop overnight is unverified (questions for Agent D). If the watch cannot wake reliably, it should not be allowed to command the pump. A degraded mode is the most it should get.
10. Output: 27 failure modes (FM-01 to FM-27), 26 safety requirements (SR-1 to SR-26), and 28 questions for the proposed architecture.

## 1. Scope, method, conventions

- Code read at the baseline SHA plus the submodule pins: LoopKit `babddf04`, OmnipodKit `6fdf0e0`, DanaKit `787a639`, MedtrumKit `eee17b0`. I did not read the experimental branch or the other agents' deliverables.
- Claim tags: **[V]** Verified (I read the code at the cited line), **[I]** Inferred (follows from verified code plus reasoning), **[U]** Unverified (platform or pump behavior I did not confirm; needs evidence).
- Dose-state vocabulary used throughout:

| State | Meaning | Where it shows up in Trio today |
|---|---|---|
| Requested | Algorithm output or user request | `OrefDetermination.smbToDeliver` / `rate` (OpenAPS.swift:47-63) [V]; UI or remote bolus amount |
| Accepted | Driver took the command and sent it | `PumpManager.enactBolus` returns without error (APSManager.swift:673, 807, 813) [V] |
| Executed | Pump acknowledged the program | Omnipod: `unacknowledgedCommand` cleared, `unfinalizedBolus` set (PodCommsSession.swift:692-696) [V] |
| Confirmed | Delivery finalized and stored as history | `PumpEventStored` row, `isMutable == false` (PumpHistoryStorage.swift:121-133) [V] |

`OrefDetermination.enacted` (APSManager.swift:874) means "temp and SMB commands returned without error". That is Accepted at best. It does not mean Confirmed [V].

- Automation decision levels used below:
  - **Continue**: full automation.
  - **Degrade**: no insulin-adding actions. Trio already has this as `AutomationLevel.reductionsOnly` (Max IOB clamped to 0) via `DosingMode.lowGlucoseSuspend` (DosingMode.swift:4-36) [V]. Per the repo rule, the clamp is derived at the call site and never stored.
  - **Stop**: no pump commands. Running temps expire to scheduled basal, and the user is alerted.

## 2. Baseline safety mechanisms (what exists, what each assumes)

| # | Mechanism | Evidence | What it guards | Single-device assumption |
|---|---|---|---|---|
| B1 | `LoopGuard` actor: one loop at a time, 3 min minimum interval | APSManager.swift:80-122, 313-320; Config.swift:7 [V] | Overlapping loops in one process | In-memory, per-process; nothing across devices |
| B2 | No pump, no loop | APSManager.swift:306-309 [V] | Looping without a pump | Per device |
| B3 | Glucose validation: at least 3 readings in the last hour, newest 12 min old at most; enactment blocked otherwise | APSManager.swift:512-528, 550-552; NSPredicates.swift:87-90 [V] | Dosing on stale or missing glucose | Local glucose store is complete |
| B4 | oref BG-age guard (`minAgo > 12` or `< -5`), calibration/noise guard, flat-CGM guard | DetermineBasalGenerator.swift:612-632 [V] | Old, future or bad glucose | Local clock is the reference |
| B5 | oref current-temp vs history-temp check, cancels the temp on mismatch | DetermineBasal+Helpers.swift:194-210; DetermineBasalGenerator.swift:81-87 [V] | Pump state disagreeing with history | History holds all temps |
| B6 | SMB interval from `lastBolusTime` (1-10 min, default 3) | DosingEngine.swift:818-850 [V] | Back-to-back SMBs | History holds all boluses |
| B7 | SMB size cap (maxSMB / maxUAMSMB basal minutes) | DosingEngine.swift:698-730 [V] | Oversized SMB | Correct IOB and COB |
| B8 | Max IOB cap in oref | DosingEngine.swift:637-648 [V] | Total insulin on board | Correct IOB |
| B9 | `BolusSafetyValidator`: max bolus, IOB unavailable, Max IOB, recent-bolus 20 % in 6 min | BolusSafetyValidator.swift:42-61 [V] | Duplicate or oversized external boluses | Applied to remote control and Shortcuts only (TrioRemoteControl+Bolus.swift:11-14, BolusIntentRequest.swift:16) [V]. Not the in-app or watch path |
| B10 | Manual bolus pre-check: pump not bolusing, not suspended | APSManager.swift:441-456, 643-655 [V] | Bolus during bolus or suspend | Pump status is fresh |
| B11 | Enactment skipped when suspended, refused during a manual temp | APSManager.swift:794-802 [V] | Fighting user pump actions | Status is fresh |
| B12 | Remote command window of 600 s either way | TrioRemoteControl.swift:18, 52-69 [V] | Replay or delay of remote commands | No `commandId` dedupe within the window [V] |
| B13 | Orphaned-resume filter (cold start) | OpenAPS.swift:135-140, 186-232 [V] | Negative IOB from a resume with no matching suspend (#898) | History boundary artifacts |
| B14 | DynISF off when TDD history is insufficient | OpenAPS.swift:323-327 [V] | DynISF on thin data | Degrades safely when history is thin |
| B15 | Pump event upsert by `syncIdentifier`, falling back to timestamp+type; finalized rows immutable; pending rows replaced on `replacePendingEvents` | PumpHistoryStorage.swift:63-224 [V] | Duplicate events from one driver | One driver is the only writer |
| B16 | Pump event timestamps clamped to now | PumpHistoryStorage.swift:130 [V] | Future-dated events | One clock |
| B17 | Omnipod write-ahead `unacknowledgedCommand` before transmit, recovery by `lastProgrammingMessageSeqNum`, new commands fail closed while unresolved | PodCommsSession.swift:489-509, 650-704, 1086-1100 [V] | Uncertain delivery | Exactly one controller and one copy of pod state |
| B18 | Omnipod checks pod status before a bolus if a bolus is unfinalized or status is unknown | PodCommsSession.swift:663-678 [V] | Bolus on top of a running bolus | Local `podState` is current |
| B19 | Omnipod `deliveryIsUncertain = needsCommsRecovery` | OmniPumpManager.swift:597; PodState.swift:119-124 [V] | Surfacing uncertainty | Trio only logs it (DeviceDataManager.swift:457-459) [V] |
| B20 | `NotLoopingMonitor`: pre-scheduled notifications at 20/40/60/80/100 min, critical at 120 min | NotLoopingMonitor.swift:8, 33, 82-130 [V] | Silent loop failure | Lives on the phone; keyed to the local `lastLoopDate` |
| B21 | Watch acknowledgment timeout of 15 s; text admits a send error can still have delivered | WatchState.swift:75, 170-188 [V] | User confusion after a lost ack | Retry by the user is still possible |
| B22 | Pump delivery limits re-applied from settings on pump set | DeviceDataManager.swift:115-125 [V] | Stale limits in driver state | Per device |
| B23 | Pump event filter drops temps above max basal (Medtronic bug) | DeviceDataManager.swift:580-586 [V] | Bogus TBRs | – |

## 3. Upstream findings (independent of the watch, amplified by it)

| ID | Finding | Evidence | Why it matters for a watch |
|---|---|---|---|
| F1 | `enactDetermination` fetches the newest determination with `deliverAt` in the last 30 min (DeterminationStorage.swift:28-46; NSPredicates.swift:102-105). It is not bound to the run's own result and does not check `enacted`. If saving the new determination fails, the failure is logged and swallowed (OpenAPS.swift:92-102, 361), so the loop enacts the previous determination, including its `smbToDeliver` (APSManager.swift:783-816). This can repeat on every loop while saves keep failing. | [V] code path; never exercised by me in a test | Storage pressure and process kills are more likely on a watch [I]. Fix it upstream regardless. See SR-8. |
| F2 | Trio ignores `lastReconciliation` (DeviceDataManager.swift:571). `ensureCurrentPumpData` always reports success and starts the loop (DeviceDataManager.swift:306-329), and Omnipod calls its completion even if `getPodStatus` fails (OmniPumpManager.swift:2681-2706). | [V] | Loops run on stale pump state. Safety then rests on the driver refusing commands and on B5. |
| F3 | `deliveryIsUncertain` is logged only (DeviceDataManager.swift:457-459). Kits other than Omnipod signal uncertainty only through `didError(.uncertainDelivery)` (DanaKitPumpManager.swift:1700; MedtrumPumpManager.swift:1214, 1238), which Trio turns into a dwell-suppressed error, not a gate. | [V] | Handoff and new dosing have to be gated at the Trio level, not left to each kit. |
| F4 | Driver state changes reach Trio via `queue.async` (WeakSynchronizedDelegate.swift:46-56; OmniPumpManager.swift:297-300) and are then written as a plist (DeviceDataManager.swift:387-388; PersistedProperty.swift:101-113). Write failures are only logged. | [V] async path; [I] crash window between transmit and persistence | A kill in that window loses the pending-command record. After relaunch the device may not know a bolus was sent. |
| F5 | Watch bolus requests go straight to `enactBolus` with no `BolusSafetyValidator`, no idempotency key, and no age check for bolus-only messages (AppleWatchManager.swift:654-659, 811-822, 932-941). | [V] | Retry after a lost ack can produce a second bolus once the first finishes. README lists open PR #1648 ("watch bolus safety check"); I have not read it [U]. |
| F6 | `detectedSystemTimeOffset` is hard-coded to 0 (DeviceDataManager.swift:378-380). There is no trusted-time check. | [V] | Cross-device clock disagreement goes undetected. |
| F7 | The user copy says "at least three glucose readings in the last six hours", but the predicate is one hour (APSManager.swift:514-518 vs NSPredicates.swift:87-90). | [V] | Nit. The wrong copy would be inherited by a watch. |
| F8 | When glucose is older than 12 min, oref returns a fallback (replace high temp with neutral, shorten a long zero temp), but `determineBasal` throws on `isValidGlucoseData` before `enactDetermination` runs (APSManager.swift:550-552, 376-383). The fallback is computed but never enacted. | [V] | High temps (30 min max) then run to expiry with no glucose. Bounded, but a CGM drop on the watch is the common case. Worth a deliberate decision upstream. |

## 4. Failure modes

Each entry gives impact, existing protection, required mitigation, the automation decision, recovery, and testing. Severity: **S1** unbounded or repeated over-delivery; **S2** bounded over-delivery or a missed hypo alarm; **S3** under-delivery or hyperglycemia; **S4** nuisance.

### FM-01 iPhone unavailable or out of range (watch is commander)
- **Impact**: with the phone away, there is no phone UI, phone alerting, phone not-looping monitor (B20) or backup commander. Nightscout upload depends on the watch's own network [U]. S2 through lost alerting (see FM-24).
- **Existing protection**: none for multiple devices. B20 is phone-local.
- **Mitigation**: the watch commands only if ownership was transferred to it before separation (SR-2). The watch carries its own dead-man's switch and alerting (SR-15, SR-16).
- **Automation**: Continue if the watch is a verified owner and passes SR-17. Otherwise Stop.
- **Recovery**: on reconnect, sync data (history, carbs, overrides) before any ownership change. Ownership stays with the watch until an explicit handoff.
- **Testing**: simulator (two devices, mock pump, phone made unreachable). Physical: phone in airplane mode, walk-away, overnight run.

### FM-02 Watch disconnected from phone (session unreachable, or the phone app is dead)
- **Impact**: messages are lost or arrive late. A queued message delivered late can execute a stale intent [I]. The non-owner may wrongly conclude its peer is dead. S1 if it then takes over (FM-07).
- **Existing protection**: watch treatment requests use `sendMessage` only, with a 15 s ack timeout (WatchState+Requests.swift:136-150; WatchState.swift:75) [V]. The baseline watch only queues via `transferUserInfo` for notifications, not treatments (WatchNotificationHandler.swift:55-64) [V]. WCSession delivery semantics: [U].
- **Mitigation**: no takeover on loss of contact (SR-3). Every cross-device command carries an id, issue time, expiry and owner epoch, and is rejected when expired, duplicated or from the wrong epoch (SR-9, SR-10).
- **Automation**: the owner continues. The non-owner never commands.
- **Recovery**: on reconnect, exchange epochs, clock offset and history deltas.
- **Testing**: unit (message validation, expiry, dedupe). Simulator (drop, delay and replay injection). Physical (Bluetooth off on phone, Wi-Fi only).

### FM-03 Pump disconnected from the watch
- **Impact**: commands fail. A drop mid-command leaves delivery uncertain (FM-12). The running temp continues and then reverts to scheduled basal. S3 (missed corrections), or S2 if the drop happens during an SMB.
- **Existing protection**: driver certain-failure vs unacknowledged split (PodCommsSession.swift:687-704; OmniPumpManager.swift:2787-2799) [V]. Loop errors surface (APSManager.swift:419-439). B20 on the phone.
- **Mitigation**: unchanged loop retry. Watch-local not-looping ladder (SR-15). Handoff to the phone only by explicit user action, and only after the uncertain state is resolved (SR-4).
- **Automation**: Continue (commands simply fail). Stop insulin-adding commands while uncertain (SR-11).
- **Recovery**: reconnect, `getStatus`, resolve the pending command, then resume.
- **Testing**: physical hardware per pump (distance, shielding, wrist versus pocket placement), on DASH, Dana-i/RS, Medtrum. Driver behavior is kit-specific.

### FM-04 CGM disconnected from the watch
- **Impact**: no new glucose. Within 12 min the loop throws before enacting (B3). A high temp runs to expiry (30 min max) without the oref fallback being enacted (F8). S2/S3, bounded.
- **Existing protection**: B3, B4. Both devices connecting to one transmitter may compete for its connection slots [U per CGM].
- **Mitigation**: define exactly one CGM data path for the commander (direct BLE, or relayed with the original sensor timestamps). Decide on F8 deliberately. Raise a CGM-signal-loss alert on the watch (SR-16).
- **Automation**: Stop automatically through B3. Running temps expire.
- **Recovery**: the loop resumes once at least 3 readings exist in the last hour and the newest is fresh. Backfill is handled (FetchGlucoseManager.swift:324-333).
- **Testing**: physical per CGM (G7, G6, Libre via LibreTransmitter, others) on a watch. Simulator: GlucoseSimulator gap injection.

### FM-05 Stale glucose (old, delayed or future-dated)
- **Impact**: dosing on old trend data. S2.
- **Existing protection**: B3 (12 min), B4 (12 / −5 min), `filterTime` 3.5 min dedupe (GlucoseStorage.swift:45, 410-425) [V]. A future-dated reading moves `syncDate` forward and causes later real readings to be treated as backfill (FetchGlucoseManager.swift:324-339; GlucoseStorage.swift:351-381) [I].
- **Mitigation**: keep the guards and evaluate them on the commander's clock. Relayed glucose keeps the sensor timestamp. Reject relayed readings whose source clock offset is unknown or outside tolerance (SR-20).
- **Automation**: Stop through the existing guards.
- **Recovery**: automatic once fresh readings arrive.
- **Testing**: unit (offset readings, a future reading followed by real ones). Simulator (clock skew between the two sims).

### FM-06 Missing glucose (gaps, warmup, fresh install on the watch)
- **Impact**: no loop until 3 readings exist in the last hour (B3). Autosens and smoothing see less history. DynISF turns off if TDD history is thin (B14), which is a change in dosing behavior the user may not expect. S3.
- **Existing protection**: B3, B14. The copy is wrong (F7).
- **Mitigation**: the handoff snapshot includes enough glucose for autosens (24 h) and enough TDD history for DynISF (SR-5). Otherwise the receiver states which features are degraded.
- **Automation**: Stop until B3 passes. Continue with DynISF possibly off.
- **Recovery**: automatic.
- **Testing**: unit (thin-history profiles produce the same determination as the phone given the same inputs). Parity across devices for identical inputs.

### FM-07 Both devices believe they own the pump (split brain)
- **Impact**: two loops command the pump. Every history-based guard (B5-B9) is computed from partial data on each side, so doubled SMBs and conflicting temps are possible. The two copies of driver state diverge (FM-23). **S1, the worst case.**
- **Existing protection**: none. B1 is per process. Omnipod nonce and EAP-SQN resync recover without user involvement (PodCommsSession.swift:396-418; BlePodComms.swift:297, 343) [V], so the pump will not stop a second controller. That second controller holds the full pod key (`ltk`, PodState.swift:128, 643-683) [V].
- **Mitigation**: a single-writer ownership token `(owner, epoch)`, persisted on both sides. Handoff releases before it acquires (SR-1, SR-2). No timeout takeover (SR-3). A forced takeover (old owner lost or broken) is an explicit user action that bumps the epoch. The old owner must stop as soon as it sees a higher epoch, and must hold its pump manager inert while unsure (SR-3, SR-21). Peer-commander detection: an unexpected nonce or SQN resync, unknown insulin (Omnipod `insulinDelivered` versus recorded doses, StatusResponse.swift:19-21 [V]), or a current temp that disagrees with own history (B5). Any of these stops insulin-adding automation (SR-21).
- **Automation**: Stop insulin-adding automation on both devices on any evidence of a second owner.
- **Recovery**: merge both histories by stable identity (SR-6). Re-validate IOB. Resume on one device after a user-confirmed handoff.
- **Testing**: unit (ownership state machine with fault injection: lost ack, restart at every step, forced takeover with the old owner offline). Simulator (two sims sharing a mock pump that fails the test whenever it sees a second commander). Physical DASH: deliberately run two controllers on a test pod only (not on a person) to characterize what the pod accepts.

### FM-08 Split-brain IOB (partial dose history on one device)
- **Impact**: IOB, `lastBolusTime` (B6), Max IOB (B8, B9), TDD (B14) and COB are all wrong. Under-counted IOB leads to over-delivery. S1/S2.
- **Existing protection**: none across devices. Omnipod cannot backfill: doses enter history only from the commanding instance (`dosesForStorage` after success, OmniPumpManager.swift:2787-2793; 3435-3445) [V]. The pod exposes only cumulative `insulinDelivered` [V]. Pumps with their own UI (Dana, Medtrum, Medtronic) can read history back, but I have not verified completeness and timeliness per kit [U].
- **Mitigation**: the transfer carries the full pump event history (at least 24 h, which covers DIA, plus the TDD window), pending and unfinalized doses, and driver state (SR-5). The receiver checks continuity: for Omnipod, compare pod `insulinDelivered` with recorded doses since activation, and degrade on mismatch. Merge by `syncIdentifier`/UUID only. The timestamp+type fallback (PumpHistoryStorage.swift:107-116) is unsafe across clocks. `replacePendingEvents` purges every mutable row the local driver did not assert (PumpHistoryStorage.swift:196-209), so mutable rows imported from the peer need a different treatment (SR-6).
- **Automation**: Degrade (no insulin-adding actions) until continuity is verified.
- **Recovery**: reconciliation step after handoff or reconnect.
- **Testing**: unit (merge, purge, dedupe across clock offsets; IOB parity between devices on identical history). Physical per pump family.

### FM-09 Duplicate commands
- **Impact**: double bolus. S1/S2.
- **Sources**: retry after a lost ack (B21), at-least-once transports [U], replay inside the remote window (B12), the same request handled on both devices, re-enactment of an old determination (F1).
- **Existing protection**: B9 (remote and Shortcuts only), B18 (only while the first bolus is unfinalized), B12 window.
- **Mitigation**: an idempotency key per bolus request, persisted on the commander. Validator on every bolus path (SR-9). SMB enactment bound to the determination id with an `enacted` check (SR-8). Ambiguous outcomes are never auto-retried (SR-10).
- **Automation**: Continue. Duplicates are rejected.
- **Recovery**: user-visible "outcome unknown, check history" state.
- **Testing**: unit (dedupe store, validator on all paths). Simulator (inject duplicate and replay).

### FM-10 Delayed commands
- **Impact**: a bolus or temp computed on an earlier context executes later. S2.
- **Existing protection**: B12 (600 s for remote). Determinations are computed on the enacting device, but enactment accepts any up to 30 min old (F1).
- **Mitigation**: dosing is computed only on the commander at enact time. Computed temps and SMBs are never forwarded between devices (SR-7). User bolus requests carry a short expiry and are re-validated on the commander when executed (SR-9). Enactment rejects determinations older than a small bound (SR-8).
- **Automation**: Continue. Late commands are rejected.
- **Recovery**: user re-issues the request.
- **Testing**: unit (expiry boundary). Simulator (delay injection).

### FM-11 Failed pump communication (certain failure)
- **Impact**: the intended change does not happen. S3.
- **Existing protection**: B17 classification, loop error, B20.
- **Mitigation**: unchanged. Mirror the not-looping ladder on the watch (SR-15).
- **Automation**: Continue (retry next cycle).
- **Recovery**: automatic.
- **Testing**: physical per pump. Simulator with MockPumpManager error injection.

### FM-12 Unconfirmed or uncertain insulin delivery
- **Impact**: IOB omits a dose that may have been delivered. A retry could double it. S1/S2.
- **Existing protection**: B17-B19 for Omnipod. Dana and Medtrum report `.uncertainDelivery` (F3). Trio's bolus alert says "Bolus failed. Check pump history before repeating." (APSManager.swift:684-690) [V]. For an uncertain outcome, the word "failed" is misleading.
- **Mitigation**: a Trio-level gate. No insulin-adding command while `deliveryIsUncertain` or while an unresolved dose intent exists (SR-11). Block handoff in this state (SR-4). Fix the copy to say the outcome is unknown.
- **Automation**: Degrade. Suspend and reductions stay allowed.
- **Recovery**: driver recovery (`getStatus`), or the kit's own recovery UI.
- **Testing**: physical (pull the pod or pump out of range mid-bolus) per pump. Unit tests for the gate.

### FM-13 App suspension (watchOS)
- **Impact**: the loop does not run, readings are missed, and a suspension mid-command drops the BLE session (FM-12). S3 (not looping) or S2 (mid-command).
- **Existing protection**: the phone uses `beginBackgroundTask` (APSManager.swift:330-337) [V]. The baseline watch target declares no background modes and uses no Core Bluetooth (Trio Watch App/Info.plist; no CoreBluetooth references in `Trio Watch App Extension`) [V]. watchOS background BLE wake and runtime budgets: [U]. That is Agent D's question.
- **Mitigation**: start a dose command only if there is runtime left to finish it and persist the result. Prove the wake source on hardware (SR-17). Pre-schedule dead-man's-switch notifications (SR-15).
- **Automation**: Continue while running. A gap behaves like "not looping": temps expire.
- **Recovery**: on wake, run the restore checklist (SR-24).
- **Testing**: physical only. Overnight, screen off, wrist on, with no Xcode attached (per the repo rule, an attached debugger lifts CPU limits).

### FM-14 App termination mid-command
- **Impact**: the pending command record is lost (F4), the dose may be missing from IOB, and stale `messageNumber`/nonce state is left on disk. S1/S2.
- **Existing protection**: Omnipod sets `unacknowledgedCommand` before transmit, but only in memory first, then persists asynchronously (B17 + F4).
- **Mitigation**: on the commander, a write-ahead dose-intent journal and synchronous persistence of driver pending state before transmit (SR-12). On relaunch, any unresolved intent counts as uncertain (SR-11).
- **Automation**: Degrade until resolved.
- **Recovery**: `getStatus`, reconcile with the intent journal.
- **Testing**: kill-at-every-step tests. In the simulator with a mock pump that has an injectable "received but not acked" state. On hardware with DASH, by killing the process during a bolus on a test pod.

### FM-15 Watch restart
- **Impact**: as FM-14, plus the app may not relaunch until the user opens it [U], and ownership may have changed while the watch was down (a forced takeover by the phone). If the restarted watch still believes it owns the pump, that is S1.
- **Existing protection**: pump state plist uses `FileProtectionType.none` (PersistedProperty.swift:105-109) [V], so it is readable before first unlock. Core Data store protection on a watch: [U].
- **Mitigation**: the restarted device re-validates its epoch with the peer when reachable. If it is unreachable, it may continue only if no forced takeover is possible without its knowledge. Otherwise it starts passive (SR-3, SR-24). This is a real trade-off between unattended uptime and split-brain risk. See Q-6.
- **Automation**: Stop until revalidated, or Continue under a defined policy.
- **Recovery**: handshake, or explicit user attestation.
- **Testing**: physical (reboot mid-night, reboot during an in-flight bolus). Unit (state machine).

### FM-16 Battery depletion
- **Impact**: the watch dies and nobody commands. Temps expire (high ≤ 30 min, zero ≤ 120 min: DosingEngine.swift:299-305, 481-497) [V]. A pod bolus already acknowledged completes on the pod [I]. Death between transmit and ack is uncertain on the next owner. The alarms go too. S2/S3.
- **Existing protection**: none watch-specific. Power-saving modes that stop third-party apps: [U].
- **Mitigation**: battery thresholds trigger a proactive handoff when the phone is reachable, or an alert when it is not. Refuse to accept ownership below a threshold (SR-18). The next owner treats the last known state as uncertain until `getStatus` (SR-24).
- **Automation**: Degrade or hand off at the warning threshold. Stop at critical.
- **Recovery**: handoff to the phone. Charge.
- **Testing**: physical (drain tests with logging). Measure loop-power cost on target watch models.

### FM-17 Interrupted algorithm run
- **Impact**: determination saved but not enacted. Temp enacted but not the SMB (APSManager.swift:806-815) [V]. F1 can then enact a stale determination. S2 through F1.
- **Existing protection**: B1 resets on relaunch (in memory). `lastLoopStartDate` is persisted (APSManager.swift:137). Next loop recomputes.
- **Mitigation**: SR-8 (bind enactment to the run id, cap age, check `enacted`). SR-12 intent journal.
- **Automation**: Continue next cycle.
- **Recovery**: automatic.
- **Testing**: unit with injected throw points. Simulator with process kill.

### FM-18 Persistence failure
- **Impact**: determination save failures (F1), pump-state plist failures (F4), and pump-event save failures (error passed back to the driver, DeviceDataManager.swift:595-599) [V]. A full disk on the watch is plausible [I]. S1 through F1, S2 through lost pending state.
- **Existing protection**: logging only for determinations and plists. Pump events propagate the error to the driver [V]. Core Data `fatalError` paths at stack setup (CoreDataStack.swift:44, 107, 111) [V].
- **Mitigation**: failure to persist pump state, pump events or the determination is a dosing-blocking fault: Degrade and alert (SR-13). Disk-space reserve check before accepting ownership.
- **Automation**: Degrade.
- **Recovery**: free space, re-verify state.
- **Testing**: unit (injected save errors on each store). Simulator (fill disk).

### FM-19 State restoration after restart
- **Impact**: persisted flags (`lastLoopDate`, `isManualTempBasal`, `isSuspended`, APSManager.swift:137-167 [V]) may be stale. The pump manager is restored from its plist (DeviceDataManager.swift:211) [V]. Event fetch starts at `lastEventDate − 15 min`, or 2 h back if unset (DeviceDataManager.swift:641-643) [V], which has to be consistent with history imported in a handoff. S2.
- **Existing protection**: B5 cancels a temp that disagrees with history.
- **Mitigation**: restore checklist before the first command: ownership epoch, successful pump status, history continuity, glucose freshness (SR-24).
- **Automation**: Stop until the checklist passes.
- **Recovery**: automatic.
- **Testing**: unit (checklist). Simulator (relaunch with crafted state).

### FM-20 App upgrade on one device only (version skew)
- **Impact**: incompatible pump-state schema. A PodState that fails to decode `ltk` makes "every pod command fail" (PodState.swift:676-683) [V]. Core Data model mismatch. Different algorithm builds produce different dosing from identical inputs. Message protocol mismatch. S2.
- **Existing protection**: none across devices. Whether the phone and watch apps can run different builds is [U].
- **Mitigation**: version handshake covering message protocol, driver state schema per kit, Core Data model and algorithm build. A mismatch blocks handoff and leaves the current owner as it is (SR-19). Never ship a pump-state snapshot to a driver version that has not been qualified for it.
- **Automation**: owner Continues. No handoff.
- **Recovery**: update both devices.
- **Testing**: unit (handshake matrix). CI check that both targets embed the same version constants.

### FM-21 Clock changes, time zone changes, drift between devices
- **Impact**: wrong BG age, wrong SMB interval if `lastBolusTime` came from a skewed peer (DosingEngine.swift:823-843) [V], fallback dedupe misses (FM-08), lease and expiry errors, profile schedule offsets. S2.
- **Existing protection**: B4, B16, B12, Omnipod clock-offset alert (OmniPumpManager.swift:3061-3070) [V]. No trusted time (F6). The profile uses elapsed-minutes semantics for DST (repo rule).
- **Mitigation**: exchange clock offset at every contact. Refuse handoff above a threshold or while time zones differ (SR-20). Use single-device monotonic time for expiries. Never compare wall clocks across devices for safety decisions.
- **Automation**: Continue on the owner. Block handoff.
- **Recovery**: user fixes the clock or time zone. Pump time sync follows the existing kit flow.
- **Testing**: unit (skewed fixtures). Simulator (manual clock offsets, DST and TZ transitions with `TZ=Europe/Berlin` as in parity tests).

### FM-22 Handoff during an in-flight bolus or temp basal
- **Impact**: the receiver may not know a bolus is running or unfinalized. With a stale `lastDeliveryStatusReceived`, Omnipod skips its pre-bolus status check (PodCommsSession.swift:663) [V] and sends a new bolus. Pod-side rejection behavior: [U]. A running temp unknown to the receiver is caught by B5 (it cancels), which is safe but disruptive. S1/S2.
- **Existing protection**: B18, B5.
- **Mitigation**: two-phase handoff. The owner quiesces: stops its loop, waits for no in-flight commands, finalizes doses, persists "released, epoch n". Then it transfers the snapshot. The receiver validates, persists "owner, epoch n+1", runs `getStatus`, and acks. Handoff is refused while the bolus state is not `noBolus`, a dose is unfinalized, a command is unacknowledged, or delivery is uncertain (SR-2, SR-4). A lost ack leaves zero owners. Alert, never two.
- **Automation**: Stop during handoff.
- **Recovery**: retry the handoff, or the user re-confirms on one device.
- **Testing**: unit (every interleaving). Simulator. Physical DASH and Dana: handoff attempts during a 2 U+ bolus on a test pod or reservoir.

### FM-23 Pod nonce or sequence desync when two devices talk to the same pod
- **Impact**: Eros nonce and DASH message, EAP and nonce sequences live in each device's copy of `PodState` (PodState.swift:126-134, 239-272; BleMessageTransport.swift:15-35) [V]. Resyncs are automatic (B17, BlePodComms.swift:297, 343) [V], so a second controller is masked rather than refused. Pending-command recovery matches on the 4-bit `lastProgrammingMessageSeqNum` (PodCommsSession.swift:1090; StatusResponse.swift:21) [V]. With interleaved senders that match can be falsely positive (about 1 in 16 [I]) or falsely negative, so a dose is wrongly booked or dropped. S1.
- **Existing protection**: none for two controllers.
- **Mitigation**: never two live pump manager instances for one pod (SR-1). Transfer driver state only after quiesce, exactly as last persisted (SR-2, SR-12). Outside the single expected post-handoff session setup, a resync is peer evidence that stops automation (SR-21).
- **Automation**: Stop on evidence.
- **Recovery**: one controller only, `getStatus`, reconcile `insulinDelivered`.
- **Testing**: physical test pods only (Eros via RileyLink is probably phone-only, see Q-20). Unit tests on resync-as-signal detection.

### FM-24 Alerting path lost with the phone away (added)
- **Impact**: no low glucose, pump fault, occlusion or not-looping alerts. S2.
- **Existing protection**: phone-only alert stack: B20, `DeviceManagerDelegate.issueAlert` (DeviceDataManager.swift:649-657) [V].
- **Mitigation**: alert parity on the watch for glucose thresholds, pump and CGM kit alerts, and not-looping. Alerts must not be suppressed on the phone just because "the watch owns the pump" while the phone can still see that the owner is silent (SR-15, SR-16).
- **Automation**: n/a.
- **Testing**: physical (alert delivery with the watch locked, in Do Not Disturb, in Sleep focus) [U on platform behavior].

### FM-25 Divergent treatment or settings state (added)
- **Impact**: a carb entry deleted on one device but alive on the other means dosing for phantom COB (S1/S2). Overrides and temp targets differ. Settings (Max IOB, basal, ISF, CR) changed on the phone while the watch owns the pump. S2.
- **Existing protection**: none across devices.
- **Mitigation**: treatments and settings sync to the owner before use, with stable ids and tombstones for deletions. Settings changes go to the owner and are acknowledged. The non-owner displays "pending" until then (SR-5, SR-6, SR-25).
- **Automation**: Degrade if the settings version is unknown.
- **Testing**: unit (merge with tombstones). Simulator.

### FM-26 BLE connection contention for CGM or pump (added)
- **Impact**: the phone and watch both connect to the same transmitter or pod. Readings or commands are lost, and connection thrash leaves delivery uncertain. S3/S2.
- **Existing protection**: none. Per-device slot rules: [U].
- **Mitigation**: the non-owner's pump manager must not connect (SR-1). The CGM path is defined per CGM type (Q-14).
- **Testing**: physical per CGM and pump.

### FM-27 Manual bolus requested on the non-owner (added)
- **Impact**: routing errors, double execution, or a bolus validated against the wrong IOB. S1/S2.
- **Existing protection**: F5 (no validator on the watch path).
- **Mitigation**: all boluses route to the owner and are validated there against the owner's IOB (SR-9). The non-owner never calls `enactBolus`.
- **Testing**: unit and simulator.

### Summary matrix

| FM | Severity | Automation decision |
|---|---|---|
| 01 Phone unavailable | S2 | Continue if verified owner, else Stop |
| 02 Watch-phone link down | S1 via takeover | Owner Continue; non-owner never commands |
| 03 Pump link down | S2/S3 | Continue (fail); gate insulin-adding commands on uncertainty |
| 04 CGM link down | S2/S3 | Stop (existing guard) |
| 05 Stale glucose | S2 | Stop (existing guard) |
| 06 Missing glucose | S3 | Stop until 3 readings |
| 07 Two owners | **S1** | Stop insulin-adding on both |
| 08 Split IOB | S1/S2 | Degrade until continuity verified |
| 09 Duplicates | S1/S2 | Reject duplicates |
| 10 Delays | S2 | Reject expired |
| 11 Comms failure | S3 | Continue |
| 12 Uncertain delivery | S1/S2 | Degrade |
| 13 Suspension | S2/S3 | Continue while running; runtime proof required |
| 14 Kill mid-command | S1/S2 | Degrade until resolved |
| 15 Restart | S1 | Stop until revalidated (policy Q-6) |
| 16 Battery | S2/S3 | Degrade or handoff, then Stop |
| 17 Interrupted run | S2 | Continue next cycle |
| 18 Persistence failure | S1/S2 | Degrade |
| 19 Restoration | S2 | Stop until checklist |
| 20 Version skew | S2 | No handoff |
| 21 Clocks | S2 | No handoff; owner continues |
| 22 Handoff in flight | S1/S2 | Refuse handoff |
| 23 Pod desync | S1 | Stop on evidence |
| 24 Alerting lost | S2 | n/a (must exist) |
| 25 State divergence | S1/S2 | Degrade on unknown settings |
| 26 BLE contention | S2/S3 | Non-owner never connects |
| 27 Bolus on non-owner | S1/S2 | Route to owner |

## 5. Safety requirements

Any architecture must meet these. "Owner" means the single device allowed to command the pump.

- **SR-1 Single commander.** At most one device holds a live, connected pump manager able to send commands at any instant. On the non-owner the pump manager is not instantiated, or it is instantiated with transport disabled. Ownership is a persisted `(owner, epoch)` on both devices.
- **SR-2 Release before acquire.** Handoff is two-phase: the owner quiesces and persists "released", then the snapshot transfers, then the receiver persists "owner, epoch+1" and acks. Every failure path ends with zero owners, never two.
- **SR-3 No autonomous takeover.** Timeouts, unreachability or a missed heartbeat never grant ownership. A takeover without the peer needs an explicit user action, bumps the epoch, and is recorded. An old owner that sees a higher epoch stops all pump commands at once.
- **SR-4 Handoff preconditions.** Refuse handoff while: bolus state is not `noBolus`; an unfinalized dose exists; a command is unacknowledged; `deliveryIsUncertain`; pump status is older than the kit's freshness bound; the version handshake fails (SR-19); clock offset or time zone fails SR-20; battery fails SR-18.
- **SR-5 Complete transfer.** The snapshot contains: driver state as persisted at quiesce; pump events covering at least 24 h and the TDD window used by DynISF; pending and unfinalized doses; glucose for the autosens window; carbs, overrides and temp targets, including deletions; settings, profile and preferences with a version. The receiver refuses a partial snapshot.
- **SR-6 Identity-based merge.** Cross-device merges use stable identifiers (`syncIdentifier`, UUID) and tombstones, never timestamp alone. Imported peer rows are not purged by local `replacePendingEvents` handling.
- **SR-7 Dose locally.** Temps and SMBs are computed only on the owner, from its own verified state, at enact time. Computed doses are never forwarded between devices.
- **SR-8 Bind enactment to the run.** Enact only the determination this run produced (by id), only if it is younger than a small bound, and only if it is not already `enacted`. This fixes F1 upstream regardless of the watch.
- **SR-9 One bolus gate.** Every bolus (in-app, watch, remote, Shortcut) is checked by `BolusSafetyValidator` on the owner against the owner's IOB. It carries an idempotency key, issue time and expiry, and keys are deduped persistently.
- **SR-10 At-most-once insulin.** A cross-device insulin command with an ambiguous outcome is reported as "unknown, check history" and never auto-retried.
- **SR-11 Uncertainty gate in Trio.** No insulin-adding command while `deliveryIsUncertain`, a kit `.uncertainDelivery` error is unresolved, or a journaled dose intent is unresolved. Suspend and reductions stay allowed.
- **SR-12 Write-ahead.** On the owner, the dose intent and the driver's pending-command state are durably persisted before the radio transmits.
- **SR-13 Persistence faults block dosing.** Failing to persist driver state, pump events or the determination switches to Degrade and alerts.
- **SR-14 Glucose guards preserved.** Keep B3/B4 on the owner's clock. Relayed glucose keeps the sensor timestamp. Make an explicit decision on F8.
- **SR-15 Dead-man's switch on the owner.** The owner pre-schedules not-looping notifications on itself, as B20 does on the phone. The non-owner, when it can see the owner's heartbeat, also alerts when the heartbeat goes silent. Neither device suppresses the other's safety net.
- **SR-16 Alert parity.** Glucose, pump, CGM and not-looping alerts reach the device the user is carrying when the phone is away.
- **SR-17 Proven runtime.** A watch may own the pump only if hardware tests (overnight, screen off, no debugger) show it runs a loop in at least an agreed share of 5-min cycles with its real wake source. Otherwise it gets Degrade at most.
- **SR-18 Battery policy.** Warning threshold leads to handoff or alert. Critical leads to Stop. Below threshold, ownership cannot be accepted.
- **SR-19 Version gate.** The handshake covers message protocol, per-kit driver state schema, Core Data model and algorithm build. A mismatch means no handoff.
- **SR-20 Clock discipline.** Measure peer clock offset at each contact. Handoff is refused above a threshold or on a time zone mismatch. Expiries use monotonic time on one device.
- **SR-21 Peer-commander detection.** An unexpected nonce or SQN resync, unexplained delivered insulin, or a pump temp unknown to local history triggers Stop of insulin-adding automation plus an alert.
- **SR-22 Explicit degrade ladder.** Full, then reductions-only (existing clamps derived at call sites, never stored), then Stop. Every transition is logged and visible to the user.
- **SR-23 Per-kit qualification.** Each pump and CGM kit is qualified separately for watch ownership and state transfer. An unqualified kit is phone-only.
- **SR-24 Restore checklist.** After launch or restart, before the first command: epoch valid, pump status fresh, history continuous, glucose fresh, no unresolved intent.
- **SR-25 Settings authority.** Settings and treatment changes made on the non-owner apply only once the owner acknowledges them. The UI shows the pending state.
- **SR-26 Observability.** Ownership transitions, epochs, handoff phases and gate decisions are logged per the CONTRIBUTING logging rules, with no health data or identifiers.

## 6. Questions for the proposed architecture

- **Q-1** Where is the ownership token stored on each device, and is it written durably before any pump command?
- **Q-2** Show the handoff state machine, with the persisted state after each step and the outcome when any message is lost or either process dies at each step.
- **Q-3** On the non-owner, is the pump manager absent, or present but inert? What stops a kit's own timers, heartbeats or alert polling from connecting to the pump?
- **Q-4** Which component refuses insulin-adding commands while delivery is uncertain? Is it Trio-level (SR-11) or left to each kit?
- **Q-5** How is forced takeover done when the owner is lost? What does the old owner do when it comes back, and what does the user see?
- **Q-6** Does ownership survive a process relaunch or a reboot without peer contact? What risk does that accept?
- **Q-7** What exactly is in the transfer snapshot, how big is it, and how is completeness verified on receipt?
- **Q-8** How are pump events merged? How does the design handle `replacePendingEvents` purging imported mutable rows?
- **Q-9** For Omnipod, is `insulinDelivered` reconciliation used to detect missing doses after handoff?
- **Q-10** Is the F1 enactment binding fixed in the proposal, or upstream first?
- **Q-11** Which transport carries commands (`sendMessage`, `transferUserInfo`, application context, network)? What are its delivery guarantees [U], and how are expiry and dedupe enforced?
- **Q-12** Does every bolus path on both devices go through the owner's `BolusSafetyValidator`?
- **Q-13** What wakes the watch every 5 min overnight with the screen off? What evidence shows it works on target watchOS and watch models? [U]
- **Q-14** How does each supported CGM reach the owner (direct BLE, or relay)? What happens to the phone's CGM connection when the watch owns the pump? Are transmitter connection slots a constraint? [U]
- **Q-15** Is the pump driver state written synchronously before transmit on the watch? If not, how is F4 closed?
- **Q-16** Which alerts exist on the watch, and how are they delivered through focus modes and while the watch is locked? [U]
- **Q-17** How do the phone's not-looping monitor and watch status interact so that the safety net is never suppressed on both sides?
- **Q-18** What are the battery thresholds, and what is the measured power cost of looping on the watch?
- **Q-19** How is version skew between the phone and watch builds detected, and can it actually happen? [U]
- **Q-20** Which pump kits are in scope? RileyLink-based pumps (Eros, Medtronic) need a bridge device. Are they phone-only?
- **Q-21** How are clock offset and time zone differences detected and handled?
- **Q-22** How are settings and treatment edits from the non-owner applied, and how are deletions propagated?
- **Q-23** What does the user see when there are zero owners, and how fast are they alerted?
- **Q-24** What logs and diagnostics let a maintainer reconstruct a handoff from a user's shared logs without exposing health data?
- **Q-25** Which parts of the design are needed for v1, and which are speculative (multiple watches, automatic takeover, shadow loops)?
- **Q-26** Does the non-owner compute determinations for display? If so, what prevents it from ever enacting them?
- **Q-27** How is the F8 decision (enact the oref stale-glucose fallback or not) made, and does it differ between phone and watch?
- **Q-28** What is the test plan for SR-1/SR-2 under fault injection, and which hardware runs it before any in-vivo use?

## 7. Test plan outline

| Layer | What | Notes |
|---|---|---|
| Unit (Swift Testing) | Ownership state machine with crash and loss at each step; snapshot completeness; identity merge with tombstones and clock offsets; validator on all bolus paths; F1 binding; uncertainty gate; clock-offset gate; version handshake | Safety-relevant and very testable. Most SRs are checkable here. |
| Algorithm parity | Identical inputs give byte-identical determinations on phone and watch builds | Reuse the existing Parity harness (Europe/Berlin TZ) |
| Simulator | Two simulators with MockPumpManager and GlucoseSimulator; a mock pump that fails the test on a second commander; injected delay, drop, replay and kill | Fresh simulators, never the one the developer is using |
| Physical, no person (in-vitro) | DASH test pods: two-controller characterization, kill mid-bolus, handoff during bolus, out-of-range mid-command. Dana-i/RS and Medtrum equivalents. CGM per type on the watch: G7, G6, Libre | No insulin-delivering test on a person until in-vitro passes |
| Physical, endurance | Overnight runs: loop cadence, battery, alert delivery, with no debugger attached | Evidence for SR-17 and SR-18 |
| In-vivo | Only after all of the above, by people who choose to test experimental builds | Out of scope for this document |

## 8. YAGNI notes

- **Needed for v1**: SR-1 to SR-4, SR-7 to SR-13, SR-15 to SR-17, SR-19, SR-23, SR-24. Each addresses an S1 or S2 failure mode above.
- **Needed but could be narrowed**: SR-5 (transfer only what the qualified kits need), SR-25 (owner-only settings edits are simpler than synced edits).
- **Speculative, reject for v1**: automatic takeover, more than two devices, both devices running enacting loops in "shadow" mode, formal TLA+ modelling. A model is nice to have; an exhaustive unit-level interleaving suite is probably enough for a two-party protocol.

## Open questions

1. watchOS background BLE wake, runtime budgets, relaunch after reboot, and power-saving behavior. Unverified here; Agent D owns them.
2. Pod-side behavior when a second controller sends a bolus during a running bolus, and whether any pump offers a real fence against a second controller. [U]
3. Per-kit history readback completeness for Dana, Medtrum and Medtronic, which matters for SR-5 and FM-08. [U]
4. Whether the F1 re-enactment path has ever been seen in the field. Searching the issues and logs is suggested; I did not.
5. Whether F8 (oref stale-glucose fallback never enacted) is intentional upstream.
6. Whether phone and watch app builds can diverge on real installs. [U]
7. CGM connection slot limits per transmitter when the phone and watch both connect. [U]

## Evidence index

Trio baseline `ad6c66876e5ccca8b0a6e1c5b7626ed4caa65926`:
- `Trio/Sources/APS/APSManager.swift`: 80-122 LoopGuard; 137-167 persisted flags; 289-372 loop; 306-309 pump guard; 330-337 background task; 376-389 executeLoop; 419-439 finalizeLoop; 441-456 verifyStatus; 488-580 determineBasal and glucose validation (512-528, 550-552); 582-595 determineBasalSync; 635-711 enactBolus (684-690 bolus-failed alert); 739-780 fetchCurrentTempBasal; 783-817 enactDetermination; 854-884 reportEnacted
- `Trio/Sources/APS/OpenAPS/OpenAPS.swift`: 40-102 processDetermination and swallowed save; 135-140, 186-232 orphaned resumes; 235-369 determineBasal (323-327 DynISF off; 348-368 store or throw)
- `Trio/Sources/APS/Storage/DeterminationStorage.swift`: 28-46
- `Model/Helper/NSPredicates.swift`: 87-90, 102-105
- `Model/Helper/PumpEvent+helper.swift`: 88-91, 112-118
- `Trio/Sources/APS/OpenAPSSwift/DetermineBasal/DetermineBasalGenerator.swift`: 60-100, 585-720
- `Trio/Sources/APS/OpenAPSSwift/DetermineBasal/DetermineBasal+Helpers.swift`: 190-210
- `Trio/Sources/APS/OpenAPSSwift/DetermineBasal/DosingEngine.swift`: 299-305, 481-497, 637-648, 698-730, 739-850
- `Trio/Sources/Services/BolusSafety/BolusSafetyValidator.swift`: 1-105
- `Trio/Sources/Services/RemoteControl/TrioRemoteControl.swift`: 18, 52-69; `TrioRemoteControl+Bolus.swift`: 5-60
- `Trio/Sources/Shortcuts/Bolus/BolusIntentRequest.swift`: 16, 26
- `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`: 626-672, 811-822, 932-941
- `Trio Watch App Extension/WatchState.swift`: 75, 170-215; `WatchState+Requests.swift`: 136-150; `Helper/WatchNotificationHandler.swift`: 55-64; `Trio Watch App/Info.plist`
- `Trio/Sources/APS/DeviceDataManager.swift`: 59-125, 211, 287-329, 378-392, 446-458, 562-643, 649-657
- `Trio/Sources/APS/Storage/PumpHistoryStorage.swift`: 63-224
- `Trio/Sources/APS/Storage/GlucoseStorage.swift`: 45, 346-425
- `Trio/Sources/APS/FetchGlucoseManager.swift`: 302-369
- `Trio/Sources/Helpers/PropertyWrappers/PersistedProperty.swift`: 52-115
- `Trio/Sources/Services/Alerts/NotLoopingMonitor.swift`: 8, 33, 82-130
- `Trio/Sources/Models/DosingMode.swift`: 4-36
- `Trio/Sources/Config/Config.swift`: 7
- `Model/CoreDataStack.swift`: 44, 107, 111, 240-279

LoopKit `babddf04`:
- `LoopKit/DeviceManager/PumpManager.swift`: 66-72 (lastReconciliation contract), 80-90, 200-235
- `LoopKit/DeviceManager/PumpManagerError.swift`: 10-25
- `LoopKit/DeviceManager/PumpManagerStatus.swift`: 91
- `LoopKit/WeakSynchronizedDelegate.swift`: 46-56

OmnipodKit `6fdf0e0`:
- `OmnipodKit/PumpManager/PodCommsSession.swift`: 29-34, 306-418, 485-509, 648-704, 1086-1100
- `OmnipodKit/PumpManager/PodState.swift`: 119-134, 239-272, 643-683
- `OmnipodKit/PumpManager/OmniPumpManager.swift`: 297-300, 597, 2681-2706, 2722-2799, 2874-2966, 3061-3070, 3435-3445
- `OmnipodKit/PumpManager/OmniPumpManagerState.swift`: 426-430
- `OmnipodKit/Bluetooth/BleMessageTransport.swift`: 15-35
- `OmnipodKit/Bluetooth/BlePodComms.swift`: 297, 343, 826-835
- `OmnipodKit/OmnipodCommon/MessageBlocks/StatusResponse.swift`: 15-21

DanaKit `787a639`: `DanaKit/PumpManager/DanaKitPumpManager.swift`: 1685-1705
MedtrumKit `eee17b0`: `MedtrumKit/PumpManager/MedtrumPumpManager.swift`: 1205-1240

External (not fetched, [U]): Apple WatchConnectivity and Core Bluetooth on watchOS documentation. Deferred to Agent D.
