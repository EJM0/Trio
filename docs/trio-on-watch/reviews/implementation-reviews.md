# Implementation reviews

## M1 review

Reviewer: independent agent; did not write the code. Branch `feat/tow-oref-run` @ `d40070789` (8 commits on `1a9dba899`), worktree `~/workspaces/Trio-tow-oref-run`. Read against `target-architecture.md` §2 + v2 amendments, `arch-review-C.md` C-01..C-04, `implementation-status.md` M1. Line numbers are at `d40070789`.

Severity: **critical** = wrong dosing or data loss; **major** = fix before M1 merges; **minor** = fix in M1 or M1b; **nit** = when touched.

### What I checked and how

- **Phone path, line by line.** Diffed every moved function against `1a9dba899` with indentation ignored: `OrefRun.profilePreferences` / `profiles` / `autosens` / `trioCustomOrefVariables` / `determinationProfile` / `iob` / `meal` / `determine`, `OrefInputs.pumpHistoryEvents` / `orphanedResumes` / `filterTooFrequentGlucose` / `algorithmGlucoseValue` / `bloodGlucose` / `exponentiallySmoothedGlucose` / `carbsEntry` / `tddInsulin` and the TDD helpers. They are verbatim apart from parameter plumbing.
- **Side-effect order is unchanged.** In `createProfiles`: temp-target fetch, then HBT, then clamp, then `Date()`, then profiles. In `determineBasal`: `iob.json` is saved before the determination and skipped in a simulation; the DynISF switch-off happens before `missingInputs`; `timestamp = deliverAt`; `cob.json` is written, then Core Data.
- **Values are unchanged.** `Decimal(Double)` for the override percentage. NSDecimalNumber → Decimal → NSDecimalNumber for the smoothed glucose (lossless). Positional order of pump history events. `as? Decimal` → `.decimalValue` for `currentTDD` (a bridged NSDecimalNumber gives the same value; the `dynisf-sufficient-tdd` golden shows `currentTDD` 28.0137). The `?? Date()` / `?? UUID()` fallbacks are kept. The extra 0 g carb entry in `determineBasal` but not in `autosense` is unchanged, and MealHistory drops it (`carbs > 0`).
- **The goldens really come from the unmodified code.** `ae8efa8d7` contains goldens and test files only. Production code at that commit is baseline plus the context injection (`a010bc81a`, behaviour-neutral). Goldens recorded at `ae8efa8d7` are byte-identical at HEAD. I ran it myself: HEAD's test files and all 12 HEAD goldens (including the two added in `7f7ec8aba`) against the production sources from `ae8efa8d7`, with a fresh iPhone 17 / iOS 27.2 simulator and `-only-testing:TrioTests/OrefCharacterizationTests`. Result: **12/12 passed**.
- **Mutation run** on HEAD, both characterization suites, four mutations at once. Result: 5 issues, all from mutation (b) only.

| # | Mutation | Detected? |
|---|---|---|
| a | `OrefRun.autosens`: `ratio8h.ratio < ratio24h.ratio` → `>` | **no** (0/11 production, 0/11 `OrefRun`) |
| b | `OpenAPS.determineBasal`: `currentTime: Date()` → `Date() + 60 s` | yes: `low-glucose-suspend`, `basal-testing-suspend-only`, `simulation` (minGuardBG, forecasts) |
| c | `OverrideState.init`: swap `smbMinutes`↔`uamMinutes` and `start`↔`end` | **no** |
| d | `OrefRun.run`: drop the MMAT + 0.5 h glucose window | **no** |

Scratch copy: `/private/tmp/claude-501/-Users-dnzxy-workspaces-Trio/3f8cbd66-3ec5-4539-8f2f-f9e5df9ae9dc/scratchpad/m1-mut`; logs `m1-review-runA5.log` and `m1-review-runB.log` in the same scratchpad. The branch was not touched. Note: the scratchpad path canonicalises to `/tmp`, so the copy needed `CI=true` (SwiftFormat otherwise reformats LoopKit) and absolute submodule gitdirs (for `capture-build-details.sh`).

### Verdict on the claim

**I found no change to phone dosing behaviour.** The one semantic difference I found is M1-07 (milliseconds on a TDD window edge). The weak point is the test net. Several dosing-relevant pieces that M1 now presents as "guarded by goldens" survive mutation. For the watch, `OrefRun.run` and the phone's staged calls are two separate orchestrations of the same stages. Only 11 scenarios check that they agree, and those scenarios miss whole branches.

### Findings

| ID | Sev | Where | Failure scenario | Recommended fix |
|---|---|---|---|---|
| M1-01 | major | `OrefRun.swift:238`; `TrioTests/OpenAPSSwiftTests/Parity/ParityScenarios.swift:205-227`; `goldens/*/autosens.json` | Classic autosens is `ratio 1` in all 11 goldens, so the stage is effectively unchecked. Mutation (a) flips the 8 h/24 h choice to the *less* sensitive result, which means more insulin for a resistant user, and every suite stays green. The parity harness has its own copy of the selection, so parity goldens don't cover `OrefRun.autosens` either. A future edit to the 8 h/24 h logic, the precomputed treatments or the autosens inputs (pump history, temp targets, profile) ships unnoticed on the phone and on the watch. | Record (on the current code, before any further change) one scenario where 8 h and 24 h ratios differ and neither is 1: e.g. 24 h of glucose rising above BGI, with the last 8 h flatter. Then do C-01 step 3: point `ParityScenarios.runPipeline` at `OrefRun.autosens` (or `run`) so parity and production share the selection. |
| M1-02 | major | `OrefRun.swift:18-106` vs `OpenAPS.swift:229-330, 340-365, 380-410, 430-482`; `OrefRunCharacterizationTests.swift:50-175` | Two orchestrations of the same stages: the phone's `OpenAPS` and `run`. `run` re-implements the glue: the MMAT + 0.5 h glucose window, the two clamps, the JSON round trips, the autosens timestamp and the cache hand-off. The test that "proves" they agree builds `OrefInputs` with its own hand-written copy of the phone's selection rules: 24 h/48 h windows, sort direction, the TDD predicate `date > 10 d AND total > 0`, and the 75 %-of-7-days threshold copied as a literal (`:166`). Mutation (d) removes `run`'s glucose window with no failure, because every carb sits 45 min back. Breakage path: someone changes the window, `hasSufficientTDD` or the orphan rule on the phone; the phone goldens get re-recorded and the test helper edited; `run` and the M5 watch builder silently keep the old rule. C-04's "same inputs by construction" holds for per-row mappers only, not for row selection. | Move the selection rules into the shared `OrefInputs` set and call them from the phone stores and the test: `tddRows(_:now:)`, `hasSufficientTDD(rowDates:now:)`, the pump-history window plus orphan filter over `[PumpHistoryEvent]`, and `determinationGlucose(_:mmat:now:)`. Delete the copies in `OrefRunCharacterizationTests.inputs(for:)`. Add one scenario with carbs older than MMAT + 0.5 h, so the window is observable. Optional, stronger: a DEBUG/test hook in which `OpenAPS` builds `OrefInputs` once per loop and asserts `run(inputs)` equals the staged outputs. |
| M1-03 | minor | `OpenAPS.swift:579-597`; `OrefCharacterizationScenarios.swift:188-198` | Override fields `smbMinutes`, `uamMinutes`, `start`, `end`, `advancedSettings` and `smbIsScheduledOff` are nil/false in every scenario, and `maxSMBBasalMinutes` = `maxUAMSMBBasalMinutes` = 30. So mutation (c), or swapping the two preference fallbacks at `OrefRun.swift:250-251`, is invisible. Today the mapping is correct (checked by reading). M5 builds `OverrideState` from the grant, where a swap would change the SMB/UAM caps or the scheduled-SMB-off hours. | Make the override scenario use advanced settings: `smbMinutes` 45, `uamMinutes` 60, `smbIsScheduledOff` with `start` ≠ `end`, and preferences with 30/90 minutes. Record it on the current code. |
| M1-04 | minor | `OrefInputs+TDD.swift:6-48`; `TDDStorage.swift:67` | `tddInsulin`, the composed TDD (grouping, the `isScheduledBasal != true` filter, suspension spans, sum), has no test; only its parts do. C-03 asked for "phone and watch produce identical TDD for the same fixture". TDD feeds DynISF `currentTDD` and the weighted average. Also, the labelled tuple is destructured by position (`let (bolus, temp, scheduled)`), so a reorder of the return swaps the stored temp and scheduled components silently. | Add one `tddInsulin` test with a fixed history: bolus, temp, scheduled row, suspend/resume, and expected totals. Use the result's labels at the call site (`result.tempBasal`, …). |
| M1-05 | minor | `OrefCharacterizationTests.swift:177, 216-223` | Goldens map `deliverAt`/`timestamp`/`date` within −1..120 s of the clock to `<now>`. A 60 s shift is caught in 3/12 scenarios (mutation b). `Date()` vs `clock` (sub-second to a few seconds) is not: `run` uses `clock` everywhere and matches the same goldens. The M1 note "Quirks preserved: the determination time is `Date()`" (C-01 step 4) is therefore verified by reading, not by a test. | Either accept and say so in the status doc, or start the production-path clock 30 s in the past and require wall-clock keys to sit 25–120 s after it (run suite: exactly `clock`). |
| M1-06 | minor | `OrefCharacterizationTests.swift:180`; `ParityHarness.swift:26` | Both suites record on `TRIO_RECORD_GOLDENS`. Re-recording parity goldens after an intended algorithm change, with the characterization suite in scope, overwrites the characterization goldens. Their only value is that they were recorded once on pre-refactor code. The suite does fail on record, but a "record, then re-run" routine clears that. | Give the characterization suite its own env var (e.g. `TRIO_RECORD_CHARACTERIZATION`). |
| M1-07 | nit | `OpenAPS.swift:347, 359` → `OrefRun.swift:252` | The 2 h TDD window used to be anchored on a `Date()` taken *before* the TDD and override fetches. Now it uses the `Date()` passed after them, so it is later by the fetch time (ms). A TDD row inside that slice drops out of `past2hoursAverage` / `weightedAverage`. That is a real but negligible deviation from "byte-identical", and no golden can hit it. | Take `let now = Date()` before the fetch, derive `tenDaysAgo` from it, and pass it. Or document it under "Quirks". |
| M1-08 | nit | `OrefRun.swift:6`; `OrefInputs+TDD.swift:174-214`; `OrefInputs+Mapping.swift:107, 184` | `Outputs: Codable` has no user yet (yagni until M4/M5). The free function `findBasalRateForOffset` moved into `OpenAPSSwift/OrefRun/` while its only callers are in `APS/Storage/ScheduledBasalInference.swift`. Smoothing and the too-frequent filter are not oref input mapping, but they live in `extension OrefInputs`. | Drop `Codable` from `Outputs` until it is sent anywhere. Consider a `TDDCalculation` / `GlucoseFiltering` namespace next to `ScheduledBasalInference`. |
| M1-09 | nit | `APSManager.swift:459`; `OrefRun.swift:189-192` | `isAutosensFresh` has no test. It is equivalent to the old guard (argument evaluation order keeps `Date()` after the await). The watch will rely on it, and `run` itself never checks freshness of `inputs.autosens`. | One boundary test (29:59 fresh, 30:00 stale, nil timestamp stale). Document on `OrefInputs.autosens` that `run` trusts the caller. |

Also checked, no finding:
- **pbxproj:** 4 sources in the Trio app phase (same phase as `OpenAPS.swift`), 3 tests in TrioTests, groups correct. Goldens are read via `#filePath`, as the parity suite does.
- **`Package.swift`:** `DosingMode`, `Preferences+DosingMode`, `TempTargetCalculations`, `ScheduledBasalInference` added; `OrefRun/` is picked up through the `APS/OpenAPSSwift` directory. `swift test` still can't build on Xcode 27.2 (M0), so I didn't verify this beyond the author's `swiftc -typecheck`.
- **Concurrency:** stages are pure statics. `tddInsulin` now runs inline rather than in `async let` children, which is harmless (nonisolated async).
- **Logging and comments:** logging unchanged and per CONTRIBUTING. Comment density matches; the #1054 rationale moved with the code.
- **Scope:** `TimeZone` in inputs (V2-23) is correctly deferred to M1b.

**Verdict: merge after fixes.** Fix M1-01 and M1-02 before merge. They are test and structure gaps on dosing-relevant code, not current phone regressions. M1-03..M1-06 can land in M1 or M1b. Nits optional.

Not verified: device or in-vitro runs, the full Trio Tests suite (I trusted the author's 998/954/0/44), Xcode 26.2 (the CI toolchain), DST and non-flat schedules (the goldens are flat by design).

## M2b review

Reviewer: independent agent; did not write the code. Trio `feat/tow-kits` @ `dc6404c8b` (worktree `~/workspaces/Trio-tow-kits`). OmnipodKit `trio-on-watch` = #177 @ `3d21d9c` + `d5606d6`, `2e5f9bd`, `b647ea9`. LoopKit `trio-on-watch` = `babddf04` + `7fd4d1a7`. Read against V2-6, V2-7b, safety review R-4, C-1, C-2, A2-03/A2-08 and `implementation/omnipodkit-177-proposal.md`. OmnipodKit line numbers are at `b647ea9`.

Severity: **critical** = two controllers command, or wrong dosing; **major** = fix before M5 relies on the rule; **minor** = fix in M2b or note for M4/M5; **nit** = when touched.

### What I checked and how

- **Every command entry point.** All 30 `OmniPumpManager` session callers (status, detailed status, alert acknowledgement and silence, beeps, basal schedule, time zone, suspend, resume, bolus, cancel bolus, temp basal, reminders, deactivation, pulse log, post-connect status) go through `OmniPumpManager.runSession` (`OmniPumpManager.swift:1769`), which refuses before dialling. Both handshake paths (`completeConfiguration` at `BlePodComms.swift:935`, `blePairAndSetupPod` at `:712`) go through `establishNewSession`, which refuses before the first handshake and before the retry. `blePairAndSetupPod`'s "already established" branch can't run after a refusal, because a refused handshake leaves `needsSessionEstablishment` set. Eros never sets the flag.
- **Persistence and export.** The four fields are in `rawValue` (Dates follow the `activatedAt` pattern) and in synthesized `Equatable`, so `PodComms.podState.didSet` notifies. `sharedFacts` clears all four, and `localState` carries none.
- **Concurrency.** The new fields are written only under `podStateLock`: in the handshake, in `expectSessionResync` and in `stopSupersedingAnotherController`. The manager copy is `Locked`. `pumpManagerDidUpdateState` is delivered async through `pumpDelegate.notify`, so a host reacting to it can't deadlock on `podStateLock`. The host sees the refusal after the failing session's own error, not before.
- **LoopKit pin.** `7fd4d1a7`'s patch is byte-identical to upstream `a78fe3bb` (LoopKit#687) apart from pbxproj hunk offsets. The author (jeremybarnum) and message are kept, and the parent is `babddf04`. Faithful.
- **Pins and hygiene.** The Trio tree pins LoopKit `7fd4d1a7`, OmnipodKit `b647ea98`, RileyLinkKit `52a652c9` and G7SensorKit `08d48863`, as the status doc says. `6fdf0e0e` is an ancestor. All six commits are signed, none carries Claude attribution, and the submodules are clean.
- **Tests, run myself.** I copied OmnipodKit, LoopKit and RileyLinkKit into a scratch workspace, created a fresh iPhone 17 / iOS 27.2 simulator (deleted afterwards) and ran `-only-testing:OmniTests/DeviceHandoffTests`: **37/37 passed**.
- **Mutation run, all at once.** I removed both `establishNewSession` refusals, the `expectsSessionResync = false` after a session, the `bleRunSession` refusal, the `OmniPumpManager.runSession` refusal and the restored-link hook. That is every production line in the patch outside `PodState`. Result: **37/37 still pass** (see M2b-01). Scratch: `/private/tmp/claude-501/-Users-dnzxy-workspaces-Trio/3f8cbd66-3ec5-4539-8f2f-f9e5df9ae9dc/scratchpad/m2b-review` (`base.log`, `mut1.log`, `scripts/mutate.py`).

### Verdict on the claim

The **rule** in `PodState` is right as written. An adopt or a take expects one resync. Any later resync on a shared pod is reported. Outside a scoped take it sets a persisted refusal, and only a take lifts it. Every command and handshake path I found honours that refusal. I found no path in the patch where the kit lets a refused controller send anything.

**The claim as worded doesn't hold.** Each break below needs a specific condition, but none is ruled out by the patch:
- A restored link can skip the new handshake because of an init-order race the code already documents (M2b-02). Safety then rests on the pod rejecting stale keys, which is unverified.
- A stale controller can complete a full session after the owner's sessions, not only first after the take (M2b-06).
- One plain `takeControl()` call from a host silently removes both the refusal and the scope (M2b-05).

A legit owner can also be locked out:
- by its own late-saved counter (M2b-03);
- after a refusal on a held link, where taking control again doesn't work while the phone is in the foreground (M2b-04).

The tests don't exercise any of the kit's guards (M2b-01).

### Findings

| ID | Sev | Where | Failure scenario | Fix |
|---|---|---|---|---|
| M2b-01 | major | `OmniTests/DeviceHandoffTests.swift:404-431` (`PodCounter`); `BlePodComms.swift:410-438, 806-809, 856-866`; `OmniPumpManager.swift:1776-1780` | The pod double re-implements `establishNewSession`: the two refusals, the retry and the `expectsSessionResync` clear. The tests therefore check the double plus the `PodState` methods, not the kit's guards. Removing all six production changes outside `PodState` leaves **37/37 green** (my run). So R-4's and C-1's "the stale watch's next command of any kind fails" is shown for the double only. A later edit that drops a guard, or the `expectsSessionResync = false` line (without it every later resync counts as "expected" and is never detected), ships unnoticed. The proposal's "Never refusing fails 14 assertions" mutated the shared `PodState` code, so it doesn't support the kit-level claim. | Move the handshake decision into `PodState`. For example, `mutating func handshakeResynced(to podSqn: Int) -> Bool` sets `eapSeq`, calls `resolveAfterSessionResync()` and returns whether a retry may follow, and `mutating func sessionEstablished(...)` clears `expectsSessionResync`. Call both from `establishSession`/`establishNewSession` and from the double, and delete the double's copies. Add one manager-level test that reaches `OmniPumpManager.runSession`: an Eros-typed manager (no CBCentral) whose `podState.refusesSessions` is set must fail `getPodStatus` and `enactTempBasal` with `.podUsedByAnotherController` without reaching `ErosPodComms`. Re-run the mutation above. |
| M2b-02 | major | `BlePodComms.swift:856-866`; `BluetoothManager.swift:1616-1633`; `BlePodComms.swift:45-49, 897-901` | C-2's restored-link handshake depends on `omnipodPeripheralWasRestored` firing. `willRestoreState` calls it only if `autoConnectIDs` already holds the pod, and `autoConnectIDs` is filled by `connectToDevice`'s `managerQueue.async` from `BlePodComms.init`. These two race, and the comment at `BluetoothManager.swift:1629` says "autoConnectIDs may not be populated yet due to init ordering". If the restore wins, `needsSessionEstablishment` stays `false`. `assertConfiguration` then runs `completeConfiguration`, which logs "Session already established", and `bleRunSession` later picks the restored, connected `PeripheralManager` and sends on the saved keys with no handshake. So the stale controller never sees the resync and is never refused. The only thing between it and the pod is the unverified "a message under stale keys is dropped". The proposal and status doc say C-2 is closed ("the kit always handshakes"). | Set it in `init`, where no race exists: `if hasLTK, podState?.sharedWithAnotherController == true || (podState?.bleMessageTransportState.ck?.isEmpty ?? true) { needsSessionEstablishment = true }`, and drop the restore hook. A process on a shared pod then never trusts keys it saved. If the hook loses the race, `completeConfiguration` skips login (`manager !== self.manager`) and `bleRunSession` refuses with `podNotConnected` until the link cycles, which fails closed. Keep the in-vitro M8 case for C-2. |
| M2b-03 | major | `OmniPumpManager+DeviceHandoff.swift:142-158`; `PodState.swift:304`; Trio `DeviceDataManager.swift:387-388` | This controller's own counter, saved late, looks exactly like a foreign session. The doc comment at `:144` calls it the known reason a never-shared pod resyncs. Example: the watch (or the phone after any lend, since `sharedWithAnotherController` lasts the pod's life) handshakes, and the process dies before the host saves `rawValue`. Trio saves it from the async `pumpManagerDidUpdateState`. On relaunch, `eapSeq` is behind the pod, the resync is unexpected, and the holder sets `refusesSessions`. It stops dosing and raises a false "another device used your pod", with no foreign controller anywhere. This fails closed, but it costs looping and trust, and recovery runs into M2b-04. | Persist a kit-local write-ahead high-water mark of the EAP counter before each handshake, for example an atomic file or UserDefaults keyed by pod address. Treat a resync with `podSqn <= highWater` as this controller's own (resync as before, no refusal). If that's judged too much for #177, at least document it in the proposal, and make M4/M5's alert copy say "may have", not "did". |
| M2b-04 | major | `BlePodComms.swift:897-945`; `PeripheralManager.swift:197-222, 828-848`; `OmniPumpManager+DeviceHandoff.swift:239-260` | A refusal found during `completeConfiguration` throws after `needsConfiguration` was already cleared (`PeripheralManager.swift:205`), and the link stays up. (1) A refused phone in the foreground (`shouldHoldConnection`, `:839`), or a refused controller with Pod Keep Alive or the heartbeat probe, keeps holding or re-dialling the pod's one BLE link, so the holder can't connect. (2) When the user then takes control, `expectSessionResync` clears the flag, but `rearmConnection` won't redial a connected link, and nothing re-runs the handshake. Every session fails `podNotConnected` ("no session established on this connection", `:811`) until the app goes to the background and the idle disconnect fires. The owner stays locked out while looking at the screen. | On `.podUsedByAnotherController` in `completeConfiguration`, drop the link (`bluetoothManager.disconnectOnDemand(manager.peripheral, reason: "used by another controller")`). That frees the pod for the holder, and the first session after a take reconnects and handshakes. Add to M5's acceptance tests: on `refusesSessions` the host calls `releaseControl()` at once, which removes the pod from `autoConnectIDs` and stops the probe. |
| M2b-05 | major (integration) | `OmniPumpManager+DeviceHandoff.swift:230-243` | `takeControl()` does several jobs at once: it reconnects, resets the scope to nil, clears `refusesSessions` and `foreignSessionDetectedAt`, and makes the next resync "expected". Each of these can go wrong. (a) A watch host that calls `takeControl()` on relaunch to "check the pod" (V2-11) lifts its own refusal. Its handshake then resyncs as expected and succeeds, so the stale watch commands again, and the phone, inside its scope, keeps commanding too: two controllers. (b) The phone redoing Take Back step 2 after a relaunch (C-3) with the plain form silently ends the scope, and the stale watch's next session stops the phone. | Kit: log a device event when a take lifts a refusal or replaces a scope (one line, so in-vitro logs show it). Host (M4/M5 acceptance tests): the watch calls `takeControl()` only immediately after `init(adopting:)` or after a user-confirmed take. The C-3 redo passes the original `until`. V2-11's "no foreign controller" check reads `refusesSessions`/`foreignSessionDetectedAt` and never takes. |
| M2b-06 | minor | `BlePodComms.swift:428-436`; `PodState.swift:304`; proposal "Tests" | The proposal limits the leak to "the stale watch handshakes first after the take". `incrementEapSeq()` runs before each attempt, so attempts that never reached the pod (a link drop mid-EAP) leave the stale controller's counter ahead. After the owner's *n* handshakes, a stale controller with at least *n* such attempts is accepted, runs a full session, and is refused only at the one after that. The phone inside its scope reports it and keeps going. | No cheap kit fix. Widen the documented limit in the proposal and status doc. C-1 already has the phone audit every foreign session, which covers it. Keep it as an M8 in-vitro case if feasible. |
| M2b-07 | minor | `OmniPumpManager+DeviceHandoff.swift:150-155` | The scope is checked against the wall clock. Setting the clock back stretches the 6 h scope, so the phone keeps commanding through foreign sessions past C-1's horizon (fail-open). Setting it forward ends the scope early (availability). | Also store the take time, and treat `now < takenAt` or `until - now > until - takenAt` as out of scope. Or document that the host must re-check its own horizon. |
| M2b-08 | minor | `implementation/omnipodkit-177-proposal.md`; `implementation-status.md` M2b | The docs claim more than the code shows. "Checked by mutation … fails 14 assertions" and the R-4 "pump-double test" cover the double (M2b-01). "C-2 … the kit always handshakes" ignores M2b-02. The patch is "about 90 lines", but the source diff is about 110. Nothing says that a refused controller keeps bidding for the link (M2b-04). | Correct the wording after the fixes. Say that the kit guards are verified by reading plus the manager-level test. |
| M2b-09 | nit | `PodCommsSession.swift:116, 187`; `PodState` `debugDescription` | `podUsedByAnotherController` has no recovery suggestion, so a non-technical user sees "Another device has used this pod" with no next step. `refusesSessions`, `foreignSessionDetectedAt` and the scope are missing from the pod's diagnostics, so an issue report shows the refused state only if the device log still has the resync line. | Add a plain recovery line, for example "Take control of the pod on this device, or keep using the device that has it.", and add the three fields to `debugDescription`. |
| M2b-10 | nit | `OmniPumpManager+DeviceHandoff.swift:180-194` | `expectSessionResync` and `stopSupersedingAnotherController` take `podStateLock`, which a running session holds for its whole length. If the phone calls `stopSupersedingAnotherController()` on the main thread while a loop session runs, the UI stalls for that session. `markSharedWithAnotherController` already has the same pattern. | Say in the doc comment that callers stay off the main thread, or hop to a utility queue inside. |

Also checked, no finding:
- **Lean.** Each of the four fields and two methods maps to C-1 or C-2, and nothing is speculative. Fixing M2b-01 shrinks the double by about 20 lines. Fixing M2b-02 replaces the restore hook (3 lines) with one condition in `init`.
- **Style.** Matches #177's comment density and voice. The device-log line follows the existing `[trust]` format.
- **Never-shared pods.** Unchanged: every new check is false, and the restore hook is gated.
- **Release path.** A released controller is quiet: `disconnectFromDevice` removes it from `autoConnectIDs`, `beginCommandConnect` checks `loanReleased`, and `runSession` refuses. With M2b, a stray resync on a released controller now refuses instead of re-handshaking, so it can't move the counter past the holder's. That is an improvement over `3d21d9c`.

**Verdict: fix M2b-01, M2b-02 and M2b-04 before M5 depends on the rule, and decide M2b-03 (fix it, or document it and soften the alert copy).** M2b-05 goes into the M4/M5 acceptance tests. M2b-06 to M2b-08 are doc changes or small changes. The proposal can go to #177 after M2b-01 and M2b-02, with M2b-06 added to its limits.

Not verified: hardware or in-vitro runs; the pod-side behaviour (whether a resync-answered handshake leaves the counter unchanged, whether stale keys are dropped, whether a second HELLO/EAP on a live restored link drops it); whether CoreBluetooth state restoration actually fires on watchOS; the full OmniTests suite (I ran `DeviceHandoffTests` only); the full Trio Tests suite.

## M1 re-review

Delta `d40070789..f5be3bdb2` (8 commits), same rules as above. Line numbers are at `f5be3bdb2`.

### What I ran

Both runs used a fresh iPhone 17 / iOS 27.2 simulator (deleted afterwards). The scratch copy and logs are in the session scratchpad: `m1-rereview-runA.log`, `m1-rereview-runB.log`.

- **Goldens against the original code:** HEAD's characterization tests and all 15 HEAD goldens, run against the production sources from `ae8efa8d7`. **15/15 passed.** So the 3 new goldens (`autosens-8h-24h-differ`, `carbs-glucose-window-gap`, `override-advanced`) are the original code's output, whatever route recorded them.
- **Mutations (a)–(d) again on HEAD:** `OrefCharacterizationTests`, `OrefRunCharacterizationTests`, `OrefRunStageTests` and `ParityGoldenTests`. **All four are now caught:**
  - (a) autosens selection: `autosens-8h-24h-differ` fails in both suites (autosens, iob, determination);
  - (b) +60 s determination time: 3 scenarios, as before;
  - (c) override field swap: `override-advanced` (custom variables, determination);
  - (d) no glucose window in `run`: `carbs-glucose-window-gap` (cob, determination).
  - `OrefRunStageTests` and the 14 parity goldens passed. Parity runs through the `OrefRun` stages now, but it can't see (a) on its own scenarios; the characterization scenario covers it.

### Status of M1-01..M1-09

| ID | Status | Note |
|---|---|---|
| M1-01 | resolved | The new scenario has ratios 1.12 (8 h) and 1.2 (24 h). Parity uses `OrefRun.autosens`. |
| M1-02 | mostly resolved | The drift test now builds inputs only through `OrefInputs+Selection.swift`: the hand-copied windows, sorts and 75 % literal are gone, and (d) is caught. Residue in R-02. |
| M1-03 | resolved | (c) is caught. |
| M1-04 | resolved | `tddInsulin` has a test; `TDDStorage.swift:67-73` reads the tuple by label. |
| M1-05 | accepted | Documented as verified by reading. Fine. |
| M1-06 | resolved | Own env var `TRIO_RECORD_CHARACTERIZATION`. |
| M1-07 | resolved | `now` is taken before the fetches (`OpenAPS.swift:325`), which is the original anchor for the 2 h/10 d windows. The custom-variables `date` moves to the same instant; the algorithm never reads it. |
| M1-08 | partly | `Codable` is dropped; placement deferred to M1b. OK. |
| M1-09 | resolved | Boundary test added. |

### New findings in the delta

| ID | Sev | Where | Failure scenario | Recommended fix |
|---|---|---|---|---|
| R-01 | major (sign-off) | `OpenAPS.swift:113-140`, `OrefInputs+Selection.swift:49-71` | The pump-event list used to come from a descending fetch. It now comes from an ascending 48 h fetch plus two Swift sorts, so events with an **identical timestamp** probably come out in reverse relative order on device. `PumpEventStored` has a descending `byTimestamp` index: a forward scan gives ties in insertion order, the backward scan for `ascending: true` gives the reverse, and the in-practice-stable Swift sorts keep it. This depends on SQLite's query plan, which I didn't verify; the in-memory test store can't show it. The order reaches the algorithm through `removingDuplicateSuspendResumeEvents`, which keeps the *first* suspend/resume per timestamp: a suspend and a resume at the same instant flips which one survives, which means "suspended until the next resume" vs not. It also reaches `IobHistory`'s stable sorts, where it decides which of two same-time temps wins. Rare, because it needs identical timestamps, but `.claude/rules/algorithm-safety.md` lists unstable-tie sort changes as needing explicit sign-off. Calling the order "unspecified before and after" is disclosure, not sign-off. | Either get maintainer sign-off on record, or keep the old list order. To keep it: fetch the 48 h window `ascending: false` as before, take orphans over `reversed()`, and filter without re-sorting on the phone; the input is already sorted, and only the watch builder needs an explicit sort. |
| R-02 | minor | `OrefInputs+Selection.swift:21-35, 77-100` vs `GlucoseStorage.swift:437-443`, `CarbsStorage.swift:442`, `OpenAPS.swift:550-559`, `TDDStorage.swift:256-267` | Only the window *starts* are shared. The filter conditions are written twice: as NSPredicate strings on the phone (`date >= %@`, `date > %@ AND total > 0`) and as Swift closures in `glucose(_:since:)`, `carbs`, `tddHistory` and `hasSufficientTDD`. The phone never calls those Swift functions, so the drift test validates the Swift copies, not the phone's predicates. Example: edit `total > 0` in the `TDDStorage` predicate, and the goldens stay green unless a scenario has a zero-total row. | Build the predicates from the same place, e.g. `OrefInputs.tddPredicateFormat`. Or fetch by window only and apply the Swift selection to the fetched rows on the phone too. |
| R-03 | minor | `OpenAPS.swift:136` | On the phone, `isScheduledBasal: { $0.tempBasal?.isScheduledBasal == true }` is redundant, because the fetch predicate already excludes those rows. It also fires a `tempBasal` relationship fault for every event in the 24–48 h band, which the old orphan pass never touched (it read only `type`/`timestamp`). That's roughly 300 extra faults per determination and per autosense, under background CPU caps. Otherwise perf is better: one 48 h fetch instead of a 24 h fetch plus a 48 h fetch, and memory is about the same (the old orphan fetch already materialised 48 h). | Pass `{ _ in false }` on the phone with a one-line reason, or set `relationshipKeyPathsForPrefetching = ["tempBasal"]`. |
| R-04 | nit | `OpenAPS.swift:153-156`; `PumpEvent+helper.swift:88-91`; `OrefRun.swift:203` | `nativePumpHistory(orphanedResumes:)` is now always `[]` (dead parameter). `NSPredicate.pumpHistoryLast1440Minutes` is used by tests only. `includeDeviationsForTesting` is a test flag on a production stage; it mirrors `AutosensGenerator`'s existing parameter, so acceptable. | Drop the parameter and the predicate, or point the predicate tests at the new fetch. |

Checked in c4239815a, no other change:
- **Windows:** identical. The 24 h list is still `Calendar` −1440 min with `>=`, and the orphan window is still `now − 48 h`; one `now` replaces two `Date()` calls (ms apart).
- **Orphan rule:** unchanged. Same 48 h set, same scheduled-basal exclusion (`isScheduledBasal` is a non-optional Bool, so `== true` matches the predicate's `== NO` complement), same ascending order as the old orphan fetch, nil timestamps dropped as before.
- **Simulated bolus:** still inserted first.
- **Glucose, carbs, TDD:** the window helpers reproduce the old expressions exactly (`predicateForOneDayAgo` was `Calendar .day −1`; the TDD windows were `now − 10 d` / `now − 7 d`).

**Verdict: not yet.** Merge once R-01 is either fixed (keep the descending order) or signed off by the maintainer in the status doc. R-02 and R-03 can go to M1b; R-04 is optional. Everything else from the first review is resolved or accepted.

---

## M3 architecture/code review (Agent C: Trio fit and gate coverage)

Branch `feat/tow-loan-core`, worktree `~/workspaces/Trio-tow-loan-core`, commits `af368b6b5`, `3a54a7959`, `d46918afb`, reviewed against the merge base `f059f1809`. Read-only: nothing was built or run, and the verdict rests on code reading only.

### Gate coverage against C-05

I searched the branch for every `PumpManager` command call (`enact*`, `cancel*`, `sync*`, `set*`, `ensureCurrentPumpData`, `acknowledgeAlert`) and every external `apsManager` command caller. Every Trio-side path from C-05 #1–#14 is gated, and each has a Swift Testing test in `WatchLoanGateTests.swift`:

| Path | Gate on the branch |
|---|---|
| loop entry and its re-entry after a manual temp ends | `APSManager.swift:312` |
| enactment | `:794`; the gate is re-checked before any pump call |
| `enactBolus`, through `verifyStatus` | `:448`; covers Treatments, QuickPick, Shortcuts, remote and watch callers |
| `cancelBolus` | `:721` |
| basal-testing temp cancel | `:1531` |
| TDD | `:479` |
| `syncDeliveryLimits` in the setter, including launch restore | `DeviceDataManager.swift:128` |
| all four BLE heartbeat sends | routed through `sendBLEHeartbeatRequest` `:290-293` |
| heartbeat / `ensureCurrentPumpData` | `:306` |
| three settings providers and the basal schedule sync | `UnitsLimitsSettingsProvider:36`, `AlgorithmAdvancedSettingsProvider:41`, `NightscoutConfigProvider:36`, `BasalProfileEditorProvider:30` |
| pump alert acknowledgement | `TrioAlertManager.swift:390` |
| kit settings and setup screens | `PumpSettingsView:13`, `PumpSetupView:15`; this also covers pod replacement through `HomeRootView:309` and onboarding delegates |

No Trio-side pump-command path is missing.

The kit layer (a released manager refusing pod commands) is still open for M2b, as planned.

### Behaviour when the phone is home (no state file)

Unchanged, as far as the code shows:
- `load()` returns `.success(nil)`, which maps to `.initial` = `home`, and `permits` returns true.
- Every gate sits after the existing early returns and before the same calls.
- The only differences: one `fileExists` stat per gate check; `enactDetermination` and `cancelAutomaticTempBasal` widened from `private` to internal so tests can reach them; `PumpConfig` returns nil, so the view is built as before.

The tests run each path with `owner: true` and with no file.

### Findings

| ID | Severity | Where | Finding | Fix |
|---|---|---|---|---|
| M3C-01 | major (M4) | `PumpSettingsView.swift:13`, `PumpSetupView.swift:15` | The UI gate runs only in `makeUIViewController`. A kit settings screen already open when a lend starts stays fully usable (suspend, manual temp, deactivate) after `lending` is persisted. | M4: lend precondition "no pump settings or setup screen presented", or dismiss them when `lending` is persisted. Add a test that opens the screen and then lends. |
| M3C-02 | major (M4) | `WatchLoan.swift:61, 296` (`.awaitPumpIdle`) | The decision table is right (persist `lending`, then wait for the in-flight loop, then cancel the temp). But a loop that passed `enactDetermination`'s gate still awaits Core Data (`:795-835`) before `performBasal`. Only an actual wait closes that window, and `LoopGuard` is a `private actor` in `APSManager.swift:80`. | M4: implement `.awaitPumpIdle` as `await loopGuard.waitForLoop()` (existing API, `:104-107`), plus `pumpEventsTask` and `bolusState == .noBolus`, exposed through one `APSManager` method. Test: a lend issued while a loop is between gate and `performBasal` cancels after that loop's temp, not before. |
| M3C-03 | minor | `PumpSettingsView.swift:27` `handedOverViewController(gate: WatchLoanGate = WatchLoanGate())` | Bypasses DI: it builds a second gate with no resolver, so an unreadable file shows the reason but issues no alert from this path, and it keeps its own `didAlertUnreadable`. | Pass the injected gate: `@Injected` on the PumpConfig provider or state model. Keep the parameter for tests only. |
| M3C-04 | minor | `WatchLoanGate.swift:11, 21-27` | `didAlertUnreadable` is check-then-set under two separate lock acquisitions, so two concurrent readers (heartbeat and loop) can both alert. It is reset on every good read, so a flapping file re-alerts each time. | Do the test and set in one locked step (`$didAlertUnreadable` with the lock, or a small `NSLock` block). Reset only on a transition to readable that has persisted for at least one heartbeat, or never during the process lifetime. |
| M3C-05 | minor | `WatchLoanGate.swift:43-48` | `refusalMessage` loads and decodes the file a second time after `permits` already did. | Have `permits` return the state (or a `Refusal?`), and derive the message from it. That is one read per command. |
| M3C-06 | minor | hot paths `APSManager.swift:312`, `DeviceDataManager.swift:306`, `PumpSettingsView` (main thread) | A file read plus JSON decode on every gate check. The cost is negligible (small file, at most a few checks a minute, a stat only when home). No lock is held across IO, and `permits` doesn't hop queues, so there is no deadlock risk with `processQueue.safeSync`. Acceptable as is. | None required. If profiling ever shows it, cache by file modification date. Don't cache without that, or a crash-recovery write from the coordinator could be missed. |
| M3C-07 | minor | `WatchLoan.swift:3-147` (19 occurrences) | Production comments cite fleet document IDs (`V2-12`, `C-1`, `N-4`, …) that won't exist upstream. That is against Trio's comment convention (no doc cross-references, one terse line). | Drop the IDs or move them to the PR/tests. Keep the one-line "why" where it isn't obvious. |
| M3C-08 | minor | `WatchLoanGate.swift:39` | Every refusal logs at `debug`. A user-initiated bolus or cancel refused during a loan is a meaningful event, while per-reading refusals (heartbeat, BLE) are noise. | `info` for user-initiated refusals (bolus, cancel, settings sync, screens), `debug` for periodic ones. Pass the level, or split `permits` into a periodic variant and a user-initiated variant. |
| M3C-09 | minor | `Localizable.xcstrings` | Four new `String(localized:)` keys (`WatchLoanGate.swift:45, 47, 52-54`) are not in the catalog. The build extracts them, but a commit without them leaves Crowdin unaware. | Build once in Xcode and commit only the catalog additions it generates (no hand edits, project rule). |
| M3C-10 | minor (M4) | `DeviceDataManager.swift:128, 290` | While gated, `syncDeliveryLimits` and the BLE heartbeat request are skipped. On the transition back to `home` nothing re-sends them until a pump is set again or the next CGM reading arrives. The heartbeat recovers on the next reading; the delivery limits never do. | M4: on persisting `home` after take-back, re-run the setter's sync block (delivery limits plus the last heartbeat request). Test it. |
| M3C-11 | minor | `APSManager.swift:794`, `:1531` | `private` was widened to internal only for tests. Trio's tests already use `@testable`, so it's acceptable, but it widens the API surface. | Fine. Optionally mark it `// internal for tests` per the file's comment density. |
| M3C-12 | minor | `Trio.xcodeproj/project.pbxproj:10-22, 5871-5875, 6658-6667` | Hand-written object IDs (`A7A10A0000…`) are valid but not Xcode-shaped. Membership looks right: the 5 sources are in `Trio`, the 8 tests and the mock in `TrioTests`, and nothing is in the watch target, which is right for M3. | Let Xcode re-save the project once to normalise, or leave it. Check for collisions when rebasing onto #1749/#1723, which also edit this file. |

Conventions:
- DI registration in `APSAssembly` (container scope) matches its siblings.
- File placement (`APS/WatchLoan/`, `APS/WatchLoanGate.swift`) fits the architecture map.
- Naming fits Trio: `permits`, `phoneMayCommandPump`.
- Tests use Swift Testing (`@Suite`, `@Test`, parametrized `owner`), with no XCTest.
- No unnecessary abstraction: one gate class and one store struct, and the state machine is pure. The pbxproj and tests are fine.

**Verdict: approve with changes.** M3 is mergeable as is; nothing in it changes behaviour for a phone that never lends. M3C-01 and M3C-02 are real safety gaps but sit in M4's lend flow, so they must be tracked as M4 acceptance items. Fold M3C-03 to M3C-09 in before M7.

## M3 safety review (Agent E)

Branch `feat/tow-loan-core` @ `d46918afb` (worktree `~/workspaces/Trio-tow-loan-core`), against `f059f1809`. Reviewed: `Trio/Sources/APS/WatchLoan/*`, `WatchLoanGate.swift`, the gate wiring, `TrioTests/WatchLoanTests/*`, and `watch-loan-decision-table.md` (P1–P42, W1–W33). Criteria: SR-1 to SR-4, V2-1/3/7b/10/11/12/15, R-1 to R-5, C-1, C-3, C-4, N-4, and M2b-05.

Basis: code reading only. I did not build or run the tests. The kit facts used below (what `takeControl()` lifts) come from the M2b review (M2b-05), not from my own reading of the kit.

### What holds

**Message and gate rules are correct:**
- SB-1 / V2-1: the grant is bound to `requestID`, carries an expiry checked on the offset-corrected clock, and is refused outside `requesting` (W4–W9).
- N-4: `grantRejected` triggers an automatic retake with no takeover context (`WatchLoan.swift:306-309`). The 120 s timeout is longer than the 60 s worst-case lend plus the 30 s grant lifetime.
- P42: late release and take-control results carry the epoch, so a late result from an earlier hand-off is ignored.

**Effect ordering is correct:**
- Every state change persists before any pump action, except the documented take-back finish (`takeControlResult` → cancel, refresh, audit, then persist `home`), which acts under a persisted `takingBack`.
- Alarms are armed before the persist and disarmed after it (`alarmTransition`).
- V2-3: End persists `returning` before cancel and release, and a relaunch in `returning` releases again.
- V2-10: stop and revoke decode before the version probe (`WatchLoanMessage.swift:93-104`).
- V2-15 / SR-1 phone side: the gate reads the file on every check and fails closed with a one-time time-sensitive alert. Agent C found the coverage complete.
- V2-12: the invariant search covers the listed pairs, and `.unreadable` maps to `phoneNotLooping`.

**Take Back follows V2-7b, and C-1 is scoped:**
- R-1: Take Back cancels the temp (`WatchLoan.swift:204`).
- R-3: the audit is recomputed on every foreign session.
- C-1 window: the takeover context is set only by a user Take Back (`:219-227`), never by End or `grantRejected`. It ends when the watch's stop arrives (`:174-179`) or after 6 h.
- C-3: a relaunch in `takingBack` redoes take, cancel, refresh and audit.
- Still open for M4: C-4 and R-2 live in the audit implementation, which M3 only names.

### Findings

| ID | Sev | Where | Scenario | Fix |
|---|---|---|---|---|
| M3E-01 | **blocker** | `WatchLoan.swift:440-451` (W26) | **A watch relaunched in `holding` re-emits `takeControl` when the phone doesn't answer.** Sequence: the watch is off or crashed while holding; the user taps Take Back on the phone, which then doses at `home(e+1)` and advances the pod's EAP counter; the watch relaunches with the phone unreachable (`phoneEpoch == nil`) and with no foreign session seen yet (it hasn't touched the pod since). W26 then emits `.takeControl`. Per M2b-05, `takeControl()` clears `refusesSessions` and marks the **next resync as expected**, so the watch's next handshake absorbs the phone's session without refusing. The watch commands again at `holding(e)` while the phone commands at `home(e+1)`: **two commanders**. The phone sees a foreign session inside its C-1 window and keeps commanding (by design). The invariant search can't find this, because it counts `holding(e)` against `home(n>e)` as a legal stale state and models the kit as always detecting (`LoanWorld.swift:47-49`; `recover()` injects `foreignPodSession`). | Re-emit `takeControl` on relaunch only if the kit never took control (crash between W4's persist and its take), and then only when the phone answered `phoneEpoch == e`. Add `kitHasControl: Bool` to `relaunched(...)`. If the kit already holds: resume without any take, and let the kit's resync detection act. If it doesn't hold and the phone is silent: `stopped` (it never dosed, so stopping is safe; the alarm is armed). Add W-rows and a test. In `LoanWorld`, model kit detection as switched off by any `takeControl` after a phone take, so the search covers it. |
| M3E-02 | major | `WatchLoan.swift:520-528` (`stopWatch`); `:174-179` | **A stopped watch never releases the pod, and the phone drops its context on the watch's stop.** `stopWatch` (superseded, foreign session, resume window) emits no `.releaseControl`, so the stopped watch's kit keeps holding or redialling the link (M2b-04) and may handshake again on kit timers or status reads. Meanwhile the phone clears `supersededUntil` as soon as the `stop` arrives. The stopped watch's next handshake is then an unscoped foreign session, so the phone **refuses** (`:259-262`). Both devices are refused, which is alarmed but has no recovery path (see M3E-03). | Add `.releaseControl` to `stopWatch` (it also closes M2b-04's link bidding). Clear the phone's context only on a stop that confirms release: add `released: Bool` to the stop, or send a second stop after the release result. |
| M3E-03 | major | `WatchLoan.swift:212-213` (P-row Take Back in `home`); `:259-262` | **No way back once the phone is refused while `home`.** The phone ends up refused by any of: a foreign session outside the C-1 window, a lost context (M3E-02), the unreadable-file Take Back (no context), or a false positive from its own late-saved counter (M2b-03). The kit then refuses every session. Tapping Take Back in `home` does nothing, and the pump screens are open but have no loan action. Automation stays stopped (alarmed by NotLoopingMonitor and `unexpectedPodSession`) until the pod is replaced. That is hours of scheduled basal at best, and the user has no action that fixes it. | Add a user-confirmed "Use the pod on this iPhone" event, allowed in `home` while the kit refuses. It bumps the epoch, revokes, calls the scoped `takeControl(until: now+6h)`, then cancels the temp, refreshes and runs a pod-lifetime audit (M3E-04). Add P-rows and a test. |
| M3E-04 | major | `WatchLoan.swift:230-236`, `:203` | **Take Back from an unreadable file resumes looping without an audit.** With `loan: nil`, the take result emits `.alert(.auditUnavailable)` and resumes. A corrupt file is most likely mid-loan, so any watch doses missing from the records are never booked, and IOB is under-counted. That makes R-3 / V2-8 fail open. | Make the audit work without the lost baseline: `audit(loanEpoch: nil)` means a pod-lifetime audit. Expected = all booked doses plus scheduled basal since pod activation; actual = the pod odometer, which counts from activation. The phone has the full pre-lend history. Book the excess as usual. Keep the alert. |
| M3E-05 | major | `WatchLoan.swift:66`, `:228-229`, `:269-271`, `:204` (`.takeControl` has no parameters) | **M2b-05(b) is left to the host.** Take Back, repeated Take Back taps (`takingBack` → `.takeControl`) and the C-3 relaunch redo all emit a bare `.takeControl`. If the host maps that to plain `takeControl()`, the scope ends silently, and the stale watch's next session stops the phone. A second tap whose take completes after `home` can also reset the scope. `.podSession(.keepCommanding)` has the same problem: it must re-assert the scope, not plain-take. | Make it explicit in the effect: `.takeControl(supersedingUntil: Date?)`. Take Back passes the loan's `supersededUntil`; End and `grantRejected` pass nil; the C-3 redo passes the persisted value. In `takingBack`, ignore repeated taps while a take is pending. M4 acceptance test: a redo keeps the scope. |
| M3E-06 | minor | `WatchLoanState.swift:6, 12-15, 51-55`; `WatchLoan.swift:235` | `epoch` is `Int`, which is 32-bit on `arm64_32` watches. The unreadable path uses Unix seconds, which fits in 32 bits only until 2038. After that, a revoke would fail to decode on the watch, and a stop it can't read means the watch keeps commanding. | Use `Int64` for epochs on the wire and in state. Or keep a counter (last epoch + 1,000,000 from a backup copy) instead of the time. |
| M3E-07 | minor | `WatchLoan.swift:252`; same family as M2b-07 | The C-1 window uses the wall clock. Setting the clock back extends the window in which the phone keeps commanding through foreign sessions. | Store the time of the take with the loan record. Treat `now < takenAt` as outside the window. |
| M3E-08 | minor | `WatchLoan.swift:493-494` (W9) | A duplicate grant that reaches a watch already in `returning` or `stopped` for the same epoch is answered with `grantRejected(unknownRequest)`. If the phone is still `lending` (because the holding message was lost), it then retakes without a context. That is safe, but it skips End. | For `returning` or `stopped` at `message.epoch`, answer `status(state)` instead of `grantRejected`. |
| M3E-09 | minor | `WatchLoanMessage.swift:99-101` | Every non-stop message from another protocol version is dropped. So End doesn't work across a version skew, contrary to the lifecycle row ("End is still accepted"). This fails closed, because Take Back plus the audit still recover. | Accept `handBack`, `handBackAck` and `records` across versions (versioned payload), or update the lifecycle doc. |
| M3E-10 | minor | `LoanAlarm.armed(for: .stopped)` | A watch stopped as `superseded` keeps its not-looping series ringing every 20 min while the phone loops normally, until the user acknowledges. That is alarm fatigue. | After the phone confirms `home` at a higher epoch (revoke or status), switch the series to a single "Trio on Watch ended" notice. |

No act-before-persist ordering problem found, and no epoch reuse. The audit effect is idempotent by contract (recompute); that contract needs its M4 test, including the C-4 booked intents.

### Verdict

**Not mergeable until M3E-01 is fixed.** It is a reachable two-commander path, created by the machine's own relaunch effect together with the kit's `takeControl()` semantics.

M3E-02 to M3E-05 are majors that change decision rows. They belong in M3 too, because M4 and M5 build on these rows. M3E-06 to M3E-10 can go into M4 or M5. After the M3E-01 fix, re-run the invariant search with kit detection modeled as described in the M3E-01 fix.

## M2b re-review

Reviewer: the same independent agent. Delta only: OmnipodKit `trio-on-watch` `b647ea9..e576b45`, Trio `feat/tow-kits` `7c77dd161` (pin) and `1cf63f73d` (docs). The contract change is the maintainer's: only `takeControl(supersedingAnotherControllerUntil:)` lifts a refusal or starts a scope; a release ends the scope; the scope runs on uptime within a boot and on the wall clock across a reboot. Line numbers are at `e576b45`. The commit is signed, has no Claude attribution, and the worktree and submodules are clean.

### Runs

On a fresh iPhone 17 / iOS 27.2 simulator (deleted afterwards), in a scratch copy of the three kits, `-only-testing:OmniTests/DeviceHandoffTests`:

| Run | Removed | Result |
|---|---|---|
| base | – | 43/43 pass |
| BLE sites | all eight `BlePodComms` changes: both `nextHandshakeSqn` guards, the `sessionEstablished()` call, the `AcceptedEapSqn` save and read, the `bleRunSession` refusal, the `init` condition, `releaseConnection()` in `refuseSessions()` | **43/43 pass** (survives) |
| mgrrun | `OmniPumpManager.runSession` refusal | 3 failures |
| mgrinit | the `refusesSessions` release in `OmniPumpManager.init` (`:139`) | **survives**; Eros has no `BlePodComms` |
| plaintake | a plain take calls `expectSessionResync` | 1 failure |
| relscope | a release keeps the scope | 1 failure |
| all of the above | – | 5 failures |

Scratch: `/private/tmp/claude-501/-Users-dnzxy-workspaces-Trio/3f8cbd66-3ec5-4539-8f2f-f9e5df9ae9dc/scratchpad/m2b-review` (`rr-*.log`, `scripts/mutate2.py`, `scripts/run.sh`).

The survivors match the status doc's "checked by reading only" list, with two gaps. The doc doesn't list the `sessionEstablished()` call site (its M3 mutated the method, not the call) or the `OmniPumpManager.init` release. Both are correct by reading.

### Earlier findings

| ID | Status |
|---|---|
| M2b-01 | **Resolved, with a residue.** The handshake decisions are `PodState` methods called by both `BlePodComms` and the double. The manager refusal is tested through an Eros manager, and the decision mutations are killed. The eight `BlePodComms` call sites and the manager-init release stay read-only, because nothing in the tests can build a central. I read every site, and all are wired correctly. |
| M2b-02 | **Resolved.** `BlePodComms.swift:47` requires a handshake for any shared pod in `init`, so no restore ordering matters. If the restore hook loses the race, `completeConfiguration` skips login (`manager !== self.manager`) and `bleRunSession` refuses with `podNotConnected` until the link cycles, which fails closed and costs at most one cycle in the background. |
| M2b-03 | **Resolved.** See the high-water mark section below. |
| M2b-04 | **Resolved, with a residue (R-02).** `refuseSessions()` (`BlePodComms.swift:116`) releases the link, after the active command session if there is one, and takes the pod off `autoConnectIDs` and the escalation scan. A refused manager doesn't dial at launch (`OmniPumpManager.swift:139`). A dated take re-arms the link, and the fresh connect handshakes because `needsSessionEstablishment` stayed set. |
| M2b-05 | **Resolved by the contract change.** A stray plain take no longer lifts a refusal or ends a scope. New residues: R-02, R-03, R-04. |
| M2b-06 | Documented in the proposal. |
| M2b-07 | **Replaced by R-01** (the new clock fails open the other way). |
| M2b-08 | **Resolved.** The docs now separate tested from read. Only the two omissions noted under Runs remain. |
| M2b-09, M2b-10 | Resolved. |

### The high-water mark (`AcceptedEapSqn`)

- **Order.** It is written in `establishSession`'s `.SessionKeys` branch (`BlePodComms.swift:417`), that is, after the pod accepted the handshake and before any command on that session. It is read only when classifying a resync (`:389`). It is written and read under `podStateLock`, and `UserDefaults` is thread-safe.
- **No false trust, whatever happens to it.** The pod's counter only ever goes up, and it is at least every SQN it ever accepted. So `podSqn <= highWater` means `podSqn == highWater`, which means no other controller has had a handshake accepted since this one. A lost, stale or missing value can only be lower than the truth, so the resync is classified as foreign. **Losing it can only cause a false refusal, never false trust.**
- **Why write-after is right.** Writing before sending would close one more window but create false trust: an attempt that never reached the pod would raise the mark above what a foreign session could reach.
- **Remaining false-refusal windows**, both narrow and both fail closed with an alert and recovery by a dated take:
  - The pod accepted the final EAP message but the reply was lost, and the process died before the host saved the incremented `eapSeq`.
  - The process died, or power was lost, before `cfprefsd` persisted the `set`. In-process `UserDefaults` writes are handed to `cfprefsd` asynchronously. That usually survives an app kill; power loss may not.
- **Constraint to write down.** It must stay in this device's own `UserDefaults.standard`. An app-group or iCloud-synced store shared with the peer would let the peer's accepted SQN hide the peer's sessions.

### New findings

| ID | Sev | Where | Failure scenario | Fix |
|---|---|---|---|---|
| R-01 | major | `OmniPumpManager+DeviceHandoff.swift:186-208` (`SupersedingTake`, `ProcessInfo.processInfo.systemUptime`) | `systemUptime` is time **awake** since boot. It stops while the device sleeps. Measured on this Mac: `systemUptime` 60 343 s = `CLOCK_UPTIME_RAW`, against 153 171 s for `CLOCK_MONOTONIC_RAW`. An iPhone with the screen off sleeps between BLE and CGM wakes most of the time, so "6 h of uptime" can last days of wall time. While it does, the phone keeps commanding through foreign sessions far past C-1's 6 h horizon (fail-open). It is the direction M2b-07 was meant to close. The clock test injects uptime, so it can't see this. | Use a clock that counts sleep and resets at boot: `Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9`. Keep the `kern.bootsessionuuid` check and the wall-clock fallback across a reboot. One line plus the default arguments. |
| R-02 | minor | `OmniPumpManager+DeviceHandoff.swift:322-346` | A plain `takeControl()` on a refused, not-released manager leaves the refusal in place, as intended. It still runs the radio part, though: `rearmConnection()` → `connectToDevice` clears `loanReleased` and re-adds the pod to `autoConnectIDs`, and because `isControlReady` stays false, `scheduleTakeEscalation` scans by address until the pod answers or control is released. The refused controller bids for the pod's one link again. Each connect ends in `refuseSessions()`, so nothing is sent, but the holder's connects can collide with it, and it costs battery. | Return before the radio part when `until == nil && state.podState?.refusesSessions == true`, with a device-log line. |
| R-03 | minor (contract) | proposal "Host contract" | Two dated takes in opposite directions (phone over watch, then watch over phone) leave both controllers in scope. Each reports the other's sessions and neither refuses, so two controllers command until a scope ends. The kit can't detect this. v1 has no forced takeover from the watch, but the contract text ("a user-confirmed takeover from a peer that hasn't acknowledged stopping") would allow one. | Add to the host contract: at most one side ever makes a dated take (in Trio, the phone). A future watch takeover first needs the phone's scope ended, by release or acknowledgement. |
| R-04 | minor (contract) | `OmniPumpManager+DeviceHandoff.swift:254-266`; proposal | Only the dated form lifts a refusal. A refused phone whose host later does an ordinary plain take-back stays refused (fail closed, with the error's recovery text). A host that wants to lift a refusal **without** superseding anyone has to pass `until <= now` (an empty scope). That idiom is undocumented, and the obvious alternative, passing now + 6 h, opens a superseding scope after a refusal whose source is unknown. | Document the empty-scope idiom in the doc comment and the proposal, or accept `Date.distantPast` explicitly. |
| R-05 | nit | `BlePodComms.swift:969-981` | One `AcceptedEapSqn` key per pod stays in `UserDefaults` forever (about 120 a year). | Remove it in `forgetPod`, or leave it. |

No other new path to two commanders or to an owner lockout: release ends the scope only after `mayReleaseControl` passes, a C-3 redo with the original `until` keeps the original end, and an adopt still expects its resync without a take.

**Verdict: fix R-01 before M5 relies on the scope. R-02 is a small change worth making now. R-03 and R-04 are contract text, needed before the proposal goes to #177.** With R-01 fixed, M2b meets R-4, C-1 and C-2 at kit level, with the `BlePodComms` wiring verified by reading.

Not verified: hardware, in-vitro and pod-side behaviour (unchanged from the M2b review); whether `kern.bootsessionuuid` is readable in the iOS and watchOS sandboxes (if it isn't, the code falls back to the wall clock, which is the M2b-07 behaviour); `cfprefsd` durability under power loss; the full OmniTests suite.

## M1 final check

Delta `f5be3bdb2..3d55e4102` (7 commits). Fresh iPhone 17 / iOS 27.2 simulator (deleted afterwards). Logs in the session scratchpad: `m1-final-runA.log`, `m1-final-runB.log`, `m1-final-runC.log`.

**Phone fetch code against the original (`ae8efa8d7`):**
- `fetchPumpHistoryObjectIDs` (24 h, descending, batch 50), `fetchOrphanedResumes` (48 h, ascending, batch 250) and `parsePumpHistory` are byte-identical to the original.
- `fetchOrphanedResumes` differs only by the verbatim move of the orphan rule into `OrefInputs.orphanedResumes`.
- The predicates `pumpHistoryLast1440Minutes` / `pumpHistoryLast48h` and the glucose, carbs, TDD-sufficiency and 10-day TDD windows change only their start expression, to shared helpers that compute the same value. So the change is window starts only, plus the earlier verbatim moves.

**Goldens against the original sources:** HEAD's characterization tests with all 17 HEAD goldens, run against the production sources from `ae8efa8d7`. **17/17 passed**, including `suspend-resume-same-instant` (in-memory store) and `suspend-resume-same-instant-on-disk` (SQLite file).

**Tie-order guards on HEAD:**

| Mutation | Result |
|---|---|
| Phone: c4239815a's ordering (ascending fetch, then a stable Swift sort, newest first) | both tie goldens fail: `pumpSuspendResumeMismatch` thrown, no determination. R-01 was real: that order turns a working loop into a failed one when a suspend and a resume share a timestamp |
| Phone: ascending fetch, then `reversed()` | passes. It is an equivalent mutation on these stores: SQLite gives ascending ties as the exact mirror of descending ties (a backward index scan), so `reversed()` restores the original order |
| `algorithmPumpEvents`: newest-first tie-break flipped | both tie goldens fail in the `OrefRun` suite (same error) |

`OrefInputsSelectionTests` (TDD history, sufficiency, glucose, carbs: predicate fetch against the shared Swift selection), `OrefRunStageTests` and the 14 parity goldens pass.

**R-findings:**
- **R-01:** resolved. The original phone fetches are back; the same-instant behaviour is pinned by goldens recorded from the original code on two store types; the watch-side selection reproduces the phone's tie order with an explicit offset tie-break, not by relying on sort stability.
- **R-02:** resolved. Predicate and Swift selection are pinned by tests.
- **R-03:** resolved. The phone no longer uses the closure, because the original fetch is back.
- **R-04:** resolved. `orphanedResumes` and `pumpHistoryLast1440Minutes` are live again. `includeDeviationsForTesting` stays (accepted).

Nit, not blocking: `onDiskContainer()` (`OrefCharacterizationTests.swift`) creates a fresh `oref-characterization-<UUID>.sqlite` in the simulator's tmp directory on every run and never removes it.

**Verdict: merge.** Phone dosing behaviour is unchanged from `1a9dba899` on every path I could exercise. The `OrefRun` / phone drift guard now catches all six mutations tried across the three rounds (the equivalent `reversed()` variant excluded). Not verified: device/in-vitro runs, the full Trio Tests suite at `3d55e4102`, Xcode 26.2.

---

## M2a review (Agent C: Trio fit, C-09, D-1/D-2/V2-28)

Branch `feat/tow-platform`, worktree `~/workspaces/Trio-tow-platform`, commits `657d4c082`, `2f6504a96`, `a8c59d2d8`, `58986d817`, `90e9ec76b` on `349f49523`. Read-only: nothing was built or run; this is a code and config read.

### What checks out

**Flag mechanics:**
- `TRIO_ON_WATCH = NO` is set in `Config.xcconfig` before the `ConfigOverride` includes, so an override wins.
- Config.xcconfig is the project-level base configuration (`project.pbxproj:6892, 6960`), so the watch targets inherit it.
- With the flag off, `$(TRIO_ON_WATCH_INFOPLIST_NO)` and `$(TRIO_ON_WATCH_ENTITLEMENTS_NO)` resolve to empty. With `GENERATE_INFOPLIST_FILE = YES` that leaves the generated plist and no entitlements, the same as baseline.
- The iOS target is untouched. The shim is `#if TRIO_ALGORITHM_PACKAGE || os(watchOS)`, so it's empty on iOS. The only iOS-visible change is the new `WatchLogEntry.Category.algorithm`.
- This satisfies V2-28 and D-1 for flag-off builds. D-2 is not affected, since the flag gates only the plist and entitlements.

**Module rename to `Trio`:**
- No `NSKeyedArchiver`, `NSClassFromString`, `@objc(...)` names, `String(reflecting:)` or `Bundle(for:)` anywhere in the watch sources, shared watch files or tests.
- The complication is its own module, imports only SwiftUI and WidgetKit, and keeps its `kind` string (`TrioWatchComplication.swift:84`).
- WatchConnectivity payloads are dictionaries. `WatchLogEntry` and the snapshot are plain JSON without type names.
- So there is no persisted-data or migration side effect. Only the test import changed, and it's the same rename #1749 makes, so it won't conflict.

**Logging route:**
- `algorithmLogSink` is set first thing in `TrioWatchApp.init` and maps all five levels 1:1 onto `WatchLogger` category `.algorithm`.
- On the phone it ingests as `Watch/Algorithm` (`WatchLogIngest.swift:144`). The watch's `os.Logger` per category comes from `allCases`, so the new category gets its logger.
- The levels and plain-sentence content follow CONTRIBUTING's logging rules (the algorithm's own lines already conform on the phone).

**CI with the flag off:**
- The algorithm-package job is unaffected (`os(watchOS)` is false on macOS).
- The `Trio Tests` build compiles the embedded watch app (the iOS target depends on it), so the 73 shared files get compiled in CI with the flag off. That's an inference, not an observed CI run.

### Findings

| ID | Severity | Where | Finding | Fix |
|---|---|---|---|---|
| M2aC-01 | major (flag-on only) | `fastlane/Fastfile:278-281`, `fastlane/testflight.md:197-203`, `Trio Watch App Extension/TrioOnWatch.entitlements` | Flag-on browser builds (fastlane `match` + `update_code_signing_settings` for "Trio Watch App") need **Time Sensitive Notifications** enabled on the `…watchkitapp` App ID, and the match appstore profile regenerated. `configure_bundle_id` for the watch only adds App Groups and HealthKit. The docs say time-sensitive is needed "only for the `Trio` identifier". Without the step, gym signing/export fails for a flag-on build. Flag-off is unaffected. `bluetooth-central` acceptance at upload is still D's experiment E1. | Document the extra portal step and certificate regeneration for flag-on in the status doc now; add it to `testflight.md` only when the flag is offered to builders. Keep the Fastfile unchanged for flag-off. |
| M2aC-02 | major (merge with M1) | watch target Sources phase | After merging `feat/trio-on-watch` @ `6014f8d10`, the watch target is missing every file M1 added to the package. I diffed the watch target's Sources phase against `Package.swift` and `Trio/Sources/APS/OpenAPSSwift` at `6014f8d10`, comparing basenames in C collation. Missing: `APS/OpenAPSSwift/OrefRun/OrefInputs.swift`, `OrefInputs+Mapping.swift`, `OrefInputs+Selection.swift`, `OrefInputs+TDD.swift`, `OrefRun.swift`; `Models/DosingMode.swift`, `Models/Preferences+DosingMode.swift`; `Helpers/TempTargetCalculations.swift`; `APS/Storage/ScheduledBasalInference.swift`. All are Foundation-only (verified imports). Nothing on the watch calls them yet, so the gap wouldn't show as a build error until M5. | Add these 9 files to the watch target in the merge commit (M2a's 73 + 9 = 82, matching the package). `DosingMode.swift` has 8 `String(localized:)` strings; English fallback is fine until a watch catalog exists. Add the C-09.1 membership-diff check (watch Sources vs the package list) as a test or script so the next package addition doesn't drift. |
| M2aC-03 | minor | `Config.xcconfig:20`, watch targets | "Flag-off = today's app" holds for the iOS app but not exactly for the watch app. It now requires watchOS 10.6, so watches on 10.0–10.5 must update first. It also carries 73 dead algorithm files in its binary, and the shim and sink are active regardless of the flag. All acceptable. | Say this in the status doc and the eventual PR ("watch now requires watchOS 10.6"). No code change. |
| M2aC-04 | minor | `AlgorithmLoggingShim.swift` `composed(_:_:_:)` vs `WatchLogger.message(_:error:)` (`WatchLogger.swift:134-138`) | Errors are formatted two ways on the watch. The shim uses `String(describing: error)` joined with ": ", while the watch logger uses "(domain code: localizedDescription)". The same error reads differently depending on the source. | Let the sink take `(level, category, message, description, error)` and format with `WatchLogger.message(_:error:)`, or reuse that format in `composed`. |
| M2aC-05 | minor | `WatchLogEntry.swift:45-49` | A phone build older than the watch build skips `algorithm` lines silently (an unknown category doesn't decode). It is safe, and the apps ship together, so it only matters during an update lag. | Accept. Optionally map unknown categories to `Legacy` instead of dropping them. |
| M2aC-06 | minor | CI | A flag-on build is never compiled in CI, so an entitlement or plist path typo in the `_YES` settings would only surface for a builder. | Add a build-only CI step (or an M7 checklist item) with `TRIO_ON_WATCH=YES` for the watch simulator. Ad-hoc signing ignores the entitlement. |
| M2aC-07 | minor | `Trio Watch App Extension/TrioOnWatch-Info.plist` | It uses `UIBackgroundModes` with `bluetooth-central`, as Loop does (B: `WatchApp/Info.plist:39-42`). That's correct, and the plist merges with the generated one. Whether TestFlight accepts it without `com.apple.developer.bluetooth-central-background` is still E1. | None now. Keep the flag off for users until E1 passes (V2-28). |

**Verdict: approve with changes.** The flag-off build is equivalent to today's except for the 10.6 minimum (M2aC-03). The module rename is free of side effects, and the log route is correct. M2aC-02 must be done in the M1+M2a merge, and M2aC-01 must be documented before anyone builds flag-on through the browser path. The rest are minor.

## M1b review

Branch `feat/tow-pure-calcs` @ `133d3a5d1` (8 commits on `3d55e4102`), worktree `~/workspaces/Trio-tow-pure-calcs`. Read against the M1b section of `implementation-status.md`, V2-21/23/24/16 and ADR-004/005/006. Same method as M1:
- a scratch copy (`scratchpad/m1-mut`), set to a given commit with `scratchpad/m1b-settree.sh <sha>`;
- a fresh iPhone 17 / iOS 27.2 simulator (deleted afterwards);
- `CI=true`; logs `scratchpad/m1b-*.log`.

The worktree was not touched.

### Provenance and regression

- **Goldens against the code before each change.** Every M1b golden was added once and never changed afterwards.

  | Goldens | Run at | Result |
  |---|---|---|
  | time of day (3 scenarios) | `d8a5375ec`, before the time-zone change | 3/3 passed |
  | bolus calculator (23 + 8 cases) | `4f986dc85`, before the extraction | 2/2 tests passed |
  | glucose alarms (10 sequences) | `137121345`, before the extraction | passed |

- **Clean HEAD:** 11 suites, 31 tests, all passed. The suites: M1's 17 production goldens, `OrefRun` goldens, micro-bolus, time-of-day, selection, stage, bolus, alarm and coordinator suites, 14 parity goldens, and wall-clock parity. **I found no change to phone behaviour:**
  - the phone binds `TimeZone.current` per stage, which equals the old unbound reads;
  - `jsDateString` now uses the same zone;
  - the calculator and alarm bodies are verbatim moves; `now`/`Date()` and `roundBolus` are passed at the same points;
  - the alarm action order is preserved (actions are applied in the order the old in-loop calls ran).

### Mutation tests on HEAD

| Mutation | Caught? |
|---|---|
| `basalFor` back to `Calendar.current` | yes (profile-getter test) |
| `carbsStart` ignores `timeZone` (`Calendar.current`) | **no** (all suites green) |
| `OrefRun.determine` ignores `microBolusAllowed` (always true) | yes (`OrefRunMicroBolusTests`) |
| fatty-meal factor dropped | yes (`fatty-meal`, `fatty-meal-and-super-bolus`) |
| super bolus only when the total is positive | yes (`negative-correction-with-super-bolus`) |
| stale loop at 16 min instead of 15 | yes (`loop-stale`) |
| glucose delta window 15 instead of 20 min | yes (`edge-inside`, `window-of-four`) |
| `currentBG < 54` → `<= 54` | yes (`glucose-at-54`) |
| snooze `until > now` → `>=` | yes (`per-alarm-snooze`) |
| urgent low no longer suppresses low | yes (2 sequences) |
| forecasted low no longer suppressed by the low family | yes (`forecasted-low`) |

### Findings

| ID | Sev | Where | Failure scenario | Recommended fix |
|---|---|---|---|---|
| M1b-01 | major (blocks M5; dormant on the phone, which passes `true`) | `DosingEngine.swift:757`, `DetermineBasalGenerator.swift:333`, `DetermineBasal+Helpers.swift:201` vs `trio-oref/lib/determine-basal/determine-basal.js:72-73, 678, 1286, 1403, 1429` | In oref, `microBolusAllowed = false` makes `enable_smb` return false ("SMB disabled (!microBolusAllowed)"). That `enableSMB = false` drives three other branches: the MDT top-of-hour neutral-temp cancel, and both "if in SMB mode, don't cancel SMB zero temp" guards, which instead set basal as temp. The currenttemp ≠ lastTemp cancel also runs only when micro boluses are allowed. The Swift port was written for `true` only: the flag gates `determineSMBDelivery` and nothing else. `makeSMBDosingDecision` ignores it, so `smbIsEnabled` stays true in `skipNeutralTempBasal`, `glucoseFallingFasterThanExpected` and `eventualOrForecastGlucoseLessThanMax`, and the lastTemp check runs regardless. Scenario on the watch's temp-only background wake (V2-21): eventual BG above min BG, delta below expected, a zero temp running. oref without SMB sets the scheduled basal as temp; the Swift path keeps SMB-mode behaviour and leaves the zero temp. The M1b test checks only the SMB branch, so this is not "oref's non-SMB path" as the status doc claims. | Pass `microBolusAllowed` into `makeSMBDosingDecision` (disabled, with oref's reason) and into the lastTemp check. Then record JS-parity goldens with `microBolusAllowed = false` from `trio-oref` for the scenarios that reach lines 1286/1403/1429/678. Until then, document that `false` is not oref-equivalent and keep it out of M5. |
| M1b-02 | major (M5; phone unaffected) | `ScheduledBasalInference.swift:83, 107` via `OrefInputs.tddInsulin` (`OrefInputs+TDD.swift:6`) | The time-zone binding has an escape on the TDD path. Scheduled-basal inference reads `Calendar.current` for profile boundaries and the minute of day, and `tddInsulin` is a shared entry point (C-03: the watch writes its own TDD rows) that binds nothing. A watch whose zone differs from the grant computes TDD on its own local day boundaries. TDD feeds DynISF (`currentTDD`, weighted average), so the watch's ISF drifts from the phone's. | Give `tddInsulin` a `timeZone:` (bind it, or pass a `Calendar` into `ScheduledBasalInference`). Add a test: same history and profile, bound zone ≠ process zone, result equal to the process-zone result shifted accordingly. |
| M1b-03 | minor | `OrefInputs+Selection.swift:28` | `carbsStart(now:timeZone:)` is the one zone-dependent window (23 or 25 h across DST), but the mutation that ignores the zone survives every suite. The carb window on the DST day in the grant zone is untested. | One `OrefInputsSelectionTests` case: `now` on the America/New_York spring-forward day, `timeZone` NY, expecting a 23 h window. It must differ from the same call with Europe/Berlin. |
| M1b-04 | minor (design) | `Date+MinutesFromMidnight.swift:31-43` | **Task-local or parameter?** The task-local keeps the generators' signatures and parity untouched, and it is read synchronously (no detached tasks or callbacks in the oref code; the `WallClock` offset cache is keyed by zone identifier, so mixed zones are safe). But its silent fallback to `TimeZone.current` is exactly how M1b-02 slipped through, and Trio's style is explicit parameters. The Tokyo test proves there is no escape inside `run` for the scenarios it covers. It doesn't cover helpers outside the stages. | **Keep the task-local inside the generators.** Require an explicit zone on every shared entry point: the stages (done), `tddInsulin`, `carbsStart` (done), and the alarm evaluation (`calendar: = .current` default at `GlucoseAlarmEvaluation.swift:66`; decide grant zone vs watch zone for day/night windows, ADR-004). Add one serialized escape-detector test that sets `NSTimeZone.default` to a far zone, runs `OrefRun.run` and `tddInsulin` bound to Europe/Berlin, and compares against the Berlin goldens. |
| M1b-05 | major (pre-existing, not M1b; safety) | `BolusCalculator.swift:103-109` | With IOB above max IOB, `min(max(x, 0), maxIOB − iob)` gives a **negative** recommendation (golden `iob-above-max-iob`: −1 U), and `TreatmentsStateModel` does not clamp it. The author found and documented this. The watch bolus (V2-24) would inherit it. | A separate, signed-off bug-fix PR on `dev`: clamp at 0 after the max-IOB limit, re-record that one golden. Required before M5 uses the calculator. |
| M1b-06 | minor (pre-existing, not M1b) | `TrioTests/BolusCalculatorTests/BolusCalculatorTests.swift:18`, `BolusSafetyTests/BolusSafetyValidatorTests.swift:8` (also `CalibrationsTests`, `PluginManagerTests`) | **The `malloc: pointer being freed was not allocated` crash.** I reproduced it three times: once in my mutation run, once on unmodified HEAD, and **once on M1's code `3d55e4102` with only `BolusCalculatorTests` and `BolusSafetyValidatorTests`** (`-test-iterations 8`). These suites build `TrioApp().resolver` per test instance, and Swift Testing runs them in parallel. The log shows 5 concurrent `TrioApp.init()` calls right before the double free. **M1b's code doesn't cause it.** More parallel suites only make it likelier. `FileStorageTests` is the known order-dependent flake. | Separate PR: one shared resolver (`static let`) per suite, or `.serialized` on these suites. |
| M1b-07 | minor | `GlucoseAlertCoordinator.swift:31-35, 48, 106`; `GlucoseAlarmCharacterizationTests.swift:268-281`; `BolusCalculationManager` `updateGlucoseVariables` | **The widened test seams are acceptable under `@testable`, with one exception: `launchedAt` is now a public mutable `var`.** Also, the coordinator-path golden builds a full `Assembler` graph per scenario, which means a real `FetchGlucoseManager` (timer, CGM source), `SettingsManager`, and subscriptions to `GlucoseAlertsStore.shared` and the broadcaster, all alive next to the host app's. A host-app `GlucoseAlertsStore` change can overwrite `alertsSnapshot` mid-test (flake risk), and it adds load to M1b-06. | Inject `launchedAt` through `init` (default `Date()`) and keep it `private`. Now that the pure golden exists, reduce the coordinator test to a thin wiring check with stubs, not the full assembly. |
| M1b-08 | minor (M2a) | `GlucoseAlertType.swift:2, 85`; `GlucoseAlarmEvaluation.swift` | **LoopKit coupling.** `GlucoseAlarmEvaluation` is Foundation-only, but its model types are not: `GlucoseAlertType` imports LoopKit for `defaultSoundFilename` → `AlarmSoundCatalog` → `DeviceAlertSeverity`. It also uses `Determination`, `ForecastedGlucoseEvaluator` and Trio's `debug`. Whether this blocks the watch depends on M2a/#1749 shipping LoopKit on watchOS. | Move `defaultSoundFilename` into a phone-only `GlucoseAlertType+Sound.swift`, and list the evaluator's closure of files in the watch target, as was done for the package. |
| M1b-09 | nit | `OrefInputs+Selection.swift:41`; `Date+MinutesFromMidnight.swift:19` | `pumpHistoryStart` still uses `Calendar.current`. That's harmless, because adding minutes is absolute time, but it is the only window not on the explicit-zone story. `WallClock`'s doc line still says the cache is "the one piece of state", and the task-local is a second implicit input. | Use a fixed `TimeInterval(minutes: 1440)` or a note. Update the doc line. |

**Verdict: merge after fixes for M1b-03 and M1b-04's escape-detector test (small); track M1b-01 and M1b-02 as M5 blockers.** If the maintainer wants M1b to deliver its stated scope ("oref's non-SMB path", "explicit time zone"), fix M1b-01 and M1b-02 here instead; then the verdict is not yet until they land. M1b-05 and M1b-06 are pre-existing and go to separate PRs on `dev`; M1b-05 (negative bolus) needs a maintainer decision before any watch bolus work. Phone behaviour: unchanged on everything I exercised.

Not verified: a full Trio Tests run at `133d3a5d1` (the TrioApp crash makes it nondeterministic), JS-side recording for M1b-01, a watch build, device runs, Xcode 26.2.

## M1b re-review

Delta `133d3a5d1..269a8a84b` (9 commits). Fresh iPhone 17 / iOS 27.2 simulator (deleted afterwards). Logs `scratchpad/m1b-rr-*.log`; worktrees untouched.

### Findings resolved

| ID | Status | Evidence |
|---|---|---|
| M1b-01 | resolved | Details below. |
| M1b-02 | resolved | `tddInsulin(timeZone:)` → `ScheduledBasalInference.segments(timeZone:)` / `delivery(timeZone:)`; the phone, Home and BasalChart pass `TimeZone.current`. |
| M1b-03 | resolved | The `carbsStart` zone mutation is now caught by the New York 23 h test. |
| M1b-04 | resolved, one caveat | Details below. |
| M1b-07 | resolved | `launchedAt` is a `private let` injected through `init`. |
| M1b-08 | resolved | The only LoopKit import left in `Models/GlucoseAlerts` is the phone-only `DeviceAlertSeverity+InterruptionLevel.swift`. I typechecked `GlucoseAlarmEvaluation`, `ForecastedGlucoseEvaluator`, every other `Models/GlucoseAlerts` file and `BolusCalculator.swift`, together with the AlgorithmPackage source list, for `arm64-apple-watchos10.6-simulator` (`-D TRIO_ALGORITHM_PACKAGE`): 0 errors. |
| M1b-09 | resolved | `pumpHistoryStart` is a fixed 1440 min; the `WallClock` doc line is updated. |

**M1b-01: `microBolusAllowed`.**
- **The change matches trio-oref.** In `isProfileSmbEnabled` the check sits after scheduled-off and before the high-temp-target check, as in `enable_smb`, so the downstream `smbIsEnabled` uses now equal JS `microBolusAllowed && enableSMB` (lines 1209/1286/1403/1429/1489). The currenttemp ≠ lastTemp cancel is gated (JS 678). The remaining `microBolusAllowed` check in `determineSMBDelivery` is now redundant but harmless.
- **The JS harness is faithful.**
  - The `require` resolver and the `lodash/endsWith` shim (2-argument form, the only one `round-basal.js` uses) are correct.
  - `currentTime` as an ISO string is accepted by JS (`new Date(currentTime)`).
  - JS gets the same post-stage Swift inputs: profile, IOB, meal, autosens, custom variables, clamped preferences, the determination glucose window. JS computes glucose status itself with `glucose-get-last.js`, an independent check.
  - I re-ran `TZ=Europe/Berlin jsc …` on all 10 recorded inputs: byte-identical to the committed `js-determination-*.json`.
  - Small gap: JS gets `outputs.profile` without the injected `supportedBasalRates`/`suspendOnly`. That's harmless for these rates, but say so in the suite doc.
- **Mutations caught.** Dropping the `enable_smb` gate fails `DetermineBasalEnableSmbTests` and 3 JS scenarios. Dropping the lastTemp gate fails `temp-mismatch`/false.
- **`true` is byte-identical.** Every `smb-allowed` JS comparison passes; M1's production goldens and the 14 parity goldens pass (but see the iob time-of-day issue below).

**M1b-04: the escape test is strong but opt-in.** `ProcessTimeZoneEscapeTests` (process zone Pacific/Kiritimati, bound Europe/Berlin) passes on HEAD, and it catches three escape mutations separately:
- the `WallClock` offset reading `TimeZone.current` (golden check);
- `ScheduledBasalInference` back to `Calendar.current` (TDD expectation);
- `isEligible` without the zone (alarm expectation).

No other watch-reachable `Calendar.current`/`TimeZone.current` read remains in the oref, TDD, alarm or bolus closure (`BGTargets.currentTarget` / `TherapySettingsUtil.parseTime` are reached only from the phone bolus manager). The caveat: it runs only with `TRIO_TZ_ESCAPE=1`, so CI never exercises it. Add a CI step or test plan that runs it alone.

### New findings

| ID | Sev | Where | Failure scenario | Recommended fix |
|---|---|---|---|---|
| R2-01 | **major (pre-existing from M1, blocks CI for M1 and M1b)** | `OrefCharacterizationScenarios.makeClock` (`Date()`-based clock); goldens `*/iob.json` | **The M1 characterization goldens fail depending on the time of day.** The production path must use `Date()`, so the scenario clock is "now". The IOB projection runs about 4 h ahead, and once that horizon crosses local midnight, the temp-basal split at the day boundary changes the last iob points (`netbasalinsulin` −4.8 → −4.85, `basaliob` ±0.001…0.05). Observed on **M1's own code `3d55e4102`**: at 20:05 Berlin, `autosens-8h-24h-differ`; at 20:08, 14 scenarios. HEAD behaved the same at the same minutes, so M1b is not the cause. The scheme pins Europe/Berlin, so every CI or local run between about 20:00 and 24:00 Berlin fails. My earlier "merge" verdicts for M1 were based on runs at about 19:15 and missed this. | Inject a clock into `OpenAPS` the way M1 injected the Core Data context (a `now: () -> Date` provider, default `Date()`, behaviour-neutral). Then pin the characterization clock to a fixed morning instant, and re-record from the original sources with the same provenance check. A stop-gap of skipping when the horizon crosses midnight is weaker; don't use it. |
| R2-02 | major (pre-existing port difference, not M1b; needs sign-off) | `Meal/MealTotal.swift:177-202` vs `trio-oref/lib/meal/total.js` `mealCOB: Math.round(mealCOB)` | **The masked `COB:` value hides a real port difference, but not a `microBolusAllowed` one.** JS meal rounds `mealCOB` to an integer before determine-basal; the Swift meal passes it unrounded (17.086), and Swift determine-basal predicts with it. I fed JS the rounded COB (as JS-era Trio did) for all 10 inputs. Doses stayed equal in all 10, but minPredBG, minGuardBG and eventual BG moved by 1–2 mg/dL and `insulinReq` by 0.02 U. At a rounding or threshold edge, that changes an SMB or temp. Within the M1b test, masking is acceptable, because JS and Swift get the same unrounded COB, so the comparison isolates the flag. | Raise it with the maintainer: either round `mealCOB` in `MealTotal` (a behaviour change, so re-record the parity and characterization goldens with sign-off), or document it as intended. Keep the mask, with a comment pointing at this decision. |

**Verdict: not yet.** M1b-01..09 are resolved. The blocker is R2-01, which comes from M1 and makes both M1 and M1b CI fail every evening (Berlin time). Fix it first with an injected clock and re-recorded goldens; then M1b is merge. R2-02 goes to the maintainer as a separate decision and does not block M1b.

## M1b final check

Delta `269a8a84b..e87909b0d` (5 commits). Fresh iPhone 17 / iOS 27.2 simulator (deleted afterwards). Logs `scratchpad/m1b-final-*.log`; worktree untouched.

**Results:**
- **Production behaviour is identical.**
  - The only production construction sites pass no clock: `APSManager.swift:199` builds `OpenAPS(...)`, and `StorageAssembly` builds `BaseTDDStorage(resolver:)` / `BaseGlucoseStorage(resolver:)` / `BaseCarbsStorage(resolver:)`. So `now` defaults to `Date.init`.
  - Each former `Date()` became one `now()` call at the same point. That includes the two separate reads in `autosense` (clock and timestamp), and the pump-history, 48 h orphan, last-temp-target and last-override predicates.
  - The new `lastActiveTempTarget(now:)` / `lastActiveOverride(now:)` use the same expression as `Date.oneDayAgo` (`Calendar.current` −1 day), and the no-argument forms still exist for the other callers.
- **Every time read on the characterized algorithm path goes through the seam, verified empirically.** The scenario clock is now 2026-06-15 07:40:10 CEST, five months before the real date. Any `Date()` left on the path would make glucose and pump history months stale and break every golden; all pass. The remaining `Date()` reads in these files are outside the oref input path or only fallbacks:
  - fallbacks: the `?? Date()` for nil row dates and the simulation's `carbsDate ?? Date()`;
  - the stored forecast row date;
  - `processAndSave`;
  - TDD row creation in `calculateTDD` / `calculateWeightedAverage` (TDD rows are seeded in the goldens; the watch passes its own `now`).
- **Goldens are unchanged** (no golden file in the diff). At **20:50 CET**, inside the window that failed before, 17 suites with 104 tests all passed: production, `OrefRun`, micro-bolus and its JS parity, time-of-day, selection, stage, bolus, alarm, coordinator, parity, wall-clock parity, enable-SMB, scheduled-basal inference, pump-event finalization, DynISF enable, and pump-event predicates. The escape test, run alone with `TEST_RUNNER_TRIO_TZ_ESCAPE=1`, passed.
- **The CI step is sane.** It is a separate `test-without-building` step after "Run tests", on the same `$DESTINATION` and DerivedData, with `pipefail`, its own log, and `TEST_RUNNER_TRIO_TZ_ESCAPE=1`. The main run (parallel testing off) skips the suite because the variable is unset. Nits:
  - it is skipped when the main tests fail (default `if: success()`), which is fine;
  - it adds no `.timings` line;
  - the outcome-report step doesn't read `xcodebuild-tz-escape.log`, so a failure shows only as a red step.
- **R2-02:** accepted by the maintainer as documented; the JS parity suite notes the profile and the COB mask (`53eb9837e`).

**Verdict: merge.**

## M3 safety re-review (Agent E)

Branch `feat/tow-loan-core` `d46918afb..f366e84ad` (`99f51bdf7`, `86c0cea34`, `f366e84ad`). Re-read: `WatchLoan.swift`, `WatchLoanState.swift`, `WatchLoanMessage.swift`, `LoanWorld.swift`, `WatchLoanInvariantTests.swift`, and the decision table (P1–P44, W1–W37, T1–T6).

Basis: code reading only. I did not build or run the tests. I relied on the author's report that the search and the `TRIO_STRESS` two-Start variant passed.

### M3E-01 to M3E-10

| ID | Status | Evidence | Note |
|---|---|---|---|
| M3E-01 | **Resolved** | `WatchLoan.swift:458-479` (W26, W36, W37) | A kit that holds is never taken again. Re-adopt happens only when the kit never adopted and the phone confirms the same epoch; otherwise the watch stops with `unconfirmed`. If `kitHasControl` reads stale (async kit persistence, F4/M2b-03), the bounded adopt sees the watch's own later session as foreign and stops. That fails closed and is alarmed. |
| M3E-02 | **Resolved** | `:552-561`, `:411-413`, `:438-439`, `:189-194` | Every stop path releases the pod. Only `stop(released: true)`, sent after the release result, clears the phone's window. |
| M3E-03 | **Resolved** | `:245-252` (P43) | See M3R-03 for the window it opens. |
| M3E-04 | **Resolved** | `WatchLoanState.swift:26`; `:216`, `:274` | `.podLifetime` when the peer is unknown. Whether the audit is correct is M4's test. |
| M3E-05 | **Resolved** | `:77`, `:235`, `:283`, `:370` | `.takeControl(supersedingUntil:)` is used everywhere. The C-3 redo and repeated taps pass the persisted window. `keepCommanding(until:)` carries it too. |
| M3E-06 | **Resolved** | Int64 in state and on the wire | – |
| M3E-07 | **Resolved** | `WatchLoanState.swift:21-24` | `takenAt <= now < until`. |
| M3E-08 | **Resolved** | `:505-508` | A duplicate grant in `returning` or `stopped` is answered with `status`. |
| M3E-09 | **Resolved** | `WatchLoanMessage.swift` `HandBackProbe` | `handBack` and `handBackAck` decode across versions. Records still don't (acceptable: Take Back plus the audit recover). |
| M3E-10 | **Resolved** | `WatchLoan.swift:17-29`, `:559` | `superseded` disarms after the persist and the alert. No silent pair results: a phone in `takingBack` keeps `phoneNotLooping` armed. |

### The adopt race and its fix

The race was real. W4 used to emit a take, and per M2b-05 a take absorbs whatever session the phone opened in between. `.adoptControl`, which resyncs only to the session the lender released and treats anything newer as foreign, is the right rule. The model catches the race (`adoptRacesTakeBack`), and the machine side is correct (W4, W36).

It now rests on two things outside M3, and both block **M5**, not M3:
- **Bounded adopt in the kit (M2b/A2).** It does not exist yet. The kit's existing EAP-SQN resync handling would otherwise absorb the newer session. Specify it as: the adopted export's `eapSeq` is the only counter value a resync may land on, and any higher counter means foreign.
- **Host mapping.** A refused adopt must reach the machine as `.foreignPodSession`, which leads to `stopped` and a release. It must not arrive as `takeControlResult(false)`, which only alerts and leaves the watch `holding` with a refused kit. `LoanWorld` does it right (`completeWatch` emits `foreignPodSession` first); M5's host must match and test it.

### Is the proof basis acceptable?

**Yes, for the decision logic, with the limits stated.**
- **Looser kit model.** The model lets any take lift a refusal, keeps the window through a release, and makes every foreign session visible at the next session. On each of these axes it is at least as permissive as the real kit as reviewed in M2b, so a pass carries over.
- **What the model can't see.** It does not cover the kit leaks that are *more* permissive than the model:
  - M2b-02: a restored link sends on saved keys without a handshake, so no resync is seen.
  - M2b-06: a stale counter that ran ahead is accepted for one full session.

  These belong to M2b and must be closed (M2b-02) or covered by the audit (M2b-06) before M5. The M3 proof assumes them away.
- **Epoch-2 bound with multiset queues.**
  - The machine compares epochs only relatively (`>`, `==`, `max+1`).
  - Request IDs and epoch-tagged results stop cross-loan confusion.
  - Multisets are sound because delivery is already arbitrary-order and lossy.

  So epoch 3 is mostly a repetition. What the bound does leave out is interference from late messages of loan *n* during loan *n+1*. Cover that with deterministic tests (M3R-01). Run the `TRIO_STRESS` two-Start search in the M7 gate.

### New findings

| ID | Sev | Where | Scenario | Fix |
|---|---|---|---|---|
| M3R-01 | minor | `WatchLoanInvariantTests` bound | The epoch-2 bound never reaches loan 2 after Take Back 1 with loan-1 messages still in flight: a late `stop(released: true)`, `handBack`, `holding`/`records`, or a revoke. The code guards each one (epoch match or request ID), but no test proves it. | Add deterministic flow tests for each late loan-1 message during loan 2. Run the `TRIO_STRESS` search in the M7 gate. |
| M3R-02 | minor | `WatchLoanMessage.swift:50-65` | `released` is a non-optional `Bool` in the "never changes" stop format. A stop without the key fails to decode as a stop and then fails the version probe, so it is dropped as `malformed`. No shipped build sends that today. But the first future change that omits the field silently drops stop and revoke, which is the V2-10 fail-open. | Decode with `decodeIfPresent ?? false`. Add a test that `{"stop":{"kind":"revoke","epoch":N}}` decodes. Add a comment freezing the format. |
| M3R-03 | minor | `:245-252` | "Use the pod on this iPhone" opens a 6 h superseding window for an **unknown** peer (`epoch: nil`). The phone then keeps commanding through that peer's sessions, with an audit and an alert each time. That is safe only if the peer refuses (R-4), which the phone can't know for an unknown device. Every session books the excess, so it is bounded but repeated. | If `lastLoan` is nil or its window is closed, take with `supersedingUntil: nil`, so a further foreign session refuses again and the user can re-confirm. Keep the window only when the last loan was a watch loan. |
| M3R-04 | minor | `LoanWorld.swift:189-193`; kit | The model keeps the kit window through a release and through a later nil take. In the real kit, a window left over from Take Back 1 would then survive lend 2 and End 2. The host verdict still refuses (the machine's `lastLoan` has no window), but the kit commands within that one session before the verdict. | M2b/M4: clear the kit's superseding window on `releaseControl()`. Then a nil take after End starts without a window. |
| M3R-05 | minor | Invariant search | `.unreadable`, which leads to a Unix-seconds epoch and a pod-lifetime audit, is reachable only in decision tests, not in the search. | Add a "state file corrupted" event to the search (the phone loads `.unreadable` at any step), or add flow tests for corruption in `lending`, `lent` and `takingBack`. |

No act-before-persist, epoch-reuse or silent-stop problem found in the changed rows.

### Verdict

**Merge M3.** M3E-01 to M3E-10 are resolved, and the adopt race is fixed on the machine side. M3R-01 to M3R-05 are minor and can land in M4 or M5.

**Gate for M5** (it depends on these): the bounded adopt in the kit; the host mapping a refused adopt to `foreignPodSession`; and M2b-02 fixed. Until then the two-commander proof covers the decision logic only, not the kit.

## Bounded adopt review

Reviewer: the same independent agent. Delta only: OmnipodKit `trio-on-watch` `1450b24..0f10883` ("Bound an adopt to the session the exporter released"), Trio `feat/tow-kits-adopt` `4426ecbb6` (pin) and `fcaf2291c` (docs). The commit is signed and the submodule is clean. Line numbers are at `0f10883`.

### Runs

Fresh iPhone 17 / iOS 27.2 simulator (deleted afterwards), scratch copy of OmnipodKit, LoopKit and RileyLinkKit from the `feat/tow-kits-adopt` worktree, `-only-testing:OmniTests/DeviceHandoffTests`. Logs `ad-*.log` and `scripts/mutate3.py` are in `/private/tmp/claude-501/-Users-dnzxy-workspaces-Trio/3f8cbd66-3ec5-4539-8f2f-f9e5df9ae9dc/scratchpad/m2b-review`.

| Run | Result |
|---|---|
| base | 50/50 pass |
| bound check removed from `handshakeResynced` | 5 failures |
| bound not spent in `sessionEstablished` | 1 failure |
| `expectSessionResync` doesn't clear the bound | **survives** |
| export never carries the bound | 8 failures |
| bound not persisted (`rawValue`) | 8 failures |
| **review test: one handshake attempt by the adopter lost before it reached the pod** | **fails at `0f10883`**: the adopt absorbs the phone's Take Back session (BA-01) |
| BA-01 fix (below) plus the review test | 51/51 pass |

### Checked, holds

- **Export.** `sharedConfiguration` always sets `releasedEapSqn` explicitly: the SQN when released, nil when not. A stale bound in the exporter's own state can't leak, and the exporter keeps none (tested). The adopter gets it through `sharedFacts` → `adopted()`, and `rawValue` persists it, so an adopt relaunched before its first session keeps it (tested). `localState` doesn't carry it.
- **Repeated adopt** of an old configuration after the bound was spent (against V2-4) resets the counter to the bound. The resync it causes is at or below `AcceptedEapSqn`, so it is classified as this device's own and nobody is refused.
- **The phone's own resync after its take** never meets a bound: only adopters carry one, and the exporter's own state carries none.
- **Offline start** (export without a release) carries no bound and is unchanged (tested).
- **Host signal.** A refused adopt shows `refusesSessions` together with `foreignSessionDetectedAt`. A take that fails only for reach shows neither. The caveat: a false refusal (BA-02) looks the same as a refused adopt.

### Findings

| ID | Sev | Where | Failure scenario | Fix |
|---|---|---|---|---|
| BA-01 | **major** | `OmniPumpManager+DeviceHandoff.swift:166-168` (`nextHandshakeSqn`), `:178-180` | The bound is checked only when the pod answers with a resync. Each handshake attempt increments the adopter's counter, including attempts that never reach the pod (a link drop mid-EAP). Sequence: the watch adopts at bound E, its first attempt (E+1) is lost, the phone's Take Back handshakes E+1 and is accepted, then the watch sends E+2 > E+1. **The pod accepts it, with no resync**, so the bound never fires. The watch's session runs and spends the bound, and both controllers command. This is exactly the flaky-watch-link situation that makes a user tap Take Back. Reproduced with the review test above. | While `releasedEapSqn` is set, every handshake sends `releasedEapSqn + 1` (`nextHandshakeSqn` returns it and sets `eapSeq`). Any session since the release, including the phone's E+1, then makes the adopter's E+1 resync beyond the bound, so it refuses. Also clear the bound in `handshakeResynced`'s `AcceptedEapSqn` branch, so a repeated adopt doesn't loop on the same SQN. Tried in scratch: the review test and all 50 existing tests pass. Add the review test to the suite. |
| BA-02 | minor | same | Trade-off of BA-01's fix: suppose the adopter's E+1 reached the pod and was accepted but the reply was lost. Resending E+1 then resyncs beyond the bound, and the legit adopter refuses, a false lockout that fails closed. The pod can't tell this apart from the phone's own E+1, so failing closed is the right default. Without the fix, the same loss leaves the adopt working but keeps BA-01 open. | Document it in the proposal's limits. The host maps it to the same "pod used by another device" path, and the user takes back or re-lends. |
| BA-03 | minor | `OmniPumpManager+DeviceHandoff.swift:71-74` | The bound is read from the manager's state without `podStateLock`. If the export is taken while a session that started before the release is still handshaking (`releaseConnectionForLoan` waits for a command under way), the bound can be read before that handshake's increment. It is then one too low, and the legit adopt refuses (fails closed). V2-2's drain makes this unlikely. Similarly, an export taken *before* the release carries no bound at all, which reopens the race. | Read the SQN under `podStateLock` in `exportConfiguration` (it waits out a session, like `markSharedWithAnotherController`). Host contract: export only after `releaseControl()` has succeeded, never from a grant built earlier. |
| BA-04 | nit | `:273`; the docs' "cleared by any take" | Clearing the bound in `expectSessionResync` has no test (its mutation survives). It also runs only on a dated take or on a plain take after a release, not on "any take". | Add one assertion (an adopter with a bound, released and then taken plainly, has no bound), and correct the wording. |

**Verdict: fix BA-01 before M5 relies on the bounded adopt.** As written, the bound stops the race only when the adopter's first handshake attempt reaches the pod. BA-03's host-contract line and lock read are cheap and should go in now. BA-02 and BA-04 are doc and test changes. Everything else in the delta holds.

Not verified: hardware and pod-side behaviour, as before. In particular, whether a mid-EAP drop can leave the pod's counter unchanged while ours moved; BA-01 assumes it can, which is the same assumption as M2b-06. The full OmniTests and Trio builds (I trusted the author's BA3 to BA5).

## Bounded adopt re-review

Reviewer: the same independent agent. Delta only: OmnipodKit `0f10883..c23daca`, Trio `feat/tow-kits-adopt` `8b464d15c` (pin) and `4f1af1fbe` (docs). The commit is signed and the submodule is clean.

### Runs

Fresh iPhone 17 / iOS 27.2 simulator (deleted afterwards), scratch copy, `-only-testing:OmniTests/DeviceHandoffTests`. Logs `ar-*.log` are in `/private/tmp/claude-501/-Users-dnzxy-workspaces-Trio/3f8cbd66-3ec5-4539-8f2f-f9e5df9ae9dc/scratchpad/m2b-review`.

- **Baseline:** 53/53 pass.
- **Mutations:** the bound pin reverted (BA-01): 3 failures. The own-counter branch keeps the bound: 1. The bound check removed: 3. Not spent: 1. A take keeps it: 1 (BA-04 is now covered). The export never carries it: 12. Not persisted: 12. The export's `waitOutSession()` removed: **survives**, and the status doc already lists it as read-only.
- **Three review-only scenario tests**, added in scratch only; all pass at `c23daca`:
  - The adopter's E+1 is accepted with its reply lost, then the phone takes back: the adopter refuses, and the phone commands alone.
  - The same lost reply with no take: the adopter refuses (BA-02, fails closed, as documented).
  - A repeated adopt of the same configuration after three sessions runs: `AcceptedEapSqn` explains the resync and spends the bound.

### Bypass search (by reading plus the runs above)

- **Repeated E+1 attempts when the phone's Take Back also used E+1.** Every adopter attempt sends E+1 while the bound is set. Once the pod holds E+1 or more from anyone, the adopter's E+1 gets a resync at or beyond E+1, which is past the bound, so it refuses. Whether the phone's or the adopter's E+1 landed first makes no difference to the adopter. If the adopter's landed first and its reply arrived, that is the documented "first after the take" limit: one session, then the bound is spent and the next contact refuses as for any stale controller.
- **A resync at or below the bound can't happen** while the adopter sends E+1, because a resync means the pod is at E+1 or more. The "expected" branch and a second-resync loop are therefore unreachable.
- **Relaunch mid-adopt.** The bound and the pinned SQN persist. If the first session was accepted but the host didn't save the cleared bound, `AcceptedEapSqn` (saved separately) explains the resync, spends the bound and lets the next attempt increment (test `testABoundedAdoptRelaunchedAfterItsFirstSessionRunsAgain`). If both were lost, the adopter refuses: fail closed, as BA-02.
- **`AcceptedEapSqn` can't hide the phone's session.** The adopter's mark is either from this adopt or from an earlier lend, and in both cases it is below every SQN the phone's Take Back can produce, so the own-counter branch never swallows a foreign resync. This is the same monotonic argument as in the M2b re-review.
- **Superseding scope.** An adopter starts without a scope (`sharedFacts`), and a dated take clears the bound, so the two never combine. Outside a scope, a resync beyond the bound refuses.
- **Export.** `waitOutSession()` is an empty lock round trip before the read, so a session already holding the lock has finished. A session that starts after it can't dial (the release sets `loanReleased`, and `runSession` refuses while released), so the bound can't go stale. A host that exports on the main thread while a session finishes stalls the UI for that session; the doc comment says the call waits.

### Remaining

| ID | Sev | Note |
|---|---|---|
| BB-01 | nit | The `waitOutSession()` call has no test (its mutation survives). That's acceptable as read-only. A test would need a contended `podStateLock`, which isn't worth building. |
| BB-02 | nit | A plain take after the adopter's own release clears the bound and expects a resync, so it runs through any session since. These are #177's hand-back semantics, and a v1 watch never re-takes after a release without a new grant. Keep that line in the host contract. |

**Verdict: BA-01 to BA-04 are resolved. I found no remaining bypass or new owner lockout beyond the documented, fail-closed BA-02. Ship the bounded adopt to M5.**

Not verified: hardware and pod-side behaviour (whether a lost attempt can leave the pod's counter unchanged); the full OmniTests and Trio builds (I trusted the author's BB3 to BB5).

---

## M4 architecture/code review (Agent C: Trio fit and code quality)

Branch `feat/tow-phone`, worktree `~/workspaces/Trio-tow-phone`, commits `140a5eb51`, `651e747f4`, `dd301b2ba`, reviewed against the merge base `e7a865ef4`. Read-only: nothing was built or run, and the verdict rests on code reading.

### What fits

**DI and lifecycle:**
- `WatchLoanCoordinator` is registered in `ServiceAssembly` in container scope. The assembler default is `.container` as well (`TrioApp.swift:54`), so the host's late `resolve(WatchManager.self)` returns the one `BaseWatchManager`.
- The coordinator is started after `NotLoopingMonitor`, so the relaunch can re-assert which loop alarms are armed.
- There is no Swinject cycle: the host resolves the transport lazily.
- Making the coordinator an actor with a serial event queue fits Trio's existing concurrency, which uses `LoopGuard` as an actor plus `processQueue`.

**One WCSession:** `BaseWatchManager` conforms to `WatchLoanTransport`, so there is no second session. Loan payloads are recognised by `WatchLoanWireKey` and forwarded before any existing handling, so existing watch messages take the unchanged path.

**Kit access:** `WatchLoanPumpAdapter` is the only file that imports OmnipodKit for the loan. `DeviceDataManager` only reads `foreignSessionDetectedAt` through it.

**Hooks are small:**
- `APSManager.awaitPumpIdle` (+ `LoopGuard` made internal);
- `DeviceDataManager`: `syncDeliveryLimits` extracted verbatim, plus `resyncPumpAfterTakeBack`, `awaitPumpEventStorage` and the foreign-session publisher;
- `PumpHistoryStorage`: `getPumpHistory(since:)`, `replaceTaggedBolus`;
- `NotLoopingMonitor.setArmed`;
- `OpenAPS.orefInputs`.

**No loan means no change:**
- The new protocol members are only called by the coordinator.
- `syncDeliveryLimits` is the same code, moved.
- `pumpManagerDidUpdateState` adds an adapter read that is nil for non-Omnipod pumps. For Omnipod it writes UserDefaults only when the date changes.
- `NotLoopingMonitor`: `armedAt` is set at init, which is the same moment as the monitor's own `lastLoopDate` default. Every loop date it receives later is newer. So `max(lastLoopDate, armedAt)` equals the baseline `lastLoopDate`, and `setArmed(true)` is a no-op while already armed.
- Relaunch with no state file goes to `home(0)`.
- With the flag off, `startRefusal` returns `.featureOff`, while the gate and Take Back stay compiled in, which satisfies D-2.
- `TRIO_ON_WATCH` reaches Swift through the project-level `$(inherited)` chain.

**Merges reuse existing stores:** `storePumpEvents(replacePendingEvents: false)`, `storeCarbs`, `storeGlucose`, `CarbEntryMutationService.deleteMeal`, all with id or time-window dedupe. This addresses C-08.

**Wire format:**
- The snapshot is compact JSON, using Trio's ISO-8601 date format, compressed with lzfse, with schema, protocol, app build and per-kit state versions inside.
- Validation is exact-match. That's fine for v1, because both apps ship together.

**Tests:** 49 tests: coordinator 24, audit 13, integration 7, snapshot 5.
- The coordinator tests drive the production `WatchLoanCoordinator` and the production `WatchLoanPumpAdapter` over `LoanPumpDouble`, with a fake host.
- The integration tests use the real stores.
- The one `withKnownIssue` (`WatchLoanCoordinatorTests.swift:573`) is legitimate: it proves the double records an issue when a released pump is commanded.

**Conventions:** logging categories and levels follow the rules, there are no `print` calls, no fleet document IDs in production code, and user-facing strings use `String(localized:)`.

### Findings

| ID | Severity | Where | Finding | Fix |
|---|---|---|---|---|
| M4C-01 | major (before M5) | `OpenAPS.swift:495-556` (`orefInputs`) | The pure steps are shared, so there's no second algorithm. But `orefInputs` is a fourth copy of the gathering that `createProfiles`, `autosense` and `determineBasal` each still do, and nothing proves it gathers the same thing. No test runs `OrefRun.run(orefInputs(…))` against the phone's own path on the same store and clock. A divergence would mean the watch starts from different inputs than the phone just used (glucose window, autosens freshness, TDD rows, active adjustments). | Preferred: let the phone path itself gather through `orefInputs` and run `OrefRun.run`, so there is one gather, and re-run M1's characterization goldens. Minimum: an equivalence test that seeds an in-memory store with a characterization scenario and compares the phone's `determineBasal` determination, profile and autosens with `OrefRun.run(orefInputs(...))`, both pinned to the same clock. |
| M4C-02 | minor | `WatchLoanCoordinator.swift:153-212, 452-503` | Actor reentrancy. `receive` and `receiveRecords` run while `drain` is suspended inside an effect. `audit()` holds a copy of the ledger entry across awaits while `recomputeAudits` can write the same entry, so the last writer wins on `bookedUnits` and `notedShortfall`. The result can be a repeated notice. Insulin isn't double-booked, because `replaceTaggedBolus` replaces by id. | Feed record batches through the event queue as an event, or re-read the entry from `ledger` after each await before saving. |
| M4C-03 | minor | `WatchLoanCoordinator.swift:162-166` | A message id is marked seen and persisted before its event is handled. A crash between the two drops the watch's resend as a duplicate. The phone stays in its previous state, so this is fail-closed, and the grant-unconfirmed alert and Take Back recover. | Mark it seen after the resulting `.persist`, or document that this is accepted. |
| M4C-04 | minor | `APSManager.swift` `awaitPumpIdle`, `WatchLoanCoordinator.swift:572-585` | The bolus wait polls every 0.5 s with no cancellation. `finishes(within:)` doesn't cancel the work task on timeout, so a stuck `bolusState` leaves a polling task running for the rest of the process. | Cancel the work task on timeout and loop `while !Task.isCancelled`. Or wait on the existing `deviceDataManager.bolusTrigger` (`.values.first { $0 == .noBolus }`) instead of polling. |
| M4C-05 | minor | `AppleWatchManager.swift` (+53 lines) | Conflict surface with #1598, which rewrites `didReceiveMessage` and adds `didReceiveMessage(_:replyHandler:)`. #1723 and #1775 touch this file lightly. | Move `forwardLoanPayload` and the `WatchLoanTransport` extension into `AppleWatchManager+WatchLoan.swift`. The main file then keeps 1 property and 2 early-return lines. When #1598 lands, add the same loan-key check to the reply-handler variant. #1723's queued complication transfers are safe, because cancellation is filtered by loan keys. |
| M4C-06 | minor | `WatchLoanSnapshot.swift:7`, `WatchLoanCoordinator.swift:425-430` | The 65,536-byte cap counts only the two data blobs, not the dictionary encoding overhead that `sendMessage` adds. | Leave headroom (for example 60,000), and have the "full day fits" test assert that margin. |
| M4C-07 | minor | `WatchLoanPhoneHost.swift:310-313, 339-361` | `String(format: String(localized: "… %d min …"))` hides the variable from the catalog and has no plural variants. `String(localized: "U")` builds the insulin unit by hand, against the "no hard-coded U" rule. | Use interpolated `String(localized: "No update from Trio on Watch for \(minutes) min. …")`, and Trio's existing insulin formatter for amounts. |
| M4C-08 | minor | `WatchLoanPhoneHost.swift:96-101, 164-169` | Two ad-hoc `OpenAPS(...)` instances are built per Start. | One lazily built instance in the host, or get it from `APSManager`. |
| M4C-09 | minor | tests | Missing: <br>- flag-off `startRefusal == .featureOff`; <br>- a `NotLoopingMonitor` test showing that unchanged loop dates fire the same steps as baseline (the equivalence argued above); <br>- a routing test showing a non-loan watch message isn't swallowed by the new early return. | Add these three small tests. |

**Ponytail lens:**
- The size is proportionate: 620 lines of coordinator, 458 of host, 134 of adapter.
- The two protocols (`WatchLoanTransport`, `WatchLoanPhoneHost`) are what make the coordinator testable without a WCSession or Core Data. Keep them.
- `KitScreenToken`'s static counter is the simplest correct way to answer "is a kit screen up?" from outside SwiftUI.

**Verdict: approve with changes.** It fits Trio's architecture, there is no second session, existing paths are unchanged when there's no loan, and the tests exercise production code. M4C-01 must be resolved before M5 relies on the snapshot's inputs. The rest are minor and can go in before M7.

## M4 safety review (Agent E)

Branch `feat/tow-phone` (`140a5eb51`, `651e747f4`, `dd301b2ba` on `e7a865ef4`), worktree `~/workspaces/Trio-tow-phone`.

Reviewed:
- `WatchLoanAudit.swift`, `WatchLoanRecords.swift`, `WatchLoanSnapshot.swift`;
- `WatchLoanPumpAdapter.swift`, `WatchLoanCoordinator.swift`, `WatchLoanPhoneHost.swift`;
- the hooks in `APSManager`, `DeviceDataManager`, `NotLoopingMonitor` and `PumpHistoryStorage`;
- the take variants in OmnipodKit `OmniPumpManager+DeviceHandoff.swift:318-392`.

Basis: code reading only. I did not build or run the tests.

### Conditions and host contract

| Item | Status | Evidence |
|---|---|---|
| Read the delivered total before the release | Met | Lend effects run `refreshDeliveredUnits` before `releaseControl`; `WatchLoanCoordinator.swift:290-315` |
| `isControlReleased` checked right after the release | Met | `WatchLoanPumpAdapter.swift:76-79` |
| Export only after the release | Met | `exportedConfiguration` throws unless released (`:105-112`); `sendGrant` checks `isReleased` (`Coordinator:413`) |
| Only a dated take on Take Back | Met | `Coordinator:324` maps a window to `takeControl(supersedingAnotherControllerUntil:)` |
| P43 uses `takeControlLiftingRefusal()` | Met | No window and no known peer leads to `.liftingRefusal` (`Coordinator:324-325`). The kit implements it as a take dated `.distantPast` (`DeviceHandoff:390-392`): it lifts the refusal, opens no scope, and expects one resync. The machine gives P43 and P24 `LoanRecord(epoch: nil)` with no window. |
| No plain take that lifts a refusal | Met | The kit enforces it: a plain take of a refused pod stays refused and off the radio (`DeviceHandoff:331-334`). |
| R-1 temp cancel at Take Back | Met | `takeControlResult` runs cancel, refresh, audit, then persist `home` |
| R-2 bolus remainder | Met, approximate | `bolusRemainder` estimates from `bolusUnderWayEndsAt` (M4E-05) |
| R-3 recompute, replace by id | Met | `recompute` / `replaceTaggedBolus` |
| C-1 audit every foreign session; window only from a user take | Met in logic, but events can be lost (M4E-03) | `Coordinator:333-344` |
| C-3 relaunch redo | Met | P37, with the window passed; the audit entry is keyed by (epoch, start) and recomputed |
| C-4 booked intents count as expected | Met in logic | Every booked bolus except audit-tagged ones counts. M5 must book intents as bolus events. |

### The author's host choices

- **Failed pump step.** During a lend it is treated as a refused release and the phone goes `home`. During a take-back it alerts and stays `takingBack`. **Accepted**: both fail closed. `takingBack` keeps `phoneNotLooping` armed. See M4E-07 for retry.
- **Grant that can't be built or sent.** Treated as the watch's rejection (P11), and the phone retakes with a plain take on a released kit. **Accepted**: the watch never had the pod.
- **Audit books "excess − (pulse + 0.15 U)", floored to whole pulses.** This is **conservative-enough but not the conservative choice** (M4E-06).
- **`takeControl(nil)` for an unknown peer.** It maps to `takeControlLiftingRefusal()`. That is acceptable for P43, which the user confirms. For P24 (unreadable file while a watch may still hold the pod) it is still fail-closed: with no scope, the stale watch's next session makes the phone refuse again and alert. That is alarmed, and P43 recovers.
- **Keep-commanding re-opens the window only when the kit refuses.** **Accepted.** The kit's scope normally covers it, and the re-open is the same user take continuing.

### Known gaps, judged

- **A glucose-alert snooze clears the 30, 60 and 90 min "No updates from Apple Watch" steps.** Acceptable against V2-12 and SR-15: the 120 min critical step survives, so an alarm is still pending, and it matches how `NotLoopingMonitor` already treats a user snooze. Required: re-issue the remaining steps when the snooze ends, as `NotLoopingMonitor.snoozeDidChange` does (M4E-11).
- **The pod-lifetime audit uses today's basal profile.** Minor; it's a rare path (M4E-10).
- **The 40 s pump-idle timeout is untested.** It fails closed (the release counts as refused). Add a test (M4E-12).
- **Snapshot of 48.7 KB against an assumed 64 KB limit.** An oversized grant is rejected and the phone retakes, so Start just fails. Measure a worst-case fixture (M4E-13).
- **The `withKnownIssue`** (`WatchLoanCoordinatorTests.swift:570-576`) is a self-test that the pump double records an issue when anything commands a released pump. It is legitimate and useful. Nit: add `matching:` on the double's issue, so that an unrelated failure inside the block can't pass as "known".

### Findings

| ID | Sev | Where | Scenario | Fix |
|---|---|---|---|---|
| M4E-01 | **major** | `WatchLoanAudit.swift:49-55` | **External insulin hides real pod insulin.** `expectedDelivery` counts every booked bolus except audit-tagged ones. That includes `isExternal` entries: pen or syringe doses the user logs, which `storeExternalInsulinEvent` books as type bolus (`PumpHistoryStorage.swift:315-333`). If the user logs 3 U of external insulin inside an audit window (hours for a loan, days for a pod-lifetime audit), expected delivery rises by 3 U, and up to 3 U the pod delivered but nobody booked goes unbooked, or shows up as a false shortfall. That is **lost insulin**, and it is the case the audit exists for. | Count only pump-delivered boluses: `isExternal != true`. The audit bolus itself is stored `isExternal = true`, so handle tagged audit boluses explicitly (M4E-02). Test: external 3 U plus unexplained pod 3 U books 3 U. |
| M4E-02 | **major** | `WatchLoanAudit.swift:50`; `Coordinator.swift:462-488` | **A pod-lifetime audit books a loan audit's insulin a second time.** The prefix filter drops *every* audit-tagged bolus from expected delivery. A pod-lifetime audit (P43, P24, or a foreign session with no `lastLoan`) on a pod that already has a loan audit bolus `trio-watch-loan-audit-<e>` therefore sees that loan's unexplained insulin again and books it under `…-pod-<start>`. **IOB is double-counted.** That errs high, but it can mean hours of withheld insulin. | Exclude only the audit's own `bolusID`. Count other tagged audit boluses inside the window as delivered (they stand for pod insulin). Test: loan audit X, then pod-lifetime audit, gives total X. |
| M4E-03 | **major** | `DeviceDataManager.swift` `pumpManagerDidUpdateState` (`lastForeignPodSession` persisted before handling); `WatchLoanPhoneHost.swift:449-453`; `Coordinator.start()` | **Foreign-session events can be lost.** `DeviceDataManager` persists `lastForeignPodSession` and then sends on a `PassthroughSubject`. If the coordinator hasn't subscribed yet (launch order), or the app dies before `handle(.foreignPodSession)` runs, the event is gone for good: the persisted date suppresses a re-send. Inside the C-1 window the kit keeps commanding without refusing. So the stale watch's one possible session is **never audited**: lost insulin, the exact case C-1 covers. | Keep the "last handled foreign session" in the coordinator's ledger, persisted after the audit. On `start()` and on every kit state change, compare it with `pump.foreignSessionDetectedAt` and handle anything newer. Drop the dedupe in `DeviceDataManager`, or keep it for logging only. Test: kill between detection and handling, then relaunch, and the audit runs. |
| M4E-04 | minor | `Coordinator.swift:301` | The loan audit records `TimeZone.current` (the phone's), while the pod delivers scheduled basal in its own zone, as the pod-lifetime path already uses (`pump.status.timeZone`, `:475`). A traveller whose pod time wasn't synced gets scheduled basal at the wrong offsets, so the error can go either way. | Use `pump.status.timeZone` for both. |
| M4E-05 | minor | `WatchLoanPumpAdapter.swift:115-120` | The bolus remainder is estimated from the end time and the nominal rate. The pod's status reports `bolusNotDelivered` exactly (StatusResponse.swift:20). | Prefer the pod's `bolusNotDelivered` from the reading's status. Keep the estimate as a fallback. |
| M4E-06 | minor | `WatchLoanAudit.swift:41` | Subtracting the band means every booked excess is short by up to pulse + 0.15 U (0.2 U on DASH). The band exists to suppress noise, not to discount real insulin. | Once the excess passes the band, book `floorToPulse(excess)`. Write down which reading of the Loop rule ("excess beyond 0.20 U") was chosen. |
| M4E-07 | minor | `Coordinator.swift:382-392` | A take-back that fails at cancel or refresh (pod briefly out of range) waits for a user tap. It is alarmed by `NotLoopingMonitor`, but the loop stays off longer than it needs to. | Retry the take-back result step automatically on the next pump heartbeat or CGM reading while in `takingBack`. |
| M4E-08 | minor | `Coordinator.swift:339-344` | On a `.refuse` verdict the coordinator only ends the scope. The host contract says to release on refusal. If the kit's scope was still valid (the clocks differ), the kit keeps commanding until the next session. | On `.refuse`, call `releaseControl()` as well, so the refusal takes effect now and the link is freed. P43 lifts it (it works on a released kit through `resumeControl`). |
| M4E-09 | minor | Machine P-rows plus kit `:331-334` | In `takingBack` from End or `grantRejected` (plain take), a kit that is refusing stays refused. Each Take Back tap repeats the plain take, and P43 is offered only in `home`. The phone is stuck (alarmed). Rare. | Offer P43 in `takingBack` too when the kit refuses. |
| M4E-10 | minor | `Coordinator.swift:469-477` | The pod-lifetime audit assumes today's basal profile for the whole pod, so a schedule change mid-pod skews it either way. | Start the pod-lifetime window at the later of activation and the last basal-schedule sync, or flag the result as approximate in the notice. |
| M4E-11 | minor | `WatchLoanPhoneHost.swift:297-324` | The snooze case above. | Re-issue the remaining silence steps when the snooze ends, and test that the 120 min critical step survives a snooze. |
| M4E-12 | minor | `Coordinator.swift:81, 275-279` | The pump-idle timeout path is untested. | Add a test: a pump that never goes idle gives `releaseResult(false)`, then `home`, and no release is sent. |
| M4E-13 | minor | `sendGrant` size check | The margin is unmeasured for heavy users: SMB every 5 min, many carb entries, 10 days of TDD. | Add a worst-case fixture test, and log the size in hardware runs. It fails closed. |

No command reached the pump while the phone wasn't owner:
- the coordinator's own pump steps run only in `lending` (before the release) and in `takingBack` after a take;
- the gate covers everything else;
- the double fails any command on a released pump, and that check is self-tested.

No silent no-dosing state found:
- `lending` and `takingBack` keep `NotLoopingMonitor` armed;
- `lent` keeps the silence ladder, anchored on the last batch and re-anchored on relaunch.

### Verdict

**Merge after M4E-01, M4E-02 and M4E-03.** Each is lost or double-counted insulin in the audit path, and each is small and testable. The host contract is followed, and the rest is sound. M4E-04 to M4E-13 can go into M5 or M7.
