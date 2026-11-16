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
