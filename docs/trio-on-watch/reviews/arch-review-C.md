# Architecture review C: fit with Trio's existing architecture

Reviewer: Agent C (upstream Trio map, `research/upstream-trio-architecture.md`).

Reviewed: `architecture/{requirements-and-scope,target-architecture,state-and-synchronization,lifecycle-and-execution,architecture-decisions}.md` and `implementation/roadmap.md` on `feat/trio-on-watch` @ `1a9dba899`. Code references are at baseline `ad6c66876` unless marked otherwise. Read-only review; nothing was built or run for it.

Severity: **blocker** = must change before M1/M3 starts; **major** = must change before the milestone it affects; **minor** = fix when touched.

## Summary

The overall shape fits Trio:
- On the phone it adds one gate and one coordinator, with no second loop.
- It reuses LoopKit#626's `ExclusiveDeviceControl` / `DeviceConfigurationSharing`, which I verified are in the pin at `LoopKit/LoopKit/DeviceManager/DeviceManager.swift:62-152`.
- The algorithm stays the same Swift code.

Three things don't hold as written:
1. The M1 parity acceptance cannot detect a broken extraction, because the goldens never call `OpenAPS.swift`.
2. `WatchLoanGate` misses at least 11 pump-command paths, including the kit settings UI and alert acknowledgement.
3. "Small host + pure shared code" only works if the Core Data–bound input mappers are pulled out into shared code too. Otherwise the watch ends up with a second, divergent input pipeline, which is exactly the parallel architecture the documents want to avoid.

## Findings

### C-01 (blocker): M1 acceptance does not cover the code being extracted

- **Evidence:**
  - The parity goldens run `ParityScenarios.runPipeline`, which calls the generators directly: `ProfileGenerator` → `AutosensGenerator` ×2 → `MealGenerator` → `IobGenerator` → `DeterminationGenerator` (`TrioTests/OpenAPSSwiftTests/Parity/ParityScenarios.swift:189-262`). They never touch `OpenAPS.determineBasal` / `createProfiles` / `autosense`, which is the code M1 extracts.
  - Production differs from the harness in ways only `OpenAPS.swift` encodes:
    - temp-target half-basal-target adjustment and `lowTemptargetLowersSensitivity` override before clamping (`OpenAPS.swift:506-546`);
    - the profile is written to and re-read from `settings/profile.json`;
    - `preferences.clamped(for:)` is applied separately for determination (`:256-257`);
    - DynISF is switched off when TDD is insufficient (`:324-328`);
    - `profile.suspendOnly` and `supportedBasalRates` are injected (`:293-296`);
    - autosens precomputes treatments (`:635-643`) and is cached for 30 min through `autosense.json` (`APSManager.swift:458-469`);
    - `currentTime` is `Date()` at `OpenAPS.swift:684`, not the `clock` parameter.
  - Byte-exact goldens therefore say nothing about whether `OrefRun` reproduces production.
- **Change:**
  1. Before any extraction (M0 or the first M1 commit), add characterization goldens that run `OpenAPS.createProfiles` + `autosense` + `determineBasal` on `CoreDataStack.createForTests()` (`Model/CoreDataStack.swift:90-94`), with a temp-directory `FileStorage` and fixed fixtures. Cover: an active temp target with custom HBT, insufficient TDD with DynISF on, an override with SMB off, and suspend-only mode. Record them on the baseline.
  2. M1 acceptance becomes: those goldens byte-exact **plus** the existing goldens.
  3. Then point `runPipeline` at `OrefRun`, so harness and production are the same code from then on.
  4. Keep `Date()` vs `clock` exactly as is in M1. Any fix there is a separate, signed-off behaviour change (`.claude/rules/algorithm-safety.md`).

### C-02 (major): the exact `OrefInputs` inventory

The extraction is feasible without changing parity. Every read and every IO happens before the generator calls, so they separate cleanly. `OrefInputs` must carry the following, all as values:

| Input | Today's source | Notes |
|---|---|---|
| `pumpSettings`, `bgTargets`, `basalProfile`, `insulinSensitivities`, `carbRatios` | `settings/*.json` with the bundled-defaults fallback (`OpenAPS.swift:488-503, 704-727`) | the fallback must be applied by the caller, identically |
| `tempTargets` (JSON form) | `settings/temptargets.json` (`:494, 451`) | used by `ProfileGenerator` and autosens |
| active temp target (Core Data form): `enabled`, `target`, `halfBasalTarget` | `TempTargetStored` via `fetchActiveTempTargets` (`:509-512, 764-773`) | **second source of truth for temp targets.** The snapshot must carry both consistently |
| `preferences` (raw, unclamped) | `preferences.json` (`:506`, `:256`) | HBT logic needs the real `autosensMax` before the clamp (`:546`) |
| `dosingMode` | `SettingsManager` | drives `clamped(for:)` and `suspendOnly` |
| TDD history rows (`date`, `total`), 10 days | `TDDStored` via `fetchHistoricalTDDData` (`:381, 786-795`) | feeds `currentTDD`, the 10-day average and the 2-h weighted average (`:392-400`). Note that `currentTDD` is read `as? Decimal` from an `NSDecimalNumber` (`:401`); reproduce it bit for bit |
| active override (all fields used at `:384-430`) | `OverrideStored` via `fetchActiveOverrides` (`:775-784`) | |
| `hasSufficientTDD` | `TDDStorage.hasSufficientTDD` (`TDDStorage.swift:419-445`) | |
| pump history, 24 h, plus orphaned-resume filter over 48 h | `PumpEventStored` (`OpenAPS.swift:104-232`) | see C-04 |
| carbs, 24 h (`predicateForOneDayAgo`) | `CarbsStorage.getCarbsForAlgorithm` (`CarbsStorage.swift:437-480`) | |
| glucose, `maxMealAbsorptionTime + 0.5` h for determination, 24 h for autosens | `GlucoseStorage.getGlucoseForAlgorithm` + smoothing flag (`GlucoseStorage.swift:447-500`, `OpenAPS.swift:258-262, 446-449`) | see C-04 |
| current temp | `APSManager.fetchCurrentTempBasal` (`APSManager.swift:739-781`): the live `basalDeliveryState` wins over history | |
| `supportedBasalRates` | live pump manager (`APSManager.swift:620-626`) | |
| previous autosens + its timestamp | `settings/autosense.json` (30-min cache) | |
| `clock` | caller | |

- **Outputs the caller must persist** (side effects pulled out of `OpenAPS` today): `pumpprofile.json`, `profile.json`, `autosense.json`, `monitor/iob.json`, `monitor/cob.json`, `monitor/trio_custom_oref_variables.json`, and the Core Data determination with its forecasts (`processDetermination`, `OpenAPS.swift:41-91, 329-360`).
- **Change:** put this table into the M1 design, and make `OrefInputs` → `OrefRun` → `OrefOutputs` the boundary. `OpenAPS` keeps every fetch and every save. Also move `TempTargetCalculations` (HBT) into the shared set, since it is used inside `createProfiles`.

### C-03 (major): a frozen TDD snapshot breaks "same inputs"

- **Evidence:**
  - Every loop writes a fresh TDD row (`APSManager.swift:472-486` → `TDDStorage.storeTDD`).
  - `currentTDD`, the 2-h average and the weighted average are derived from those rows (`OpenAPS.swift:392-400`).
  - The grant carries "TDD history for DynISF" only once (target-architecture §4). During a loan of hours, DynISF (sigmoid or log) would run on a TDD that stops at grant time, while the phone's would move.
- **Change:** the watch computes and appends TDD rows each cycle from its own pump events and the snapshot's basal profile. Share the TDD computation by making `TDDStorage.calculateTDD` pure over `[PumpHistoryEvent]` + `[BasalProfileEntry]`:
  - its `pumpManager: PumpManagerUI` parameter is unused in the computation (`TDDStorage.swift:44-48`);
  - `suspensionSpans`, `timelineEvents` and `ScheduledBasalInference` are already static or pure.

  Test: phone and watch produce identical TDD for the same fixture.

### C-04 (major): "no APSManager / Core Data on watch" needs shared input mappers, or it becomes a parallel pipeline

- **Evidence:** turning device data into oref inputs is about 1.6k lines that live inside Core Data stores today:
  - pump events: `PumpHistoryStorage.storePumpEvents` (pending/replace and syncIdentifier upsert, `PumpHistoryStorage.swift:63-270`), `PumpEventStored.toPumpHistoryEvents()` (`Model/Helper/PumpEvent+helper.swift:165`), orphaned-resume detection (`OpenAPS.swift:186-232`), `removingDuplicateSuspendResumeEvents` (`:597`);
  - glucose: `filterTooFrequentGlucose` (`GlucoseStorage.swift:411-420`), exponential smoothing (`FetchGlucoseManager.swift:486-560`), `algorithmGlucoseValue` (`GlucoseStorage.swift:485-500`);
  - carbs: `mapToCarbsEntry` (`CarbsStorage.swift:463-480`);
  - glucose validation, at least 3 readings in 1 h and 12 min staleness (`APSManager.swift:512-527`);
  - the TDD logic in C-03.

  A watch "input builder" written from scratch duplicates all of this, and target-architecture §10's "same fixture gives identical determination" test would only catch a divergence after the fact.
- **Options:**
  - (a) Extract these as pure functions over value types (`NewPumpEvent` / `PumpHistoryEvent`, `BloodGlucose`, `CarbsEntry`) in the shared set, used by both the phone stores and the watch host.
  - (b) Put Core Data and the stores on the watch, with the UIKit seams from the research doc §3.4.
- **Recommendation:** (a). Most of the logic is already static or nearly so. It keeps the watch small, as the documents intend, and it is the only way "same inputs" holds by construction. Choose (b) instead if (a) needs more than a mechanical lift of `storePumpEvents`' dedupe semantics. Then the watch is no longer "small", but it doesn't duplicate anything.
- **Change:** add the mappers to M1 (or an M1b before M5) with phone-side byte-equality tests. M5 then builds inputs only through them.

### C-05 (blocker): `WatchLoanGate` coverage is incomplete

The document lists `APSManager.loop`, `enactBolus`, `enactTempBasal`, `cancelBolus`, and "every DeviceDataManager path". Every phone path that commands, or can command, the pump at this baseline:

| # | Path | file:line | In the doc? |
|---|---|---|---|
| 1 | Loop temp basal | `APSManager.swift:846` (via `enactDetermination` `:783`) | yes (loop) |
| 2 | Loop SMB | `APSManager.swift:850` | yes (loop) |
| 3 | Loop re-entry when a manual temp basal ends | `APSManager.swift:268-280` | implicit |
| 4 | Manual bolus, `enactBolus` | `APSManager.swift:673`; callers `TreatmentsStateModel.swift:637`, `HomeStateModel+QuickPickTreatments.swift:189`, `Shortcuts/Bolus/BolusIntentRequest.swift:26`, `TrioRemoteControl+Bolus.swift:44`, `AppleWatchManager.swift:814, 934` | yes |
| 5 | Cancel bolus | `APSManager.swift:717`; callers `HomeStateModel.swift:848`, `TreatmentsStateModel.swift:297` | yes |
| 6 | Cancel automatic temp on switch to basal testing | `APSManager.swift:1517-1531` (`enactTempBasal(0, 0)` at `:1525`) | **no** |
| 7 | Pump status refresh on every reading, `ensureCurrentPumpData` (a pod command for Omnipod, I) | `DeviceDataManager.swift:287-320` (call at `:315`) | **no** (not named) |
| 8 | BLE heartbeat requests | `DeviceDataManager.swift:87, 268, 275, 284` | **no** |
| 9 | `syncDeliveryLimits` when the manager is set, **including the restore at every launch** (`setupPumpManager` `:251-257`) | `DeviceDataManager.swift:128` | **no** |
| 10 | `syncDeliveryLimits` from settings | `UnitsLimitsSettingsProvider.swift:41`, `AlgorithmAdvancedSettingsProvider.swift:46`, `NightscoutConfigProvider.swift:41` | **no** |
| 11 | Basal schedule sync | `BasalProfileEditorProvider.swift:38` | **no** |
| 12 | Alert acknowledgement sent to the pump (Omnipod acknowledges by pod command, I) | `Services/Alerts/TrioAlertManager.swift:390` | **no** |
| 13 | Kit settings UI: suspend/resume, manual temp basal, pod deactivate/replace, time sync, beeps, status read; calls the `PumpManager` directly | `Modules/PumpConfig/View/PumpSettingsView.swift:13` | **no**, and not gateable inside Trio |
| 14 | Kit setup UI (pairing a new pod while lent) | `Modules/PumpConfig/View/PumpSetupView.swift:28` | **no** |

- **Change:**
  - **Layer 1 (Trio gate)** at the lowest common points: `APSManager.loop` (before `loopGuard.tryStart`, without `processError`, so the user isn't flooded with banners), `enactBolus`, `cancelBolus`, `enactDetermination`, `cancelAutomaticTempBasal`; `DeviceDataManager.heartbeat`, `updatePumpBLEHeartbeat`, the `pumpManager` setter's sync block; the four settings sync calls; and `TrioAlertManager` acknowledgement for the pump's identifier.
  - **Layer 2 (UI):** PumpConfig settings and setup are unreachable unless the phone is `home`, with a reason shown.
  - **Layer 3 (kit):** require, and test in M2, that an OmnipodKit manager with `isControlReleased == true` refuses every pod command. LoopKit's protocol doesn't promise it (`DeviceManager.swift:125-143`), so check it in #177 @ `e8216cd06`.
  - Don't "gate" by setting `pumpManager = nil`: the setter's nil branch records pump removal, deletes battery rows and resets `bolusIncrement` (`DeviceDataManager.swift:171-206`).
  - Phone `NotLoopingMonitor` suppression (target-architecture §6) needs an explicit hook. It reschedules from `lastLoopDate` (`NotLoopingMonitor.swift:73-102`), which freezes during a loan.
  - M3's acceptance test enumerates this table.

### C-06 (major): roadmap ignores overlapping open PRs; the kit pin is unstable

- **Evidence:**
  - PR #1749 already does M2's watch-platform work: links LoopKit and G7SensorKit into the watch, adds the watch `Info.plist` with `bluetooth-central`, moves to watchOS 10.6, renames the module to `Trio`, makes `JSON.swift` log through `WatchLogger`, and adds a `WatchCGMHost` built on `DeviceConfigurationSharing`.
  - #1648 changes `BolusSafetyValidator`, #1598 rewrites `AppleWatchManager`/`WatchState`, and #1775 defines idempotency and freshness for watch commands.
  - The roadmap names none of them.
  - OmnipodKit#177 is open (head `e8216cd0601c6fe6edfcc58e6a14fdce5d99baaf`, updated 2026-11-12). Pinning "the #177 head" also swaps the **phone's** pod driver from M2 on.
- **Change:**
  - M2 starts from #1749 (rebase onto it, or declare it a dependency) and reuses its `WatchCGMHost`. Building a second CGM host would be duplication.
  - Record #1598/#1648/#1775 as inputs to M3–M5. Reuse #1775's request-cache/freshness semantics for loan messages rather than a new dedupe scheme.
  - Split M2 into M2a (watch target, algorithm, LoopKit/G7; OmnipodKit unchanged) and M2b (OmnipodKit pinned to an explicit SHA, with an iOS regression pass recorded in the status doc).

### C-07 (major): `BolusSafetyValidator` cannot run on a watch without Core Data

- **Evidence:** `BaseBolusSafetyValidator` needs `SettingsManager`, IOB and a Core Data fetch for recent boluses (`BolusSafetyValidator.swift:71-104`). Only `BolusSafetyEvaluator.evaluate` is pure (`:43-59`).
- **Change:**
  - R-3 and target-architecture §5 should say the watch runs `BolusSafetyEvaluator.evaluate`, with watch-side inputs: max bolus and max IOB from the snapshot, IOB from the last `OrefRun`, and recent boluses from watch records.
  - Put the evaluator file in the shared set.
  - Coordinate with #1648, which extends the evaluator with overridable checks.
  - The watch bolus recommendation (`BolusCalculationManager`) is Core Data–bound too. State whether v1 has one.

### C-08 (major): `WatchLoan` record types should reuse existing models and merge paths

- **Evidence:** the document defines new "dose, carb, glucose, pump event" record types plus a merge by sync identifier. Trio already has:
  - an upsert by `dose.syncIdentifier` in `PumpHistoryStorage.storePumpEvents` (`:69-132`);
  - glucose dedupe and backfill (`GlucoseStorage` backfill, `filterTooFrequentGlucose`);
  - carbs storage with ids.

  LoopKit's `NewPumpEvent` is `RawRepresentable` and `DoseEntry` is `Codable` (`LoopKit/LoopKit/InsulinKit/NewPumpEvent.swift:43`, `DoseEntry.swift:179`).
- **Change:**
  - Records = kit-reported `NewPumpEvent.rawValue`, `BloodGlucose`, `CarbsEntry` with ids, plus the loan envelope (epoch, sequence).
  - The phone merges through the existing `storePumpEvents(_:replacePendingEvents:)`, `storeGlucose`/`backfillGlucose` and `storeCarbs`. No second merge implementation.

### C-09 (minor): pbxproj and target-membership pitfalls for M2

1. **Three hand-maintained source lists** (iOS target, `AlgorithmPackage/Package.swift:22-73`, watch target) will drift. Add a test or script that diffs the watch target's membership against the package list. The project rule already says to add files to `Package.swift` by hand.
2. **Logging:** `OpenAPSSwift` calls the app's `debug`/`warning`. The package uses `AlgorithmLoggingShim` under `TRIO_ALGORITHM_PACKAGE` (`AlgorithmLoggingShim.swift:12`), whose sink discards by default. On the watch, set `algorithmLogSink` to `WatchLogger`, or add a watch shim; otherwise the watch's algorithm logs vanish. #1749 already touches `JSON.swift` for this.
3. **Strings:** `DeterminationError` uses `String(localized:)` (`DeterminationError.swift:19-27`). Adding the full `Localizable.xcstrings` to a SwiftPM-built set fails `xcstringstool generate-symbols` on duplicate keys under Xcode 27.2 (seen in my research compile test). Use a small watch catalog, or keep the xcstrings out of package builds.
4. **Info.plist:** do not point `INFOPLIST_FILE` at `Trio Watch App/Info.plist`. It is an App Intents extension plist, and that folder's two Swift files are compiled by no target (`project.pbxproj:1987-1988, 4442-4443`).
5. **Deployment target:** raise all three watch targets to 10.6 (`project.pbxproj:7101-7261`), not just the app; the complication and tests currently say 10.
6. **Linking:** `LoopKit-watchOS` builds a product named `LoopKit.framework`, the same as the iOS target. Add explicit target dependencies and an Embed Frameworks phase; the watch app has an empty Frameworks phase today. LoopKit-watchOS omits 21 LoopKit files (e.g. `StatefulPluggable`, `TherapySettings`, `AlertSoundPlayer`), so OmnipodKit-watchOS must compile against that subset. Make that an M2 acceptance item.
7. **Module rename** (#1749: `Trio`) breaks `@testable import Trio_Watch_App` in `Trio Watch App Tests/Unit Tests.swift`.
8. **CI** builds no watch target and doesn't set `TZ` for the algorithm job (`unit_tests.yml:9-36`). M0 should record that the parity goldens skip in CI, and M2 should add a watch build.

### C-10 (minor): phone-side residue during a loan

- Every G7 reading still runs `heartbeat` → `recommendsLoop` (`DeviceDataManager.swift:322-329`). Gate at `heartbeat` (C-05 #7) so neither pod polling nor loop attempts happen.
- `determineBasalSync` after carb entries is refused anyway (F-5). Make sure `calculateAndStoreTDD` doesn't run on the phone against a released manager, or IOB/COB on the phone is computed from incomplete history until the merge. Show it as stale instead.
- Where the persisted phone loan state lives is unspecified. Use one file with atomic writes, read on every gate check; not `@Persisted` UserDefaults, which is written from several queues today (`APSManager.swift:137-167`). Fail closed on a read error, as the document says.

## Milestone order

M0 → M1 (with C-01's characterization goldens first, and C-02/C-03/C-04's shared mappers) → M2a (#1749-based) → M3 (gate per C-05's table) → M2b (OmnipodKit pin + kit-release refusal test) → M4 / M5 → M6 → M7.

M5 must depend on M2b. M4's merge depends on C-08's decision.

## Verdict

**Approve with changes.** The architecture fits Trio: a minimal phone delta, no parallel loop, upstream LoopKit hand-off protocols, and the same algorithm code. It is not ready to start M1/M3 until:
- C-01 (characterization goldens through `OpenAPS`) is in the M1 plan;
- C-05 (the full gate table, plus UI and kit layers) is in M3.

C-03, C-04, C-06, C-07 and C-08 must be settled in the architecture documents before M4/M5.
