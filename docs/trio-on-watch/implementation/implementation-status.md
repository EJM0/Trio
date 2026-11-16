# Trio on Watch: implementation status

## M0: build and test baseline (2026-11-16)

No source changes. This records what builds and what passes before any Trio on Watch work.

### Environment

| Item | Value |
|---|---|
| Branch | `feat/trio-on-watch` |
| Baseline SHA | `1a9dba899ec7203e311193c89e3c6f50124bda63` (= `nightscout/dev` `ad6c66876e5ccca8b0a6e1c5b7626ed4caa65926` + docs-only commit) |
| Xcode | 27.2 (27B52) |
| Swift | 6.4.2 (swiftlang-6.4.2.1.9) |
| Host | macOS 27.2, arm64 |
| Signing | `ConfigOverride.xcconfig` one level above the worktree |
| Submodules | initialised; `git submodule status` identical before and after all runs |

CI (`.github/workflows/unit_tests.yml`) uses Xcode 26.2 and an iOS 26.2 runtime. This baseline uses Xcode 27.2 and iOS 27.2 / watchOS 27.2 because Xcode 27.2 is the only Xcode installed here.

### Simulators (created fresh for M0, paired)

| Role | Device | Runtime | UDID |
|---|---|---|---|
| Phone | iPhone 17 ("Trio-M0 iPhone 17") | iOS 27.2 (24B8117) | `267B410A-871B-4287-93FC-F2D9873ACC70` |
| Watch | Apple Watch Series 12 46mm ("Trio-M0 Watch S12 46mm") | watchOS 27.2 (24S118) | `BE93BC2C-E747-43E6-9950-0819630B720E` |
| Pair | | | `AF348FC2-D5D3-45B6-9086-2C5DD212F144` |

```sh
xcrun simctl create "Trio-M0 iPhone 17" com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-27-2
xcrun simctl create "Trio-M0 Watch S12 46mm" com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-12-46mm com.apple.CoreSimulator.SimRuntime.watchOS-27-2
xcrun simctl pair <watch UDID> <phone UDID>
```

### Executed

Shorthands used below:

- `X` = `xcodebuild -workspace Trio.xcworkspace -derivedDataPath $DD` (`$DD` is a session scratch directory outside the source root)
- `PHONE` = `-destination 'platform=iOS Simulator,id=267B410A-871B-4287-93FC-F2D9873ACC70,arch=arm64'`
- `WATCH` = `-destination 'platform=watchOS Simulator,id=BE93BC2C-E747-43E6-9950-0819630B720E,arch=arm64'`

Each command ran with its output sent to a log file; the exit code is the command's own `$?`. Durations are wall clock and include build time.
Test counts come from `xcrun xcresulttool get test-results summary` on each run's result bundle.

| # | Step | Command | Exit | Duration | Total | Passed | Failed | Skipped |
|---|---|---|---|---|---|---|---|---|
| 1 | iOS app build | `X -scheme Trio PHONE build` | 0 | 335 s | | | | |
| 2 | Watch app build | `X -scheme "Trio Watch App" WATCH build` | 0 | 69 s | | | | |
| 3 | Parity suites | `X -scheme "Trio Tests" PHONE test` + `-only-testing:TrioTests/{ParityGoldenTests,WallClockParityTests,ParityPerformanceTests}` | 0 | 123 s | 4 | 3 | 0 | 1 |
| 4 | Determination / bolus / dosing suites | `X -scheme "Trio Tests" PHONE test` + `-only-testing:` list below | 0 | 41 s | 145 | 144 | 0 | 1 |
| 5 | Watch-related iOS suites | `X -scheme "Trio Tests" PHONE test` + `-only-testing:TrioTests/{ContainerResolutionTests,WatchLogIngestTests}` | 0 | 35 s | 10 | 10 | 0 | 0 |
| 6 | Watch app tests | `X -scheme "Trio Watch AppTests" WATCH test` | 0 | 65 s | 21 | 21 | 0 | 0 |
| 7 | Full `Trio Tests` | `X -scheme "Trio Tests" PHONE test` | 0 | 112 s | 996 | 952 | 0 | 44 |
| 8 | Algorithm package | `TZ=Europe/Berlin swift test --package-path AlgorithmPackage --scratch-path $SPM` | **1** | 5 s | 0 (build failed) | | | |

Notes on the runs:

- Step 3: `ParityGoldenTests` ran all 14 scenarios (parameterised, counted as 1 test) and passed. The scheme pins `TZ=Europe/Berlin`, so the golden suite was enabled. The 1 skip is `ParityPerformanceTests`, which only runs with `TEST_RUNNER_TRIO_RUN_PERF=1`.
- Step 4 scope: `ExpectedDeltaTests`, `DetermineBasalGlucoseFallingFasterThanExpectedTests`, `DetermineBasalAggressiveDosingTests`, `DetermineBasalEnableSmbTests`, `DetermineBasalEarlyExitTests`, `DetermineBasalEventualOrForecastGlucoseLessThanMaxTests`, `DetermineBasalSmbMicroBolusTests`, `DetermineBasalIobGreaterThanMaxTests`, `HandleLowEventualGlucoseTests`, `SetTempBasalTests`, `DeterminationStorageTests`, `BolusSafetyValidatorTests`, `EnactBolusAmountTests`, `BolusCalculatorTests`, `AlgorithmSuggestedBolusTests`, `DosingModeClampTests`, `MaxIOBSuggestionTests`, `BasalRoundingDriverParityTests` (18 suites). The 1 skip is "Calculate insulin with backdated carbs", disabled in source ("Flaky test, disabled while investigating").
- Step 5: there is no `APSManager` or `WatchManager` unit suite in `TrioTests`. `ContainerResolutionTests` resolves both from the DI container; `WatchLogIngestTests` covers watch log ingestion. These are the only watch-related suites in the iOS test target.
- Step 6: the `Trio Watch AppTests` scheme runs `Trio Watch App Tests/Unit Tests.swift` (`TrioWatchAppTests`, "Watch App Tests").
- Step 8 uses `--scratch-path` outside the worktree only to keep `.build` out of the source tree (`AlgorithmPackage/.build` is not gitignored). It does not change what is built.

#### Failures

No test failed in any run, so there was nothing to re-run in isolation. The full run (step 7) finished without the order-dependent aborts described in `.claude/rules/testing.md`.

The one failure is step 8, `swift test` on `AlgorithmPackage`, which fails to **build** on Xcode 27.2 / Swift 6.4.2 before any test runs:

- `GenerateStringSymbols` on `AlgorithmPackage/Sources/Localizations/Main/Localizable.xcstrings` (that is `Trio/Sources/Localizations/Main/Localizable.xcstrings` through the `Sources` symlink) fails with 21 errors:
  - 20 × "This string key would generate the same symbol as …": keys that differ only in case or punctuation, for example "Temp targets" / "Temp Targets", "Normal" / "Normal ", "Return to Normal" / "Return to Normal?", "[ +1 ]" / "[ -1 ]", "All" / "all".
  - 1 × "Unable to create a Swift type from the format specifier `%-i`" (the exercise-mode half-basal target help text).
- This reproduces on every run, in isolation; it is not order-dependent.
- Probable cause (not verified): SwiftPM in this toolchain generates string symbols for package `.xcstrings` resources, and the Xcode project build does not. The Xcode builds and tests (steps 1–7) are unaffected. CI uses Xcode 26.2 and does not run `swift test`. Xcode 26.2 is not installed here, so I could not check whether the older toolchain still builds the package.
- Impact for Trio on Watch: the fast algorithm-only loop (`swift test --package-path AlgorithmPackage`) is not available on this machine as-is. Algorithm verification goes through `Trio Tests` (steps 3, 4, 7) until this is resolved separately. M0 does not change the string catalog.

#### Skipped tests in the full run (44)

| Suite | Count | Reason |
|---|---|---|
| Logging Robustness Stress Tests | 23 | env-gated (`TRIO_STRESS=1`) |
| Logging Volume Stress Tests | 11 | env-gated (`TRIO_STRESS=1`) |
| Logging Long-Run Stress Tests | 5 | env-gated (`TRIO_STRESS=1`) |
| OpenAPSSwift performance | 1 | env-gated (`TEST_RUNNER_TRIO_RUN_PERF=1`) |
| Redactor Throughput | 1 | env-gated (`TRIO_STRESS=1`) |
| GlucoseStorage Tests | 1 | disabled in source: "Flaky test, disabled while investigating" |
| Bolus Calculator Tests | 1 | disabled in source: "Flaky test, disabled while investigating" |
| Trio Alert Emission: TandemKit | 1 | "No test cases found." (parameterised test with an empty argument list) |

### Not executed

- Watch Complication Extension scheme: not built separately; it builds as a dependency of the iOS app.
- Live Activity, widget and other extension targets: covered only by the iOS app build in step 1, not built or tested separately.
- Performance or stress runs (`TEST_RUNNER_TRIO_RUN_PERF=1`, `TRIO_STRESS=1`): not run; these are the env-gated skips listed above.
- Golden re-recording (`TEST_RUNNER_TRIO_RECORD_GOLDENS=1`): not run; the goldens matched.
- App launch or install on the simulators, and phone ↔ watch connectivity: not exercised. M0 covers build and test only.
- Physical devices: none used.
- Xcode 26.2 (CI toolchain): not installed, so CI parity of these results is unconfirmed.

### Worktree hygiene after the runs

- The build-phase SwiftFormat reformatted one line in `Trio Watch App Tests/Unit Tests.swift` (it joined a `@Test(...)` attribute onto the `func` line). Reverted with `git checkout`.
- `Trio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`: unchanged.
- Submodules: `git submodule status` unchanged and no dirty files inside any submodule.

## M1: `OrefInputs` + `OrefRun` (2026-11-16)

Branch `feat/tow-oref-run`, worktree `~/workspaces/Trio-tow-oref-run`, off `1a9dba899`. Local signed commits, not pushed.

| Commit | Subject |
|---|---|
| `a010bc81a` | Inject the Core Data context into OpenAPS |
| `ae8efa8d7` | Add OpenAPS characterization goldens |
| `4bc264749` | Extract the oref pipeline into OrefRun |
| `25688da46` | Move algorithm input mapping into OrefInputs |
| `656312bf7` | Make the TDD insulin math pure |
| `c1768d92e` | Check OrefRun against the characterization goldens |
| `7f7ec8aba` | Add LGS and basal-testing characterization goldens |
| `d40070789` | Record M1 status |
| `b15660d11` | Record characterization goldens on their own env var (M1-06) |
| `89523c085` | Add autosens, carb-window and override goldens (M1-01, M1-02, M1-03) |
| `920e1fcb6` | Pass advanced override fields to the OrefRun check (M1-03) |
| `c4239815a` | Share the oref input selection rules (M1-02, M1-07) |
| `09be2d3b8` | Run the parity pipeline through OrefRun (M1-01) |
| `1047c50f4` | Test TDD insulin and autosens reuse (M1-04, M1-09) |
| `8772abcc6` | Drop Codable from OrefRun outputs (M1-08) |

### What was done

**C-01 first.** `a010bc81a` adds a `contextProvider` to `OpenAPS.init` (default `CoreDataStack.shared.newTaskContext()`, the stores' existing pattern). It is the only production change before the goldens, and it changes no behavior. `ae8efa8d7` then records goldens through `OpenAPS.createProfiles` → `autosense` → `determineBasal` (the `APSManager` order) on `CoreDataStack.createForTests()`, with an in-memory `FileStorage` that encodes and decodes like `BaseFileStorage`. The two later scenarios (`low-glucose-suspend-high`, `basal-testing-dynisf-on`) were recorded the same way, with the sources checked out at `ae8efa8d7`, before they were committed on top.

Per scenario the goldens hold `pumpprofile.json`, `profile.json`, `autosense.json`, `trio_custom_oref_variables.json`, `iob.json`, `cob.json`, the returned determination, and the stored `OrefDetermination` row with its forecasts.

| Scenario | Covers (C-01) |
|---|---|
| `closed-loop-baseline` | boluses, SMBs, temp basals, carbs, a paired suspend/resume, an orphaned resume dropped from history, `supportedBasalRates` |
| `temp-target-custom-hbt` | Core Data temp target with its own HBT; `lowTemptargetLowersSensitivity` switched off because autosens max is 1 |
| `temp-target-standard-adjusted-hbt` | standard temp target where the settings HBT gives ≤ 15 %, so the HBT is recomputed |
| `dynisf-insufficient-tdd` | sigmoid Dynamic ISF switched off for insufficient TDD |
| `dynisf-sufficient-tdd` | 7 days of TDD rows, logarithmic Dynamic ISF on, weighted TDD averages |
| `override-smb-off-smoothed` | active override (120 %, target 95, SMB off, ISF/CR), glucose smoothing on |
| `low-glucose-suspend`, `low-glucose-suspend-high` | LGS clamp (Max IOB 0), low and high glucose |
| `basal-testing-suspend-only`, `basal-testing-dynisf-on` | basal-testing clamp, `profile.suspendOnly` |
| `defaults-no-settings` | no settings files (bundled defaults), no `preferences.json` |
| `simulation` | bolus/carb simulation: nothing written, nothing stored |

`OpenAPS` still reads `Date()` for the profile, autosens and determination times and the TDD windows. So every fixture sits on a whole-second clock and at least 10 s from any rounding or window edge, schedules are flat, and dates in the goldens are written relative to the clock. Fields taken from `Date()` (`deliverAt`, `timestamp`, autosens `timestamp`, custom-variables `date`) become `<now>`; `cob.json` times are rebased on `deliverAt`. Three back-to-back runs before the refactor were byte-identical after this normalization.

**Design.** Files in `Trio/Sources/APS/OpenAPSSwift/OrefRun/`, Foundation-only, listed in `AlgorithmPackage/Package.swift` through the `OpenAPSSwift` directory. Not in any watch target (M2a).

- `OrefInputs` (Codable value):
  - therapy settings: `pumpSettings`, `bgTargets`, `basalProfile`, `insulinSensitivities`, `carbRatios`, `tempTargets` (decoded from `settings/*.json`, bundled defaults for a missing file);
  - `preferences: Preferences?` (stored, unclamped; nil when the file is missing), `dosingMode`;
  - adjustments: `activeTempTarget` (`TempTargetState`: target, HBT), `activeOverride` (`OverrideState`: every field the custom variables read);
  - Dynamic ISF: `tddHistory` (`TDDRow`: date, total; 10 days, total > 0, oldest first), `hasSufficientTDD`;
  - device data: `glucose` (24 h, newest first), `pumpHistory` (24 h, orphaned resumes removed, newest first), `carbs` (24 h), `currentTemp`, `supportedBasalRates`;
  - `autosens: Autosens?` (the cached result while the caller considers it fresh; nil runs autosens), `clock`.
- `OrefRun` stages: `profilePreferences` (temp-target HBT, low-TT rule, then the dosing-mode clamp), `profiles`, `isAutosensFresh` (30 min), `autosens`, `trioCustomOrefVariables`, `determinationProfile` (`supportedBasalRates`, `suspendOnly`), `meal`, `iob`, `determine` (Dynamic ISF off on insufficient TDD; `timestamp = deliverAt`).
- `OrefRun.run(_:) -> OrefRun.Outputs` chains the stages on one clock and repeats the phone's JSON round trips (profile, autosens, custom variables), so a caller without files sees the same values. `Outputs` is what the caller persists: pump profile, profile, autosens, meal, IOB, custom variables, determination.
- The phone does not call `run`. `OpenAPS.createProfiles`, `autosense` and `determineBasal` gather inputs as before and call the stages. File writes, monitor files and the Core Data save stay in `OpenAPS`, in the same order. `iob.json` is still written before the determination, so it is written even when the determination throws. `APSManager.autosense` uses `OrefRun.isAutosensFresh`.

**Moved into shared pure functions** (`OrefInputs+Mapping.swift`, `OrefInputs+TDD.swift`); the Core Data side keeps thin adapters:

| Function | From |
|---|---|
| `pumpHistoryEvents(id:timestamp:type:bolus:tempBasal:)` | `PumpEventStored.toPumpHistoryEvents` |
| `orphanedResumes(in:type:timestamp:)` | `OpenAPS.fetchOrphanedResumes` |
| `filterTooFrequentGlucose(_:at:filterTime:)` | `BaseGlucoseStorage.filterTooFrequentGlucose` |
| `algorithmGlucoseValue`, `bloodGlucose` | `BaseGlucoseStorage.algorithmGlucoseValue`, `mapToBloodGlucose` |
| `exponentiallySmoothedGlucose` (AAPS constants as defaults) | `FetchGlucoseManager.applyExponentialSmoothingAndStore` |
| `carbsEntry` | `BaseCarbsStorage.mapToCarbsEntry` |
| `tddInsulin`, `suspensionSpans`, `calculateTempBasalInsulin`, `calculateScheduledBasalInsulin`, `timelineEvents`, `findBasalRateForOffset` | `BaseTDDStorage` / `TDDStorage.swift` (`ScheduledBasalInference.swift` is added to the package list) |

Not moved, on purpose:
- `PumpHistoryStorage.storePumpEvents` (upsert and pending replacement are Core Data semantics; C-04's criterion for option b);
- glucose validation in `APSManager` (a loop gate, not input mapping);
- `TDDStorage.calculateWeightedAverage` (reads stored TDD rows; not an oref input) and `calculatePumpDataHours` (log only);
- `APSManager.fetchCurrentTempBasal` (live pump state);
- the simulation's extra bolus and carb entry (phone only).
- `ParityScenarios.runPipeline` originally kept calling the generators directly. The review fixes point it at the `OrefRun` stages (see below).

### Commands and results

`X` = `xcodebuild -workspace Trio.xcworkspace -scheme "Trio Tests" -destination 'platform=iOS Simulator,id=C51E8717-C311-4B70-BDD7-1F96894618D4,arch=arm64' -derivedDataPath $DD`. Simulator "TOW-M1-oref-run", iPhone 17 Pro, iOS 27.2 (24B8117), created for M1. Recording: `TEST_RUNNER_TRIO_RECORD_GOLDENS=1` in the shell env.

| # | Command | Result |
|---|---|---|
| 1 | record on the unmodified code (`ae8efa8d7` sources): `X test -only-testing:TrioTests/OrefCharacterizationTests` | 10 scenarios recorded, then 2 more the same way; 3 compare runs before the refactor identical |
| 2 | `X test -only-testing:TrioTests/OrefCharacterizationTests -only-testing:TrioTests/OrefRunCharacterizationTests` at `7f7ec8aba` | passed: production path 12/12 scenarios, `OrefRun.run` 11/11 (simulation excluded), byte-exact |
| 3 | mapper suites after `25688da46`: `PumpHistoryNativeConversionTests`, `GlucoseNativeConversionTests`, `GlucoseSmoothingTests`, `CarbsNativeConversionTests`, `GlucoseStorageTests`, `JSONImporterTests` + characterization | passed, 58 tests in 7 suites |
| 4 | TDD suites after `656312bf7`: `PumpEventFinalizationTests`, `ScheduledBasalInferenceTests` + both characterization suites | passed, 46 tests in 4 suites |
| 5 | full `X test -resultBundlePath …` at `7f7ec8aba` | passed: 998 total, 954 passed, 0 failed, 44 skipped (M0: 996 / 952 / 0 / 44; +2 are the two new parameterised tests). Includes `OpenAPSSwift golden parity` 14/14 and `Wall clock parity` under the scheme's Europe/Berlin TZ. Skips are the same env-gated and source-disabled tests as M0 |
| 6 | `TZ=Europe/Berlin swift test --package-path AlgorithmPackage --scratch-path $SPM` | **not runnable**: fails to build on Xcode 27.2 before any test (string-symbol generation, same as M0 step 8) |
| 7 | package source list typecheck: `xcrun -sdk macosx swiftc -typecheck -target arm64-apple-macos14 -D TRIO_ALGORITHM_PACKAGE -module-name Trio <the Package.swift source list>` | passed (81 files) |

Mutation checks on `OrefRun.run` (reverted after each):
- `hasSufficientTDD: true` → `dynisf-insufficient-tdd` determination and cob differ: the direct comparison is live.
- The determination's own `clamped(for:)` replaced by `.closed` → no golden changes, also after the two added scenarios. Every value that clamp sets is already in the profile (`max_iob`, autosens 1/1, threshold), and Dynamic ISF also checks the profile's autosens limits. That clamp is defence in depth today, so no golden can detect its loss.

### Quirks preserved

- The determination time is `Date()` at the `OrefRun.determine` call, not `clock` (was `OpenAPS.swift:684`). The autosens and profile clocks, the TDD windows and the custom-variables `date` are `Date()` too. `run` uses `inputs.clock` for all of them.
- Dynamic ISF is off on insufficient TDD; the condition keeps its redundant `|| (useNewFormula && sigmoid)`.
- The HBT adjustment comes from the Core Data temp target and uses the unclamped `autosensMax`; the clamp follows. `lowTemptargetLowersSensitivity` is off when `autosensMax <= 1`.
- `suspendOnly` and `supportedBasalRates` are injected into the determination profile only, never into `profile.json`.
- Two clamps: one for profile generation, one for the determination.
- A missing `preferences.json` gives `Preferences()` for profile and determination, but weight 1.0 and 30/30 SMB/UAM minutes for the custom variables.
- `currentTDD` was read `as? Decimal`, the averages via `NSDecimalNumber.decimalValue`; both now read `decimalValue` (goldens with a 30.0137 U total are unchanged).
- `iob.json` is written before the determination; a simulation writes and stores nothing.
- The orphaned-resume window stays at 48 h; duplicate suspend/resume removal before IOB (ISSUE-399) is unchanged.
- The `?? Date()` / `?? UUID()` fallbacks in the glucose, carb and bolus mappings are unchanged.

### Bugs and oddities found, not fixed

- Three defaults for `weightPercentage`: `Preferences()` 0.35, custom variables 1.0 when `preferences.json` is missing, `TDDStorage.calculateWeightedAverage` 0.65.
- `lastActiveTempTarget` only checks `enabled` and a start within 24 h, not the temp target's end. The HBT adjustment relies on `enabled` being cleared at expiry. I did not verify where that happens.
- `createProfiles` generates `pumpprofile` and `profile` from identical inputs twice.
- The determination-side dosing-mode clamp has no observable effect today (see the mutation check).
- C-03 says `calculateTDD` doesn't use `pumpManager`. It does, for `roundToSupportedBasalRate`, so `tddInsulin` takes that rounding as a closure.

### Not verified

- `swift test` for `AlgorithmPackage` (toolchain build failure, M0); only a `swiftc -typecheck` of its source list.
- The characterization schedules are flat, so time-of-day lookups are covered only by the existing parity goldens. DST is not exercised.
- Values the production path takes from `Date()` are checked for presence and closeness to the clock (within 120 s), not compared exactly.
- The phone-side file IO is an in-memory `FileStorage`, not `Disk`.
- No device, in-vitro or in-vivo run; no watch build (M2a).
- Xcode 26.2 (the CI toolchain) is not installed.

### Worktree hygiene

The SwiftFormat build phase reformats `Trio Watch App Tests/Unit Tests.swift` on every build; I reverted it each time. `Package.resolved` was dirtied once and reverted. Characterization `actual-*.json` files from failed comparisons were deleted.

### Review fixes (M1 review in `reviews/implementation-reviews.md`)

| ID | Fix |
|---|---|
| M1-01 | New scenario `autosens-8h-24h-differ`: 8 h ratio 1.12, 24 h ratio 1.2, the 8 h one is chosen. `ParityScenarios.runPipeline` now calls `OrefRun.profiles`, `determinationProfile`, `autosens` (new `includeDeviationsForTesting` pass-through), `meal`, `iob` and `determine`. All 14 parity goldens are unchanged. |
| M1-02 | `OrefInputs+Selection.swift` holds the selection rules: the glucose windows (`autosensGlucoseHours`, `determinationGlucoseHours`, `glucoseStart`, `glucose(_:since:)`), `carbsStart` / `carbs(_:now:)`, `pumpHistoryStart`, `orphanedResumeWindowStart`, `algorithmPumpEvents` (no scheduled-basal rows, no orphaned resumes, last 24 h, newest first), `tddHistoryStart` / `tddHistory`, `sufficientTDDStart` / `sufficientTDDRowCount` / `hasSufficientTDD`. The phone uses them: `OpenAPS` now does one 48 h pump-event fetch through `algorithmPumpEvents` instead of the 24 h fetch plus the separate orphan fetch; `GlucoseStorage`, `CarbsStorage`, `TDDStorage.hasSufficientTDD` and the TDD fetch take their windows from it. `OrefRun.run` uses it for the meal-time glucose window. The drift test builds `OrefInputs` with these functions only; its hand-copied windows and the 75 % literal are gone. New scenario `carbs-glucose-window-gap`: 200 g at 5 h 45 min, a CGM gap from 5 h 46 min to 7 h 5 min, plus 20 g older than the window, so the pre-meal reading only exists outside the 6.5 h window. |
| M1-03 | New scenario `override-advanced`: advanced settings, SMB minutes 45, UAM minutes 60, SMB scheduled off for hours [0, 24). Preferences use 30 / 90 minutes there and in `autosens-8h-24h-differ` (no override), so the fallbacks differ too. |
| M1-04 | `OrefRunStageTests`: `tddInsulin` with a bolus, an SMB, a temp, a suspend/resume and a schedule row → 2.5 / 2 / 4.5 U. `TDDStorage` reads the result by label. |
| M1-05 | Accepted, not changed: the goldens map `Date()`-derived fields within −1…120 s of the clock to `<now>`. A 60 s shift is caught (mutation b), but sub-second `Date()` vs `clock` is not; that quirk is verified by reading. |
| M1-06 | Characterization goldens record on `TEST_RUNNER_TRIO_RECORD_CHARACTERIZATION=1`; `TRIO_RECORD_GOLDENS` no longer touches them. |
| M1-07 | `prepareTrioCustomOrefVariables` takes `now` before the TDD and override fetches again and derives the 10-day and 2-hour windows from it, as the original did. |
| M1-08 | `OrefRun.Outputs` is no longer `Codable`. The free `findBasalRateForOffset` and the glucose filter/smoothing stay where they are for now (M1b can regroup them). |
| M1-09 | `isAutosensFresh` boundary test: nil, nil timestamp, 29:59 fresh, 30:00 stale. `OrefInputs.autosens` documents that `run` does not recheck freshness. |

The three new scenarios were recorded from the original production code: a throwaway worktree at `ae8efa8d7` (baseline + context injection only), with the new scenario and test files copied in, built with `CI=true` into its own derived data on the same simulator, `TEST_RUNNER_TRIO_RECORD_CHARACTERIZATION=1 … -only-testing:TrioTests/OrefCharacterizationTests`. All 15 scenarios were re-recorded there; the 12 existing goldens came out byte-identical, and the 3 new ones were copied over. The worktree was then removed with `git worktree remove --force <its literal path>` (`--force` because it held the copied submodules).

Mutation set from the review, one at a time on `8772abcc6`, both characterization suites plus `ParityGoldenTests` (reverted after each):

| # | Mutation | Caught by |
|---|---|---|
| a | `OrefRun.autosens`: `<` → `>` | `autosens-8h-24h-differ` autosens, iob, determination (both suites) and stored determination |
| b | `OpenAPS.determineBasal`: `currentTime: Date()` → `Date() + 60 s` | `low-glucose-suspend`, `basal-testing-suspend-only`, `simulation` |
| c | `OverrideState.init`: swap `smbMinutes`↔`uamMinutes` and `start`↔`end` | `override-advanced` custom variables, determination, stored determination |
| d | `OrefRun.run` without the meal-time glucose window | `carbs-glucose-window-gap` determination and cob (`OrefRun` suite) |

Results after the fixes:

| Command | Result |
|---|---|
| both characterization suites at `920e1fcb6` (before the selection refactor) | production 15/15, `OrefRun` 14/14 |
| characterization + `PumpHistoryNativeConversionTests`, `PumpEventPredicateTests`, `CarbsStorageTests`, `GlucoseStorageTests`, `DynamicISFEnableTests`, `JSONImporterTests` at `c4239815a` | 56 tests in 8 suites passed |
| `ParityGoldenTests` (14/14), `WallClockParityTests`, `ParityPerformanceTests` (skipped, env-gated) + characterization at `09be2d3b8` | passed |
| `OrefRunStageTests` + `PumpEventFinalizationTests` at `1047c50f4` | 35 tests passed |
| full `X test` at `8772abcc6` | passed: 1000 total, 956 passed, 0 failed, 44 skipped (before the fixes 998 / 954; +2 = the two `OrefRunStageTests`) |
| package source typecheck (`swiftc -typecheck`, 82 files) | passed; `swift test` still not runnable (M0) |

New behaviour notes:
- Pump-event ties: the phone used Core Data's descending sort for the 24 h list and now uses a Swift sort of the 48 h fetch. The order of events with an identical timestamp was unspecified before and still is.
- The parity pipeline now gets autosens through `OrefRun.autosens`, so it shares the precomputed treatments with production. Mutation (a) changed no parity golden, so the characterization scenario is what guards the 8 h/24 h choice.

