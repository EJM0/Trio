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

## M1b: pure calculations (2026-11-16)

Branch `feat/tow-pure-calcs`, worktree `~/workspaces/Trio-tow-pure-calcs`, on `feat/tow-oref-run` at `3d55e4102` (rebased from `d40070789`). Local signed commits, not pushed. Each item is a characterization commit (goldens recorded on the unmodified code) followed by the change.

| Commit | Subject |
|---|---|
| `d8a5375ec` | Add time-of-day characterization goldens |
| `97bd472ed` | Look up oref schedules in an explicit time zone |
| `c24226f65` | Make microBolusAllowed an explicit oref input |
| `4f986dc85` | Add bolus calculator characterization goldens |
| `ed4e49788` | Extract the bolus calculator math into a pure type |
| `137121345` | Add glucose alarm characterization goldens |
| `ce5190c3c` | Extract glucose alarm decisions into a pure type |

### What was done

**Time zone (V2-23).** `OrefInputs.timeZone`. Every time-of-day lookup in the oref Swift port goes through `WallClock`: `secondsIntoDay` (profile basal/ISF/CR/target lookups, autosens, IOB temp-basal splits, `DosingEngine` hour and minute checks), the `Profile` getters (`basalFor`, `sensitivityFor`, `carbRatioFor`, now on `WallClock.calendar`) and the reason-string `jsDateString`. `WallClock.boundTimeZone` is a `@TaskLocal`; unbound it is `TimeZone.current`, as before. The stages `profiles`, `autosens`, `meal`, `iob` and `determine` take `timeZone:` and bind it for their body; `run` passes `inputs.timeZone`; `OpenAPS` and the parity pipeline pass `TimeZone.current`. The one zone-dependent selection rule, `OrefInputs.carbsStart` (one calendar day back, 23 or 25 h across DST), takes `timeZone:` too; `CarbsStorage` passes `TimeZone.current`. The other selection windows are fixed durations. Calendar elapsed-minutes semantics in the `Profile` getters are unchanged (only the calendar's zone is set). A task-local instead of a parameter through every generator keeps the parity-sensitive generator signatures untouched; it is read synchronously inside the stage, and the oref code has no concurrency hops.

**`microBolusAllowed` (N-1).** `OrefInputs.microBolusAllowed`, passed to `OrefRun.determine` (was hard-coded `true` there). `OpenAPS` passes `true`. No determination field is stripped. As first committed, false only gated `determineSMBDelivery`; the review (M1b-01) showed that is not oref's non-SMB path. See the review fixes below.

**Bolus calculator (ADR-005, V2-24).** `Trio/Sources/Services/BolusCalculator/BolusCalculator.swift`, Foundation only. `CalculationInput` and `CalculationResult` moved there unchanged. The manager keeps every fetch (settings, schedules, Core Data glucose and determination, backdating) and calls:
- `BolusCalculator.calculate(_ input: CalculationInput, now: Date, roundBolus: (Decimal) -> Decimal) -> CalculationResult` (was `calculateInsulin(input:)`; `now` replaces `Date()`, `roundBolus` is `apsManager.roundBolus`)
- `BolusCalculator.glucoseVariables(readings: [(date: Date?, glucose: Int16)], now: Date) -> BolusCalculator.GlucoseVariables` (was `updateGlucoseVariables(with:)`)

Not moved: `getCurrentSettingValue` (the watch has the profile's current values from its own `OrefRun`), the determination fallbacks and the backdated-carbs rule in `prepareCalculationInput`.

**Glucose alarms (ADR-006, V2-16).** `Trio/Sources/Services/Alerts/GlucoseAlarmEvaluation.swift`, Foundation only, over the Codable `GlucoseAlert` list and `GlucoseAlertConfiguration`:
- `evaluateReading(latestMgDL:alarms:configuration:firing:now:calendar:) -> [Action]`
- `evaluateForecast(_ determination:alarms:configuration:firing:now:calendar:) -> [Action]`
- `evaluateCarbsRequired(_ carbsRequired: Decimal?, alarms:configuration:firing:now:calendar:) -> [Action]`
- `Action` is `.fire(GlucoseAlert, valueMgDL:)` or `.retract(GlucoseAlert)`; `firing: inout Set<UUID>` is the coordinator's firing set. Also `breached`, `shouldRetract`, `isEligible`, `recoveryMarginMgDL`, `readingFreshnessWindow` (moved from the coordinator).

`GlucoseAlertCoordinator` keeps the launch quiet window, the CGM-ownership retraction, the Core Data fetch of the latest reading, snooze handling, and the alert content (title, body, interruption level, sound, identifier).

### Characterization

| Suite | Recorded through | Content |
|---|---|---|
| `OrefRun time-of-day goldens` | `OrefRun.run` (OpenAPS reads `Date()`, so the clock can't be fixed there) | closed-loop baseline with non-flat basal/ISF/CR/target schedules at 07:40 CEST, at 03:20 CEST on the spring-forward day and at 06:40 CET on the fall-back day; all seven stages per scenario. Enabled only in Europe/Berlin |
| `Bolus calculator characterization goldens` | `BaseBolusCalculationManager` with an `APSManager` stub that rounds down to 0.05 U | 23 input cases (standard, fatty meal, super bolus, both, override-adjusted ISF/CR/target, glucose and min predicted below / at 54, loop 15 min ± 10 s, COB cap, IOB above max IOB, negative correction with and without super bolus / fatty meal, no glucose, flat / falling delta, max bolus and max IOB caps, rounding, repeating decimals); 8 glucose-delta cases |
| `Glucose alarm characterization goldens` | `GlucoseAlertCoordinator` with an alert manager spy | 10 step sequences: low / urgent low / high hysteresis, urgent low suppressing low, disabled alarms and the urgent-low floor, per-alarm snooze, day and night windows (wrapping and not), several alarms of one type, interruption level and sound, forecasted low with low-family suppression, carbs required |

The characterization commits widen access only: `updateGlucoseVariables` and its struct; the coordinator's `evaluationQueue`, `alertsSnapshot`, `configurationSnapshot`, `applyReadingBasedEvaluation`, and `launchedAt` (`let` → `var`). After each extraction the same goldens are checked through the phone type and through the pure function.

### Commands and results

`X` = `xcodebuild -workspace Trio.xcworkspace -scheme "Trio Tests" -destination 'platform=iOS Simulator,id=D20E4570-0D6D-4323-9741-B253097ECCD7,arch=arm64' -derivedDataPath $DD test`. Simulator "TOW-M1b-pure-calcs", iPhone 17 Pro, iOS 27.2, created for M1b. Recording (before the rebase): `TEST_RUNNER_TRIO_RECORD_GOLDENS=1`; M1 has since moved it to `TEST_RUNNER_TRIO_RECORD_CHARACTERIZATION=1`.

| # | Command | Result |
|---|---|---|
| 1 | record at `d40070789` + test files: `X -only-testing:` the three new suites | recorded; then compare run on the same sources passed (5/5, with `OrefRunCharacterizationTests`) |
| 2 | after `e6167f1a5`: time-of-day, `OrefRunCharacterizationTests`, `OrefCharacterizationTests`, `ParityGoldenTests`, `WallClockParityTests` | passed, 9 |
| 3 | after `6d80072f7`: `OrefRunMicroBolusTests` + the three oref characterization suites | passed, 7 |
| 4 | after `94c273893`: bolus characterization, `BolusCalculatorTests`, `AlgorithmSuggestedBolusTests` | passed 17, skipped 1 (the source-disabled flaky test) |
| 5 | after `3c04e0149`: alarm characterization, `GlucoseAlertCoordinatorTests`, `ForecastedGlucoseEvaluatorTests`, `GlucoseAlertTests`, `GlucoseAlertConfigurationTests`, `ContainerResolutionTests` | passed, 56 |
| 6 | full `X` at `3c04e0149` | passed: 1009 total, 965 passed, 0 failed, 44 skipped (M1 at `d40070789`: 998 / 954 / 0 / 44; +11 new tests). Skips as in M0 |
| 7 | mutation: recovery margin 5 → 4, and `minPredBG < 54` → `<= 54` | both coordinator/manager and pure golden tests failed; reverted |
| 8 | package source list `swiftc -typecheck` (as in M1) | passed (81 files) |

New behavior tests: another zone (America/New_York) looks the non-flat schedules up at its own local time; the same local time in Asia/Tokyo reproduces the Berlin golden byte for byte; the `Profile` getters follow the bound zone. `microBolusAllowed = false` on two SMB scenarios gives no units, no "low temp" or "Microbolusing" in the reason, the same `insulinReq` and predictions, and a 30 min temp above the profile basal.

### Quirks preserved

- `Profile.basalFor` / `sensitivityFor` / `carbRatioFor` use elapsed minutes since midnight, `WallClock` uses wall-clock minutes; on DST days they disagree by an hour. The goldens record it (the getters are fallbacks, so the profile values come from `WallClock`).
- The time zone is read once per stage instead of at every lookup; it only differs if the system zone changes mid-stage.
- Bolus: current glucose is the newest reading of any age, even one without a date, while the delta uses only dated readings from the last 20 min. Negative wholeCalc skips the fraction and fatty-meal factor; super bolus is still added. `minPredBG`/glucose 54 is allowed, 53 is not. Loop staleness is strictly over 15 min. Rounding is applied once in the calculator; the Treatments screen rounds the result again.
- Alarms: no hysteresis for carbs required; snooze ends at its instant (`snoozedUntil == now` fires); urgent-low recovery at threshold + 5 immediately lets low fire; disabled urgent-low alarms still fire. The reading path's unreachable `forecastedLow` early return was dropped (the loop only visits reading-driven types).

### Bugs and oddities found, not fixed

- The bolus recommendation can be **negative**: with IOB above max IOB, `min(…, maxIOB - iob)` goes below 0 after the `max(…, 0)` (golden `iob-above-max-iob`: −1 U with the stub; without a pump `roundBolus` returns it unchanged). `TreatmentsStateModel` does not clamp it. I did not check what the UI or a real driver's rounding shows.
- `GlucoseAlertType` imports LoopKit and its `defaultSoundFilename` reaches `AlarmSoundCatalog` → `DeviceAlertSeverity` (LoopKit). The new pure evaluator is Foundation only, but its model types are not yet (M2a). `BolusCalculator` and `GlucoseAlarmEvaluation` also use Trio's `debug` and `Decimal.rounded(toPlaces:)`.
- `BolusCalculatorVariables.lastLoopDate` and `insulinRequired`/`evBG` are filled but never read.

### Not verified

- `swift test` on `AlgorithmPackage` (toolchain, M0); only `swiftc -typecheck`.
- Determination-path alarm steps use the coordinator's `Date()`, so day/night and snooze are characterized on the reading path only.
- The bolus manager's input gathering (`prepareCalculationInput`, `getCurrentSettingValue`, backdating) has no characterization; it was not changed.
- No device, in-vitro or in-vivo run; no watch build (M2a). Xcode 26.2 not installed.

### Worktree hygiene

SwiftFormat reformatted `Trio Watch App Tests/Unit Tests.swift` on every build; reverted each time. `Package.resolved` and submodules unchanged. No `actual-*.json` left.

### After the rebase onto M1 `3d55e4102`

Conflicts: `OrefRun.swift` (M1's stage changes, including `autosens(includeDeviationsForTesting:)`) re-done with the same `timeZone:` threading, and this status file. Also threaded: `ParityScenarios.runPipeline` (now on the `OrefRun` stages) passes `TimeZone.current` and `microBolusAllowed: true`; `carbsStart`/`carbs` take `timeZone:`. No golden was re-recorded.

| # | Command | Result |
|---|---|---|
| 1 | all characterization and parity suites: `OrefCharacterizationTests`, `OrefRunCharacterizationTests`, `OrefRunMicroBolusTests`, `OrefTimeOfDayCharacterizationTests`, `OrefInputsSelectionTests`, `OrefRunStageTests`, `BolusCalculatorCharacterizationTests`, `GlucoseAlarmCharacterizationTests`, `ParityGoldenTests`, `WallClockParityTests` | passed, 22 (M1's 17 production scenarios and all M1b goldens unchanged, no `actual-*.json`); run twice |
| 2 | full `X` (run 1) | host app crashed early: `malloc: pointer being freed was not allocated` while several suites started in parallel (`TrioApp()` inits in the log). 16 in-flight tests reported as crashed. Not reproduced in runs 2 and 3 |
| 3 | full `X` (runs 2 and 3) | 1015 total, 970 passed, 1 failed, 44 skipped. The failure is `FileStorageTests` "Can parse mmol/L settings to mg/dL" (the order-dependent flake in `.claude/rules/testing.md`); `FileStorageTests` alone: 9/9 passed |
| 4 | package source list `swiftc -typecheck` | passed (82 files) |

The crash in run 1 has no crash report on the host, so its cause is not identified. I don't think it comes from M1b, because nothing in M1b frees memory by hand, but that is not verified.

### Review fixes (M1b review, 2026-11-16)

| Commit | Subject | Finding |
|---|---|---|
| `c30abf9c3` | Follow oref JS when micro boluses are not allowed | M1b-01 |
| `5cc83fd3f` | Look up TDD scheduled basal in an explicit time zone | M1b-02, M1b-04 |
| `be9f90eb1` | Test the carbs window in its own time zone | M1b-03 |
| `c025100e4` | Require an explicit time zone for alarm windows | M1b-04 |
| `445f9268b` | Inject the alert coordinator's launch time | M1b-07 |
| `c844aade8` | Add a process time zone escape test | M1b-04 |
| `d04deb8ed` | Keep LoopKit out of the glucose alarm models | M1b-08 |
| `ae0f568ee` | Use a fixed 24 h pump history window | M1b-09 |

- **M1b-01.** `microBolusAllowed = false` now does what trio-oref's `determine-basal.js` does. `enable_smb` returns false ("SMB disabled (!microBolusAllowed)"), so `smbIsEnabled` is false in the top-of-hour neutral-temp cancel and in both "don't cancel SMB zero temp" guards. The "currenttemp rate != lastTemp rate" cancel runs only when micro boluses are allowed (JS line 678). With `true` nothing changes: every golden and the parity suite are unchanged.
  - JS reference: `TrioTests/OpenAPSCharacterization/js/determine-basal-jsc.js` runs `trio-oref/lib/determine-basal/determine-basal.js` (with `glucose-get-last.js`, `basal-set-temp.js`, `round-basal.js`) under JavaScriptCore's `jsc` (`/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc`), with shims for `require`, `lodash/endsWith`, `console` and `process.stderr`. `OrefRunMicroBolusJSParityTests` records the determination inputs from `OrefRun.run` (`TRIO_RECORD_CHARACTERIZATION=1`); `TZ=Europe/Berlin jsc determine-basal-jsc.js -- trio-oref/lib js-inputs-….json` writes `js-determination-….json`. Goldens in `goldens/micro-bolus-js/`.
  - 5 scenarios × allowed / not allowed, all equal to JS in rate, duration, units and reason: SMB plus low temp; delta below expected with a zero temp running (JS line 1403: not allowed sets the scheduled basal as temp); in range with a zero temp running (line 1429: same); top of the hour with `skip_neutral_temps` (line 1286: not allowed cancels the temp); temp mismatch (line 678: allowed cancels, not allowed carries on to a high temp).
  - The reason's `COB:` value is masked in the comparison: JS gets the port's unrounded meal COB and prints it raw, the port prints it rounded. Feeding JS a rounded COB (as `meal/total.js` would) moves minPredBG by 1 mg/dL: a pre-existing port difference, not M1b.
  - Mutation: both gates removed → the four not-allowed scenarios that reach those lines fail; the allowed ones pass.
- **M1b-02.** `ScheduledBasalInference.segments` and `delivery`, and `OrefInputs.tddInsulin`, take `timeZone:`. TDDStorage, Home (`activeBasalDelivery`) and the basal chart pass `TimeZone.current`. Test: same history at 14:30 CEST and 14:30 JST gives the same scheduled basal; Tokyo at the Berlin instant differs. Mutation (inference back on `Calendar.current`) caught.
- **M1b-03.** `carbsStart` on the America/New_York spring-forward day: 23 h in New York, 24 h in Berlin. Mutation (`Calendar.current`) caught.
- **M1b-04.** Explicit zone on every shared entry point: `OrefRun` stages, `carbsStart`/`carbs`, `tddInsulin`, `ScheduledBasalInference`, and `GlucoseAlarmEvaluation` (`timeZone:` replaces `calendar: = .current`; the coordinator passes `TimeZone.current`; the watch passes the grant's zone per ADR-004). The bolus calculator has no time-of-day input. The task-local stays inside the generators; it is unbound only when a test calls a generator directly. `ProcessTimeZoneEscapeTests` sets the process zone to Pacific/Kiritimati (`TZ`, `tzset`, `resetSystemTimeZone`), then checks `OrefRun.run` against the three time-of-day goldens, `tddInsulin` against its Berlin result, and an alarm's night window, all with an explicit Europe/Berlin. Because changing the process zone races every parallel suite, it runs only with `TRIO_TZ_ESCAPE=1` and alone. Passed; mutation (`WallClock.timeZone` ignoring the binding) caught.
- **M1b-07.** `launchedAt` is `private let`, injected through `init(resolver:launchedAt:)` (default `Date()`). The coordinator golden still builds the full assembly; I didn't reduce it to stubs.
- **M1b-08.** The LoopKit dependency was `DeviceAlertSeverity.init?(level: Alert.InterruptionLevel)`, reached from `GlucoseAlertType.defaultSoundFilename` through `AlarmSoundCatalog`. Moving only `defaultSoundFilename` would not make the models Foundation-only, because `GlucoseAlert.init(type:)` and its decoder fall back to it. So that one initializer moved to `DeviceAlertSeverity+InterruptionLevel.swift` (imports LoopKit), and `GlucoseAlertType` and `DeviceAlertSeverity` dropped `import LoopKit`. `swiftc -typecheck` of the package sources plus `BolusCalculator`, `GlucoseAlarmEvaluation`, `ForecastedGlucoseEvaluator` and the alarm models (`GlucoseAlert`, `GlucoseAlertType`, `GlucoseAlertConfiguration`, `DayNightOptions`, `AlarmSoundCatalog`, `DeviceAlertSeverity`) passes with Foundation only.
- **M1b-09.** `pumpHistoryStart` is `now - 1440 min` (same instant as before); `WallClock`'s doc names both pieces of state.
- Not fixed here, as agreed: M1b-05 (negative bolus recommendation), M1b-06 (parallel `TrioApp()` crash).

| # | Command | Result |
|---|---|---|
| 1 | 22 targeted suites (all characterization, parity, DetermineBasal SMB/early-exit/aggressive, selection, stage, inference, finalization, alarm, bolus, device alerts, container) | passed, 169 |
| 2 | `TRIO_TZ_ESCAPE=1`, `ProcessTimeZoneEscapeTests` alone | passed, 1 |
| 3 | full `X` at `ae0f568ee` | passed: 1020 total, 975 passed, 0 failed, 45 skipped (+1 skip: the env-gated escape test). No crash and no FileStorage flake in this run |
| 4 | package source list and the alarm/bolus closure, `swiftc -typecheck` | passed |


### Re-review fix (R2-01, 2026-11-16)

| Commit | Subject |
|---|---|
| `0cb1ded50` | Inject a clock into OpenAPS and its algorithm fetches |
| `dc024e740` | Pin the characterization clock to a fixed morning |
| `6dc0dcbd5` | Run the time zone escape test in CI |
| `53eb9837e` | Note the JS parity profile and COB mask |

- **Clock seam.** `OpenAPS`, `BaseGlucoseStorage`, `BaseCarbsStorage` and `BaseTDDStorage` take `now: () -> Date` (default `Date.init`, next to `contextProvider`). Every time read on the characterization path goes through it:
  - the profile, autosens and determination clocks, the autosens timestamp, the custom-variables and TDD windows, and the simulated bolus timestamp;
  - the pump-history (24 h, 48 h), active temp target and active override predicates (new `(now:)` forms; the existing `static var`s call them with `Date()`);
  - the glucose, carbs and TDD-sufficiency fetch windows.

  Production passes nothing, so each read is still `Date()` at the same point. `determineBasal(clock:)` keeps its `Date()` default, and stored forecast dates still read `Date()`; neither reaches a golden.
- **Pinned clock.** `OrefCharacterizationScenarios.makeClock()` is 2026-06-15 07:40:10 CEST for every M1 scenario, `simulation` included; the production-path test injects it as `now`. The M1b time-of-day, JS-parity, bolus and alarm suites already used fixed clocks or no time of day.
- **Provenance.** I made a throwaway worktree at `ae8efa8d7` (baseline + context injection) at `~/workspaces/Trio-tow-m1b-record` and applied only the same clock seam there (the 7 production files above, plus the `hasSufficientTDD(context:now:)` call in `DynamicISFEnableTests`). I copied in the current scenario and production-test files, built with `CI=true` into separate derived data on the same simulator, and recorded with `TRIO_RECORD_CHARACTERIZATION=1`. All 17 goldens came out byte-identical to the committed ones, so none changed. Two compare runs passed there. The worktree was then removed with `git worktree remove --force /Users/dnzxy/workspaces/Trio-tow-m1b-record`.
- **Proof.** Every run was on simulator `D20E4570-…`:

  | Run | Process zone, local time | Result |
  |---|---|---|
  | fixed clock, all characterization suites | Europe/Berlin, 20:18 | 27/27 passed |
  | control: `makeClock()` back on real time | Europe/Berlin, 20:20 | 2/2 suites failed (`autosens-8h-24h-differ/iob`, `defaults-no-settings/iob`, …): the evening failure is reproducible right now |
  | fixed clock; scheme `TZ` set to Europe/Moscow for the run only (not committed) | Europe/Moscow, 22:21 | 19 passed, 8 skipped (the Berlin-gated suites); all 17 production scenarios passed |
  | full `X` | Europe/Berlin, 20:22 | 1020 total, 975 passed, 0 failed, 45 skipped |

  I didn't wait for a real 22:30 in Berlin: the Moscow run puts the process at local 22:21, which is the failing mechanism (the IOB projection crossing local midnight).
- **Escape test in CI.** `unit_tests.yml` gains a step after "Run tests": `TEST_RUNNER_TRIO_TZ_ESCAPE=1 xcodebuild test-without-building … -only-testing:TrioTests/ProcessTimeZoneEscapeTests`. It reuses the build and runs alone. Locally that exact command passed (1 test). Not verified on GitHub Actions.
- R2-02 (meal COB rounding) is untouched; the mask's comment now points at it.

## M2a: watch platform plumbing (2026-11-16)

Branch `feat/tow-platform`, off `feat/trio-on-watch` @ `349f49523`. Build and platform changes only: no loan logic, no UI, no kit linking.

### Commits

| SHA | Subject |
|---|---|
| `657d4c082` | Raise watch targets to watchOS 10.6 |
| `2f6504a96` | Add TRIO_ON_WATCH flag for watch capabilities |
| `a8c59d2d8` | Compile shared algorithm code in watch app |
| `58986d817` | Route watch algorithm logs to WatchLogger |
| `c5f0a1a18` | Merge feat/trio-on-watch into feat/tow-platform (M1 + M2b; adds M1's 9 files to the watch target) |
| `4659d3d41` | Check watch algorithm sources against the package |
| `f3d057878` | Format watch algorithm errors like WatchLogger |

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
- **Shared algorithm code on the watch:** the watch app target now compiles `Trio/Sources/APS/OpenAPSSwift/**` (46 files plus `AlgorithmLoggingShim.swift`), `APS/Extensions/DecimalExtensions.swift`, and the 17 models and 8 helpers listed in `AlgorithmPackage/Package.swift` (73 files). The entries are one contiguous, path-sorted block at the end of the watch app's Sources phase and of the PBXBuildFile section. The merge of `feat/trio-on-watch` (M1 + M2b) added M1's 9 files to that block, so it now holds 82, matching the package (see review follow-ups).
  - `PRODUCT_MODULE_NAME = Trio` on the watch app, as in #1749 and the package (whose module is also `Trio`). `BloodGlucose.swift` calls `Trio.rounded(...)`, which needs that module name. `Trio Watch App Tests/Unit Tests.swift` now uses `@testable import Trio` (C-09 #7).
  - No string catalog change: the watch app already bundles `Localizable.xcstrings`, and the Xcode build does not generate string symbols, so the C-09 #3 failure (SwiftPM only) does not apply here.
  - Nothing is linked: no LoopKit, OmnipodKit or G7SensorKit (M2b/M5).
- **Algorithm logging on the watch (C-09 #2):** `AlgorithmLoggingShim.swift` is active for `TRIO_ALGORITHM_PACKAGE || os(watchOS)`. Its sink now carries the level and the error. `warning`/`error`/`fault` join `description` onto the message as the app logger does, and the watch formats the error with `WatchLogger.message(_:error:)` ("(domain code: description)"), the same as its own lines (M2aC-04). The watch app sets `algorithmLogSink = WatchLogger.shared.algorithm` at launch. Lines keep their level and use a new `WatchLogEntry.Category.algorithm`, which reaches the phone's log as `Watch/Algorithm`. Nothing in the package used the sink before this change.

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
- The membership check only fails when a package source is missing from the watch target. A watch-only extra file is not flagged; that is harmless.

### Review follow-ups (M2a review C)

- **M2aC-02 (done):** the merge commit adds `OrefRun/OrefInputs.swift`, `OrefInputs+Mapping.swift`, `OrefInputs+Selection.swift`, `OrefInputs+TDD.swift`, `OrefRun.swift`, `Models/DosingMode.swift`, `Models/Preferences+DosingMode.swift`, `Helpers/TempTargetCalculations.swift` and `APS/Storage/ScheduledBasalInference.swift` to the watch target, which brings it to 82. `TrioTests/WatchAlgorithmMembershipTests.swift` reads `AlgorithmPackage/Package.swift` (the `sources` entries, with directories expanded, plus the model and helper lists) and the watch app's Sources phase from `project.pbxproj`, resolving full paths through the groups. It fails with the list of missing paths. It runs in the normal `Trio Tests` scheme, so CI runs it too. A negative run was done: with `OrefRun.swift` removed from the watch phase, the test failed and named that file.
- **M2aC-04 (done):** see the logging bullet above.
- **M2aC-05 (documented, no code):** an older phone skips watch log lines whose category it doesn't know. In practice that doesn't happen here. The watch app is embedded in the iOS app and installed from it, so after an update the watch is the same build as the phone or older, never newer. An older watch never sends `algorithm`. Only a phone downgrade with a newer watch app still installed could hit it, and then those lines are skipped, not misattributed.
- **M2aC-03 (accepted):** "flag off = today" holds exactly for the iOS app, not for the watch app. The watch app now requires watchOS 10.6, so watches on 10.0–10.5 must update first. It also compiles the 82 shared algorithm files, and the shim and sink are active with the flag off, although nothing calls the algorithm on the watch yet. The PR must say "the watch app now requires watchOS 10.6".
- **M2aC-06 (open, M7):** CI never builds with the flag on. Add a build-only step `xcodebuild -scheme "Trio Watch App" -destination 'generic/platform=watchOS Simulator' TRIO_ON_WATCH=YES build` (or an M7 checklist item), so a typo in the `_YES` paths surfaces.
- **M2aC-07:** no change. E1 still decides whether `bluetooth-central` is accepted.

#### Browser build with the flag on (M2aC-01)

Flag-off browser builds need nothing new. For a flag-on build through the GitHub Actions / fastlane path, the maintainer (or builder) must:

1. On [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list), open the **Trio Watch App** identifier (`org.nightscout.TEAMID.trio.watchkitapp`), enable **Time Sensitive Notifications**, and save. The `identifiers` lane does not add it: `configure_bundle_id` for the watch only adds App Groups and HealthKit, and the existing guide already handles time-sensitive as a manual step for `Trio`.
2. Regenerate the match profiles: run **3. Create Certificates** (`fastlane certs`, match with `MATCH_READONLY=false`). The stored appstore profile for `…watchkitapp` predates the capability, and with that profile gym fails with "Provisioning profile … doesn't include the com.apple.developer.usernotifications.time-sensitive entitlement" (the same error as step 7 above, locally). If match keeps the old profile, set `FORCE_NUKE_CERTS=true` for one run, then remove it (the guide's existing renewal path). To verify: I have not checked whether `certs` alone replaces a profile that became invalid after a capability change.
3. Set the flag for that build. Browser builders have no local `ConfigOverride.xcconfig`, and the CI runner writes one for `DEV_BRANCH_WARNING_DISABLED` already, so the flag fits that pattern.

The Fastfile needs no change. `match` already requests the `…watchkitapp` profile, `update_code_signing_settings` only sets the profile and identity for "Trio Watch App", and `CODE_SIGN_ENTITLEMENTS` still comes from the flag. The change belongs in the workflow. Proposed, not applied (`.github/workflows/build_trio.yml`, after "Configure Dev Branch Warning"):

```diff
+      # Experimental: Trio on Watch. Off unless the repository variable TRIO_ON_WATCH is true.
+      # Needs Time Sensitive Notifications on the Trio Watch App identifier and regenerated certificates.
+      - name: Configure Trio on Watch
+        if: vars.TRIO_ON_WATCH == 'true'
+        run: |
+          echo 'TRIO_ON_WATCH = YES' >> ConfigOverride.xcconfig
+          echo "::warning::Trio on Watch (experimental) enabled for this build."
```

Add the identifier step to `fastlane/testflight.md` only when the flag is offered to builders (after E1 and E2), not now.

#### Re-verification after the merge (tip of this branch)

| Step | Command | Result |
|---|---|---|
| Watch, simulator, flag off | `X -scheme "Trio Watch App" WATCH build` | 0 |
| Watch, simulator, flag on | same + `TRIO_ON_WATCH=YES` | 0 |
| iOS app, flag off | `X -scheme Trio PHONE build` | 0 |
| Watch tests | `X -scheme "Trio Watch AppTests" WATCH test` | 0; 21 / 21 passed |
| Full `Trio Tests` | `X -scheme "Trio Tests" PHONE test` | 0; 1005 total, 961 passed, 0 failed, 44 skipped (M1 tip: 1004 / 960 / 0 / 44; +1 = the membership test). Two earlier full runs on the same tree failed: 9 tests the first time and 66 the second. Both times the test host crashed while `BolusSafetyValidatorTests.init()` built `TrioApp()` (`let resolver = TrioApp().resolver`): heap corruption inside `TrioApp.init` (`FileProtectionFixer`, `configureTabBarAppearance`), with every test still in flight marked failed. That file and `TrioApp.swift` are unchanged since `349f49523`. The suites that failed in the first run, re-run in isolation, passed 20 / 20. Pre-existing flake, worse under machine load; not caused by M2a |
| Membership test, negative | `OrefRun.swift` removed from the watch phase, `-only-testing:TrioTests/WatchAlgorithmMembershipTests` | 1 (expected): the test failed and reported `Trio/Sources/APS/OpenAPSSwift/OrefRun/OrefRun.swift` as missing. The project file was restored afterwards |

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

### Bounded adopt (`0f10883`, M3 exhaustive search rows W4/W36, M3R-04)

Branch `feat/tow-kits-adopt` off `feat/trio-on-watch` @ `a6b81b853`. It pins OmnipodKit `0f10883` (LoopKit `7fd4d1a7` unchanged). The commit is local-only, like the earlier kit commits.

- An export made after a release carries `PodState.releasedEapSqn`, the exporter's EAP SQN at the release. The adopter keeps it through a relaunch.
- In `handshakeResynced`, a resync beyond the bound is a foreign session: the adopter refuses and reports it. The bound is spent by the first established session, by a resync this device's own accepted counter explains, and by the takes that call `expectSessionResync` (a dated take, `takeControlLiftingRefusal()`, a plain take after this device's own release). A plain take without a release leaves it.
- An export without a release carries no bound, so #177's offline start is unchanged.
- **M3R-04: a release ends the scope.** Covered by the manager-level `testOnlyASupersedingTakeLiftsTheManagersRefusalAndAReleaseEndsTheScope`. Mutation M6 (a release keeps the scope) fails it.
- **How the host can tell a refused adopt from a failed take:**
  - A refused adopt sets `refusesSessions == true` and `foreignSessionDetectedAt`, reported through `pumpManagerDidUpdateState`.
  - Every session then fails with `PodCommsError.podUsedByAnotherController`, wrapped in `PumpManagerError.communication`.
  - `deviceManagerControlDidBecomeReady` never fires, because no session is established.
  - A take that merely fails (pod out of reach) leaves `refusesSessions` false and fails with `podNotConnected` or a timeout.
  - M5 maps `refusesSessions` to `foreignPodSession`. No new signal is needed.

| # | Step | Result |
|---|---|---|
| BA1 | `DeviceHandoffTests` | 50 run, 0 failed (4 new) |
| BA2 | Mutations: the bound ignored in the handshake; no bound in the export; the bound not spent; a bound on every export | 5, 8, 1 and 35 failures |
| BA3 | OmniTests, all, against the exact pins | 268 run, 0 failed, 3 skipped |
| BA4 | `OmnipodKit-watchOS`, simulator and `arm64_32` | Build succeeded |
| BA5 | Trio iOS app (`feat/tow-kits-adopt`), `X -scheme Trio` | Exit 0 |

Wiring checked by reading only, in addition to the list above: none new. The export (`sharedConfiguration`) and the decision (`handshakeResynced`) are both exercised by the tests above.

#### Bounded adopt review fixes (`c23daca`, BA-01..BA-04)

| Finding | Change |
|---|---|
| BA-01 | While `releasedEapSqn` is set, `nextHandshakeSqn` sends `releasedEapSqn + 1` on every attempt. A lost attempt no longer carries the adopter past the phone's Take Back session. The `AcceptedEapSqn` branch of `handshakeResynced` also spends the bound, so a relaunched adopt whose first session was accepted doesn't loop. The reviewer's bypass test is in the suite as `testAnAdoptWithALostAttemptStillRefusesASessionAfterTheRelease`. |
| BA-02 | Documented in the proposal's limits: the adopter's accepted handshake with a lost reply refuses, failing closed. |
| BA-03 | `exportConfiguration()` waits out a session in progress (`podStateLock`) before it reads the bound. Host contract: export only after `releaseControl()` has succeeded. |
| BA-04 | `testATakeClearsAnAdoptsBound`. The docs now name the takes that clear the bound. |

| # | Step | Result |
|---|---|---|
| BB1 | `DeviceHandoffTests` | 53 run, 0 failed (3 new) |
| BB2 | Mutations | Fix reverted (the `0f10883` behaviour): the bypass test fails (3 assertions). A take keeps the bound: 1 failure. The own-counter resync keeps the bound: 1 failure (the relaunch test) |
| BB3 | OmniTests, all, against the exact pins (OmnipodKit `c23daca`) | 271 run, 0 failed, 3 skipped |
| BB4 | `OmnipodKit-watchOS`, simulator and `arm64_32` | Build succeeded |
| BB5 | Trio iOS app (`feat/tow-kits-adopt`), `X -scheme Trio` | Exit 0 (OmnipodKit recompiled) |

Read only: the export's wait (`waitOutSession`) is a lock round trip that the tests don't exercise under contention.

## M3: loan core (2026-11-16)

Branch `feat/tow-loan-core` off `f059f1809`. Decision table, per-row tests and the gate coverage: `architecture/watch-loan-decision-table.md`.

### What landed

- **Pure core** in `Trio/Sources/APS/WatchLoan/` (Foundation only, Trio target; watch membership comes at integration):
  - phone states `home`, `lending`, `lent`, `takingBack`, `unreadable`; watch states `idle`, `requesting`, `holding`, `returning`, `stopped`;
  - messages with `protocolVersion`, `epoch`, `messageID`, `sentAt` (V2-1 request id and grant expiry), and a stop/revoke envelope that any protocol version parses (V2-10);
  - `WatchLoan.decide` for both devices, effects as values.
- **Persistence:** `WatchLoanStore`, one JSON file per device, written atomically. The phone file is `Documents/watch-loan-state.json`. No file means `home`, which is today's behaviour. A file that can't be decoded means "may not command" plus an alert (V2-15).
- **Phone gate:** `WatchLoanGate`, registered in `APSAssembly`. It reads the file on every check and is wired into every V2-27 / C-05 path, plus the pump settings and setup screens. It never sets `pumpManager` to nil and doesn't depend on `TRIO_ON_WATCH` (D-2).
- **Safety conditions covered:** N-4 (automatic retake on `grantRejected`; watch timeout 120 s > worst-case lend 60 s + grant lifetime 30 s), R-1 (temp cancel at take-back), C-1 (takeover context: set only by Take Back, carries the peer epoch and a 6 h window, cleared by the watch's `stopped`, audit and alert on every foreign session, refuse outside the window), C-3 (relaunch in `takingBack` redoes take control, temp cancel, refresh and the idempotent audit), C-4 (the audit effect names the loan, so booked intents can count as booked), and the V2-12 invariant with SM-5's pairs.

### Tests

New iPhone 17 simulator "Trio-M3 iPhone 17", iOS 27.2, UDID `1991CB91-59A3-4174-8F99-6F6C2B7279D2`. Xcode 27.2. Derived data in the session scratchpad (`dd-m3`).

| Run | Scope | Total | Passed | Failed | Skipped |
|---|---|---|---|---|---|
| New suites | `WatchLoanPhoneDecisionTests`, `WatchLoanWatchDecisionTests`, `WatchLoanFlowTests`, `WatchLoanInvariantTests`, `WatchLoanStoreTests`, `WatchLoanGateTests` | 117 | 117 | 0 | 0 |
| Full `Trio Tests` | everything | 1113 | 1069 | 0 | 44 |

The full run is the M0 baseline (952 passed, 44 skipped, same skips) plus the 117 new tests. The V2-12 search covers about 77,000 states in about 30 s. Gate tests take about 20 s because they build real `BaseAPSManager` and `BaseDeviceDataManager` instances against a spy pump.

The V2-12 search found one bug during development, now fixed and covered by row P42. A late release result from an earlier lend could complete a later lend. The phone then went `home(e)` while the watch adopted `holding(e)`. Pump results now carry the epoch of the state that asked for them.

### Deviations from the architecture documents

- **End bumps the epoch at `takingBack`.** Both End and Take Back persist `takingBack(e+1)`, and `home` keeps that epoch. The state-and-sync End table had `takingBack(e)` then `home(e+1)`. The final epoch is the same, and one take-back path is simpler.
- **Watch request timeout is 120 s, not 20 s.** N-4 requires it to exceed a worst-case lend.
- **Relaunch in `holding` emits `takeControl`.** A crash between persisting `holding` and taking control would otherwise leave the watch holding without control. The host treats take-control as idempotent.
- **No `status` handling on the phone.** Take Back in `lending` takes the watch's reply as an event argument (`takeBackTapped(watchAnswer:)`). Only `holding(e)` points to End (N-4).
- **Take Back from an unreadable file** uses the current Unix time in seconds as the new epoch and has no takeover context. A later foreign session is then refused (fail closed), and the audit is replaced by an "audit unavailable" alert.

### Not verified or deferred

- No coordinator, WatchConnectivity, watch host or UI beyond the two disabled screens. Those are M4, M5 and M6. The effects (`audit`, `podSession`, `awaitPumpIdle`, alarms) have no executor yet.
- The 60 s worst-case lend is a bound that M4's coordinator must enforce.
- The gate's alert and refusal strings are English only. The string catalog wasn't regenerated by the command-line build.
- Not run on a device. The gate's unreadable-file alert reaches `TrioAlertManager` only through the DI-registered gate; the screens use a resolver-less instance that only answers.

### Worktree hygiene

- The build-phase SwiftFormat changed `Trio Watch App Tests/Unit Tests.swift` again; reverted.
- `Package.resolved` and the submodules are unchanged.
- The gate tests write a spy pump's raw state while they run. They clear it afterwards.

### M3 revision after the reviews (2026-11-16)

This revision responds to `reviews/implementation-reviews.md`: the "M3 safety review (Agent E)" and the "M3 architecture/code review (Agent C)". It supersedes the earlier statements about the relaunch take, the unreadable Take Back and the search bound.

| Finding | Change | Rows / tests |
|---|---|---|
| M3E-01 (blocker) | A relaunched watch never takes over a kit that holds. It re-adopts only if its kit never adopted and the phone answers with the same epoch; otherwise it stops (`unconfirmed`). The search now models the kit: a take lifts refusals and absorbs the other controller's session, and a device counts as commanding unless its kit provably refuses. | W26, W36, W37; `takeBackWatchOffPhoneUnreachable`, `adoptCrashThenTakeBack`, `kitModelCatchesPlainTake` |
| Found by the re-search | A watch adopt still in flight could complete after the phone's superseding Take Back and absorb its session: two commanders. The watch now emits `.adoptControl`, which may resync only to the session the phone released. **This is a kit requirement for M2b/A2.** | W4, W36; `adoptRacesTakeBack` |
| M3E-02 | Every stop releases the pod, and the release result sends `stop(released: true)`. The phone clears its window only on that confirmation. | W19–W24, W35, P31, P32 |
| M3E-03 | Adds "Use the pod on this iPhone" (`usePodOnThisPhoneConfirmed`) in `home`: superseding take, pod-lifetime audit, alert. | P43 |
| M3E-04 | Take Back from an unreadable file audits the pod's whole life (`AuditScope.podLifetime`) and gets a window. | P23, P24, P28, P41 |
| M3E-05 | `.takeControl(supersedingUntil:)`; retries and the relaunch redo pass the persisted window; `.podSession(.keepCommanding(until:))`. | P22, P25, P37 |
| M3E-06 | Epochs are `Int64` in state and on the wire. | `wideEpoch`, `phoneRoundTrip` |
| M3E-07 | The window holds only while `takenAt ≤ now < supersededUntil`. | P44 |
| M3E-08 | A duplicate grant at `returning` or `stopped` of the same loan is answered with `status`, not rejected. | W34 |
| M3E-09 | `handBack` and `handBackAck` decode across protocol versions. Records follow in M4. | `handBackAcrossVersions` |
| M3E-10 | A superseded watch disarms its not-looping alarm after the persist and the user alert. | W19, W25, W32 |
| M3C-03 | The pump screens use the injected gate. | `pumpScreens` |
| M3C-04 | The unreadable-file alert fires once per process (test-and-set under one lock). | — |
| M3C-05 | `refusal(_:userInitiated:)` does one read and returns the message. | gate tests |
| M3C-07 | Production comments no longer cite doc IDs. | — |
| M3C-08 | User-initiated refusals log at `info`, periodic ones at `debug`. | — |
| M3C-09 | **Not done.** `xcstringstool sync` with the gate's `.stringsdata` rewrote the whole catalog (about 75k lines changed), so I reverted it. The four strings need one Xcode IDE build, then committing only the added keys. | — |

Search: with the kit modelled, an epoch-3 bound didn't finish in 15 min. The search now runs at epoch 2:
- The default run allows one Start and takes about 60 s.
- A second Start is gated by `TRIO_STRESS=1` and takes about 4 min. That variant passed on this revision, run before the split.

M4 and M2b items handed on:
- M3C-01: a pump screen opened before the lend.
- M3C-02: `.awaitPumpIdle` maps to `loopGuard.waitForLoop()`.
- M3C-10: re-sync the delivery limits on `home`.
- The bounded adopt above (kit).
- Mapping `.takeControl(supersedingUntil:)` and `.adoptControl` to the kit API.

Not done: a dedicated test for M3C-04's concurrent alert.

Tests on this revision (same simulator, `1991CB91-59A3-4174-8F99-6F6C2B7279D2`):

| Run | Total | Passed | Failed | Skipped |
|---|---|---|---|---|
| Full `Trio Tests` | 1126 | 1081 | 0 | 45 |

- The 1081 passed are the 952 baseline tests plus 129 watch loan tests.
- The 45 skipped are the 44 baseline skips plus the `TRIO_STRESS`-gated two-Start search.

### M3 re-review items (2026-11-16)

- **M3R-01:** `lateLoanOneMessages` delivers every late loan-1 message (request, grantRejected, holding, records, handBack, status, stop with and without `released`; grant, refused, handBackAck, revoke) while loan 2 is `lending` or `lent`. Neither device changes state, except that a watch still requesting learns the newer epoch, and no pump action starts.
- **New, from M3R-01:** a late loan-1 revoke used to cancel loan 2's request. W21 now keeps the request and learns the epoch, so a grant from before the revoke is stale.
- **M3R-02:** `released` decodes with `decodeIfPresent`, defaulting to false. The stop format is documented as "only optional keys".
- **M3R-03:** "Use the pod on this iPhone" and Take Back from an unreadable file take without a window when the other device is unknown. Only a Take Back from a known watch loan opens one; P43 inside such a window keeps it (P45).
- **M3R-04:** unchanged here. It is for M2b/M4: clear the kit's window on `releaseControl()`.
- **M3R-05:** `unreadableStateFile` flow tests cover `lending`, `lent` and `takingBack`.
- **M3C-09:** left for the maintainer's IDE build. The four new catalog keys are:
  - "Trio couldn't read which device controls your pump, so it won't send pump commands."
  - "Your pump is handed over to Apple Watch, so iPhone won't send pump commands."
  - "Trio stopped sending pump commands"
  - "Trio couldn't read which device controls your pump. Your pump finishes any running temp basal and then follows its basal schedule."

Tests: the watch loan suites ran 134 tests: 133 passed, 0 failed, 1 skipped (the `TRIO_STRESS` search). Full `Trio Tests`: 1130 total, 1085 passed, 0 failed, 45 skipped.

## Integration check (M1-M3) (2026-11-16)

Branch `feat/trio-on-watch` at `df5cda433` (M1, M1b, M2a, M2b, M3 merged, plus the cherry-picked test-host fix). Submodules clean (`git submodule status`: no `+` or `-`). Fresh paired simulators: iPhone 17 iOS 27.2 `422F5A9D-E24C-45C1-A343-823C9D5B6F87`, Apple Watch Series 12 46mm watchOS 27.2 `D6E39F53-A6BE-4EE0-94C9-13B08A4AC06B`. Xcode 27.2 (27B52). `X` = `xcodebuild -workspace Trio.xcworkspace -derivedDataPath $DD`. Exit codes are each command's own `$?`.

| # | Step | Command | Result |
|---|---|---|---|
| 1 | iOS app | `X -scheme Trio PHONE build` | 0, BUILD SUCCEEDED |
| 2 | Watch, flag off | `X -scheme "Trio Watch App" WATCH build` | 0, BUILD SUCCEEDED |
| 3 | Watch, flag on | same + `TRIO_ON_WATCH=YES` | 0, BUILD SUCCEEDED; log uses `TrioOnWatch-Info.plist` and `TrioOnWatch.entitlements` (step 2 doesn't) |
| 4 | Full `Trio Tests` | `X -scheme "Trio Tests" PHONE test` | 0; 1155 total, 1109 passed, 0 failed, 46 skipped |
| 5 | Watch tests | `X -scheme "Trio Watch AppTests" WATCH test` | 0; 21 / 21 passed |
| 6 | TZ escape | `TEST_RUNNER_TRIO_TZ_ESCAPE=1 X test-without-building -scheme "Trio Tests" PHONE -only-testing:TrioTests/ProcessTimeZoneEscapeTests` | 0; 1 / 1 passed |

- No merge-induced compile errors; no fix commit needed.
- Flakes: none this run. The known ones (`FileStorageTests` "Can parse mmol/L settings to mg/dL", `PumpStatusStorageTests` "A suspend and resume are stored in order") passed in the full run, so no isolated re-run was needed.
- Each build reformatted `Trio Watch App Tests/Unit Tests.swift` (SwiftFormat joined a `@Test` attribute onto its `func` line); reverted after every step. `Package.resolved` stayed clean.

## M4: phone side of a loan (2026-11-16)

Branch `feat/tow-phone` off `feat/trio-on-watch` @ `e7a865ef4`, merged with `feat/trio-on-watch` @ `485051ea4` for the reviews (kit pins LoopKit `7fd4d1a7`, OmnipodKit `c23daca`). Every row P1–P45 is executed as written; the review round added P46 (see below).

### Components

| Component | Where | What it does |
|---|---|---|
| `WatchLoanSnapshot` | `APS/WatchLoan/WatchLoanSnapshot.swift` (shared) | The grant snapshot, its wire format (compact JSON, lzfse) and the validator both devices use (`missingParts`, `refusal(for:)`). |
| `WatchLoanRecordBatch`, `WatchLoanRecordAck`, `WatchLoanInbox` | `APS/WatchLoan/WatchLoanRecords.swift` (shared) | Record batches (finalized `NewPumpEvent`s by raw/sync identifier, running temp as status only, carbs and deletions, glucose), the ack, wire keys, persisted dedupe and the epoch filter. |
| `WatchLoanAudit` | `APS/WatchLoan/WatchLoanAudit.swift` (shared, pure) | Delivered-total audit (V2-8, R-2, R-3, C-4, `.podLifetime`). |
| `WatchLoanPumpAdapter` | `Services/WatchManager/WatchLoanPumpAdapter.swift` | The only place that calls the kit: `SupersedingDeviceControl` (OmnipodKit conformance), release, the three takes, scope end/restore, temp cancel, delivered-total read, export, bolus remainder. Kit calls that wait out a session run off the main thread. A kit pin change touches this file only. |
| `WatchLoanCoordinator` | `Services/WatchManager/WatchLoanCoordinator.swift` | Actor. One event at a time through `WatchLoan.decide`; executes the effects in order; feeds release and take results back as epoch-tagged events. Ledger (`Documents/watch-loan-ledger.json`): release readings, audits, seen message ids, last batch time. |
| `BaseWatchLoanPhoneHost` | `Services/WatchManager/WatchLoanPhoneHost.swift` | Start preconditions, snapshot builder, merge, audit booking, alarms and alerts. |
| Transport | `AppleWatchManager.swift` (`WatchLoanTransport`) | Same `WCSession`. Loan payloads are routed to the coordinator before any other handling. |

Other changes: `APSManager.awaitPumpIdle()` (loop guard, bolus, pump-event storage); `DeviceDataManager.resyncPumpAfterTakeBack()`, `awaitPumpEventStorage()`, `foreignPodSession`; `NotLoopingMonitor.setArmed(_:)`; `PumpHistoryStorage.getPumpHistory(since:)`, `replaceTaggedBolus`; `OpenAPS.orefInputs(...)`; `PumpConfig.KitScreenToken` on the kit settings and setup screens; `Config.xcconfig` turns `TRIO_ON_WATCH = YES` into the Swift condition `TRIO_ON_WATCH`. Only `startRefusal()` depends on it (flag off: `featureOff`); gate, store, Take Back, P43, merge and audit run regardless (D-2).

### Effect mapping

| Effect | Host action |
|---|---|
| `persist` | Atomic write of the phone file; on failure nothing more runs and the state stays. A loan whose window was just cleared (P31/P32) calls `stopSupersedingAnotherController()`. `takingBack` → `home` re-sends delivery limits and the heartbeat request (M3C-10). |
| `awaitPumpIdle` | `APSManager.awaitPumpIdle()`, bounded at 40 s (inside the 60 s worst-case lend). Timeout = release refused (P7). |
| `cancelTemp` | Temp 0 U/h for 0 min, always (R-1). |
| `refreshDeliveredUnits` | Real status read. In `lending` it stores the release reading before the release (SM-14). |
| `releaseControl` | `releaseControl()`, then `isControlReleased` read at once → `releaseResult`. |
| `takeControl(until)` | `until` set → `takeControl(supersedingAnotherControllerUntil:)`; nil with an unknown peer (P43, P24) → `takeControlLiftingRefusal()`; else plain `takeControl()`. Result = not released and not refusing. |
| `podSession(.keepCommanding)` | Restore the scope with a dated take only if the kit lost it (refusing); never a plain take. |
| `podSession(.refuse)` | `stopSupersedingAnotherController()`, then `releaseControl()` (host contract; P43/P46 lift it). |
| `audit` | Recompute and replace the tagged bolus `trio-watch-loan-audit-<epoch>` (or `-pod-<activation>`). On a foreign session the phone reads the pod first if it holds it. |
| `send(.grant)` | Export only after the release held; snapshot built, checked with `missingParts`, sized, sent with `sendMessage` only. |
| Other `send`, `sendStop` | `sendMessage` when reachable (falls back to `transferUserInfo` on error), else `transferUserInfo`. |
| `cancelOutstandingTransfers` | Cancels the queued user-info transfers that carry loan keys. |
| `arm`/`disarm` | `phoneNotLooping` → `NotLoopingMonitor.setArmed`; `phoneNoWatchUpdates` → 30/60/90 min time-sensitive and 120 min critical "No updates from Apple Watch", anchored on the last batch (persisted, kept across relaunch). |

Host decisions that aren't rows (flag if you disagree):
- A pump step that fails mid-list stops the list. In `lending` it reports the release as refused (P7: back home, nothing released). In `takingBack` it alerts `takeBackPodUnreachable` and leaves the phone in `takingBack`; Take Back again (P22) or a relaunch (P37) redoes it.
- A grant that can't be built or sent live is fed back as `grantRejected` (P11, automatic retake). The watch never had it.
- The audit books the whole excess in whole pulses once it passes pulse + 0.15 U (M4E-06; the band only suppresses noise). External (pen) insulin and the audit's own tagged bolus don't count as pod delivery; other audits' tagged boluses do. Temps count in whole pulses, scheduled basal comes from the basal profile in the grant's (pod's) zone, scheduled-basal rows are ignored, suspended spans deliver nothing. The tagged bolus is timestamped at the reading it explains, so a later reading moves it forward (IOB errs high).
- `.podLifetime` uses the current basal profile and the pump's time zone from pod activation; a profile edit during the pod's life skews it.
- Late records recompute the audit of their epoch, else the latest pod-lifetime audit.
- Below the phone's epoch only `request`, `handBack` and `records` envelopes pass the inbox; `stop`/`revoke` always pass; record batches are always merged (never drop insulin). Batches of another record version are not merged and not acked.

### Snapshot

Contents: versions (snapshot schema, protocol, app build, pump and CGM plugin and state version), request id, epoch, `expiresAt` (now + 30 s), phone time, time zone, `OrefInputs` as the phone gathers them (`OpenAPS.orefInputs`: settings, unclamped preferences, dosing mode, schedules, temp target and override as oref reads them, 10 days of TDD rows, `hasSufficientTDD`, 24 h glucose, pump history and carbs per `OrefInputs+Selection`, the fresh autosens if any), override and temp target at the grant with end times, bolus calculator settings, the glucose alarms and their configuration, pump export and G7 `SharedDeviceConfiguration` (binary plists), delivery pulse, release reading, pod and sensor end.

Size (budget 80 % of the cap, `grantBudgetBytes` = 52,428 B; worst case: 288 readings, an SMB and a temp every 5 min, 8 meals, 2880 TDD rows, all alarms): JSON 513,309 B, compressed 48,764 B, envelope 205 B. Limit used: 65,536 B for the whole live message (`WCSession` payload limit as commonly cited; not measured on a device). Fallback if a real payload is too big: today the phone refuses locally and retakes (P11). The next step would be pre-aggregating TDD rows (largest part) or sending the snapshot ahead with `transferFile`, keyed by request id, while the grant itself stays a live message.

### Tests

New: `WatchLoanAuditTests` (13), `WatchLoanSnapshotTests` (5, one with 16 scenarios), `WatchLoanCoordinatorTests` (24), `WatchLoanPhoneIntegrationTests` (7), helper `LoanPumpDouble`. Fresh simulator "Trio-M4 iPhone 17", iOS 27.2, `1AA6E67F-FFAC-415B-8254-9D3A7DA56AE6`; derived data in the session scratchpad (`dd-m4`).

| Requirement | Test |
|---|---|
| R-1 | `takeBack`, `takeBackCancelFails` |
| R-2 | `takeBackDuringBolus`, audit `bolusRemainder` |
| R-3 | `lateRecords`, audit `recompute` |
| C-1 | `foreignSessionInWindow`, `foreignSessionAfterWindow`, `releasedStopClearsWindow` |
| C-3 | `relaunchRedo` (same window, one booking) |
| C-4 | `bookedIntent` (coordinator and audit) |
| M3C-01 | `lendRefused`, `preconditions`, `kitScreens` |
| M3C-02 | `lendWaitsForLoop` (real `BaseAPSManager` loop guard), `lendWaitsForBolus` |
| M3C-10 | `takeBack` (host call), `resyncAfterTakeBack` (real `DeviceDataManager`) |
| Snapshot | `roundTrip`, `completeness`, `validator`, `size`, `gatheredInputsMatchProduction` (gathered from the stores, over the wire, through `OrefRun`: byte-exact with the production goldens, 16 scenarios) |
| Merge | `mergeIdempotent`, `purgeProtection`, `carbDeletion`, `taggedBolus` |
| Transport | `dedupe` (persisted across relaunch), `epochFilter`, `inboxCapacity`, `recordsOtherVersion`, `grantNotLive` |
| Pump double | `noCommandWhileReleased`; `doubleCatchesCommand` is the known-issue control showing the double fails a test |

Mutation checks (reverted): remainder forced to 0 fails `takeBackDuringBolus`; dropping the loop-guard wait fails `lendWaitsForLoop` (the double also flags the loop's temp on a released pump).

| Run | Total | Passed | Failed | Skipped |
|---|---|---|---|---|
| New suites | 49 | 48 + 1 known issue | 0 | 0 |
| Full `Trio Tests` | 1204 | 1157 + 1 expected failure | 0 | 46 |

Builds: `Trio` with the flag off and with `TRIO_ON_WATCH=YES` (`-DTRIO_ON_WATCH` reaches swiftc): both succeed.

### New strings (catalog sync left to the maintainer's IDE build)

"No updates from Apple Watch"; "No update from Trio on Watch for %d min. Check your watch."; "Apple Watch Didn't Confirm"; "Open Trio to check, or take back your pump."; "Trio on Watch Didn't Start"; "Trio closed while starting Trio on Watch. Open Trio to check, or take back your pump."; "Can't Reach Your Pump"; "Keep your iPhone close to your pod. Nothing is giving insulin automatically."; "Your pump keeps running the last temp basal until it ends (at most 2 hours), then your scheduled basal."; "Apple Watch Is in Control"; "End Trio on Watch on your watch, so your history comes back first."; "Trio on Watch Stopped"; "Your watch stopped controlling your pump. Take back your pump on this iPhone."; "Apple Watch Contacted Your Pod"; "Apple Watch contacted your pod after you took it back. Trio counts any insulin it gave. Open Trio on your watch to stop it."; "Another Device Used Your Pod"; "iPhone stopped sending commands to your pod."; "Open Trio to use the pod on this iPhone."; "Pod in Use on This iPhone"; "If another device still runs this pod, it stops when it next reaches your pod."; "Insulin Added to History"; "Your pod delivered %1$@ %2$@ that Trio on Watch didn't record. Trio counts it as insulin on board, so insulin on board may read high for a while."; "Check Your Insulin History"; "Trio on Watch recorded %1$@ %2$@ more insulin than your pod reports delivering. Insulin on board may read high for a while.". Reused: "OK", "U", and the gate's unreadable-state strings.

### Not verified or deferred

- Nothing ran on a device or with a real pod or watch: `sendMessage` size limit, `transferUserInfo` cancellation, kit timing of release and take, Omnipod pulse rounding of temps against the audit's whole-pulse rule.
- No UI: the Take Back, "Use the pod on this iPhone" and Start-facts surfaces (M6) call `takeBack()`, `usePodOnThisPhone()` and read the snapshot fields.
- A glucose-alert snooze clears pending non-critical notifications, including the 30/60/90 min watch-silence steps; the 120 min critical step survives. Not re-armed on snooze yet.
- The 40 s pump-idle timeout path has no test (it would take 40 s).
- `BaseWatchLoanPhoneHost.snapshot` and the precondition wiring with the flag on are covered by compile only; their logic is tested through `preconditionRefusal` and the fake host.
- Only the tip commit was built and tested, not each commit on its own.

### Worktree hygiene

SwiftFormat reformatted `Trio Watch App Tests/Unit Tests.swift` again; reverted. `Package.resolved` and the submodules unchanged.

### Review fixes (M4 reviews C and E, v3 amendments)

| Item | Change | Test |
|---|---|---|
| M4E-01 | `getPumpHistory` maps `isExternal`; the audit leaves external insulin out. | `externalInsulin`, `externalInsulinMapped` |
| M4E-02 | The audit excludes only its own tagged bolus (`ownBolusID`); earlier audits' boluses count as delivered. | `otherAuditBolus` |
| M4E-03 | The ledger keeps `lastForeignSessionHandled`, saved after the audit. `start()` and every kit report compare it with the kit's persisted `foreignSessionDetectedAt`. `DeviceDataManager`'s dedupe is in memory, for logging only. | `foreignSessionDurable` |
| M4C-01 | Not the single path: the gather is still separate from `createProfiles`/`autosense`/`determineBasal`. `gatheredInputsMatchProduction` now also runs the phone's own pipeline on the same store and clock and compares every stage directly (16 scenarios), besides the goldens. Making the live pipeline gather through `orefInputs` rewires file writes, the iob-on-throw order and the simulation path, which is parity-sensitive and outside M4; flagged for the maintainer. | `gatheredInputsMatchProduction` |
| V3-1 | Record batches of any epoch are merged by sync identifier (already so); only control messages are epoch-filtered. | `olderEpochRecords` |
| V3-6, M4R-01 | A faulted pod (`deliveredUnitsAreFinal`) is audited with its final total and no bolus remainder; it's skipped only when that reading predates the window. A delivered total below the last reading books nothing and alerts "Pod Total Not Checked" (copy says insulin on board may read too low). | `faultedPod`, `decreasingTotal` |
| V3-7 | `NightscoutManager` skips the device status (IOB, loop, pump) while the gate says the phone isn't the owner. | `nightscoutStatus` |
| M4E-06 | Whole excess booked past the band. | audit `tolerance` |
| M4E-11 | The host re-issues the silence steps from the same anchor on a snooze change, as `NotLoopingMonitor` does. | `silenceStepsAfterSnooze` |
| M4C-02 | Audits and recomputes run one at a time (task chain); each reads its entry from the ledger. | coordinator suite |
| M4C-03 | A message id is marked seen after its event ran. | `dedupe` |
| M4C-04 | The pump-idle wait is cancelled at the timeout, and `awaitPumpIdle` stops polling when cancelled. Timeout injectable. | `pumpIdleTimeout` |
| M4C-05 | Loan transport in `AppleWatchManager+WatchLoan.swift`; the main file keeps the property and two early returns (`WatchLoanWireKey.isLoanPayload`). | `routing` |
| M4C-06 | Grant budget 80 % of the 65,536 B cap; worst case 48,927 B + 205 B. | `size` |
| M4C-07 | Interpolated `String(localized:)`; amounts with `Formatter.bolusFormatter` and `HKUnit.internationalUnit().localizedShortUnitString`. | — |
| M4C-08 | One lazily built `OpenAPS` in the host. | — |
| M4C-09 | Flag-off `.featureOff`; `NotLoopingMonitor` unchanged for loop dates (`armedAt` starts at `.distantPast`, so the baseline anchor is untouched), disarm and re-arm; routing. `withKnownIssue` gets `matching:`. | `featureOff`, `notLoopingArming`, `routing` |
| M4E-04 | Loan audits use the pump's time zone. | — |
| M4E-05 | Kept: OmnipodKit derives `bolusUnderWayEndsAt` from the pod's `bolusNotDelivered` at that status read, at the rate `estimatedDuration` uses, so the remainder equals it to the pulse. | `takeBackDuringBolus` |
| M4E-08 | Release on a `.refuse` verdict. | `foreignSessionAfterWindow` |
| M4E-09 | New row P46: "Use the pod on this iPhone" also in `takingBack`. The invariant search and `LoanWorld`'s recovery offer it there when the phone's kit refuses; the search passes. | `p46`, invariant |
| M4E-07 | Skipped as agreed: a take-back stuck on an unreachable pod still waits for a tap (alarmed). | — |

New strings: "No update from Trio on Watch for \(minutes) min. Check your watch." (now interpolated), "Trio on Watch recorded \(amount) more insulin …", "Your pod delivered \(amount) that Trio on Watch didn't record …", "Pod Total Not Checked", "Trio couldn't check your pod's delivered insulin against your history, so it added nothing. Check your insulin history."

Tests after the fixes (same simulator): loan, decision, flow, invariant and `NotLoopingMonitor` suites 136 / 136 (1 known issue, the double's control). Full `Trio Tests`: 1216 total, 1169 passed, 0 failed, 46 skipped, 1 expected failure. `Trio` with `TRIO_ON_WATCH=YES` builds.

### M4 re-review follow-ups (2026-11-16)

- M4R-01: faulted pod audited with its final total (above).
- Equivalence: `gatheredInputsAcrossDST` runs the non-flat time-of-day scenarios a few hours after each Europe/Berlin DST change (the pod's and phone's zone in the tests; the 24 h window spans the change) through the snapshot encode/decode round trip and compares every stage with the phone's own pipeline on the same store and clock. The goldens scenarios already went through the round trip.
- Snooze re-issue of the watch-silence steps tested (`silenceStepsAfterSnooze`).
- Full `Trio Tests`: 1219 total, 1172 passed, 0 failed, 46 skipped, 1 expected failure.

## M5: watch loan host and loop (2026-11-16)

Branch `feat/tow-watch-loop` off `feat/trio-on-watch` @ `8b5227851`. Local signed commits, not pushed. Kit pins unchanged (LoopKit `7fd4d1a7`, OmnipodKit `c23daca`, G7SensorKit `08d48863`).

| Commit | Subject |
|---|---|
| `b0926c16e` | Link the kits and the loop's pure code to the watch |
| `6098d1ece` | Share the loop's glucose guard with the watch |
| `e30fc0e47` | Build the watch's oref inputs from the grant |
| `211c00c58` | Sync M4's snapshot and record batch types |
| `793e9b84a` | Add the watch loan host and loop cycle |
| `346ead130` | Test the watch loan host with a pump double |

### What landed

- **Watch target.** Links `LoopKit`, `OmnipodKit` and `G7SensorKit` (their watchOS targets, found as implicit dependencies of the `BUILT_PRODUCTS_DIR` references, as in #1749) and embeds them. The watch tests link LoopKit. The watch app compiles the M1b pure files (`BolusCalculator`, `GlucoseAlarmEvaluation`, `ForecastedGlucoseEvaluator`, the six `GlucoseAlerts` models) and every file in `APS/WatchLoan` except the phone gate. `BolusSafetyEvaluator` (result, rejection, inputs, evaluator) moved unchanged out of the Core Data validator file. `TRIO_ON_WATCH = YES` now also defines the Swift condition `TRIO_ON_WATCH` on the watch app.
- **Membership test.** `WatchAlgorithmMembershipTests` gains a second test: every file in `APS/WatchLoan` plus the listed pure files are in the watch target and import nothing but Foundation and LoopKit. Both tests run in `Trio Tests`, so CI keeps them.
- **Shared, pure (`APS/WatchLoan`, iOS and watch):**
  - `LoopGlucoseGuard`: at least 3 readings in the last hour, the newest at most 12 min old. `APSManager.determineBasal` now calls it; same messages and logs. A failure enacts nothing, including oref's stale-glucose fallback (F8 as on the phone).
  - `WatchLoopInputs.orefInputs(snapshot:records:now:currentTemp:autosens:microBolusAllowed:)`: the snapshot's `OrefInputs` plus the watch's records, through the phone's selection windows (`OrefInputs+Selection`), in the grant's time zone. Overrides and temp targets end at their `endsAt` or when cancelled on the watch (a cancel entry is appended to the temp target list). `pumpHistoryEvents(_ NewPumpEvent…)` maps a kit event the way `storePumpEvents` stores it and `toPumpHistoryEvents` reads it (bolus rounding to the bolus increment through a Decimal, `isSMB = automatic ?? true`, temp duration rounded to minutes, scheduled basal dropped, time clamped to storage). `tddRow` books today's insulin as the phone does before each determination.
  - `WatchLoopRules`: `WatchLoopPolicy` (constants: no SMB in the background, the 20–120 min series, the 6 min pump status age, battery 20/10 %, 3.5 min glucose filter, 5 min pod-link notice); `WatchDoseIntent` and its R-5 resolution; `WatchDosingGate` (holds back a temp above the scheduled rate and any SMB while delivery is uncertain or an intent is unresolved; nothing while suspended; never changes oref's numbers).
- **Watch host (`Trio Watch App Extension/Loan`, watch only):**
  - `WatchLoanHost` runs `WatchLoan.decide`'s watch effects. Events, cycles and treatments run one at a time. A failed persist stops the rest of the effect list. Grant checks use M4's `WatchLoanSnapshot.refusal(for:)`; the snapshot is saved before the grant is decided, so a crash after `holding` can still adopt (W36). Message ids are deduped through M4's `WatchLoanInbox`, persisted.
  - Pump lifetime: one `OmniPumpManager(adopting:localState:)` per loan, its `rawState` saved before `takeControl()` and on every `pumpManagerDidUpdateState` (synchronously, on the kit's queue). A relaunch rebuilds only from that saved state. The manager is let go at `idle` (its `localState` kept for the next adopt). Kit calls that wait on a session run off the main thread. `refusesSessions` or `foreignSessionDetectedAt` becomes `.foreignPodSession`, never `takeControlResult(false)`; a take without an answer in 60 s (and no refusal) reports `takeControlResult(false)` (W12). The pump heartbeat is switched off at install (`setMustProvideBLEHeartbeat(false)`, `setBLEHeartbeatRequest(nil)`), so no StartDelay probe runs (V3-10).
  - Relaunch (W26/W36/W37/W27–W32): `kitHasControl` is "a saved pump state exists", `podSessionForeign` is read from the restored manager, `phoneEpoch` is the phone's answer to a live `statusQuery` (5 s). The relaunch never takes control.
  - G7 (`WatchLoanCGM.swift`, the only G7 glue): `G7CGMManager(adopting:localState:nil)` from the grant's export, after the old manager is deleted; saved `rawState` on relaunch; `recheckAcquisition()` on non-Bluetooth refresh tasks; the new-reading callback drives the cycle. Public kit API only. Distinct restore identifiers come from the kits (`com.OmnipodKit`, `com.loudnate.CGMBLEKit`); the host keeps one manager of each.
  - Cycle: background time held for the whole cycle (`performExpiringActivity`) and given back on every path; foreign session check; pump status (`ensureCurrentPumpData`, at most 6 min old); unresolved intent first (R-5); glucose guard; inputs with `microBolusAllowed = foreground && !uncertain` (N-1: oref's temp-only path, nothing stripped); TDD row; `OrefRun.run` off the main thread; gate; per command a synchronous atomic intent write before sending (a failed write sends nothing and alerts; an expired wake starts no command); outcome; not-looping series moved only when the pump state was confirmed; battery; record batch; autosens on its 30 min cadence after the commands (cached result from the grant until then, SM-24).
  - Records (`WatchLoanRecordStore`): pump events kept as M4's `PumpEventRecord` by sync identifier with the phone's mutable/finalized/purge rules; readings dropped within 3.5 min of the newest known; carbs; TDD rows; cancels. Batches carry everything unacknowledged (finalized doses only, the running temp as status), go with each cycle, the hand-back and every stop, and are cleared by M4's ack. A booked intent is a finalized dose tagged by its sync identifier, so audits count it as booked (C-4).
  - Treatments: bolus recommendation from the last determination through `BolusCalculator`; `requestBolus` checks `BolusSafetyEvaluator` with IOB recomputed now and the recent-bolus sum from records plus the snapshot; carbs first, then the intent, then the command; states requested, accepted, delivering, done, cancelled, failed, uncertain (never retried). Suspend, resume, cancel override, cancel temp target.
  - Alerts (`WatchLoanAlerts`), all time-sensitive: not-looping series at 20–120 min (steps already due collapse into one); the user's glucose alarms through `GlucoseAlarmEvaluation` in the grant's zone (reading, forecast, carbs required); Bluetooth budget (`CBError` 17/18 anywhere in the error chain); battery 20 % and 10 %; pod unreachable for two cycles and 5 min (V3-4, once per outage); intent booked; file not saved; kit alerts from the pump.
  - Runtime: `WatchAppDelegate` is the one background-task handler. Bluetooth tasks are held until the cycle ends, the system's expiry, or 25 s; WatchConnectivity refresh tasks are completed once the session has nothing pending, at most after 8 s; others at once (with a G7 recheck). With the flag off there is no host and every task completes at once.
  - Observable for M6: `state`, `loop` (last cycle, last confirmed cycle, IOB, COB, eventual BG, temp rate, suspended), `bolus`, `isCycleRunning`, `awaitingFirstReading` and `isInControl` (false until the first watch-side G7 reading after the adopt, V3-8).
  - Logging (V2-31, V3-5) to the existing watch log: transitions, every message sent and received, adopt/release/restore, each background task (types and counts, held, expiry, completion with seconds), each expiring activity's expiry, cycle start (trigger, front or background), CGM latency and gap, determination and its time, command start seconds after the wake and confirmation time, held-back commands, not-looping reschedules, record batch sizes, battery, every pod and CGM link event with the app state and the seconds since the previous one. New watch log categories `loop`, `pump`, `cgm`. No glucose values in alarm logs, no identifiers.

### Assumptions about M4 (reconcile at integration)

- `WatchLoanSnapshot.swift` and `WatchLoanRecords.swift` are byte copies of M4's files at `651e747f4`/`dd301b2ba` (first copy at 14:14 MST from its working tree, synced to its commits in `211c00c58`). Take M4's version on merge.
- The phone answers the watch's `statusQuery` (sent with `sendMessage` and a reply handler) with `["watchLoanPhoneEpoch": <Int64>]` (`WatchLoanHost.phoneEpochReplyKey`). M4's coordinator doesn't do this yet; until it does, every relaunch in `holding` sees "phone silent": W26 still resumes a kit that holds, W36 can't re-adopt (it stops as W37).
- The grant comes as `[watchLoan: envelope, watchLoanSnapshot: compressed snapshot]`, record acks as `[watchLoanRecordsAck: WatchLoanRecordAck]`, as M4 sends them.
- M4's `WatchLoanAudit.swift` lives in `APS/WatchLoan`; the new membership test requires every file there in the watch target with Foundation/LoopKit imports only. At integration either add it to the watch target or move it next to the coordinator.
- The snapshot has no `smoothGlucose`, so the watch's own readings reach oref raw. With smoothing on, the watch's input differs from the phone's for readings taken during the loan. Proposed for M4: carry the setting and the raw values.

### Deviations from the decision table and the architecture

- No row changed. Implementation choices the table leaves open:
  - A watch state file that can't be read is held in memory as `stopped(0, unconfirmed)`: the relaunch releases and nothing is commanded (W32). Not persisted.
  - The not-looping series is anchored at the loan's last confirmed cycle (else its start) on relaunch, and at "now" when armed before the first `holding`.
  - End's temp cancel is sent in `returning` (V2-3 order); no other command runs in `returning`.
- `hasSufficientTDD` stays the snapshot's value for the loan; watch TDD rows feed `tddHistory` only.
- In a transitional pump state (initiating or cancelling a temp) the current temp is "none", where the phone falls back to its stored last temp.
- Watch carbs are carbs only (no fat/protein, no FPU entries).
- Small atomic JSON writes (state, intent, records, cycle info) still run on the main actor; the algorithm, kit calls and waits do not (V3-2 is partly met).
- Not built: the Series 6 / SE 2 model check and the time-sensitive setting check at Start (only notification authorization, reachability and battery ≥ 30 % are checked), `willRestoreState` logging (inside the kits), D's daily summary and peak memory, the Start screen and its "keep Trio open" progress (M6).

### Tests

Fresh paired simulators: iPhone 17 iOS 27.2 `D71CB07E-98B8-404B-AA3A-4D1E35B7F394`, Apple Watch Series 12 46mm watchOS 27.2 `FC7B122E-D1CB-4B99-BB42-C6BF64561A85` (pair `2C9F40B4-487D-4301-BDAD-D23240C63606`). Xcode 27.2. Derived data in the session scratchpad (`dd-m5`).

| Suite | Target | Tests | Covers |
|---|---|---|---|
| `WatchLoopInputsParityTests` | Trio Tests | 5 (16 scenario cases) | every OrefRun golden from a snapshot that crossed M4's wire format; the same golden with the last 50 min (a bolus and a temp as kit events, 10 readings, the meal) recorded on the watch; kit event mapping; override and temp target end and cancel; the grant's zone |
| `LoopGlucoseGuardTests` | Trio Tests | 2 | the rule at its edges; the watch's last-hour selection |
| `WatchLoopRulesTests` | Trio Tests | 4 | SMB constant; series offsets; gate; intent resolution |
| `WatchAlgorithmMembershipTests` | Trio Tests | +1 | loop sources in the watch target, imports |
| `WatchLoanHostTests` | Watch AppTests | 17 | simulator loop (Start, grant, adopt, loop on readings, revoke, nothing after) with a pump double that records a violation for any command while not owner; SMB only in the foreground; refused adopt → `foreignPodSession`; relaunch W26 (phone silent), W36/W37, W27; foreign session found in a cycle; cycle guards (stale status, suspended, too few readings); failed intent write; expired wake; unconfirmed bolus (no retry, insulin held back, booked as delivered, in the next batch); not-looping series; glucose alarms; bolus states; suspend/resume and cancels; message dedupe across a relaunch; the pump heartbeat never enabled |
| `WatchLoanIntegerWidthTests` | Watch AppTests | 2 | epochs, ms timestamps and odometer values above 2^31 round-trip; no plain `Int` stored in the loan types except small counts |

Mutations (each reverted): watch inputs ignore the watch's glucose → the records parity test fails; SMB allowed in the background → 3 host tests fail; intent not written → 2 fail; foreign session not mapped → refused-adopt test fails; expiry ignored → expired-wake test fails; relaunch ignoring the kit → survived the first version of the W26 test (the host's own "one manager" guard masked it); with the phone silent in that test it now fails it.

Runs: see "M5 verification" below.

### New strings (English source, for Crowdin after an IDE build)

All in `Trio Watch App Extension/Loan/`:
"Trio on Watch isn't looping", "No loop for %lld minutes. Open Trio on your watch. The pump finishes any running temp basal, then follows its basal schedule.", "iPhone didn't answer", "Trio on Watch didn't start. Your iPhone still controls your pump.", "Trio on Watch didn't start", "Can't hand back yet", "Trio on Watch stopped", "Pod not found", "Keep your watch close to the pod. Trio keeps trying.", "Your iPhone took the pump back. It controls your pump again.", "Another device used your pod. This watch sends no more pump commands. Check Trio on your iPhone.", "Trio on Watch was off for too long. Take the pump back on your iPhone.", "Your iPhone didn't confirm the hand-over. Take the pump back on your iPhone.", "Your iPhone isn't reachable. Keep it close and try again.", "Charge your watch to at least 30 % first.", "Allow notifications for Trio on your watch first.", "Wait until the bolus is finished.", "The pump hasn't confirmed the last command. Wait for it, then try again.", "The pump hasn't confirmed the last command, so this watch keeps it for now.", "Check Trio on your iPhone (%@).", "%@ g of carbs needed", "Glucose %@ %@", "Open Trio on your watch to keep it looping", "watchOS is limiting background Bluetooth for Trio. Until you open it, loops may be missed.", "Trio on Watch will stop soon", "Watch battery low", "End Trio on Watch, or take the pump back on your iPhone, before the watch runs out of charge.", "Trio on Watch can't save", "No pump commands are sent until it can. Check your watch's storage, or take the pump back on your iPhone.", "Pump command unconfirmed", "The pump never confirmed the last dose, so Trio counts it as given. Insulin on board may be shown too high.", "Can't reach your pod", "Open Trio on your watch, or End to let your iPhone loop.", "Open Trio on your watch.", "Trio on Watch doesn't control the pump.", "The pump hasn't confirmed the last command. Check recent doses before trying again.", "Trio on Watch couldn't save. Nothing was sent.", "The pump didn't take the bolus. Nothing was given.", "More than your max bolus of %@ U.", "Insulin on board can't be worked out right now.", "This would go over your max IOB of %@ U.", "A bolus was given in the last few minutes."

### Not verified

- Nothing ran on a watch, a pod or a sensor. In particular: Bluetooth alert wakes and their real time budget (E2, E5), `performExpiringActivity` on a backgrounded watch, StartDelay-free pod connects inside a cycle, the G7 watch-slot adopt and its first bond, whether the kits pass `CBError` 17/18 up to the host, time-sensitive delivery under Silent/Focus/lock, file protection while locked (D-8), restore-identifier behaviour after a relaunch.
- The simulator tests drive the host with a pump double and injected readings; OmnipodKit and G7SensorKit are only compiled, never run.
- `arm64_32`: compiled only (see below); the integer-width tests ran on the arm64 simulator.

### M5 verification

`X` = `xcodebuild -workspace Trio.xcworkspace`, simulators as above. Exit codes are each command's own `$?`.

| # | Step | Result |
|---|---|---|
| 1 | Watch app, simulator, flag off | 0 |
| 2 | Watch app, simulator, flag on | 0; uses `TrioOnWatch-Info.plist` (step 1 doesn't) |
| 3 | Watch app, `generic/platform=watchOS`, flag on, `CODE_SIGNING_ALLOWED=NO` | 0; binary `arm64 arm64_32` (V3-3: compiled only) |
| 4 | iOS app (`-scheme Trio`), fresh derived data | 0 |
| 5 | `Trio Watch AppTests`, flag off and flag on, `-parallel-testing-enabled NO` | 0 and 0; 40 / 40 each (21 existing + 19 new) |
| 6 | Full `Trio Tests` | 1167 total, 1120 passed, 1 failed, 46 skipped. The failure is the known `FileStorageTests` "Can parse mmol/L settings to mg/dL" flake (`.claude/rules/testing.md`) |
| 7 | `FileStorageTests` alone (`test-without-building`) | 0; 9 / 9 passed |

The baseline is 1109 / 0 / 46; the 12 new `Trio Tests` tests account for the difference.

Build notes:
- Watch-only (arm64) and iOS (whose embedded watch app builds arm64 and x86_64) builds sharing one derived-data folder broke later builds: `RileyLinkBLEKit-watchOS` linked its x86_64 slice against an arm64-only `EagerLinkingTBDs/…/LoopKit.tbd`. With separate derived data for each, every build passes. CI builds the iOS app only, so it isn't affected, but a local workflow that alternates both will be.
- With parallel testing on, the watch tests ran in clones and the first version of the pump double crashed (main-actor assertions on the kit's queue); fixed in the double before the runs above.

### Worktree hygiene

- The build-phase SwiftFormat reformatted the new files (kept) and `Trio Watch App Tests/Unit Tests.swift` (reverted every time). `Package.resolved` reverted. Submodules unchanged.
