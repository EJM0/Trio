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
| M1-02 | `OrefInputs+Selection.swift` holds the selection rules: the glucose windows (`autosensGlucoseHours`, `determinationGlucoseHours`, `glucoseStart`, `glucose(_:since:)`), `carbsStart` / `carbs(_:now:)`, `pumpHistoryStart`, `orphanedResumeWindowStart`, `algorithmPumpEvents` (no scheduled-basal rows, no orphaned resumes, last 24 h, newest first), `tddHistoryStart` / `tddHistory`, `sufficientTDDStart` / `sufficientTDDRowCount` / `hasSufficientTDD`. The phone uses the window starts: `OpenAPS`'s two pump-event fetches (24 h list, 48 h orphan check), `GlucoseStorage`, `CarbsStorage`, `TDDStorage.hasSufficientTDD` and the TDD fetch take their windows from it. `OrefRun.run` uses it for the meal-time glucose window. The drift test builds `OrefInputs` with these functions only; its hand-copied windows and the 75 % literal are gone. New scenario `carbs-glucose-window-gap`: 200 g at 5 h 45 min, a CGM gap from 5 h 46 min to 7 h 5 min, plus 20 g older than the window, so the pre-meal reading only exists outside the 6.5 h window. |
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
- Pump-event ties: superseded by R-01 below. `c4239815a` briefly replaced the two fetches with one; the re-review fixes restore the original fetches.
- The parity pipeline now gets autosens through `OrefRun.autosens`, so it shares the precomputed treatments with production. Mutation (a) changed no parity golden, so the characterization scenario is what guards the 8 h/24 h choice.

### Re-review fixes (R-01..R-04)

| Commit | Subject |
|---|---|
| `c69334081` | Add same-instant suspend and resume goldens |
| `4d9e0939b` | Pair the tied resume in the same-instant goldens |
| `eb3d95b20` | Restore the original pump history fetches (R-01, R-03, R-04) |
| `b90064ba8` | Order same-time pump events like the phone |
| `79c90f7b6` | Keep storage order for same-time events newest first (fixes the newest-first half of `b90064ba8`) |
| `d400ee998` | Pin phone fetches to the shared selection (R-02) |

- **R-01, fixed (no sign-off needed).** `OpenAPS` is back to the original two fetches: the 24 h list descending (`pumpHistoryLast1440Minutes`) and the 48 h orphan check ascending (`pumpHistoryLast48h`). Both predicates take their start from `OrefInputs`, so the code matches `920e1fcb6` except for those two expressions. I restored the two fetches rather than the suggested "one descending fetch, orphans over `reversed()`". `reversed()` only equals an ascending fetch if SQLite's tie order mirrors exactly; restoring the fetches needs no such assumption.
  - Observed tie order in the test store (`/dev/null` SQLite) and in an on-disk SQLite file, with a temporary probe test: a descending fetch returns same-timestamp rows in insertion order, an ascending one in reverse.
  - `algorithmPumpEvents` (watch/test builder) now follows the same rule: ties reversed in the ascending orphan check, in storage order in the newest-first result.
  - New scenarios `suspend-resume-same-instant` and `-on-disk`: a suspend 100 min ago, then a suspend and a resume at the same instant 90 min ago. The `-on-disk` variant seeds a temporary on-disk SQLite store. Each pump event is saved on its own, so row order follows the list. Both were recorded from the original sources (throwaway worktree at `ae8efa8d7`, recorded, compared twice, removed with `git worktree remove --force` on its literal path); the 15 other goldens came out identical again.
  - Proof: with `c4239815a`'s fetch code and selection file put back, both tie scenarios fail. The original code produces a determination; `c4239815a` throws `pumpSuspendResumeMismatch` (it keeps the resume, not the suspend, as the first of the tie). So the reorder was a real behaviour change on the phone, and it is gone.
- **R-02, test added.** `OrefInputsSelectionTests` checks the phone's own fetches against the shared Swift selection on the same rows:
  - TDD history through `OpenAPS.fetchHistoricalTDDData` with rows at start − 1 s, at start (excluded by `>`), start + 1 s, and totals 0 / nil / 0.01;
  - `BaseTDDStorage.hasSufficientTDD` at the threshold − 1 and at the threshold, with a zero-total row and an 8-day-old row;
  - `getGlucoseForAlgorithm` (24 h and 6.5 h) and `getCarbsForAlgorithm`, each with rows one minute either side of the window start. These read `Date()` themselves, so the exact `>=` edge is pinned only for TDD.
- **R-03, resolved** by the restore: no `isScheduledBasal` closure and no `tempBasal` faults on the phone.
- **R-04, resolved** by the restore: `nativePumpHistory(orphanedResumes:)` is fed again; `pumpHistoryLast1440Minutes` and `pumpHistoryLast48h` are production predicates again.

Results at `79c90f7b6`: full `X test` passed, 1004 total, 960 passed, 0 failed, 44 skipped (+4 = the four tests of the new selection suite). Both characterization suites: production 17/17, `OrefRun` 16/16. Package source typecheck passed.

## M2a: watch platform plumbing (2026-11-16)

Branch `feat/tow-platform`, off `feat/trio-on-watch` @ `349f49523`. Build and platform changes only: no loan logic, no UI, no kit linking.

### Commits

| SHA | Subject |
|---|---|
| `657d4c082` | Raise watch targets to watchOS 10.6 |
| `2f6504a96` | Add TRIO_ON_WATCH flag for watch capabilities |
| `a8c59d2d8` | Compile shared algorithm code in watch app |
| `58986d817` | Route watch algorithm logs to WatchLogger |

### What changed

- **Deployment target:** `WATCHOS_DEPLOYMENT_TARGET` 10 → 10.6 on the watch app, the complication extension and the watch tests (C-09 #5). `LoopKit-watchOS` and `G7SensorKit-watchOS` already require 10.6, so M2b needs it. Every watchOS 10 device can update to 10.6 (D-12). The only output change with the flag off is `MinimumOSVersion` in the watch app's Info.plist.
- **Build flag (V2-28, D-1):** `TRIO_ON_WATCH = NO` in `Config.xcconfig`. A builder sets `TRIO_ON_WATCH = YES` in `ConfigOverride.xcconfig` (or on the `xcodebuild` command line). The watch app target selects its variant by nested expansion:
  - `INFOPLIST_FILE = $(TRIO_ON_WATCH_INFOPLIST_$(TRIO_ON_WATCH))` and `CODE_SIGN_ENTITLEMENTS = $(TRIO_ON_WATCH_ENTITLEMENTS_$(TRIO_ON_WATCH))`.
  - Only the `_YES` names are defined (watch app target settings), so with the flag off both expand to empty, which is exactly today's state (generated Info.plist, no entitlements file).
  - With the flag on, `Trio Watch App Extension/TrioOnWatch-Info.plist` is merged into the generated plist (`GENERATE_INFOPLIST_FILE` stays on) and `Trio Watch App Extension/TrioOnWatch.entitlements` is used. `Trio Watch App/Info.plist` is not touched (C-09 #4).
  - Flag-on additions, and why each is needed:
    - `UIBackgroundModes` = `bluetooth-central`: the watch must keep the G7 and pod connections and receive BLE events while backgrounded. Same key and value as #1749.
    - `com.apple.developer.usernotifications.time-sensitive`: the dead-man and glucose alerts (§8) must use the time-sensitive level. The phone app already has this entitlement.
    - Nothing else. No app group, keychain group, HealthKit or workout mode is needed for M2a–M5 as designed.
  - The flag does not yet define a Swift compilation condition. M3/M5 add one when there is code to gate (D-2: the gate and Take Back stay unconditional).
- **Shared algorithm code on the watch:** the watch app target now compiles `Trio/Sources/APS/OpenAPSSwift/**` (46 files plus `AlgorithmLoggingShim.swift`), `APS/Extensions/DecimalExtensions.swift`, and the 17 models and 8 helpers listed in `AlgorithmPackage/Package.swift` (73 files). The entries are one contiguous, path-sorted block at the end of the watch app's Sources phase and of the PBXBuildFile section. M1's `OrefRun/*` and new models get added to that block when M1 is merged.
  - `PRODUCT_MODULE_NAME = Trio` on the watch app, as in #1749 and the package (whose module is also `Trio`). `BloodGlucose.swift` calls `Trio.rounded(...)`, which needs that module name. `Trio Watch App Tests/Unit Tests.swift` now uses `@testable import Trio` (C-09 #7).
  - No string catalog change: the watch app already bundles `Localizable.xcstrings`, and the Xcode build does not generate string symbols, so the C-09 #3 failure (SwiftPM only) does not apply here.
  - Nothing is linked: no LoopKit, OmnipodKit or G7SensorKit (M2b/M5).
- **Algorithm logging on the watch (C-09 #2):** `AlgorithmLoggingShim.swift` is active for `TRIO_ALGORITHM_PACKAGE || os(watchOS)`. Its sink now carries the level, and `warning`/`error`/`fault` include `description` and `error` in the message as the app logger does. The watch app sets `algorithmLogSink = WatchLogger.shared.algorithm` at launch. Lines keep their level and use a new `WatchLogEntry.Category.algorithm`, which reaches the phone's log as `Watch/Algorithm`. Nothing in the package used the sink before this change.

### Verification

Fresh simulators: iPhone 17 iOS 27.2 `E0E7F952-2B91-448E-9E45-05517E97EADD`, Apple Watch Series 12 46mm watchOS 27.2 `809F4B59-F49D-43BD-91E3-1996CF36F910` (paired). Xcode 27.2. `X` = `xcodebuild -workspace Trio.xcworkspace -derivedDataPath $DD`. Exit codes are each command's own `$?`.

| # | Step | Command | Result |
|---|---|---|---|
| 1 | Baseline iOS build before any change | `X -scheme Trio PHONE build` | 0, BUILD SUCCEEDED |
| 2 | Watch, simulator, flag off | `X -scheme "Trio Watch App" WATCH build` | 0 |
| 3 | Watch, simulator, flag on | same + `TRIO_ON_WATCH=YES` | 0 |
| 4 | Watch, device, flag off, signed | `X -scheme "Trio Watch App" -destination generic/platform=watchOS build` | 0 (binary `arm64 arm64_32`, team provisioning profile) |
| 5 | Watch, device, flag off, compile only | step 4 + `CODE_SIGNING_ALLOWED=NO` | 0 |
| 6 | Watch, device, flag on, compile only | step 5 + `TRIO_ON_WATCH=YES` | 0 |
| 7 | Watch, device, flag on, signed | step 4 + `TRIO_ON_WATCH=YES` | **65**: the watch app's team provisioning profile lacks the Time Sensitive Notifications capability. Expected; needs the capability on the watch App ID (not done: account change) |
| 8 | iOS app, flag off | `X -scheme Trio PHONE build` | 0 |
| 9 | Watch tests | `X -scheme "Trio Watch AppTests" WATCH test` | 0; 21 / 21 passed |
| 10 | Full `Trio Tests` | `X -scheme "Trio Tests" PHONE test` | 0; 996 total, 952 passed, 0 failed, 44 skipped (same as M0) |

Flag-off output compared with step 1 (Info.plist via `plutil`, entitlements via the `.xcent` files in `Intermediates.noindex`):

- iOS `Trio.app` Info.plist, `Trio.app.xcent` and `Trio.app-Simulated.xcent`: identical.
- Embedded `Trio Watch App.app` Info.plist: only `MinimumOSVersion` 10 → 10.6. Watch app and complication entitlements: identical (only `application-identifier`).
- Flag on vs flag off: the watch Info.plist gains only `UIBackgroundModes` = `[bluetooth-central]`, and the watch entitlements gain only the time-sensitive key. The iOS app's Info.plist and entitlements are identical between flag on and flag off.

The shim was also type-checked alone for macOS with `-D TRIO_ALGORITHM_PACKAGE` (OK). `swift test --package-path AlgorithmPackage` still fails at string-symbol generation on this toolchain (M0 step 8), so the package build itself was not re-run.

### Not verified

- E1 (D-1): whether TestFlight / App Store Connect accepts a watch bundle that declares `bluetooth-central`. The flag stays off until E1 runs. The flag-on browser build (fastlane) would also need the time-sensitive capability on the watch App ID.
- Intermediate commits were not built on their own. Only the tip was built and tested.
- No run on a device or on the CI toolchain (Xcode 26.2). Nothing installed or launched, so the algorithm log route was compiled but not exercised at runtime.
- The C-09 #1 drift check (watch Sources phase vs `Package.swift`) is not added. The membership was generated from `Package.swift` for this commit only.

### Worktree hygiene

- SwiftFormat rejoined the `@Test` line in `Trio Watch App Tests/Unit Tests.swift` again. Reverted; only the import change is committed.
- `Package.resolved` and submodules: unchanged and clean.

## M2b: kit pins and the foreign-session rule (2026-11-16)

Branch `feat/tow-kits`, off `feat/trio-on-watch` @ `349f49523`. Implements V2-6 and V2-29, plus the V2-7b context and the E safety conditions C-1 and C-2.

> [!IMPORTANT]
> The kit commits below exist only in this machine's submodule repositories, on local branches named `trio-on-watch`. Nobody else can check out or build `feat/tow-kits` until the maintainer mirrors them to loopandlearn (LoopKit `trio-on-watch`, OmnipodKit `trio-on-watch`) and updates the submodule URLs or branches. `.gitmodules` is unchanged.

### Pins

| Submodule | Before | After | Content |
|---|---|---|---|
| LoopKit | `babddf04` | `7fd4d1a7` | `babddf04` + cherry-pick of LoopKit#687 (`a78fe3bb`, author jeremybarnum). Nothing else from LoopKit `next-dev`; #695/#696 break the other kits. |
| OmnipodKit | `6fdf0e0e` | `e576b45` | loopandlearn/OmnipodKit#177 @ `3d21d9c` (jeremybarnum `sportmode/next-dev`) + `d5606d67`, `2e5f9bdc`, `b647ea98`, `e576b45` (review fixes, below). `6fdf0e0e` is an ancestor. |
| G7SensorKit | `08d48863` | unchanged | |

### The rule (OmnipodKit), as of `e576b45`

- An adopt, or taking back a pod this device had released, expects one EAP SQN resync. Any other resync on a shared pod is a foreign session, unless it is at or below the last SQN the pod accepted from this device (`AcceptedEapSqn`, saved at once, so this device's own late-saved counter isn't mistaken for another controller).
  - Every foreign session is reported: `foreignSessionDetectedAt` is updated, which reaches the host as `pumpManagerDidUpdateState`.
- If the foreign session falls outside a superseding take, the kit sets `refusesSessions` and lets go of the pod's BLE link. From then on, until the host makes a superseding take:
  - no session runs and nothing is sent: no bolus, no temp of any rate including zero, no suspend, no resume, no basal schedule, no alert acknowledgement, no status read;
  - there is no handshake at all, not even the retry after the resync that found the foreign session;
  - every refusal returns `PodCommsError.podUsedByAnotherController`.
- A superseding take is `takeControl(supersedingAnotherControllerUntil:)` with a date. It is for a Take Back from a peer that has not acknowledged `stopped`; the host passes takeover + 6 h.
  - Until that date, `stopSupersedingAnotherController()` (the peer acknowledged) or a release, foreign sessions are reported but don't stop this device (V2-7b). Within one boot the scope runs on uptime, so a clock change can't stretch it (M2b-07).
  - A plain `takeControl()` (End, lend, adopt, relaunch) never lifts a refusal and never ends a scope, and it marks the next resync expected only after a release (C-1, M2b-05, M3E-01).
- Pods never shared are unchanged.
- C-2: a fresh connect always handshakes. A new process on a shared pod never trusts saved session keys (`BlePodComms.init`), so its first session handshakes too. At `b647ea9` this was a restore hook that could lose a race with `autoConnectIDs` (M2b-02); it was replaced in `e576b45`. Both points come from reading the code.
- Why reductions are refused too: see `omnipodkit-177-proposal.md`.

### Verification

| # | Step | Result |
|---|---|---|
| 1 | OmniTests at `b647ea9`, against the pinned submodules (LoopKit `7fd4d1a7`, RileyLinkKit `52a652c9`), on a fresh iPhone 17 / iOS 27.2 simulator | 255 run, 0 failed, 3 skipped. Superseded by the review-fix results below |
| 2 | Mutation checks at `b647ea9` | They mutated shared `PodState` code only. The M2b review showed that removing every guard outside `PodState` left all tests green (M2b-01). Superseded below |
| 3 | `OmnipodKit-watchOS` for the watchOS simulator and `arm64_32`; `OmnipodKitPlugin` for iOS | Build succeeded |
| 4 | Trio iOS app, `X -scheme Trio` on a fresh "Trio-M2b iPhone 17" (iOS 27.2) | Exit 0. DanaKit, MedtrumKit, MinimedKit, LibreTransmitter, LibreLoop, G7SensorKit, OmnipodKit, LoopKit (and LoopKit-watchOS) compiled as part of it |
| 5 | Full `Trio Tests`, three runs on the same simulator | Run 1: 933 passed, 19 failed, 44 skipped. Run 2: 940 / 12 / 44. Run 3: **952 / 0 / 44** (= M0) |
| 6 | The 10 suites that failed in run 1, run alone | 55 passed, 0 failed, 1 skipped |
| 7 | A/B: the same full run with the old pins (`babddf04`, `6fdf0e0e`) | 952 / 0 / 44 |

#### Runs 1–2 failures

All the failures in runs 1 and 2 are test-host crashes ("Restarting after unexpected exit"), a different set of tests each time. The four crash reports show heap corruption:
- `___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED` in `-[_UIAppearance _handleSetterInvocation:]`, called from `TrioApp.configureTabBarAppearance()` ← `TrioApp.init()` ← `BolusSafetyValidatorTests.init()` / `BolusCalculatorTests.init()`;
- later malloc traps in unrelated code.

No crash report has a LoopKit, OmnipodKit or RileyLink frame. Four suites build `TrioApp()` in a stored property (`let resolver = TrioApp().resolver`), so parallel Swift Testing suites run UIAppearance setters off the main thread at the same time.

The machine's load average was 90–175 during the runs, from other agents' builds. Probable cause (inferred, not proven): a pre-existing race in those tests that load makes more likely. Run 3 and the baseline A/B both passed clean. It is not fixed here because it is out of M2b's scope; it's worth a follow-up.

### Not executed or not verified

- No hardware: no pod and no watch device.
- The pod side of the rule is not verified. It is modelled by a pod double in `DeviceHandoffTests`, so these are our reading of the protocol, not traces:
  - that a resync-answered handshake leaves the pod's counter unchanged;
  - that a message under stale keys is dropped.
- The restored-link handshake (C-2) has no unit test, because a `BlePodComms` needs a Bluetooth central. It was checked by reading the code only.
- The watch app was not built here (M2a). Nothing in the Trio app calls the new API yet (M4/M5).
- The kits' own test suites other than OmniTests were not run.

### Worktree hygiene

- The build-phase SwiftFormat reformatted `Trio Watch App Tests/Unit Tests.swift` again (as in M0). Reverted.
- `Package.resolved`: unchanged.
- No dirty files inside any submodule.

### Review fixes (`e576b45`, M2b review M2b-01..10 and M3E-01)

| Finding | Change |
|---|---|
| M2b-01 | The handshake decisions are `PodState` methods (`nextHandshakeSqn`, `handshakeResynced(to:lastAcceptedHere:)`, `sessionEstablished`), called by `BlePodComms` and by the test double. Manager-level tests use an Eros-typed `OmniPumpManager` (no Bluetooth central) and go through `runSession` |
| M2b-02 | The restore hook is gone. `BlePodComms.init` requires a handshake on any shared pod |
| M2b-03 | `AcceptedEapSqn`: the last SQN the pod accepted, in `UserDefaults` keyed by the pod's lot and sequence numbers, written right after the pod accepts. A resync at or below it is this device's own counter |
| M2b-04 | A refusal in `establishNewSession` or `bleRunSession` calls `releaseConnection()`, and a refused manager doesn't dial at launch. A superseding take re-arms the connection, and the reconnect handshakes |
| M2b-05 / M3E-01 | Only `takeControl(supersedingAnotherControllerUntil:)` lifts a refusal and starts a scope. A plain take keeps both, and it expects a resync only after a release. A release ends the scope. Host contract in the proposal |
| M2b-06 | Documented as a limit in the proposal (a stale counter from attempts that never reached the pod) |
| M2b-07 | `SupersedingTake` runs on uptime within one boot (`kern.bootsessionuuid`) and on the wall clock across a reboot, where a clock set back before the take ends it |
| M2b-08 | The proposal and this section now separate what tests show from what was read in code |
| M2b-09 | A recovery suggestion for `podUsedByAnotherController`. The four new fields appear in `PodState.debugDescription` |
| M2b-10 | The doc comments say to call these off the main thread |

| # | Step | Result |
|---|---|---|
| R1 | `DeviceHandoffTests` | 43 run, 0 failed (15 new, 4 of them manager-level) |
| R2 | OmniTests, all, against the exact pins (LoopKit `7fd4d1a7`, OmnipodKit `e576b45`, RileyLinkKit `52a652c9`) | 261 run, 0 failed, 3 skipped |
| R3 | `OmnipodKit-watchOS` for the watchOS simulator and `arm64_32` | Build succeeded |
| R4 | Trio iOS app, `X -scheme Trio`, "Trio-M2b iPhone 17" | Exit 0; DanaKit, MedtrumKit, MinimedKit, LibreTransmitter and OmnipodKit recompiled as part of it |

Mutation runs on the production code, one at a time and each reverted, `DeviceHandoffTests` only:

| Mutation | Result |
|---|---|
| M1 `OmniPumpManager.runSession` refusal removed | 3 failures (both manager-level refusal tests) |
| M2 `nextHandshakeSqn` ignores the refusal | 12 failures (6 tests) |
| M3 `sessionEstablished` does nothing | 19 failures (7 tests) |
| M4 accepted counter ignored | 3 failures (own-counter test) |
| M5 a plain take lifts the refusal | 1 failure |
| M6 a release keeps the scope | 1 failure (manager-level) |
| M7 scope on the wall clock only | 2 failures (clock test) |
| M8 never refuse | 19 failures (8 tests) |
| M9 no report | 6 failures (6 tests) |
| M10 a plain take expects a resync without a release | 1 failure (manager-level) |
| M11 a shared pod trusts saved keys (`BlePodComms.init`) | **survives**: `BlePodComms` can't be built in tests |
| M12 a refusal keeps the link | **survives**: same reason |

So the `BlePodComms` call sites are checked by code reading only: the `init` condition, the `establishNewSession` and `bleRunSession` refusals, `releaseConnection()` on refusal, and the `AcceptedEapSqn` save and read. Everything else in the rule fails a test when removed.

Trio-side code is unchanged by the review fixes, so the full `Trio Tests` were not re-run.

### Re-review fixes (`1450b24`, M2b re-review R-01..R-05)

| Finding | Change |
|---|---|
| R-01 | `SupersedingTake` runs on `CLOCK_MONOTONIC_RAW` (via `clock_gettime_nsec_np`), with the boot-session check and wall-clock fallback kept. The SDK `_time.h` defines it, and the `clock_gettime(3)` man page says it runs "like `CLOCK_MONOTONIC`", which "will continue to increment while the system is asleep", while `CLOCK_UPTIME_RAW` "does not increment while the system is asleep". |
| R-02 | A plain `takeControl()` on a refused manager returns before the radio part (no `rearmConnection`, no take escalation) and logs a device event. |
| R-03 | Host contract: only one side ever makes a dated take (the phone in Trio). It is in the proposal and the `takeControl(supersedingAnotherControllerUntil:)` doc comment. |
| R-04 | New `takeControlLiftingRefusal()` lifts a refusal without a scope (internally a dated take at `distantPast`, and an `until` in the past starts no scope). Chosen over a documented `until <= now` idiom because the call site then says what it means. |
| R-05 | `AcceptedEapSqn.remove` on `BlePodComms.forgetPod`. The key lives in the device's own `UserDefaults` and is never exported. |

| # | Step | Result |
|---|---|---|
| RR1 | `DeviceHandoffTests` | 46 run, 0 failed (3 new) |
| RR2 | Mutations: scope clock back to `systemUptime`; plain take of a refused pod re-arms; a past `until` starts a scope | 1 failure each, in the matching new test. The clock test relies on the host having slept since boot (then `CLOCK_MONOTONIC_RAW` > `systemUptime`); on a device that never slept, the two are equal and that mutation would survive |
| RR3 | OmniTests, all, against the exact pins (OmnipodKit `1450b24`) | 264 run, 0 failed, 3 skipped |
| RR4 | `OmnipodKit-watchOS`, simulator and `arm64_32` | Build succeeded |
| RR5 | Trio iOS app, `X -scheme Trio`, "Trio-M2b iPhone 17" | Exit 0 |

#### Wiring checked by reading only

These can't be unit-tested because a `BlePodComms` needs a Bluetooth central. Every other part of the rule fails a test when removed.

- `BlePodComms.init`: a handshake is required on any shared pod.
- `BlePodComms.establishSession`, resync case: calls `handshakeResynced(to:lastAcceptedHere:)` with `AcceptedEapSqn.value`.
- `BlePodComms.establishSession`, session-keys case: calls `sessionEstablished()`, then `AcceptedEapSqn.save`.
- `BlePodComms.establishNewSession`: both handshakes take their SQN from `nextHandshakeSqn()`, and nil throws `refuseSessions()`.
- `BlePodComms.bleRunSession`: the `refusesSessions` guard calls `refuseSessions()`.
- `BlePodComms.refuseSessions()`: calls `releaseConnection()`.
- `BlePodComms.forgetPod`: calls `AcceptedEapSqn.remove`.
- `OmniPumpManager.init` (line 139): a refused pod gets `releaseConnection()` at launch.
- `takeControl`'s radio part (`rearmConnection`, search, escalation), skipped for a plain take of a refused pod. The early return itself is tested through an Eros manager.

