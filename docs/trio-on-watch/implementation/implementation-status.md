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
