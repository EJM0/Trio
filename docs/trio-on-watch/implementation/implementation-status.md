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

## M2b: kit pins and the foreign-session rule (2026-11-16)

Branch `feat/tow-kits`, off `feat/trio-on-watch` @ `349f49523`. Implements V2-6 and V2-29, plus the V2-7b context and the E safety conditions C-1 and C-2.

> [!IMPORTANT]
> The kit commits below exist only in this machine's submodule repositories, on local branches named `trio-on-watch`. Nobody else can check out or build `feat/tow-kits` until the maintainer mirrors them to loopandlearn (LoopKit `trio-on-watch`, OmnipodKit `trio-on-watch`) and updates the submodule URLs or branches. `.gitmodules` is unchanged.

### Pins

| Submodule | Before | After | Content |
|---|---|---|---|
| LoopKit | `babddf04` | `7fd4d1a7` | `babddf04` + cherry-pick of LoopKit#687 (`a78fe3bb`, author jeremybarnum). Nothing else from LoopKit `next-dev`; #695/#696 break the other kits. |
| OmnipodKit | `6fdf0e0e` | `b647ea98` | loopandlearn/OmnipodKit#177 @ `3d21d9c` (jeremybarnum `sportmode/next-dev`) + `d5606d67`, `2e5f9bdc`, `b647ea98` (below). `6fdf0e0e` is an ancestor. |
| G7SensorKit | `08d48863` | unchanged | |

### The rule (OmnipodKit)

- An adopt or a take expects one EAP SQN resync. Any later resync on a shared pod is a foreign session.
  - Every foreign session is reported: `foreignSessionDetectedAt` is updated, which reaches the host as `pumpManagerDidUpdateState`.
- If the foreign session falls outside a superseding take, the kit sets `refusesSessions`. From then on, until the host takes control again:
  - no session runs and nothing is sent: no bolus, no temp of any rate including zero, no suspend, no resume, no basal schedule, no alert acknowledgement, no status read;
  - there is no handshake at all, not even the retry after the resync that found the foreign session;
  - every refusal returns `PodCommsError.podUsedByAnotherController`.
- A superseding take is `takeControl(supersedingAnotherControllerUntil:)` with a date. It is for a Take Back from a peer that has not acknowledged `stopped`; the host passes takeover + 6 h.
  - Until that date, or until `stopSupersedingAnotherController()` (the peer acknowledged), foreign sessions are reported but don't stop this device (V2-7b).
  - A plain `takeControl()` (End, lend, adopt) is never superseding (C-1).
- Pods never shared are unchanged.
- C-2: when a link is (re)connected, the kit always handshakes, so a stale device meets the refusal. A link restored after a relaunch used to reuse the saved session keys without a handshake (#177 and stock). On a shared pod it now handshakes again. Both points come from reading the code.
- Why reductions are refused too: see `omnipodkit-177-proposal.md`.

### Verification

| # | Step | Result |
|---|---|---|
| 1 | OmniTests, all (scratch workspace: LoopKit `7fd4d1a7`'s parent + #687, RileyLinkKit `52a652c9`), fresh iPhone 17 / iOS 27.2 simulator | 255 run, 0 failed, 3 skipped. `DeviceHandoffTests`: 37, of which 9 are new |
| 2 | Mutation checks on the new tests | Rule removed (never refuse): 14 failures. Scope expiry ignored: the scope test fails. No report: 6 tests fail. Each mutation was reverted |
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
