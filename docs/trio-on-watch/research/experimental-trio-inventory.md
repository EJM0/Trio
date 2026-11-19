# Experimental untethered-watch branch: Trio-side inventory

Agent A1, research fleet, phase 1 (read-only). Scope: the Trio repository changes on `kristinkand/feature/untethered-watch-mode` @ `a56170dc0`, diffed against its merge base with `nightscout/dev`, `3f6b238b4` (dev 1.0.2.71). Kit submodule forks (LoopKit, G7SensorKit, OmnipodKit) are out of scope (Agent A2) except where Trio code depends on them.

Evidence markers: **[V]** Verified (I read the code or the GitHub data), **[I]** Inferred, **[U]** Unverified. File:line references are at `a56170dc0` unless stated otherwise. I did not build or run anything. My attempt to run the algorithm-package tests on a scratch copy was blocked by the sandbox. Test results quoted below come from the fork's GitHub check runs.

## Executive summary

1. The branch implements the whole loop on the watch, end to end. The phone hands over an Omnipod (DASH, via `OmniPumpManager`) and a Dexcom G7 through LoopKit's `ExclusiveDeviceControl` / `DeviceConfigurationSharing` exports. The watch then runs oref through the shared `OrefPipeline`, enacts temp basals and SMBs, takes manual and remote boluses, persists 24 h of history to a JSON file, and syncs it back with checksummed buckets. [V]
2. Authority is an explicit two-sided state machine (`UntetheredSession`, pure, unit tested). It uses epochs, a lease, a prepare/commit takeover and an acknowledged two-phase hand-back. The phone's dosing is blocked by a file-backed `UntetheredGate.phoneMayDose`. This core is the best part of the branch and worth keeping as a concept. [V]
3. "Exactly one device commands the pod" (the docs' claim) is not guaranteed by Trio code. The phone takes the pod back on timeout, and the watch "looks" at the pod during fallback. Both paths depend on a kit-level foreign-session refusal. A comment in the branch records a tester incident where phone and watch "both dosed it in turn" (`UntetheredWatchManager.swift:665-669`). [V]
4. Dosing guards on the watch: oref's own limits (max IOB, max basal, SMB minutes, `clamped(for: dosingMode)`) and the 3-readings / 12-minute stale-glucose check are kept [V]. Manual boluses are silently clamped to max bolus [V]. Remote boluses get BolusSafetyEvaluator-style checks [V]. There is no uncertain-delivery handling on the watch path [V for absence in Trio code]. The phone's glucose alarms are suppressed while the watch holds the pump [V].
5. Background execution relies on Bluetooth wakes (`bluetooth-central`), `performExpiringActivity` holds and a 7-minute background-refresh backstop. As options it adds an HKWorkoutSession keep-alive ("Extended Untethered Mode", off by default) and a self-care `WKExtendedRuntimeSession` for G7 pairing. Code comments document pod-link stalls of 26 to 311 minutes in testing. [V]
6. An optional automatic start ("Start by Itself When iPhone Stops", off by default) takes over the pod from a standing grant up to 60 min old. It decides from heuristics: phone silence of 14.5 min or more, 3 own readings, and two pod "looks" at least 4 min apart. It then leaks complexity into the phone's ordinary bolus path (an automatic retry of refused manual boluses). It should not be carried forward. [V]
7. Volume and shape: +29.7k lines. Most of it is two watch files (`UntetheredWatchManager*.swift`, 5.4k lines), a 2.3k-line phone manager, and 4.7k lines of G7SensorKit sources copied into the watch app target next to the linked G7SensorKit framework (two G7 stacks on one watch). Code comments are dense with dated tester anecdotes and AI-review provenance ("Ponytail's review", "Claude Fable's review", 30 lines). 318 of 382 commits carry a Claude co-author trailer. [V]
8. Upstream overlap: #1616 (meal-time reminder) is merged in whole (37/37 commits are ancestors). #1598, #1749, #1762 and #1700 are not ancestors. #1700's `OrefPipeline`/`TDDCalculator`/`BolusCalculator`/`GlucoseSmoothing` extraction reappears re-authored. #1749's watch-CGM approach differs from the branch's. [V]

## 0. Provenance

### Commit authorship (3f6b238b4..a56170dc0, 382 commits, 61 merges) [V]

| Author (git) | Commits | What |
|---|---|---|
| kristinkand (two git identities) | 204 + 91 | Untethered core, fallback, G7Direct reader, phone integration, docs, merges of dev and #1616 |
| ETolboom | 37 | Meal-time reminder (nightscout/Trio#1616, open), unrelated to untethered |
| ejm0 / EJM0 (two git identities) | 18 + 1 | TDD sliding window, parity tests, foreign-session gating, Extended Untethered Mode (workout), history handback speed-up. 4 of these were committed by "Claude" (20 commits in the branch have committer "Claude": 12 Claude-authored, 4 ejm0, 4 kristinkand) |
| Claude | 18 | Authored directly: watch chart/UI tweaks, manual BG on watch, pod message logging, G7 rebond fix, Critical Alerts build fix, volume-button snooze (8600cb4ab, mostly not in the final diff) |
| t1dude | 2 | Watch alarm snooze page (#1576, already merged in dev, so its net diff is near zero) |
| Other merge identities, GH Action | 6 + 5 | Upstream sync merges |

318 commit messages carry `Co-Authored-By: Claude`, and 303 carry a `Claude-Session:` link. [V] The initial untethered commit `676993775` says "Based on [EJM0's] EJM0/Trio feat/direct-to-watch" (name redacted to the handle). [V]

### Relation to open upstream PRs [V]

| PR | Author | State | In branch? | Notes |
|---|---|---|---|---|
| #1616 Time-to-Eat Reminder | ETolboom | open | Yes, all 37 commits are ancestors (merged in by `b01989a46`, `a297bca61`) | Files: `MealTimeReminder*`, `LiveActivity/*MealTime*`, `TrioAlertManager`, `TrioModalAlertScheduler`, `SettingInputSection`, `BolusCalculatorConfig*`, `MultiUsePanelState*`, `AlertColdStartReplay*`, `Treatments*`. Not untethered. |
| #1598 Watch: fewer, better-timed state updates | EJM0 | open | No commits are ancestors | The branch has its own `WatchState`/`AppleWatchManager` changes. No bucket/checksum glucose sync from #1598 in `WatchState.swift`. |
| #1749 G7 Direct-to-Watch | EJM0 | open | No | Different design (`WatchCGMHost`, `WatchReadableCGM` protocol over the G7SensorKit framework). The branch instead copies G7SensorKit sources into `G7Direct/`. Shared names (`WatchDeviceManagers.swift`, `TrioWatchAppDelegate.swift`) diverge in content. |
| #1762 Unreliable G7 readings | kristinkand | open | No (`PluginSource.swift`, `CGMRootView.swift` untouched) | |
| #1700 Watch Loop 1/5 (closed 2026-10-30) | EJM0 | closed | Not as commits | Its `OrefPipeline`, `GlucoseSmoothing`, `TDDCalculator`, `BolusCalculator` extraction is re-done in `676993775`/`ef3a36c08`. Its `OrefPipelineTests` (old inline path vs phases) is **not** in the branch. |
| #1576 Watch alarm snooze page | t1dude | merged | Duplicate commits, already in dev | |

Unrelated scope bundled into the branch [V]: CI runner and Xcode selection changes (`build_trio.yml`, `create_certs.yml`, `validate_secrets.yml`), a Core Data retry after first unlock (`TrioApp.swift`), `CGMSensorHandover.dropOverlap` (new-sensor overlap filter, `FetchGlucoseManager.swift:566`), a `useCriticalAlerts` setting, a watch push-test path, logging-category renames in `CoreDataStack.swift`, and removal of `Determination.minPredBGFromReason` from the app helper (moved).

## 1. What is implemented end to end vs scaffolded

| Capability | Status | Evidence |
|---|---|---|
| Phone-to-watch hand-over of pod and G7 | Implemented. Grant (settings plus 24 h history plus device exports, LZFSE JSON, chunked at 48 kB) then prepare, prepared, commit, takeover read, takeoverComplete | `UntetheredMessage.swift:224-275, 332-452`; `UntetheredSession.swift:123-296`; `UntetheredPhoneManager.swift:1247-1382` [V] |
| Pump comms from the watch | Implemented for `OmniPumpManager` only (registry `"Omni"`); RileyLink pumps are refused | `WatchDeviceManagers.swift:18-24`; watch links `OmnipodKit`, `RileyLinkKit`, `RileyLinkBLEKit`, `LoopKit`, `G7SensorKit` frameworks (project.pbxproj) [V] |
| CGM on the watch | Implemented twice. (a) Untethered: `G7CGMManager` from the G7SensorKit framework, adopted from the phone's export. (b) Display-only `WatchG7Reader` built on 4.7k lines of G7SensorKit sources copied into the app target, which "stands aside" during sessions | `UntetheredWatchManager.swift:970-1051`, `G7Direct/README.md`, `UntetheredWatchManager.swift:228-239` [V] |
| Algorithm on the watch | Implemented: `UntetheredAlgorithm.determine` calls `ProfileGenerator`, `OrefPipeline.autosens/meal/iob/determineBasal`, with TDD and smoothing re-implemented from watch-side rows | `UntetheredAlgorithm.swift:26-99` [V] |
| Enactment | Temp basal then SMB, with re-checks of `mayDose`, background-time and bolus-state | `UntetheredWatchManager+Loop.swift:344-377` [V] |
| Manual bolus, carbs, overrides, temp targets, manual BG on watch | Implemented | `UntetheredWatchManager+Loop.swift:515-571, 998-1180` [V] |
| Remote commands (LoopFollow/Nightscout) | Implemented two ways: forwarded by the phone (`TrioRemoteControl.swift:73-91`), and APNs pushes straight to the watch, decrypted with the remote-control shared secret copied into the watch keychain | `TrioWatchAppDelegate.swift:29-63, 209-340, 507-535` [V] |
| Persistence on the watch | Implemented: one JSON file (`Application Support/untethered-watch.json`) rewritten atomically with `.completeFileProtectionUntilFirstUserAuthentication` on every `update` | `UntetheredStore.swift:153-240` [V] |
| History back to the phone | Implemented: versioned records, batches of 40, 4 in flight, 30-min FNV bucket checksums, phone-side `storeRun` into Core Data | `UntetheredRecord.swift`, `UntetheredWatchManager.swift:1627-1806`, `UntetheredPhoneManager.swift:1811-2215` [V] |
| Insulin audit after return | Implemented: pod odometer vs records, tolerance 0.2 U, unexplained insulin booked as a bolus "now". Also per-loop on the watch (`podTotalExplained`) | `UntetheredAudit.swift`; `UntetheredWatchManager+Loop.swift:757-807`; `UntetheredPhoneManager.swift:1412-1536` [V] |
| Start without phone (manual, off by default) | Implemented from a standing grant younger than the insulin action time | `UntetheredWatchManager.swift:1175-1300` [V] |
| Automatic start (fallback, off by default) | Implemented, heavily heuristic | `UntetheredWatchManager.swift:1945-2620` [V] |
| Watch Nightscout upload (off by default) | Implemented with SHA-1 of the API secret in the watch keychain | `WatchNightscoutUploader.swift` [V] |
| Watch alarms | Local `UNNotification`s: urgent low every 5 min, low 15 min, high 60 min, no readings, not looping | `UntetheredWatchManager+Loop.swift:2226-2384` [V] |
| Pod deactivation on watch | Implemented (`deactivateAndForgetPod`, `discardPod`) | `WatchDeviceManagers.swift:95-107` [V] |
| Tests | 110 Swift Testing cases across 5 files. The algorithm-package suite passed on fork CI at `410a63a6d` ("Algorithm package (swift test) success"). I ran none of them myself. | GitHub check runs on `kristinkand/Trio` [V] |

Dead or scaffolded code [V]:
- `WatchRemoteCommands` logs as "Push test", and the delegate still carries "push test" handling (`TrioWatchAppDelegate.swift:33-63`). The test path and the product path are mixed together.
- The docs list "RileyLinkKit: watchOS targets" as a required submodule change. The RileyLinkKit pin is unchanged against dev (`52a652c` on both sides) [V], and the dev pin already has watchOS settings [I].
- `untethered_unit_tests.yml` triggers only on fork branch names (`feature/untethered-*`). It would never run upstream [V].
- The branch carries `G7Direct/` code paths that a later commit deleted ("drop the Dexcom-app watch code path", `c29662035`). What is left is the direct reader only [V].

## 2. Architectural decisions

### Where the algorithm runs
- On the watch, in-process, on a detached `Task` (`UntetheredWatchManager+Loop.swift:106`). It uses the same oref Swift sources as the phone, compiled into the watch target and into `AlgorithmPackage` (`Package.swift:64-78`) [V].
- The phone's own algorithm orchestration was refactored to call the same `OrefPipeline` helpers (`OpenAPS.swift` +94/-230). TDD, smoothing and bolus-calculator arithmetic moved out of `TDDStorage`, `FetchGlucoseManager` and `BolusCalculationManager` into pure enums [V]. These are behavior-preserving refactors of phone dosing code. The branch has no test that compares the pre-refactor phone path with the new one (#1700's `OrefPipelineTests` is absent) [V]. The existing JS-parity goldens cover `OpenAPSSwift`, not the `OpenAPS` orchestration [I].
- Input construction is a re-implementation. `UntetheredAlgorithm` rebuilds pump-history rows the way `PumpHistoryStorage` + `PumpEventStored.toPumpHistoryEvents` would, including Double/Decimal rounding steps (`UntetheredAlgorithm.swift:163-257`). It also rebuilds ten-day TDD averages from hourly buckets (`UntetheredMessage.swift:287-321`) [V]. That is a second source of truth for algorithm inputs.

### Device ownership
- In a session the watch owns both the pod and the G7 watch display slot. The phone keeps reading the G7 on its own slot for display only (`preflight` comment, `UntetheredPhoneManager.swift:1221`) [V].
- Ownership is enforced at three layers. (1) Trio: `UntetheredGate.phoneMayDose` (file-backed, fails closed while locked) and watch `mayDose`. (2) Session epochs. (3) Kit: `releaseControl`/`takeControl`, `refusesForeignSessionsSince`/`lastForeignSessionAt` from the forked OmnipodKit/LoopKit [V for Trio call sites; kit behavior is A2's].

### Authority hand-over (state machine, `UntetheredSession.swift`)
- Start: phone `.preparing` (prepare re-sent for up to 90 s), watch `.prepared`, phone `.starting` (lease of 120 s from the watch's answer), effect `.commit` (phone waits up to 30 s for a loop in flight, cancels or hands over the temp, releases the pod, sends the commit with the deadline), watch `.takeover` (reads the pod every 8 s until the lease), then `takeoverComplete`. A late success releases [V, lines 125-131, 207-224, 328-345].
- Phone-side timeout: lease, then 10 s, then one `statusQuery`, then 3 min. After that the phone **takes the pump back without an answer** and marks `unknownWatchSince` (`UntetheredSession.swift:279-291`) [V]. The watch side releases at its own lease expiry (`:410-413`). Both rely on the clocks of phone and watch agreeing [V, comment at `:70-74`].
- Hand-back: `endRequest`, then the watch keeps looping while records drain (≤3 min), finalizes, cancels a low temp, reads the pod and offers `handback(status)`. The watch holds the pod until `handbackAck`, at most 60 s, then lets go and keeps offering. It never retakes (`:351-380`) [V]. The phone takes the pump and holds dosing (`pumpReturnPending`) until a pod read and the audit succeed. It retries forever while the pod runs its schedule (`UntetheredPhoneManager.swift:1450`) [V].
- Without phone: the watch starts with an epoch from its own clock (`max(epoch+1, now)`). The phone **stands aside on the watch's word** when it later sees a newer epoch (`.watchHoldsPump`, `:137-148`) [V].
- Emergency: phone `forceTakeBack` (revoke and take). Watch `emergencyStop` (cancel temp, read, release) [V].
- Session duration: `.active` has no lease or maximum duration on either side. Only the start-without-phone copy age is bounded [V].

### WatchConnectivity
- One key `untethered` carrying `UntetheredEnvelope{epoch, message, appVersion}`, LZFSE-compressed JSON, split into 48 kB parts for `sendMessage` (`UntetheredMessage.swift:332-452`) [V].
- Messages: 22 cases (prepare/prepared/rejected/commit, takeoverComplete/Failed, records/recordsStored/syncRequest/syncDone, endRequest/handback/handbackAck, revoke/released, statusQuery/statusReport, startRequest/startRefused, adjustmentCancelled, dosingModeChanged, standingGrant/standingGrantRequest, handbackRequested, remoteTreatment/Result, remoteAdjustment) [V].
- Delivery: interactive when reachable. Ownership-relevant messages (`records`, `released`, `statusReport`, `syncDone`, `takeoverComplete`, `takeoverFailed`) are also queued via `transferUserInfo` (`UntetheredWatchManager.swift:750-814`) [V].
- Build-equality check: hand-over is refused unless both apps report the same "version (build)" (`UntetheredVersion`, `UntetheredMessage.swift:364-420`) [V].
- About 46 new `WatchMessageKeys` for watch state. Among them: `remoteControlSecret`, Nightscout credentials, `g7DirectPairingCode`, `watchPushToken`, `phoneLastDoseDate`, `phoneOwnGlucoseDate`, `untetheredWake` [V].

### What is persisted on the watch
`UntetheredWatchData` (`UntetheredStore.swift:5-70`): the session, the grant (settings plus 24 h history), the handover, pump and CGM raw state as plists, 24 h of pump history (two shapes), glucose, smoothed values, carbs, temp targets, overrides, autosens, TDD rows and hours, last determination, the standing grant, pending pump alerts, and unsent or unconfirmed record versions per epoch. Every `store.update` re-encodes and rewrites the whole file [V]. Secrets live in the watch keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) [V]. Fallback bookkeeping lives in `UserDefaults` [V].

### Background execution
- Base mechanism: `UIBackgroundModes = bluetooth-central` in the watch Info.plist. Bluetooth wakes are held up to 25 s (`TrioWatchAppDelegate.swift:13-14, 90-116`), and each loop is held with `ProcessInfo.performExpiringActivity` (`holdProcess`, `UntetheredWatchManager+Loop.swift:1538-1600`). There is a 7-min `scheduleBackgroundRefresh` backstop (`UntetheredWatchManager.swift:1092-1100`) and WatchConnectivity background tasks (released after ≤10 s) [V]. Whether watchOS honours `UIBackgroundModes bluetooth-central` this way on current watchOS is [U] from this branch alone. The code's own comments describe frequent suspension mid-command and pod stalls (`UntetheredWatchManager.swift:1512-1516`, "stalls of 41, 80 and 26 minutes; 2026-10-21 from 00:45 to 05:56") [V for the comment text].
- Optional "Extended Untethered Mode": an `HKWorkoutSession` (activity `.other`, indoor), started only for an app in front, heart rate collected, workout discarded at the end (`UntetheredWatchManager+Loop.swift:2585-2760`). Needs `WKBackgroundModes workout-processing`, the HealthKit entitlement and phone-side `handleAuthorizationForExtension` (`AppDelegate.swift`) [V]. Using a workout as a keep-alive is a platform-policy risk [I].
- Sensor pairing: a `WKExtendedRuntimeSession` (`WKBackgroundModes self-care`, ≤10 min) keeps Trio in front so the Bluetooth pairing prompt can show (`:2548-2583`) [V].
- Loop trigger: only a new CGM reading (or a treatment, mode change, or pod-link recovery) runs a loop. A 5-min timer only rechecks acquisition and alarms (`UntetheredWatchManager.swift:717-724`) [V].

### Automatic start claims vs code
- Docs: the start happens "once the phone's newest reading is about 15 minutes old, the watch has read three of its own, and its looks at the pod over about 4 minutes found nobody using it. Once per outage." Code: silence > 14.5 min, ≥3 own readings, first look after 9.5 min, a second look ≥3 min later, chain span ≥4 min, copy ≤60 min old at the phone's last sign. **Up to 6 tries per outage** (`fallbackTries = 6`, `UntetheredWatchManager.swift:1994`). The once-per-outage limit applies only after a successful takeover [V]. The file header still says "about 10 minutes" (`:1950-1952`), which is stale [V].
- A pod "look" is a read with a manager built from the standing grant. To a phone that is still looping, it appears as a foreign session that makes the phone's next pod command fail ("Another controller has used this pod"). The phone then answers by querying the watch and holding its own dosing for up to 3 min (`UntetheredWatchManager.swift:45-47` comment; `UntetheredPhoneManager.swift:981-1003`) [V].

## 3. Reuse vs new abstractions

Reused well [V]:
- oref Swift (`ProfileGenerator`, `IobGenerator`, `MealGenerator`, `AutosensGenerator`, `DeterminationGenerator`) through `OrefPipeline`.
- LoopKit device managers with the SportMode-style protocols (`ExclusiveDeviceControl`, `DeviceConfigurationSharing`, `PumpDeliveryOdometer`) from LoopKit/Loop#2545.
- `Preferences.clamped(for:)` and `TempTargetCalculations` for dosing-mode and half-basal-target handling.

New abstractions, judged:

| Abstraction | Verdict | Why |
|---|---|---|
| `UntetheredSession` (pure state machine, effects as values, Codable, field-by-field decode) | Justified | Small, testable, explicit phases and epochs. 35 protocol tests. Its edge cases have piled up incrementally, though (watchRecordsSeen, watchSessionEnded, checkingForeignSession, unknownWatchSince). A redesign should cut the fallback-driven states. |
| `UntetheredGate` (file-backed global, locked → no dosing) | Concept justified, shape not | Fail-closed when unreadable is right. A global enum with file I/O on every `phoneMayDose` read, called from `APSManager`, `PumpHistoryStorage`, alerts, remote control and shortcuts, is a cross-cutting singleton. |
| `OrefPipeline`, `GlucoseSmoothing`, `TDDCalculator`, `BolusCalculator` | Justified in principle | Extracting pure functions so two devices share them is right. They change phone dosing code, though, and need an old-vs-new parity test like #1700 had. |
| `UntetheredAlgorithm` input builders | Over-general / duplicated | They re-derive Core Data semantics by hand (rounding through Double, orphaned resumes, temp basal rows). That is a second implementation that must track every phone storage change. |
| `UntetheredGrant` (everything in one message, ~30 fields) | Over-general | It bundles settings, presets, colour scheme, bolus-calculator settings, 24 h history and two device exports. The same type serves as live grant and standing grant ("issued already expired"), which overloads its meaning. |
| `UntetheredRecord` + bucket checksums | Justified concept | Idempotent, versioned sync keyed by stable IDs, with repair. A reusable idea. |
| `UntetheredAudit` | Justified concept | An odometer-vs-records check on return, with IOB erring high. Loop SportMode has the same idea. |
| `UntetheredWatchManager` (5.4k lines, 58 `@ObservationIgnored` vars plus observed state) | AI-shaped / reject | A god object covering transport, devices, loop, alarms, fallback, pairing, workout, Nightscout, UI state and the meal reminder. Many timers and flags interact (see section 4). |
| `UntetheredPhoneManager` (2.3k lines) | Over-large | It combines transport, start, take-back, audit, history storage, remote forwarding, standing grant and gap checks. |
| `G7Direct/G7SensorKit/*` (26 files, 4,744 lines copied, 6 local patches) | Reject | Duplicates the linked G7SensorKit framework. Two Bluetooth centrals for one sensor, coordinated by `standAside`. Crypto code (J-PAKE, P-256) maintained by copy. |
| `PhonePumpReturn`, `PhoneLastDose`, `PhoneOwnGlucose`, `CGMSensorHandover` (UserDefaults enums in `APSManager.swift`/`FetchGlucoseManager.swift`) | Reject | Ad hoc globals that exist to feed the fallback heuristics and the bolus retry. |
| `WatchRemoteCommands` (APNs straight to watch, AES-GCM with the shared secret) | Reject for now | New security surface: a secret on the watch, and a watch device token uploaded to the Nightscout profile (`NightscoutManager.swift:940`), which is a new LoopFollow contract. Not needed for a minimal untethered mode. |
| `WatchNightscoutUploader` | Defer | Useful, but separate from dosing. Carries credentials to the watch. |

AI-shaped signals [V]: 197 code comments cite dated tester incidents ("27 October, second tester…"). 30 cite LLM reviews by name. 120 log lines use an emoji prefix ("⌚️"), which breaks CONTRIBUTING's logging rules. Many behaviors are tuned constants backed by one anecdote each (for example `fallbackWitnessSpan` "4, not 4.5, as a slow first look and a fast second can make it 263 s").

## 4. Concurrency, lifecycle, state and safety risks

### Dosing guards on the watch path

| Guard | Phone (baseline) | Watch (branch) | Status |
|---|---|---|---|
| Max IOB, max basal, SMB caps (maxSMBBasalMinutes/UAM), dosing-mode clamp, DynISF off without TDD | Inside oref via profile/preferences | Same oref, same `clamped(for:)` and `determinationPreferences`, grant carries `pumpSettings` and `preferences` | Preserved [V, `UntetheredAlgorithm.swift:29-67`] |
| `microBolusAllowed` | `true` (`OpenAPS.swift:338` baseline) | `true` (`UntetheredAlgorithm.swift:87`) | Same [V] |
| ≥3 readings in the last hour, newest ≤12 min | `APSManager.determineBasal` | `UntetheredWatchManager+Loop.swift:96-101` | Preserved [V] |
| Suspended / inoperable pump: no enact | Suspended check | Suspended and `.pumpInoperable` (`:345-347`) | Preserved [V] |
| No SMB during a running bolus | Implicit in kit | Explicit `bolusState == .noBolus` (`:361-367`) | Preserved [V] |
| Manual bolus ≤ max bolus | UI-enforced. `roundBolus` clamps for recommendations | `min(units, grant.maxBolus)` silently, logged only (`:545`) | Weaker UX: no user-visible refusal [V] |
| Remote bolus: max bolus, max IOB (with boluses since the last loop), 20 % recent-bolus rule, 10-min window, replay | `BolusSafetyEvaluator` | Re-implemented (`:874-897`) with a 15-min IOB freshness bound | Duplicated logic [V]. IOB uses the last determination plus a sum of boluses, which approximates rather than recomputes IOB [I] |
| Uncertain delivery | Kit UI and alerts on phone | No Trio handling on the watch (no `deliveryIsUncertain` reference in watch code) | Gap [V for Trio code; kit behavior is A2's] |
| Manual temp basal | `isManualTempBasal` blocks loop | Start refused if one is running. The watch has no manual temp | OK [V] |
| Loop interval guard | `loopGuard.tryStart(minInterval:)` | One loop per new reading (`lastLoopGlucose`, `:45`) | Equivalent intent [V] |
| Insulin from elsewhere | No per-loop check | `podTotalExplained` books unexplained insulin and skips that loop's dose, cancelling a high temp | Added safety [V] |
| Glucose alarms | Phone | **Phone glucose alarms are suppressed while a session runs** (`GlucoseAlertCoordinator.swift:139-142`). The phone's not-looping alarm too (`NotLoopingMonitor.swift:100`). The watch alarms with local notifications | Single point of alarming on the less reliable device [V] |

### Authority and race risks
1. Dual control is possible by design. The phone takes the pump back 3 min 10 s after the lease without an answer (`UntetheredSession.swift:279-291`), and the phone stands aside on any newer-epoch claim (`:137-148`). Safety then rests on the kit's foreign-session refusal and the watch's `yieldIfPhoneTookPod` (`UntetheredWatchManager.swift:1565-1585`), which only fires on a refused command. A documented incident shows both devices dosing (`UntetheredWatchManager.swift:665-669`) [V].
2. Epochs come from wall-clock seconds on two devices (`UntetheredSession.swift:127, 315`). Clock skew or a manual time change can reorder sessions [I].
3. The phone's `releasePump` waits at most 30 s for `isLooping` and then releases regardless (`UntetheredPhoneManager.swift:1365-1373`). `phoneMayDose` is checked at the start of the loop, not right before `enactDetermination`'s pod commands. A loop already past its gate relies on the kit refusing after `releaseControl` [V for code; kit behavior is A2's].
4. Error classification by string matching: `"Another controller has used this pod"` (`APSManager.swift:721, 752, 873`), `"podNotConnected"`/`"commsError"` (`UntetheredWatchManager+Loop.swift:194`). This breaks silently if kit wording changes [V].
5. Automatic retry of a refused manual bolus on the phone (`APSManager.swift:818-890`). It is safety-relevant new behavior in the ordinary dosing path. It is gated on a "clean look" flag in UserDefaults and an 11-s window [V]. It exists only because the fallback's looks make the phone's commands fail.
6. The watch manager claims "everything runs on the main queue" (`UntetheredWatchManager.swift:7-9`). Yet it mixes `Task { @MainActor }`, `DispatchQueue.main.async`, timers and semaphores. `holdProcess` blocks the caller (main) for up to 0.5 s waiting on a global-queue semaphore (`UntetheredWatchManager+Loop.swift:1594`), and its expiry path blocks a global thread waiting on main for up to 2 s. `isLooping`, `isFinalizing` and `podQuietUntil` are plain vars with no actor isolation [V]. Under Swift 6 strict concurrency this will not compile without restructuring [I].
7. Re-entrancy: `runLoop` defers a mode-change or treatment loop into the `defer` of a running one (`:59-72`). The hand-back waits for loops by polling `isLooping` at 0.5 s intervals with a 60-s cap, then proceeds "past a loop waiting on the pump" (`UntetheredWatchManager.swift:1445-1450`) [V].
8. Persistence cost: every `store.update` re-encodes about 24 h of glucose, pump history, the grant and the standing grant (each with 24 h of history) and writes the file. One loop calls `update`/`record` many times [V]. Battery and flash-wear impact is unmeasured [U].
9. Lifecycle: a relaunch mid-`.starting` restores the pump manager and continues the takeover. A relaunch mid-`.ending` re-runs `handback()` or resumes finalizing (`UntetheredWatchManager.swift:178-196, 1110-1125`) [V]. This is careful, but the paths have only been exercised by testers [I].
10. Stale settings: a start without the phone doses on a copy up to the insulin action time old (manual) or 60 min (automatic). Phone doses after the copy are booked "as now" from the odometer, so IOB errs high [V, `UntetheredAudit.swift:17-42`]. Settings or overrides changed after the copy are not known [V].
11. Secrets on the watch: the remote-control shared secret, the SHA-1 of the Nightscout API secret (equivalent to the secret for API v1 auth [I]) and the G7 pairing code travel over WatchConnectivity [V].

## 5. Build and configuration changes [V]

| Item | Change |
|---|---|
| Watch target Info.plist (new) | `UIBackgroundModes: bluetooth-central`; `WKBackgroundModes: self-care, workout-processing`; `NSBluetoothAlwaysUsageDescription`, `NSHealthShare/UpdateUsageDescription`; `AppGroupID` |
| Watch entitlements (new) | `aps-environment = development` (hard-coded), HealthKit, time-sensitive notifications, App Group `$(APP_GROUP_ID)` |
| Complication | New entitlements with App Group; `AppGroupID` in Info.plist |
| project.pbxproj | Watch target links LoopKit, OmnipodKit, RileyLinkKit, RileyLinkBLEKit and G7SensorKit frameworks; `CODE_SIGN_ENTITLEMENTS`/`INFOPLIST_FILE` set; `WATCHOS_DEPLOYMENT_TARGET` 10 → 10.6 (6 configs); no new targets |
| fastlane | Adds `USERNOTIFICATIONS_TIMESENSITIVE` (phone, watch) and `PUSH_NOTIFICATIONS` (watch) capabilities |
| `.gitmodules` | LoopKit, G7SensorKit and OmnipodKit repointed to `kristinkand/*` personal branches (`untethered-next-dev`, `untethered-personal`). This contradicts the docs' "reachable through the loopandlearn forks" |
| AlgorithmPackage | Adds `OrefPipeline`, `Models/Untethered`, `WatchMessageKeys`, `BolusCalculator`, `GlucoseSmoothing`, `TDDCalculator`, `ScheduledBasalInference`, `DosingMode`, `TempTargetCalculations`; excludes `Localizations` |
| CI | New `untethered_unit_tests.yml` (fork branches only); runners switched to `xcode-27` ("LoopFollow's pool") with Xcode auto-selection in `build_trio.yml` |
| Settings | `untetheredModeWatch` default **true**; `allowUntetheredStartWithoutPhoneWatch`, `fallbackLoopWatch`, `untetheredWorkoutWatch`, `nightscoutUploadWatch` default false; `untetheredTintHomeWatch`, `watchGlance*`, `useCriticalAlerts`, meal-reminder settings |

## 6. Keep conceptually vs do not carry forward

Keep (as concepts, re-implemented small):
- A pure, persisted, two-sided authority state machine with epochs, prepare/commit, a lease, an acknowledged hand-back, "never retake after letting go" and a fail-closed phone gate. Persist before acting.
- Effects as return values from the state machine, so transitions are unit-testable without devices.
- Release on lease expiry on the watch side; a timeout-bounded hand-back.
- An odometer audit on return (and optionally per loop), booking unexplained insulin so IOB errs high. Tolerance and booking policy need clinical review.
- Temp-basal hand-over rule: a low or zero temp is cancelled and re-set by the new owner for its remainder; a high temp is never re-set and is cancelled by the next owner.
- Versioned, idempotent history records with checksum-based repair.
- Build-equality check before hand-over.
- Shared pure algorithm entry points (`OrefPipeline`-style), with an old-vs-new phone parity test.
- Fail closed when the saved authority state is unreadable (first-unlock protection).

Do not carry forward:
- Automatic takeover from a standing grant (the fallback) and pod "looks". They are heuristics on timing, they interfere with a looping phone, and they forced a phone-side bolus auto-retry.
- Phone-side automatic retry of refused manual boluses; string-matched error classification.
- The copied G7SensorKit sources and the second G7 central in the app target.
- A god-object watch manager; whole-state JSON rewrites on every change.
- Suppressing the phone's glucose and not-looping alarms during a session without an independent alarm path.
- APNs remote commands straight to the watch, and shipping remote and Nightscout secrets to the watch, in a first version.
- The HKWorkoutSession keep-alive as a dependency for correctness (platform-policy and battery risk). If kept at all, only as an explicit, documented user choice.
- Personal-fork submodule URLs, fork-only CI and runner changes, and unrelated bundled features (#1616 meal reminder, critical-alerts toggle, sensor-overlap filter, Core Data unlock retry). These belong in their own PRs.
- Code comments made of dated tester anecdotes and LLM-review citations; emoji-prefixed logs.

## File-level inventory

+/- from `git diff --numstat 3f6b238b4 a56170dc0`. Verdict is about the concept or approach, not merge-readiness: keep-concept, reject, or neutral (unrelated or mechanical).

| Path | + / - | Purpose | Verdict |
|---|---|---|---|
| `Trio/Sources/Models/Untethered/UntetheredSession.swift` | 450 / 0 | Authority state machine, both sides | keep-concept |
| `Trio/Sources/Models/Untethered/UntetheredMessage.swift` | 452 / 0 | Messages, grant, envelope, chunking, temp hand-over, build check | keep-concept (slim the grant) |
| `Trio/Sources/Models/Untethered/UntetheredRecord.swift` | 161 / 0 | Versioned records, bucket checksums | keep-concept |
| `Trio/Sources/Models/Untethered/UntetheredAudit.swift` | 126 / 0 | Odometer audit | keep-concept |
| `Trio/Sources/Models/Untethered/UntetheredAlgorithm.swift` | 296 / 0 | Watch loop inputs, Core Data shape re-implementation, TDD | neutral (entry point keep; input re-derivation reject) |
| `Trio/Sources/Models/Untethered/UntetheredPhoneState.swift` | 64 / 0 | Persisted phone state | keep-concept |
| `Trio/Sources/Models/Untethered/UntetheredNightscout.swift` | 423 / 0 | Watch NS payloads | reject (defer) |
| `Trio/Sources/Services/Untethered/UntetheredPhoneManager.swift` | 2277 / 0 | Phone side: gate, start, take-back, audit, history, remote, standing grant | reject (keep gate concept) |
| `Trio/Sources/APS/OpenAPS/OrefPipeline.swift` | 223 / 0 | Shared oref steps | keep-concept |
| `Trio/Sources/APS/OpenAPS/OpenAPS.swift` | 94 / 230 | Phone uses OrefPipeline | keep-concept, needs parity test |
| `Trio/Sources/APS/GlucoseSmoothing.swift` | 86 / 0 | Extracted smoothing | keep-concept |
| `Trio/Sources/APS/Storage/TDDCalculator.swift` | 244 / 0 | Extracted TDD arithmetic | keep-concept |
| `Trio/Sources/APS/Storage/TDDStorage.swift` | 28 / 242 | Uses TDDCalculator; `storeTDD(_:at:)` | keep-concept, needs parity test |
| `Trio/Sources/Services/BolusCalculator/BolusCalculator.swift` | 196 / 0 | Extracted bolus calculator | keep-concept |
| `Trio/Sources/Services/BolusCalculator/BolusCalculationManager.swift` | 7 / 190 | Uses BolusCalculator | keep-concept, needs parity test |
| `Trio/Sources/APS/APSManager.swift` | 224 / 6 | Gate checks, `adoptLoop`, refused-bolus retry, PhonePumpReturn/PhoneLastDose | gate: keep-concept; retry and globals: reject |
| `Trio/Sources/APS/FetchGlucoseManager.swift` | 74 / 122 | Smoothing extraction, PhoneOwnGlucose, CGMSensorHandover | neutral / reject (unrelated overlap filter) |
| `Trio/Sources/APS/DeviceDataManager.swift` | 2 / 0 | Heartbeat gated | keep-concept |
| `Trio/Sources/APS/Storage/PumpHistoryStorage.swift` | 35 / 2 | Don't purge watch-held pending doses; keep in-flight | keep-concept (review) |
| `Trio/Sources/APS/Storage/GlucoseStorage.swift` | 40 / 2 | Watch glucose ingest | neutral |
| `Trio/Sources/APS/Storage/OverrideStorage.swift` | 2 / 0 | Minor | neutral |
| `Trio/Sources/APS/OpenAPSSwift/AlgorithmLoggingShim.swift` | 2 / 1 | Watch build of logging | neutral |
| `Trio/Sources/Services/Alerts/GlucoseAlertCoordinator.swift` | 7 / 0 | Suppress phone glucose alarms in session | reject |
| `Trio/Sources/Services/Alerts/NotLoopingMonitor.swift` | 7 / 1 | Suppress not-looping alarm in session | reject (as is) |
| `Trio/Sources/Services/RemoteControl/TrioRemoteControl.swift` | 158 / 0 | Forward remote commands to watch | neutral (later) |
| `Trio/Sources/Services/WatchManager/AppleWatchManager.swift` | 441 / 70 | Watch state, wakes, secrets, push token | neutral (rework) |
| `Trio/Sources/Services/Network/Nightscout/NightscoutManager.swift` | 86 / 125 | Session spans upload, watch token in profile | reject (contract change) |
| `Trio/Sources/Models/WatchMessageKeys.swift` | 256 / 0 | New WC keys, glance layout enum | neutral |
| `Trio/Sources/Models/TrioSettings.swift` | 78 / 0 | Untethered and unrelated settings | neutral |
| `Trio/Sources/Models/{Autosens,BGTargets,BloodGlucose,CarbRatios,InsulinSensitivities,Override,PumpSettings,Determination,NightscoutStatus,WatchState,DecimalPickerSettings}.swift` | ~35 / ~17 | Codable/Equatable conformances, fields | neutral |
| `Model/Helper/OverrideStored+helper.swift` | 19 / 0 | Untethered button flag in UserDefaults | reject |
| `Model/Helper/Determination+helper.swift` | 0 / 19 | `minPredBGFromReason` moved | neutral |
| `Model/Helper/PumpEvent+helper.swift`, `Model/CoreDataStack.swift` | 7 / 5 | Minor; log category renames in comments | neutral |
| `Trio/Sources/Views/UntetheredWatchViews.swift` | 453 / 0 | Phone UI for sessions | neutral |
| `Trio/Sources/Modules/WatchConfig/**` | 430 / 7 | Settings UI | neutral |
| `Trio/Sources/Modules/Home/**` | 196 / 19 | Pump area, chart band, buttons; part #1616 | neutral |
| `Trio/Sources/Modules/Treatments/**` | 188 / 13 | Refuse when watch holds pump; part #1616 | neutral |
| `Trio/Sources/Modules/Adjustments/**` | 29 / 2 | Override "untethered button" | reject |
| `Trio/Sources/Shortcuts/**` | 54 / 0 | Start intent, carb preset gate | neutral |
| `Trio/Sources/Router/Screen.swift` | 39 / 13 | Routes | neutral |
| `Trio/Sources/Services/Adjustments/AdjustmentManager.swift` | 52 / 16 | Adjustments while watch holds pump | neutral |
| `Trio/Sources/Application/{TrioApp,AppDelegate}.swift`, `Assemblies/ServiceAssembly.swift` | 41 / 1 | DI, HealthKit auth for watch, Core Data unlock retry, #1616 | neutral |
| `Trio/Sources/Logger/Watch/*` | 27 / 0 | Watch log ingest | neutral |
| `Trio/Sources/Services/MealTimeReminder/*`, `LiveActivity/*MealTime*`, `Services/LiveActivity/MealTimeReminderMetadata.swift`, `Services/Alerts/{TrioAlertManager,TrioModalAlertScheduler,AlertColdStartReplay}.swift`, `Views/SettingInputSection.swift`, `Modules/BolusCalculatorConfig/**`, `Modules/Settings/**`, `Modules/SettingsExport/**` | ~800 / ~70 | #1616 meal-time reminder and critical-alerts toggle | neutral (unrelated, own PR) |
| `Trio/Sources/Localizations/Main/Localizable.xcstrings` | 479 / 89 | Strings | neutral |
| `Trio Watch App Extension/Untethered/UntetheredWatchManager.swift` | 2616 / 0 | Watch transport, takeover, hand-back, fallback, standing grant, persistence glue | reject (god object) |
| `Trio Watch App Extension/Untethered/UntetheredWatchManager+Loop.swift` | 2815 / 0 | Loop, enact, bolus, remote, audit, alarms, delegates, holds, workout, pairing | reject (keep loop/enact guard concepts) |
| `Trio Watch App Extension/Untethered/UntetheredStore.swift` | 240 / 0 | Whole-state JSON persistence | reject (keep fail-closed lock concept) |
| `Trio Watch App Extension/Untethered/UntetheredViews.swift` | 1236 / 0 | Watch UI | neutral |
| `Trio Watch App Extension/Untethered/WatchDeviceManagers.swift` | 107 / 0 | Omni/G7 registry and helpers | keep-concept (registry), neutral |
| `Trio Watch App Extension/Untethered/WatchNightscoutUploader.swift` | 180 / 0 | Watch NS upload | reject (defer) |
| `Trio Watch App Extension/G7Direct/G7SensorKit/*` (26 files) | 4744 / 0 | Copied G7SensorKit sources | reject |
| `Trio Watch App Extension/G7Direct/{WatchG7Reader,WatchG7Session,WatchG7Messages,WatchG7View}.swift` | 2043 / 0 | Display-only G7 reader | reject (use the kit framework) |
| `Trio Watch App Extension/G7Direct/TrioWatchAppDelegate.swift` | 542 / 0 | Background task routing, APNs remote commands, secret store | neutral (task routing keep-concept; APNs reject) |
| `Trio Watch App Extension/G7Direct/README.md` | 52 / 0 | Notes | neutral |
| `Trio Watch App Extension/{WatchState,WatchState+Requests,WatchStateSnapshot,WatchLogger,TrioWatchApp}.swift` | 1058 / 30 | Watch state, complication store, logging, lifecycle | neutral |
| `Trio Watch App Extension/Views/*` | 1210 / 73 | Chart, trend, peripherals page, bolus input | neutral |
| `Trio Watch App Extension/Helper/*` | 54 / 0 | Enums, notification handler | neutral |
| `Trio Watch App Extension/Info.plist`, `TrioWatchApp.entitlements` | 41 / 0 | Background modes, HealthKit, APS, App Group | neutral (bluetooth-central keep; workout and APNs reject for v1) |
| `Trio Watch Complication/*` | 259 / 8 | App Group, untethered face symbol | neutral |
| `Trio.xcodeproj/project.pbxproj` | 526 / 48 | Framework links, file refs, watchOS 10.6 | neutral |
| `AlgorithmPackage/Package.swift` | 13 / 1 | Shared sources in package | keep-concept |
| `TrioTests/OpenAPSSwiftTests/UntetheredTests.swift` | 1012 / 0 | State machine, audit, sync, TDD | keep-concept |
| `TrioTests/OpenAPSSwiftTests/UntetheredProtocolTests.swift` | 468 / 0 | Protocol scenarios | keep-concept |
| `TrioTests/OpenAPSSwiftTests/UntetheredParityTests.swift` | 336 / 0 | Watch vs a hand-written "phone" composition | neutral (weak oracle, see below) |
| `TrioTests/OpenAPSSwiftTests/UntetheredNightscoutTests.swift` | 241 / 0 | NS payloads | neutral |
| `TrioTests/CoreDataTests/UntetheredPumpHistoryParityTests.swift` | 171 / 0 | Watch pump rows vs real `PumpHistoryStorage` | keep-concept |
| `TrioTests/CoreDataTests/{PumpEventFinalizationTests,MultiUsePanelStateTests,CarbEntryMutationServiceTests}.swift`, `TrioTests/{AlertColdStartReplayTests,TrioModalAlertSchedulerTests}.swift`, `TrioTests/Mocks/MockTDDStorage.swift` | 135 / 28 | Adjusted tests; part #1616 | neutral |
| `.gitmodules`, `LoopKit`, `G7SensorKit`, `OmnipodKit` | 9 / 9 | Personal-fork pins | reject |
| `.github/workflows/*`, `fastlane/Fastfile` | 133 / 7 | Fork CI, runners, capabilities | reject (CI) / neutral (capabilities) |
| `DeveloperDocs/Untethered/README.md`, `ACKNOWLEDGEMENTS.md` | 138 / 0 | Docs, credits | neutral |

Note on `UntetheredParityTests`: its "phone" side (`UntetheredParityTests.swift:10-85`) is a re-composition of the same `OrefPipeline` calls, not `OpenAPS`/`APSManager` with their JSON and Core Data reads. It only covers `.closed` dosing mode. It proves the watch composes the same calls, not that the watch matches the real phone path [V].

## Docs claims checked against code

| Claim (DeveloperDocs/Untethered/README.md) | Finding |
|---|---|
| "Supported devices: Omnipod DASH and Dexcom G7" | The phone's refusal string says "Omnipod DASH and Omnipod 5" (`UntetheredPhoneManager.swift:1199`). The watch registry accepts any `OmniPumpManager` (`"Omni"`) [V] |
| "Exactly one device commands the pod at any time" | Not guaranteed by Trio code. See section 4, items 1-3, and the incident comment at `UntetheredWatchManager.swift:665-669` [V] |
| Pre-start checks: pod answers, glucose ≤12 min, no bolus, no uncertain delivery, no manual temp | Present (`preflight` `:1185-1226`, `pumpAnswers`, `maxGlucoseAge` `:159`) [V] |
| Watch alarms: urgent low every 5 min, no readings, not looping | Present (`UntetheredWatchManager+Loop.swift:2226-2300`); local notifications only [V] |
| "If the pod delivered more than the records explain (by more than 0.2 U), the difference is added as a bolus" | Present (`UntetheredAudit.tolerance = 0.2`) [V] |
| Start by Itself "once per outage" | Up to 6 tries per outage; one successful takeover per outage [V] |
| "Parity tests feed both paths the same history" | The phone path in the test is a re-composition, not the app path [V] |
| "RileyLinkKit: watchOS targets" needed | The pin is unchanged against dev [V] |
| "All commits are reachable through the loopandlearn forks" | `.gitmodules` points to kristinkand forks [V]; reachability on loopandlearn is not checked here (A2) [U] |
| Untethered Mode "on by default" | `untetheredModeWatch = true` [V]; sessions still need an explicit start unless the fallback is enabled |

## Open questions

1. Does the forked OmnipodKit's foreign-session refusal reliably stop the second controller before any delivery command reaches the pod, including for a command already in flight? (A2.) Every dual-control mitigation in Trio depends on it.
2. Does watchOS actually deliver `bluetooth-central` wakes to a watch app often and long enough for pod commands, without a workout session? The branch's comments say "often not" (stalls of up to about 5 h). Platform research should confirm on current watchOS.
3. Is the HKWorkoutSession keep-alive acceptable under App Store/TestFlight review and Apple's workout API terms? What battery cost does it measure?
4. Should the phone keep its glucose and not-looping alarms during a session, as an independent alarm path when the phone is near? What is the alarm design when it is not?
5. What maximum session duration, if any, and what action at expiry? The branch has none.
6. Are the phone refactors (`OpenAPS`, `TDDStorage`, `BolusCalculationManager`, smoothing) behavior-identical? An old-vs-new parity test like #1700's `OrefPipelineTests` is needed before relying on them.
7. Is the 0.2 U audit tolerance, and booking unexplained insulin as a bolus "now", clinically acceptable? This needs a clinician to review it.
8. Do the fork CI results (algorithm tests passing at `410a63a6d`, build at `a56170dc0`) reproduce on nightscout CI with upstream kit pins? I did not run them myself.
9. Which of the 197 incident-driven constants (timeouts, windows, holds) reflect platform behavior, and which reflect one tester's environment?

## Evidence index

- Branch head: `kristinkand/feature/untethered-watch-mode` @ `a56170dc020a1d1b7ce4490514027c6ae6c297a4`; merge base `3f6b238b450d423f9aa2585e173d50d212d5273d` (dev 1.0.2.71); baseline `ad6c66876` (dev 1.0.2.72, differs from the merge base in 6 CI/config files only).
- Initial untethered commit `676993775` ("Based on [EJM0's] EJM0/Trio feat/direct-to-watch" (name redacted to the handle)); `ef3a36c08` (ejm0, committed by Claude, OrefPipeline sharing); fallback/fork-specific: `8a2111917`, `6718aed07`, `774f7dde9`; G7 direct only: `c29662035`; docs: `a56170dc0`.
- PRs: https://github.com/nightscout/Trio/pull/1598, /1749, /1762, /1616, /1700 (closed), /1576 (merged, merge commit `34bf78e0d`).
- Fork CI: `kristinkand/Trio` check runs: `410a63a6d` "Algorithm package (swift test) success"; `a56170dc0` "Build success".
- Key files (at `a56170dc0`):
  - `Trio/Sources/Models/Untethered/UntetheredSession.swift:64-80, 123-296, 300-418`
  - `Trio/Sources/Models/Untethered/UntetheredMessage.swift:8-52, 136-185, 187-222, 224-275, 332-452`
  - `Trio/Sources/Models/Untethered/UntetheredAlgorithm.swift:26-99, 163-257`
  - `Trio/Sources/Models/Untethered/UntetheredAudit.swift:7, 17-113`
  - `Trio/Sources/APS/OpenAPS/OrefPipeline.swift:1-223`
  - `Trio/Sources/Services/Untethered/UntetheredPhoneManager.swift:14-116, 159, 839-908, 981-1003, 1185-1226, 1365-1405, 1412-1536`
  - `Trio/Sources/APS/APSManager.swift` (branch): 328, 467, 608, 721, 752, 818-890, 1687, 1770-1815
  - `Trio/Sources/APS/FetchGlucoseManager.swift` (branch): 532, 566
  - `Trio/Sources/APS/Storage/PumpHistoryStorage.swift` (branch): 197-255
  - `Trio/Sources/Services/Alerts/GlucoseAlertCoordinator.swift:136-142`; `NotLoopingMonitor.swift:100`; `Trio/Sources/Services/RemoteControl/TrioRemoteControl.swift:73-91`
  - `Trio Watch App Extension/Untethered/UntetheredWatchManager.swift:7-11, 144-167, 178-196, 544-560, 600-706, 707-740, 750-814, 818-859, 924-963, 970-1051, 1092-1160, 1175-1300, 1401-1500, 1512-1600, 1607-1620, 1945-2230`
  - `Trio Watch App Extension/Untethered/UntetheredWatchManager+Loop.swift:28-212, 344-377, 442-503, 515-571, 599-690, 757-807, 874-897, 1504-1600, 1723-1795, 2226-2384, 2548-2760`
  - `Trio Watch App Extension/Untethered/UntetheredStore.swift:5-70, 153-240`
  - `Trio Watch App Extension/Untethered/WatchDeviceManagers.swift:18-24, 95-107`
  - `Trio Watch App Extension/G7Direct/TrioWatchAppDelegate.swift:12-200, 209-340, 507-535`; `G7Direct/README.md`
  - `Trio Watch App Extension/Info.plist`; `TrioWatchApp.entitlements`; `Trio Watch Complication/TrioWatchComplication.entitlements`
  - `.gitmodules`; `AlgorithmPackage/Package.swift:61-80`; `.github/workflows/untethered_unit_tests.yml`; `fastlane/Fastfile:268-284`
  - `TrioTests/OpenAPSSwiftTests/UntetheredParityTests.swift:10-85`
- Baseline comparisons (at `ad6c66876`, `/Users/dnzxy/workspaces/Trio-on-watch`): `Trio/Sources/APS/OpenAPS/OpenAPS.swift:338` (`microBolusAllowed: true`); `Trio/Sources/APS/APSManager.swift:289-330, 488-560, 626-700, 783-848`; `Trio/Sources/APS/DeviceDataManager.swift:457` (uncertain delivery only logged).
