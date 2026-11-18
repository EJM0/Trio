# Architecture reviews

## Final architecture review (pre-M8)

Reviewer: Agent C (upstream Trio architecture). 2026-11-18.

Scope:
- the M7 delta `3a7cf476e..14b5d6c08`;
- the whole integration branch `feat/trio-on-watch` @ `14b5d6c08` against baseline `ad6c66876`: 112 non-doc files, +12.5k/−1.5k in production and project files, about +9.7k lines of test Swift and +47.9k lines of golden JSON.

Read-only: nothing was built or run for this review. Earlier per-milestone findings are in `arch-review-C.md` and `implementation-reviews.md`.

Legend: **V** = verified by reading the code at `14b5d6c08`; **I** = inferred; **U** = unverified.

### 1. Verdict

**Approve with changes for M8 (hardware). Not upstream-ready as one PR.**

- **No parallel architecture:**
  - The phone keeps `APSManager`, `DeviceDataManager` and the stores. A gate, an actor coordinator and a host behind protocols were added.
  - Both devices run the same oref code. `OpenAPS` gathers inputs and calls `OrefRun`'s pure stages; the watch builds `OrefInputs` from the grant plus its own records and calls the same stages.
  - The watch uses the existing watch app and its one WCSession.
  - The kits are reached through LoopKit's `ExclusiveDeviceControl` / `DeviceConfigurationSharing` and one adapter file per kit. (V)
- **What blocks upstreaming** (not M8):
  - the local-only kit pins (§3.1);
  - the overlap with the now-merged #1598 (§4);
  - the size: it must become a stacked series (§5).
- **Still open from earlier rounds:**
  - M5R-01: is the `@objc` reply-handler witness confirmed? Check it in the M8 build log or with the one-line `instancesRespond(to:)` test.
  - M5C-08: no watch string catalog extraction yet.

### 2. M7 delta

| Change | Assessment |
|---|---|
| CI job `watch-flag-build` (`unit_tests.yml:67-97`) | Right purpose: no other job builds flag-on. It is consistent with the file's conventions (Xcode 26.2, `actions/checkout@v5` tag pins like the other jobs, `set -o pipefail` + `tee`, nightscout-only). Costs: no DerivedData cache, so every PR to `dev` pays a full kit build (I: several macOS runner minutes) for an off-by-default feature, and the log is not uploaded on failure. **Change:** gate the job on changed paths (`Trio Watch App Extension/**`, `Trio/Sources/APS/WatchLoan/**`, `Trio/Sources/APS/OpenAPSSwift/**`, the kit submodules, `Trio.xcodeproj/**`), or run it on a schedule. Add `actions/upload-artifact` for `xcodebuild-watch.log` on failure, as the test job does. |
| `NotLoopingMonitor.setArmed(_:since:)` (`NotLoopingMonitor.swift:85-93`) + coordinator `.arm` anchor `.distantPast` at `home` (`WatchLoanCoordinator.swift:~421-424`) | At home with no loan it is a no-op: already armed, and `distantPast` is never later than `armedAt`, so the baseline series is unchanged. A relaunch while nobody may dose re-anchors the series, which fixes a real gap. Takingback → home keeps the takingBack anchor until the phone loops again. (V by reading) |
| Ledger `replacedBookings` (cap 512) and `watchLoop` (`WatchLoanCoordinator.swift:63-77, 237-260`) | Keeps a replaced watch booking from being re-stored by a late batch. The bounded list matches the inbox pattern. Fine. |
| Hand-back resend, alarms in every no-dose state, watch loop age on the phone pill, suspend-reminder copy, the low-glucose bolus warning pinned to dev's rule (`LowGlucoseBolusWarning`) | Behaviour follows the decision table and the M6 design. The warning extraction replaces the inline `isGlucoseVeryLow` expression in `TreatmentsRootView`; keep its characterization test as the guard that dev's rule is unchanged. |
| `SettingsRootView` `#if DEBUG` screenshot-fixture hooks (`SettingsRootView.swift:278-288, 420`), `TrioOnWatchPhoneFixture` (`TrioOnWatchPhoneViews.swift:247-262`), watch `TrioOnWatchFixtures.swift` (181 lines, `#if DEBUG`) | Inert without the `-TrioOnWatchPhoneScreen` launch argument. Many OS-AID users build Debug from Xcode, so this ships to them, inert. **Over-built for upstream:** a screenshot harness inside production views. Keep it on the fleet branch and leave it out of the upstream series (§5), or move it to previews / a UI-test target. |

### 3. Flag-off vs `dev`: every remaining difference

`TRIO_ON_WATCH = NO` (default). "Inert" means the code is compiled but no path reaches it unless a loan state exists.

#### 3.1 Kits (affect every phone user)

| # | Difference | Evidence | Assessment |
|---|---|---|---|
| K1 | **OmnipodKit** `6fdf0e0e` → `c23daca`: loopandlearn/OmnipodKit#177 (SportMode) plus 7 local review fixes, 62 commits, 27 files, +3.4k/−0.2k. | `git -C OmnipodKit diff --stat 6fdf0e0 c23daca`. The commits exist only on the local branch `trio-on-watch` (status doc, M2b IMPORTANT note). | The biggest flag-off difference. Pod comms code changes for every Omnipod user. The kit's foreign-session rule applies only to a shared (released or adopted) pod (status M2b "The rule"; I for unshared pods). OmniTests pass (status R2: 261/0/3). **Upstream blocker:** the commits must land in loopandlearn/OmnipodKit (via #177 and follow-ups) before any Trio PR can pin them. |
| K2 | **LoopKit** `babddf04` → `7fd4d1a7`: a cherry-pick of LoopKit#687 (watch plugin protocols without LoopKitUI; direct-read CGM capability), 4 files, +50/−2. | `git -C LoopKit diff --stat` | Small and additive. The commit is also local-only, on branch `trio-on-watch`. It needs #687 merged into the loopandlearn `trio-next-dev` fork first. |
| K3 | G7SensorKit unchanged. | — | — |

#### 3.2 iOS app

| # | Difference | Assessment |
|---|---|---|
| P1 | `OpenAPS` gathers, then calls `OrefRun` pure stages (M1). `OrefInputs+Mapping/+Selection/+TDD` are shared with storage. | Byte-exact against the 17 production-path characterization goldens plus the parity goldens (status M1/M1b). M1-05, the sub-second `Date()` vs `clock` quirk, is preserved on purpose. Behaviour identical per those tests. |
| P2 | M1b pure extractions: `BolusCalculator`, `GlucoseAlarmEvaluation`, `ForecastedGlucoseEvaluator`, `BolusSafetyEvaluator` (moved verbatim), `LoopGlucoseGuard`, `LowGlucoseBolusWarning`; `GlucoseAlertCoordinator` +42/−185, `GlucoseStorage` +23/−53, `FetchGlucoseManager` +38/−137 (smoothing to a static, predicate identical). | Identical by characterization tests and my reading of the moves (`implementation-reviews.md` M5 re-review). |
| P3 | `WatchLoanGate` checked on every pump command path: one `fileExists` stat per check when no state file exists. | Behaviour identical (M3 review); a negligible cost. |
| P4 | `WatchLoanCoordinator` resolved and started at launch: reads two small files, decides `.relaunched` → `home(0)`, and the arm is a no-op. | Inert. |
| P5 | `AppleWatchManager`: loan payloads are recognised by key and routed before existing handling. The `session(_:didReceiveMessage:replyHandler:)` witness lives in `AppleWatchManager+WatchLoan.swift`, and non-status messages go the old way with an empty reply. | Inert for today's watch, which sends no reply-handler messages. Conflicts with #1598, now merged (§4). |
| P6 | `NotLoopingMonitor` `isArmed` / `armedAt` / `setArmed(_:since:)`. | Equivalent at home (M4 review, M7 row above). |
| P7 | `DeviceDataManager`: the `syncDeliveryLimits` extraction (verbatim), `foreignPodSession` publisher, `awaitPumpEventStorage`, `resyncPumpAfterTakeBack`; `@Persisted lastForeignPodSession`, written only when an Omnipod reports one. `APSManager.awaitPumpIdle`; `LoopGuard` made internal. `PumpHistoryStorage.getPumpHistory(since:)`, `replaceTaggedBolus`. | Inert or additive. |
| P8 | PumpConfig `KitScreenToken` (a static open counter) on the kit settings and setup screens; the screens are replaced by the reason only when the phone isn't the pump owner. | Inert at home. |
| P9 | Home header, Treatments, Adjustments and Settings show the "Apple Watch is in control" pill, blocked notes and the Dosing Mode lock only when the gate says not-owner. | Inert at home. `TreatmentsRootView` has one re-indented `Image(systemName: "clock")` line, a SwiftFormat drive-by; revert it in the upstream PR. |
| P10 | `TRIO_ON_WATCH_SWIFT_CONDITION_YES` / `SWIFT_ACTIVE_COMPILATION_CONDITIONS` in `Config.xcconfig`; `startRefusal` returns `.featureOff`. | Flag plumbing only. |
| P11 | Debug-only screenshot harness (§2). | Inert without the launch argument. |
| P12 | New user-facing strings (phone and watch); the catalog is not regenerated. | Needs an IDE build and catalog commit per milestone (project rule: no hand edits). |

#### 3.3 Watch app

| # | Difference | Assessment |
|---|---|---|
| W1 | **Minimum watchOS 10.6** (was 10) on the app, complication and tests. | User-visible: watches on 10.0–10.5 must update. Required by LoopKit-watchOS. Same as #1749. |
| W2 | **Module renamed `Trio`** (was `Trio_Watch_App`). | No persisted-type or archiver side effects (M2a review). Same as #1749. |
| W3 | **Kits linked and embedded**: LoopKit, OmnipodKit, G7SensorKit (and RileyLinkBLEKit through OmnipodKit, I). | Size and launch dylib loads for a feature that is off. Accepted as a maintainer decision (M5C-03), as in #1749. |
| W4 | **`NSBluetoothAlwaysUsageDescription`** on the watch app. | Needed because W3 embeds CoreBluetooth users (M5 re-review). Harmless. |
| W5 | **`check-watch-frameworks` run-script phase** (`scripts/check-watch-frameworks.sh`, `project.pbxproj:~6147-6158`): fails the build if the watch loads an `@rpath` framework it doesn't embed, or embeds a non-watchOS one. | Build-time only, no runtime difference. It runs `otool`/`file` on every watch build, flag off too. Useful, but it's a project-level policy change, so propose it separately (§5, PR 4). |
| W6 | About 100 shared algorithm, WatchLoan and pure files compiled into the watch; `AlgorithmLoggingShim` active with the sink set to `WatchLogger.algorithm`; `WatchLogEntry` categories `algorithm`, `loop`, `pump`, `cgm`. | Inert code. The log route works but carries nothing while no host exists. |
| W7 | Loan host (about 3.1k lines under `Loan/`) compiled; `WatchLoanRuntime.start` creates nothing; the delegate adaptor is under the flag; `WatchState` returns early for loan payloads; snooze, bolus and confirmation views consult `TrioOnWatchSource` / `LoanTreatments.host`, which are nil. | Inert. Background-task handling is as today (M5C-01 resolved). |
| W8 | Flag-on only: the `TrioOnWatch-Info.plist` (`bluetooth-central`) and entitlements (time-sensitive). | Not in flag-off builds (V2-28). Browser builds with the flag on need the watch App ID capability (M2aC-01). |

Net: flag off equals `dev` in behaviour on iOS (I, by the characterization goldens and reading). The watch differs in packaging (W1–W5), not behaviour. The one real behaviour delta for all users is the OmnipodKit pin (K1).

### 4. Conflict surface with open upstream PRs

States checked with `gh pr view` on 2026-11-18. File overlap computed against `git diff --name-only ad6c66876..14b5d6c08`.

| PR | State | Overlapping files | Nature of the conflict | Resolution |
|---|---|---|---|---|
| #1598 | **MERGED** 2026-11-16 | `TrioWatchApp.swift`, `TrioMainWatchView.swift`, `WatchState.swift`, `AppleWatchManager.swift`, pbxproj | **Real, now mandatory.** It rewrites the watch session handling, adds the phone's own `didReceiveMessage(_:replyHandler:)` (it answers watch state requests through it), and removes `WatchStateSnapshot`. The loan's reply-handler witness (M5R-01) and the `WatchState` early returns must be merged into #1598's versions. Two witnesses for the same selector won't compile. | Rebase the branch onto current `dev` before M8 builds are handed out. Fold the loan status query into #1598's reply handler: `if WatchLoanWireKey.isStatusQuery(message) { answer } else { #1598 path }`. Re-run the watch host and coordinator suites. |
| #1749 | Open | `GlucoseTrendView.swift`, `AppleWatchManager.swift`, pbxproj | **Duplicate platform work:** the watchOS 10.6 bump, module rename, LoopKit + G7SensorKit linking and `bluetooth-central` (it adds the mode unconditionally; this branch puts it behind the flag). `WatchCGMHost` vs `WatchLoanCGM` both adopt a G7 from `DeviceConfigurationSharing`. | Land #1749 (or its platform half) first, then rebase PR 4 below onto it. Decide whether `WatchLoanCGM` reuses `WatchCGMHost`; two G7 managers on one watch are forbidden (V2-4), so they must not both run. |
| #1648 | Open (draft) | `WatchState.swift`, `BolusSafetyValidator.swift`, `AppleWatchManager.swift` | It adds overridable checks to `BolusSafetyEvaluator`, which this branch moved to `BolusSafetyEvaluator.swift`. A textual conflict plus a semantic one: the watch-side loan bolus calls the evaluator too. | Land the evaluator move (PR 3) first; #1648 rebases onto the new file. The loan bolus path then decides whether overrides apply on the watch (it shouldn't skip `max_bolus`, which #1648 keeps). |
| #1694 | Open | `TrioMainWatchView.swift`, `WatchState.swift`, `AppleWatchManager.swift`, pbxproj | Watch Usage Mode is enforced on the phone, but during a loan the phone isn't the enforcer. | The watch host must read the mode from the grant snapshot and enforce it locally (Adjustments/View modes refuse loan boluses). Add `watchUsageMode` to `WatchLoanSnapshot` when #1694 lands. |
| #1723 | Open | `TrioWatchApp.swift`, `TrioMainWatchView.swift`, `WatchState.swift`, `Unit Tests.swift`, `AppleWatchManager.swift`, pbxproj | It adds watch App Group entitlements (this branch's flag-on entitlements file would have to merge with them), `.backgroundTask(.appRefresh)` and WC background handling in the app scene. That competes with `WatchAppDelegate` as the single background-task handler. | One owner of background tasks: if both land, `WatchBackgroundTasks` must handle #1723's refresh and complication tasks, or the reverse. Merge the entitlements files. |
| #1775 | Open | `ServiceAssembly.swift`, `AppleWatchManager.swift`, pbxproj | Small: one registration and one `AcknowledgmentCode` case. Its request cache and freshness semantics overlap with `WatchLoanInbox` dedupe. | Trivial textual merge. Don't merge the two dedupe mechanisms now; the loan protocol has epoch semantics #1775 lacks. |
| #1745 | Open | `LoopKit` submodule, `TrioApp.swift`, `ServiceAssembly.swift`, `TrioAlertManager.swift`, pbxproj | **Submodule conflict:** it pins LoopKit to `dabear/LoopKit smartwatch-manager-review` (LoopKit#684), while this branch pins a local `trio-on-watch` LoopKit (#687 cherry-pick). Also alert forwarding in `TrioAlertManager`, next to the gate's acknowledgement check. | The LoopKit fork must carry both #684 and #687 before either Trio PR merges. Coordinate through the `trio-next-dev` fork. |

### 5. Proposed upstream PR series

Rules:
- Every PR keeps flag-off behaviour identical and states its dosing impact.
- Algorithm and pure extractions go first because each has stand-alone value (test coverage, a smaller `OpenAPS`) even if Trio on Watch never ships.
- Stack them ("[Part N of M]", "Stacked on #N").
- Sizes are production / test lines, excluding goldens.

| # | Title (Trio style) | Scope | Approx. size | Depends on | Notes |
|---|---|---|---|---|---|
| 1 | Add Production-Path Oref Characterization Goldens | Tests only: goldens through `OpenAPS.createProfiles`/`autosense`/`determineBasal` on an in-memory stack (C-01), plus the clock seam the recording needs | 0.1k / 1.5k + about 25k JSON | — | No production behaviour change. Reviewable alone; locks dev's behaviour before any refactor. |
| 2 | Refactor OpenAPS Into Pure OrefRun Stages | `OrefInputs`, `OrefRun`, `+Mapping/+Selection/+TDD`; `OpenAPS` gathers and calls them; `AlgorithmPackage` list updated | 1.3k / −0.3k; 1k tests | 1 | Algorithm PR: goldens byte-exact, stated "no dosing change". Needs algorithm sign-off per `.claude/rules/algorithm-safety.md`. |
| 3 | Extract Pure Bolus, Alarm and Glucose-Guard Calculations | `BolusCalculator`, `GlucoseAlarmEvaluation`, `ForecastedGlucoseEvaluator`, `BolusSafetyEvaluator` (move), `LoopGlucoseGuard`, `LowGlucoseBolusWarning`, smoothing static, TDD pure | 0.7k / −0.5k; 1k tests | 2 | Unblocks #1648's rebase. Characterization tests prove identity. |
| 4 | Compile the Algorithm in the Watch App | watchOS 10.6, module `Trio`, shared algorithm membership + membership test, log shim route, `check-watch-frameworks` phase. No kits. | 0.1k + pbxproj; 0.1k tests | 2; **after #1749** | If #1749 lands first, this shrinks to membership + shim. Otherwise it overlaps #1749 almost completely. |
| 5 | (kit repos, not Trio) OmnipodKit#177 + foreign-session rule + bounded adopt; LoopKit#687 into the `trio-next-dev` fork | Kit PRs with OmniTests | +3.4k in OmnipodKit | — | Prerequisite for 7–9. The Trio PR is only a pin bump after these merge. |
| 6 | Add Watch Loan State Machine and Phone Pump Gate | `WatchLoan` (pure decide), state, messages, store, `WatchLoanGate` + gate on every pump path (incl. kit screens, alert acks), decision-table tests. No UI, no transport. | 1.1k / 2k tests | 2 | Gate active regardless of flag (D-2), a no-op at home. Reviewers can verify "every pump path" against the M3 table. |
| 7 | Add Phone Side of Trio on Watch | Coordinator, phone host, pump adapter, snapshot, records, audit, merge, `NotLoopingMonitor` arming, `AppleWatchManager+WatchLoan`, kit pin bump | 2.0k / 2.5k tests | 5, 6, rebased on #1598 | Behind `TRIO_ON_WATCH` for Start; Take Back always compiled. |
| 8 | Add Watch Loop Host Behind TRIO_ON_WATCH | `Loan/*`, `WatchLoopInputs`, `WatchLoopRules`, kit linking + embedding, Bluetooth purpose string, flag-on plist/entitlements, CI flag build | 3.5k / 1.5k tests | 4, 5, 7 | The largest. Possible split: 8a records, files and runtime; 8b cycle and treatments; 8c alerts. Hardware evidence from M8 goes in its Testing section. |
| 9 | Add Trio on Watch Screens | Phone pill, banner, blocked notes, Settings lock; watch status pages and treatment views | 1.0k phone + 1.6k watch / 0.3k tests | 7, 8 | Screenshots table. Leave the debug fixtures out (§2). |

Merge order: 1 → 2 → 3 → (#1749) → 4 → 5 (kit repos) → 6 → 7 → 8 → 9.

PRs 1–4 and 6 are mergeable before any hardware result. PRs 7–9 should wait for M8's E1 (TestFlight upload) and E2 (24 h wake count), since the flag can't be offered to users before those pass anyway (SR-17).

### 6. Over-built (ponytail lens)

| Item | Size | Keep? |
|---|---|---|
| Watch `TrioOnWatchStatus.swift` (863) + `TrioOnWatchStatusView.swift` (448) | 1.3k | **Biggest single UI item.** Review it against the M6 design scope before PR 9; a status page plus treatment refusal states should fit in about half. Not a correctness problem. |
| Debug screenshot harnesses (phone `TrioOnWatchPhoneFixture`, watch `TrioOnWatchFixtures.swift` 181, the Settings hooks) | ~0.25k | Keep on the fleet branch for design reviews; leave them out of upstream. |
| Diagnostics: `LinkEventClock`, `WatchAppState`, daily summary, per-task logging | ~0.2k | Keep through M8; E2 needs them (V2-31). Trim after M8 to what triage needs. |
| `WatchLoanPhoneHost` (16-member protocol), `WatchLoanTransport`, `LoanPumpFactory`, `WatchLoanEnvironment` | — | Keep: they are the seams that let the coordinator and host tests run without WCSession, Core Data or kits. |
| `WatchLoanAudit` + ledger (audits, replaced bookings, inbox) | ~0.3k | Keep: the odometer audit is the safety net for unbooked insulin (SR-21). |
| `KitScreenToken` static counter | 40 | Keep: the simplest correct answer. |
| CI `watch-flag-build` on every PR | — | Path-gate it (§2). |

Nothing found is a second implementation of something Trio already has, except the mirrored pump-history rules (`WatchLoopInputs.store`). That mirror is deliberate, since the watch has no Core Data, and it is pinned by the differential test.

### 7. Before M8

1. Rebase onto current `dev` (#1598 merged) and resolve the reply-handler witness. Confirm M5R-01 on the built product.
2. Mirror the local kit commits (OmnipodKit `trio-on-watch`, LoopKit `trio-on-watch`) somewhere the maintainer's M8 build machine and any second tester can fetch them.
3. Path-gate the CI flag job and upload its log on failure.
4. Do one IDE build per target and commit the extracted strings (phone and watch).

### Evidence index

- Branch tip `14b5d6c08`; baseline `ad6c66876`; M7 range `3a7cf476e..14b5d6c08`.
- `.github/workflows/unit_tests.yml:67-97`; `scripts/check-watch-frameworks.sh`; `Trio.xcodeproj/project.pbxproj:~6147-6158` (run-script phase).
- `Trio/Sources/Services/Alerts/NotLoopingMonitor.swift:85-93`; `Trio/Sources/Services/WatchManager/WatchLoanCoordinator.swift:63-77, 226-260, ~419-424`.
- `Trio/Sources/Modules/Settings/View/SettingsRootView.swift:278-288, 420`; `Trio/Sources/Modules/Home/View/Header/TrioOnWatchPhoneViews.swift:242-262`; `Trio Watch App Extension/Views/TrioOnWatchFixtures.swift:1`.
- Kit pins: `git -C OmnipodKit log 6fdf0e0..c23daca` (62 commits, local branch `trio-on-watch`), `git -C LoopKit log babddf04..7fd4d1a7` (1 commit, local branch `trio-on-watch`); `implementation/implementation-status.md` M2b section (IMPORTANT note, pins table, "The rule").
- PR overlap: `gh pr view {1598,1648,1694,1723,1749,1775,1745} --json files,state,mergedAt` against `git diff --name-only ad6c66876..14b5d6c08`. #1598 merged 2026-11-16T20:48:50Z.
- Sizes: `git diff --numstat ad6c66876..14b5d6c08`.
