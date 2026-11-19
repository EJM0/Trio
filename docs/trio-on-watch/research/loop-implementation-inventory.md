# Loop "Sport Mode": inventory of the Loop/LoopKit work on running the loop on Apple Watch

Research for Trio on Watch, phase 1 (read-only). Agent B. Research date 2026-11-15.
Contributor-facing; not user-facing and not medical advice.

## Executive summary

- The work exists, is public, and is called **Sport Mode**. Author: Jeremy Barnum (GitHub `jeremybarnum`). Pete Schwamb (GitHub `ps2`, LoopKit maintainer) reviews, lands, and wrote the stand-alone "G7 direct to watch" piece. The main PR is LoopKit/Loop#2545 (open, draft, base `next-dev`, head `jeremybarnum:sportmode/next-dev` @ `5aeb4703`, +30,359/-273, 153 files).
- Model: the **phone lends the Omnipod to the watch**. During a "loan" the watch runs Loop's own loop cycle (LoopAlgorithm, compiled for watchOS) on its own LoopKit stores, reads the G7 itself, and doses. The phone stays the home of the data and can take the pod back. Off by default behind `SPORT_MODE_ENABLED`.
- Authority is explicit and single-holder. A written control document (`Documentation/SportMode/Control.md`, 27 situations, one code case and one test each) decides who holds the pod. Its first rule is "insulin is conserved": no device doses closed loop until every unit the pod delivered is in its records or booked conservatively as a bolus, checked against the pod's delivered-units total ("odometer").
- Background execution: **no workout session and no extended runtime session in the current code.** The watch is woken by the G7's Bluetooth link every 5 minutes (a daemon-held pending connect plus `bluetooth-central` background mode, CoreBluetooth state restoration, `WKBluetoothAlertRefreshBackgroundTask`). A reading starts the loop cycle; the pod is connected inside that wake. An `HKWorkoutSession` keepalive was used July to October 2026 and then removed after field and bench tests.
- Hardware scope: **Omnipod (DASH tested; OmnipodKit identifier `Omni`) and Dexcom G7 only.** No Tandem, Medtrum or Dana watch work found. 32-bit watches needed Int64 fixes.
- Status: LoopKit protocols (LoopKit#626, #673, #687), G7 on watch (G7SensorKit#80, Loop#2605), the LoopCore loop-cycle refactor (Loop#2645) are **merged** into LoopKit `next-dev`. The Sport Mode engine (Loop#2545), the OmnipodKit hand-off (loopandlearn/OmnipodKit#177), failed-pod deactivation (LoopKit#686), watch uploads, push notice and run-time plugin loading are **open**. Tested in-vitro with emulated pod and G7 in paired Simulators, plus real-hardware runs (real DASH and G7) by the author and one tester, who found open bugs.
- Trio relevance: Trio's pinned LoopKit and G7SensorKit already carry the merged pieces (verified). Trio's pinned OmnipodKit does not carry the hand-off. The control rules and the odometer audit are algorithm-agnostic and transferable as design. The loop cycle, stores, record protocol and services are coupled to Loop and LoopAlgorithm and would need a Trio/oref re-implementation.

## Scope, method, evidence conventions

- Sources: GitHub via read-only `gh` (PR bodies, comments, reviews, branches, commits), and clones of `jeremybarnum/Loop` (branches `sportmode/*`, `original-SportMode-fromscratch`, `sportmode/bench`), `LoopKit/LoopKit` `next-dev` @ `e6b922d7`, `LoopKit/G7SensorKit` `next-dev` @ `8882a64c`, `jeremybarnum/OmnipodKit` `sportmode/next-dev` @ `e8216cd0` (= head of loopandlearn/OmnipodKit#177). Trio pins checked in `/Users/dnzxy/workspaces/Trio-on-watch` @ `ad6c66876`.
- Web search, LoopDocs and LoopKit issue search found **no** Sport Mode documentation, forum post or talk outside GitHub. LoopDocs has nothing on it (code search on LoopKit/loopdocs: 0 hits). If Zulip discussion exists, I could not reach it.
- Tags: **Verified** = I read the code, PR text or commit. **Inferred** = my reading, not stated. **Unverified** = claimed by a source, not checked by me (for example field results reported in PR comments).
- Classification per item: implemented and demonstrated / experimental / hardware-specific / watchOS-version-specific / theoretical.
- Abbreviations: "Loop" = LoopKit/Loop app; "SM" = Sport Mode; "#2545" without repo = LoopKit/Loop#2545; "branch head" = `jeremybarnum/Loop@5aeb4703`.

## 1. People, repos, branches

| Item | Finding | Tag |
|---|---|---|
| Jeremy Barnum | GitHub `jeremybarnum` (account since 2017; profile name empty). Commits on the SM branch carry author name "Jeremy Barnum". Author of #2545 and its stack. | Verified (`gh api users/jeremybarnum`, `git log` on branch head) |
| Pete Schwamb | GitHub `ps2`, profile name "Pete Schwamb". Wrote Loop#2605 (G7 on watch), LoopKit#673, the first carry of SM (LoopKit#612, G7SensorKit#65, RileyLinkKit#18, all superseded), OmnipodKit Int64 SQN fix (loopandlearn/OmnipodKit#205), reviews #2545 and #177. | Verified |
| Other contributors | `EJM0` (G7 acquisition fixes credited in G7SensorKit#80; Trio port attempts), `kristinkand` (G7 fixes credited; separate Trio untethered fork, findings on #177), `marionbarker` (real-hardware testing on #2545). | Verified |
| Main code | `jeremybarnum/Loop` branch `sportmode/next-dev` (= #2545 head). Stacked: `sportmode/watch-uploads` (#2554, #2555), `sportmode/push-notice` (#2624), `sportmode/watch-plugins` (#2655), `sportmode/next-dev-complications-v2` (#2563). | Verified |
| Integration branch | `jeremybarnum/LoopWorkspace` `next-dev-SportMode-PRs`: "holds every open Sport Mode pull request together". `SportMode-bench` is the author's day-to-day build. | Verified (sportmode-sim README) |
| Kit branches | `jeremybarnum/LoopKit` `sportmode/next-dev`, `sportmode/failed-device`, `sportmode/watch-plugins`, `sportmode/watch-uploads`; `jeremybarnum/OmnipodKit` `sportmode/next-dev`; `jeremybarnum/G7SensorKit` `sportmode/next-dev`, `sportmode/watch-plugins`; `NightscoutService`/`TidepoolService` `sportmode/watch-uploads`. | Verified (`gh api .../branches`) |
| Test harness | `jeremybarnum/sportmode-sim`: paired iPhone and Watch Simulators, simulated pod (`jeremybarnum/pod` `delivery-over-time`), G7 emulator (`jeremybarnum/g7sim` `multi-app`), `ImpossiBLE` Bluetooth shim, scripted tests (`TESTS.md`). | Verified (README) |
| History | `original-SportMode-fromscratch` (last commit 2026-07-18): first design with a vendored G7 client, `WorkoutKeepalive.swift` and `WatchAutoLoop.swift`. Superseded. | Verified |
| AI tooling | Many recent PR bodies end with "Generated with Claude Code" and branch commits carry Claude co-author trailers. Relevant to Trio's CONTRIBUTING policy if code is reused. | Verified |

### PR map

| PR | What | State (2026-11-15) |
|---|---|---|
| LoopKit/Loop#2545 | SM engine: loan protocol, phone lends, watch borrows, UI | open, draft |
| LoopKit/Loop#2645 | Loop types and `LoopCycle` moved into LoopCore (no behavior change) | merged 2026-11-03 |
| LoopKit/LoopKit#626 | Hand-off protocols: `SharedDeviceConfiguration`, `DeviceConfigurationSharing`, `ExclusiveDeviceControl`, `PumpDeliveryOdometer`, `localizedInoperableDescription` | merged 2026-10-24 |
| LoopKit/LoopKit#686 | Failed-device deactivation on holder, `deliveredUnitsAreFinal` | open |
| LoopKit/LoopKit#687 | UI-free plugin protocols, `DirectReadCGMManager` | merged 2026-11-10 |
| LoopKit/LoopKit#673 (ps2) | `CGMManagerDelegate.supportsWatchDirectRead` (default false) | merged 2026-10-31 |
| LoopKit/G7SensorKit#80 | G7 watchOS target, watch acquisition, hand-off, fast J-PAKE, "Read on Apple Watch" toggle | merged 2026-10-24 |
| LoopKit/G7SensorKit#110 | Watch loads G7SensorKit at run time | open |
| LoopKit/Loop#2605 (ps2) | Stock watch app reads the G7 directly (no dosing) | merged 2026-10-24 |
| LoopKit/Loop#2660 | Watch crash fix: finish every background task in a wake | merged 2026-11-08 |
| loopandlearn/OmnipodKit#177 | OmnipodKit watchOS target, hand-off, take/release, unconfirmed-command rule | open |
| loopandlearn/OmnipodKit#205 (ps2) | EAP and nonce SQN as Int64 for 32-bit watches | merged 2026-10-31 |
| LoopKit/RileyLinkKit#21 | watchOS framework targets | merged |
| LoopKit/Loop#2554, #2555; LoopKit/LoopKit#631; NightscoutService#33; TidepoolService#40 | Nightscout and Tidepool uploads from the watch during a loan | open |
| LoopKit/Loop#2624 | Watch tells the phone of an offline start by APNs push | open |
| LoopKit/Loop#2655 | Watch loads device kits at run time (plugins) | open |
| LoopKit/Loop#2562, #2563 | WidgetKit complications, "Loop Glance" complication | open |

## 2. Architecture as built

### 2.1 Untethered operation and its trigger

- A loan is entered only by a tap on the watch. Normal Start (phone near): the phone releases the pump and sends a **grant**; the watch builds its own pump manager from the export. Offline Start: if the phone does not answer within the wait, the watch offers "Start without it?" and starts from a **standing copy** of the grant the phone refreshes in the background. (Verified: #2545 body; Control.md rows 1-2; commit `9ebbaf5f` sets the waits to 6 s for "request received", then 20 s for the grant.)
- Principle 6: the watch never takes the pod from a dead or absent phone by itself, because it cannot tell a dead phone from one left at home. It warns instead ("Not Hearing From iPhone" after 25 min). (Verified: Control.md row 3; `LoanControl.notHearingFromPhoneWarning = 25*60`, `LoopCore/PodLoan/LoanControl.swift:239` @ branch head.)
- Classification: **implemented and demonstrated** (Simulator suite; real DASH and G7 runs reported by author and tester, Unverified by me).

### 2.2 Where the algorithm runs

- `LoopCycle` in LoopCore is "one cycle of the dosing loop, as both apps run it". The phone's `LoopDataManager` runs it; the watch's `WatchLoopManager` runs it while it holds the pump. (Verified: `LoopCore/Managers/LoopCycle.swift` header @ LoopKit/Loop `next-dev`; `WatchApp Extension/StockLoop/WatchLoopManager+Cycle.swift:44-53` @ branch head.)
- LoopAlgorithm declares `.watchOS(.v8)` in `Package.swift` (Verified, `LoopKit/LoopAlgorithm` default branch). The watch imports it directly (`WatchLoopManager+Cycle.swift:12`).
- Same settings as the phone, carried in the grant: therapy settings, dosing strategy, algorithm experiments (integral RC, glucose-based partial application, guard + runway with the phone's volatility baseline, slow RC), 24 h of overrides and settings history (84 h with slow RC), glucose for momentum (72 h with slow RC). About 30 KB compressed with 72 h. (Verified: `LoopCore/PodLoan/LoanMessages.swift:142-191`; #2545 body.)
- Commit `1d7283ea` moves the algorithm run off the caller's actor; `ed652e6a` stops a debug build if the algorithm starts on the main thread (Verified, commit messages).
- Classification: **implemented and demonstrated**. Coupled to LoopAlgorithm.

### 2.3 Pump connectivity

- Only OmnipodKit: `watchPumpManagersByIdentifier = ["Omni": OmniPumpManager.self]` (Verified: `WatchApp Extension/StockLoop/WatchPumpManagers.swift:16-18`). #2655 replaces the table with run-time plugin loading (open).
- Pod types: DASH tested by author and tester (Unverified results). Omnipod 5: no Loop-side evidence of testing; kristinkand reports O5 sessions on her own fork (comment on #177, Unverified). Treat O5 as **untested in Loop's line**.
- Tandem, Medtrum, Dana: **no watchOS hand-off work found** in any of the listed repos or branches. A tester mentions a TandemKit build on the phone (not SM). Classification: **theoretical** for non-Omnipod pumps.
- Mechanics in OmnipodKit#177 (Verified: PR body; code at `jeremybarnum/OmnipodKit@e8216cd0`):
  - `OmniPumpManager` implements `ExclusiveDeviceControl` and `PumpDeliveryOdometer`. No session keys or pending command are exported; a fresh EAP handshake is required on the new controller.
  - `takeControl()` connects by this device's handle, or searches by the pod ID in its advertisement on first contact ("on a watch, that first contact needs the wrist up for a couple of seconds"). After 12 s without an answer it scans by address (`takeEscalateAfter`).
  - `releaseControl()` waits up to 20 s for a command under way and refuses while a command is **unconfirmed**; Loop then refuses Start/End ("The pod hasn't confirmed the last command yet").
  - After an EAP SQN resync that shows another controller ran the pod, a pending command is settled as unresolvable (nothing booked) and the odometer check books any excess (ps2 suggestion 2026-10-26, implemented per author).
- The watch connects to the pod per cycle and lets go; the phone holds a long-lived connection. Two devices that both believe they hold the pod fail the pod's single-session handshake. (Verified: Control.md section 1.)
- Classification: **hardware-specific** (Omnipod BLE), **experimental** (#177 not merged; its PR says "not yet tested on real hardware in this round").

### 2.4 CGM connectivity (Dexcom G7 direct to watch)

- With "Read on Apple Watch" on in G7 settings (default off), the phone puts the G7's `SharedDeviceConfiguration` (sensor identity, pairing code) in the watch context. The watch builds its own `G7CGMManager` in the **watch display slot**, persists it, and stores readings beside the phone's with the same sync identifier. (Verified: `WatchApp Extension/Managers/WatchCGMHost.swift` @ LoopKit/Loop `next-dev`; Loop#2605; G7SensorKit#80.)
- SM requires it: Start is refused, naming the setting, when it is off (Verified: Control.md row 1).
- Watch acquisition (`G7SensorKit/G7CGMManager/G7WatchAcquisition.swift` @ `8882a64c`, Verified): one daemon-held connect request per burst; process held 35 s past link-up so the next connect never lands in the sensor's ~20-26 s advertising tail; bootstrap scan after 3 missed bursts. Rationale in the file and in G7SensorKit#80: connects into the tail fail (bluetoothd reason 762), and watchOS then restricts connects to strong signal (about -70 dBm), "which on a wrist usually means never". `CBConnectPeripheralOptionStartDelayKey` "doesn't seem to work on the watch".
- Pairing math sped up from 145 ms to 2.5 ms per scalar multiply, because the sensor drops a key exchange after about 4 s (Verified: G7SensorKit#65/#80 text).
- Known limit: the watch slot is the one Dexcom's own watch app uses; both together are "not expected to work" (untested) (Verified: #2545 Known limitations).
- Field reports: readings missed for 10-20 min when the watch is on the opposite arm to the sensor or arms are still; better on the same side (marionbarker comments on #2545, Unverified). G7 sensor change during a loan: the loan had to be ended to pair the new sensor on the phone (same source).
- Classification: **implemented and demonstrated** (merged, tested on Series 9 with phone Bluetooth off per #2605/#80), **hardware-specific** (G7 only).

### 2.5 WatchConnectivity and the loan protocol

- Message kinds live in `LoopCore/PodLoan/LoanMessages.swift` (Verified): request (with the highest loan number the watch knows), "request received", grant (epoch, pump config as binary plist, settings and history), standing copy, record batch ("sent every cycle, empty or not, as a liveness signal"), hand-back offer (interim or released, resent until acked), status report ("holds pod", "reached the pod on last cycle", loan start time), stop/revoke, query and answer.
- Transport (`WatchApp Extension/StockLoop/StockLoopSession.swift:51-95`, Verified): `sendMessage` when reachable and urgent; `transferUserInfo` otherwise; handshake messages ride both channels. A newer queued hand-back offer or record batch cancels older queued copies. Messages before `WCSession` activation are held. The loan history goes home as one `transferFile` at close.
- Explicit platform constraint stated by the author: WatchConnectivity works over Bluetooth and shared Wi-Fi, **not cellular** (Verified as a claim in #2545 body; Inferred consistent with Apple docs, not re-checked).
- Classification: **implemented and demonstrated**.

### 2.6 Persistence

- Watch opens its own LoopKit stores (dose, glucose, carb, dosing decision, dose metadata, alert, device log) plus override history with a 96 h window (Verified: `StockLoopStack.swift:44-58`).
- Loan state is one persisted value per side (`PersistedProperty`, plist), so either app can relaunch mid-loan (Verified: #2545 body; `LoopCore/PodLoan/PersistedProperty+Directory.swift`).
- Kit state: OmnipodKit persists `isControlReleased` and moves the per-pod BLE handle from `UserDefaults` into pump state, exposed as `localState` which the host saves per plugin (Verified: LoopKit `DeviceManager.swift` protocol docs; #177 body).
- A watch relaunched before first unlock opens stores late; messages are held and replayed; nothing doses meanwhile (Verified: Control.md section 8).
- LoopKit#612 records watch crash loops from HealthKit/Core Data zombie samples (nil `startDate`, deleted rows) and guards added for watchOS (Verified as PR text).
- Classification: **implemented and demonstrated**.

### 2.7 State sync and authority handoff

Authority model (Control.md section 2, Verified):
1. Insulin is conserved (never traded).
2. Nobody takes the pod from a device that is looping it.
3. Looping conservatively beats not looping.
4. When 2 and 3 conflict, known facts decide; if unknown, a query decides. Silence does not prove a watch stopped.
5. A device that was off queries before touching the pod; an inferred takeover is not undone when it returns.
6. Phone looping is the resting state; SM is entered only by a tap.
7. Tell the looper what happened.
"Control changes on evidence, never on a clock." The one clock exception is the resume limit (insulin action time, about 6 h).

Transfers (Control.md section 6, Verified):
- **Grant**: lease 60 s (`LoanControl.takeoverLease`); a Start the watch never confirms is taken back by the phone at its first cycle after the lease.
- **No transfer mid-bolus**, in either direction; refused with seconds left.
- **No transfer while a pod command is unconfirmed**.
- **No program crosses a transfer**: the taker cancels any running temp and doses at the next reading, to avoid a second cycle on the same reading (extra automatic bolus). Cost: a low temp can be lost for up to one reading.
- **Hand-back**: End on the watch; refused if the phone is away (the watch keeps looping and says how to stop dosing). Final offer unacked after a 2 min budget: watch lets go and tells the user ("End Not Confirmed").
- **Take-back** on the phone: reach the pod within 5 s, send stop, audit insulin; refused if the pod does not answer.
- Old vs new loan disambiguation (row 17 vs row 19) by comparing the watch's loan start (or earliest record) with the phone's takeover time.

Record sync (Verified: #2545 body; Control.md section 4; commits `7df12bf9`, `e00aba64`):
- The watch streams records (doses, carbs, carb deletions, overrides) every cycle; the phone stores finished doses as they arrive and holds a running temp until it ends. Records are resent until acked; the phone persists what it stored before acking. Carbs carry a fixed sync identifier so redelivery stores once.
- Phone during a loan: banner, actions and Settings disabled, forecast hidden (author: "any forecast would be fake"), its own glucose alerts and missed-meal detection paused.
- Behavior change mid-review: silent watch used to be taken back on silence; since `2885880b` / `0220a889` (2026-11-07/08) the phone only **tells** the user after 20 min of silence and leaves the take-back to a tap, after a tester saw the phone take control from a watch that was apparently looping (marionbarker comments 2026-11-07; author: "sounds like a bug").

Classification: **implemented and demonstrated** in Simulator; **experimental** on hardware (open bugs, see section 3).

### 2.8 Background execution

| Mechanism | Status in SM | Evidence |
|---|---|---|
| `bluetooth-central` in `UIBackgroundModes` of the watch app | used | `WatchApp/Info.plist:39-42` @ branch head (Verified) |
| CoreBluetooth state restoration (`CBCentralManagerOptionRestoreIdentifierKey`) on watchOS | used; "State restoration relaunches the app for each link" | `G7BluetoothManager.swift:267`, `G7WatchAcquisition.swift` header @ G7SensorKit `8882a64c` (Verified code; relaunch behavior Unverified by me) |
| `WKBluetoothAlertRefreshBackgroundTask` held up to 25 s through the reading | used | `ExtensionDelegate.swift:158-218` @ branch head (Verified) |
| `scheduleBackgroundRefresh` 60 s after each reading as acquisition backstop | used | `WatchCGMHost.swift:117-123` (Verified) |
| `WKWatchConnectivityRefreshBackgroundTask` | used for phone messages; completion bug fixed in #2660 (14 terminations in 2 days) | Verified |
| Loop cycle trigger | each new glucose reading calls `checkPumpDataAndLoop()`; pod is read via `ensureCurrentPumpData` then the cycle runs | `WatchLoopManager+Glucose.swift:34,69`, `+Cycle.swift:22-38` (Verified) |
| `HKWorkoutSession` keepalive | **removed**. Whole-loan session dropped 2026-09-30 ("field-proven 2026-09-15"); takeover/hand-back session removed 2026-10-14 ("bench runs with the watch face covered show both completing in the background ... the session cannot start for an app already in the background") | commits `26dcf103`, `034f33e3`, `e29added` (Verified messages); no `HKWorkoutSession` in branch head (Verified grep) |
| `WKExtendedRuntimeSession` | not used on any SM branch I grepped | Verified grep |
| Anything watchOS 11/26-specific | none found beyond the above. Testers ran watchOS 26.6 (Unverified). | Inferred |

Notes:
- The July 2026 `WorkoutKeepalive.swift` header claimed "no CoreBluetooth state restoration on watchOS". The later design relies on exactly that. Treat the old claim as superseded (Verified: both files read).
- Stale text: `Loop.xcconfig` comment and the sportmode-sim README still say the SM entitlements are for "the workout session". The entitlements file has HealthKit plus time-sensitive notifications; no code starts a workout. The #2545 body also says "unless it has a workout keepalive, which is a separate discussion". (Verified inconsistency.)
- The design premise (Control.md section 1): "A watch on the wrist is woken by the sensor every five minutes, so it always comes back within a cycle even if watchOS stops its app." The whole background story depends on the G7's BLE wake. A watch that misses readings sleeps and may not be woken for phone messages (row 10).
- Cellular in background: watchOS refused cellular to a backgrounded app's requests ("Interface type 'cellular' is prohibited", measured on watchOS 26.5), so watch uploads wait for foreground unless Wi-Fi or the phone link is available (Verified as claim in #2554; not re-measured).
- Classification: BLE-wake design **implemented and demonstrated**, **hardware-specific** (G7 cadence drives it), **watchOS-version-specific** in the sense that `WKBluetoothAlertRefreshBackgroundTask` is a newer WatchKit API (exact minimum version Unverified; Trio#1749 says LoopKit and G7SensorKit need watchOS 10.6).

### 2.9 Lifecycle and termination recovery

- Watch relaunch mid-loan: asks the phone whether the loan is still its own, shows "Checking with your iPhone...", builds nothing that can reach the pod until the check ends. Without an answer it carries on at its first reading at least 30 s later, reads the pod's odometer first and books what records cannot explain. Off longer than insulin action time: no resume, records go home, "Sport Mode Ended". (Verified: Control.md rows 12-13; `PodLoanWatchController+Resume.swift:63` compares against `InsulinMath.defaultInsulinActivityDuration`.)
- Phone relaunch: loan state persisted; `isControlReleased` persisted in the kit so a relaunch does not take the pod back (Verified: protocol doc). kristinkand reported a relaunched phone sending an SMB while the watch held the pod on her fork; the author points to `c491bf7f` ("the phone doses nothing while it asks the watch about insulin it cannot explain") (Verified commit exists; fix effectiveness Unverified).
- Background-task completion: every task finished or held, else watchOS kills the app (#2660, Verified).
- Classification: **implemented and demonstrated** (Simulator tests `WakeResumeTests`, `SeizeActivationTests`), real-hardware **experimental**.

### 2.10 Battery

- No systematic measurement found. One tester's anecdotes on #2545 (Unverified): an older watch flagged "Service Recommended" lost about a third of its charge over about 2.5 h including a 30 min workout app; an SE 3 lost about 10 points over about 3.5 h of loan; overnight mostly on loan ended at 57 % after about 20 h. Another tester app (LoopFollow) was running at the same time in one test.
- No battery-driven design decision found other than removing the workout keepalive.
- Classification: **theoretical / anecdotal**.

### 2.11 Error handling and alerts

- The watch raises Loop's glucose alarms (`GlucoseAlertManager` compiled into the watch), pod alerts and loop-failure alerts (`LoopStallWatchdog`, 20/40 min, 1 h, 2 h). (Verified file list; Control.md row 15.)
- **Watch alerts top out at time-sensitive**: "The watch has the time-sensitive entitlement, not Critical Alerts: that is its highest level." Critical alerts are mapped to time-sensitive. (Verified: `WatchAlertPresenter.swift:39-46`.) Focus modes can silence them if not allowed (Control.md section 4).
- Phone suppresses its own not-looping notifications during a known loan, because iOS mirrors them to the wrist. After an offline start it does not know yet, hence #2624 (silent APNs push from watch to phone; user-supplied APNs key; one attempt; push older than 10 min ignored; behind `SPORT_MODE_PUSH_ENABLED`).
- Faulted pod on watch: glance and alarm offer Deactivate Pod; SM ends; phone forgets the pod (rows 26-27; LoopKit#686 open).
- Logging: one `SportLog` line per event on the watch, `DiagnosticLog` on the phone.
- Classification: alerts **implemented and demonstrated**; push notice **experimental** (open, opt-in, needs user key).

### 2.12 Safety boundaries

| Boundary | Mechanism | Evidence | Tag |
|---|---|---|---|
| Insulin conservation | Pod odometer vs records at every take-over, hand-back and (on SM phones) every pod reading. Excess beyond 0.20 U is booked as a placeholder bolus "now" (conservative: IOB cannot be higher than a dose booked now); records later replace it. Shortfall raises "Insulin On Board May Be Overstated" but keeps the loop closed. | `PodLoanPhoneController+Ledger.swift:90-93` (`unexplainedInsulinBand = 0.20`); #2545 Safety | Verified code constant; behavior per text |
| Odometer granularity | "the pod knows how much it delivered but not when"; temps counted in whole pulses | `LoanReconciler.swift` header | Verified |
| Single holder | `ExclusiveDeviceControl`, Control.md rules 1-7, `LoanControl.decide` with one test per row (`LoopTests/LoanControlTests.swift`) | Verified file exists | Verified |
| No transfer mid-bolus or mid-unconfirmed command | refusals in Loop and OmnipodKit | Control.md section 6; #177 | Verified |
| Duplicate carbs | fixed sync identifiers, ack after persist, closed-loan records cannot add carbs, carb entry on wrist needs bolus-level confirmation | #2545 Safety | Verified as text |
| Phone dosing hold | phone holds dosing until audit runs after a take-back without records, and while it asks the watch about unexplained insulin | #2545; `c491bf7f` | Verified |
| Resume horizon | no watch resume after insulin action time | `+Resume.swift:63` | Verified |
| Not built | row 24 (Start, phone near, pod silent) is "not built": the watch reads silence and offers an offline start | Control.md | Verified |
| Known data issue | Apple Health missing insulin for loan periods, Nightscout/Tidepool totals disagree (tester, 2026-11-09); author: "likely to be a bug" | #2545 comments | Unverified, open |
| Known stale phone view | ps2 found the phone's IOB/COB/forecast ignored the watch's records until hand-back (IOB understated after a watch bolus); author says addressed by a refactor | #2545 comments 2026-10-26/28 | Verified review text; fix Unverified |

## 3. Status and maturity

- Merged upstream (LoopKit `next-dev`): protocols, G7 on watch, LoopCore cycle refactor, plugin protocols, background-task fix. These ship in Loop `next-dev` without SM (the stock watch app reads G7 itself). (Verified.)
- Open: the SM engine and everything that doses on the watch. Draft. "Install or update only when no loan is running. No migration from earlier Sport Mode builds." (Verified.)
- Testing claimed: Simulator end-to-end suite passes; LoopTests and WatchAppTests pass; real phone and watch with emulated pod and G7; earlier rounds with real DASH and G7; pod-fault flow on real phone and watch with emulator faults (Verified as claims; not run by me).
- Field issues reported in the last two weeks (Unverified, from tester comments): phone repeatedly taking control from a watch (led to the tell-not-take change); hand-off failing on 32-bit watches until the SQN Int64 fix; rapid back-and-forth transfer failing once; missing insulin in Apple Health for loan periods; loop status icons wrong on some watch screens and Live Activity.
- Overall classification: **experimental**, with a strong written design and a large test suite, single primary author, real-hardware exposure limited to a few people and a few weeks.

## 4. Transferability to Trio

Facts about Trio's baseline (Verified in `/Users/dnzxy/workspaces/Trio-on-watch` @ `ad6c66876`):
- `LoopKit` pin (`babddf04`, loopandlearn `trio-next-dev`) contains `DeviceConfigurationSharing`, `ExclusiveDeviceControl`, `PumpDeliveryOdometer` (`LoopKit/LoopKit/DeviceManager/DeviceManager.swift:101,127`, `PumpManager.swift:349`) and `supportsWatchDirectRead` (`CGMManager.swift:128`). It does **not** contain `PumpManagerPlugin` / `DirectReadCGMManager` (LoopKit#687).
- `G7SensorKit` pin (`08d48863`) has the `G7SensorKit-watchOS` target and `G7WatchAcquisition.swift`.
- `OmnipodKit` pin (`6fdf0e0e`, branch `session-handshake-and-key-decoding`) has **no** `ExclusiveDeviceControl`/`exportConfiguration`/`PumpDeliveryOdometer` conformance and no watchOS SDK target (grep: 0 hits). OmnipodKit#177 is still open.
- Trio PR nightscout/Trio#1749 (EJM0, open) ports G7 direct-to-watch into Trio's watch app, modelled on Loop's `WatchCGMHost`; it waits on LoopKit/G7SensorKit#119. Trio PR #1700 (EJM0, "Watch Loop 1/5", oref split into `OrefPipeline` phases) was closed 2026-10-30, unbuilt and untested per its own checklist.

| Piece | Transferable? | Why / what it costs |
|---|---|---|
| LoopKit hand-off protocols | **Yes, already present** | Algorithm-agnostic, no phone/watch naming. Trio gets them with the kit pin. |
| G7 direct read on watch (kit) | **Yes, already present**; host code needs porting (Trio#1749 does) | Kit-level. Host must declare `supportsWatchDirectRead`, run a `WatchCGMHost` equivalent, finish background tasks correctly (#2660 lesson). |
| BLE-wake background model | **Yes, as design** | Platform-level. Depends on a CGM that wakes the watch every 5 min; G7 only today. Without a direct-read CGM there is no wake source (Inferred). |
| OmnipodKit hand-off | **Yes, once #177 lands** in the fork Trio pins | Kit-level, but Trio's OmnipodKit pin is on a different branch; needs re-pin and review. |
| Control.md rules and decision table | **Yes, as design** | Written in device and looper terms, no LoopAlgorithm dependency. Strongest reusable artifact. Rows assume a single pod with a single BLE session (Omnipod-specific in places, e.g. row 24/25, unconfirmed-command handling). |
| Odometer audit and placeholder bolus | **Yes, as design**; needs Trio-side implementation | Conceptually independent of oref, but how oref treats a placeholder bolus in IOB and in SMB headroom must be checked against oref's IOB math (pump history, `iob` calc) rather than assumed. |
| `LoopCycle` / loop on watch | **No (coupled)** | Built on LoopAlgorithm, LoopKit stores and Loop's `SettingsProvider`. Trio would need oref (OpenAPSSwift, dev-only) on watchOS with its own inputs (profile, autosens, pump history, glucose, meal) and parity proof. Whether Trio's JS path could run on watchOS was not checked (JavaScriptCore availability on watchOS: Unverified). |
| Grant contents | **Partly** | The idea (export pump config, settings, enough history for the algorithm's lookback) transfers; the payload is Loop-specific (Loop settings, overrides, RC experiments). Trio needs its own: preferences, profiles, temp targets/overrides, autosens and TDD history windows. |
| Record streaming / ack / carb identity | **Partly** | Pattern transfers; implementation writes into LoopKit `DoseStore`/`CarbStore`. Trio's Core Data stores and pump-history model differ. |
| Nightscout/Tidepool from the watch | **No (coupled)** | Uses LoopKit `RemoteDataServicesManager` + NightscoutService; Trio uploads through its own Nightscout code. |
| APNs push notice (#2624) | **Maybe** | Platform pattern; needs a user APNs key; Trio's remote-command push setup is a different code path (not checked). |
| Phone UI gating, banner, suppressed alerts | **Yes, as design** | Trio-specific UI work. |
| Watch alerts | **Caution** | Loop's watch tops out at time-sensitive; Trio#1749 adds a watch Critical Alerts switch. Which is right on watchOS is a platform question for Agent(s) covering watchOS, not settled here. |

What is clearly needed vs speculative (YAGNI lens, Inferred):
- Needed for any untethered Trio: single-holder authority, odometer audit, no-transfer-mid-bolus/unconfirmed-command, BLE-wake cycle driven by a direct CGM, oref on watchOS with parity, persisted loan state, relaunch-with-query.
- Speculative for a first cut: watch-side Nightscout/Tidepool uploads, APNs push notice, run-time plugin loading, complications, carb deletion on wrist, slow-RC-sized history windows (Loop-specific).

## Open questions

1. Will LoopKit/Loop#2545 land in Loop `next-dev`, and in what shape? ps2 is actively reviewing; no merge signal yet.
2. Does `WKBluetoothAlertRefreshBackgroundTask` plus state restoration hold up across watchOS releases and watch models? Evidence is a few watches over weeks. Minimum watchOS version not verified.
3. Omnipod 5 on the watch in Loop's line: untested. Non-Omnipod pumps: no work found.
4. The insulin-record discrepancy (Apple Health, Nightscout, Tidepool) reported 2026-11-09: cause and fix unknown.
5. How would oref's IOB, SMB limits and autosens treat an odometer placeholder bolus? Needs analysis against Trio's OpenAPSSwift, not assumption.
6. Can oref (Swift) run inside a 25 s Bluetooth wake on older 32-bit watches, alongside a pod exchange? Loop does not publish cycle timings on watch.
7. Is the HealthKit entitlement in `SportMode.entitlements` still required now that the workout session is gone? Docs and code disagree.
8. Critical alerts on watchOS: Loop chose time-sensitive only; Trio#1749 adds a critical toggle. Which is correct and entitled?
9. Any Zulip or private discussion with design decisions not in PRs: not found; ask ps2 / jeremybarnum if needed.

## Evidence index

PRs (all fetched 2026-11-15 via `gh pr view`):
- https://github.com/LoopKit/Loop/pull/2545 (head `5aeb470345d7e652f1a84712f0271a91857db5ed`)
- https://github.com/LoopKit/Loop/pull/2645
- https://github.com/LoopKit/Loop/pull/2605
- https://github.com/LoopKit/Loop/pull/2660
- https://github.com/LoopKit/Loop/pull/2655
- https://github.com/LoopKit/Loop/pull/2624
- https://github.com/LoopKit/Loop/pull/2554, https://github.com/LoopKit/Loop/pull/2555, https://github.com/LoopKit/Loop/pull/2562, https://github.com/LoopKit/Loop/pull/2563
- https://github.com/LoopKit/LoopKit/pull/626, https://github.com/LoopKit/LoopKit/pull/612, https://github.com/LoopKit/LoopKit/pull/631, https://github.com/LoopKit/LoopKit/pull/673, https://github.com/LoopKit/LoopKit/pull/686, https://github.com/LoopKit/LoopKit/pull/687
- https://github.com/LoopKit/G7SensorKit/pull/80, https://github.com/LoopKit/G7SensorKit/pull/65, https://github.com/LoopKit/G7SensorKit/pull/110, https://github.com/LoopKit/G7SensorKit/pull/119
- https://github.com/LoopKit/RileyLinkKit/pull/21, https://github.com/LoopKit/RileyLinkKit/pull/18
- https://github.com/loopandlearn/OmnipodKit/pull/177 (head `e8216cd0601c6fe6edfcc58e6a14fdce5d99baaf`), https://github.com/loopandlearn/OmnipodKit/pull/205
- https://github.com/nightscout/Trio/pull/1700, https://github.com/nightscout/Trio/pull/1749

Code (read in clones under the agent scratch dir):
- `jeremybarnum/Loop@5aeb4703`: `Documentation/SportMode/Control.md`; `LoopCore/PodLoan/LoanControl.swift:224-239`; `LoopCore/PodLoan/LoanMessages.swift`; `Loop/Managers/PodLoanPhoneController+Ledger.swift:90-93`; `Loop/Managers/LoanReconciler.swift`; `WatchApp/Info.plist:39-42`; `Loop.xcconfig` (LOOP_WATCH_ENTITLEMENTS); `WatchApp Extension/SportMode.entitlements`; `WatchApp Extension/ExtensionDelegate.swift:140-245`; `WatchApp Extension/StockLoop/StockLoopSession.swift`, `StockLoopStack.swift`, `WatchLoopManager+Cycle.swift`, `WatchPumpManagers.swift`, `WatchAlertPresenter.swift:39-46`, `PodLoanWatchController+Resume.swift:63`, `PodLoanWatchController+Handback.swift:535-548`; `WatchApp Extension/Managers/WatchDeviceManagers.swift`.
- `LoopKit/Loop@next-dev` (`dcd578df`): `WatchApp Extension/Managers/WatchCGMHost.swift`; `LoopCore/Managers/LoopCycle.swift`.
- `jeremybarnum/Loop` history: `original-SportMode-fromscratch@c6c9e18f` `WatchApp Extension/G7/WorkoutKeepalive.swift`; commits `1964ed01`, `7756ea22`, `26dcf103`, `1c8ec7c2`, `034f33e3`, `e29added`, `2885880b`, `0220a889`, `c491bf7f`, `1d7283ea`, `ed652e6a`, `9ebbaf5f`, `4f9afd26`.
- `LoopKit/LoopKit@e6b922d7`: `LoopKit/DeviceManager/DeviceManager.swift:62-150`; `LoopKit/DeviceManager/PumpManager.swift:353-367`.
- `LoopKit/G7SensorKit@8882a64c`: `G7SensorKit/G7CGMManager/G7WatchAcquisition.swift`; `G7BluetoothManager.swift:254-267, 650`.
- `LoopKit/LoopAlgorithm` default branch `Package.swift` (platforms include `.watchOS(.v8)`).
- `jeremybarnum/sportmode-sim` README; `jeremybarnum/LoopWorkspace@next-dev-SportMode-PRs` `.gitmodules`.
- Trio baseline `/Users/dnzxy/workspaces/Trio-on-watch@ad6c66876`: `.gitmodules`; `git submodule status`; `LoopKit/LoopKit/DeviceManager/DeviceManager.swift:101,127`; `PumpManager.swift:349`; `CGMManager.swift:128`; `G7SensorKit/G7SensorKit/G7CGMManager/G7WatchAcquisition.swift`; OmnipodKit grep (no hand-off conformance).

Searches with no result: web search for Loop "Sport Mode" Apple Watch; `gh search code "Sport Mode" --repo LoopKit/loopdocs`; `gh search issues "Sport Mode" --owner LoopKit` (non-PR); grep for `HKWorkoutSession`/`WKExtendedRuntimeSession` on SM branches (only `original-SportMode-fromscratch` has a workout session).
