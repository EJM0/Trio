# Trio on Watch: readiness assessment (pre-M8)

Date: 2026-11-18. Branch `feat/trio-on-watch` @ `14b5d6c08`. Baseline `nightscout/dev` @ `ad6c66876`. Nothing is pushed.

## Verdict

**Ready for M8 hardware testing. Not ready for in-vivo use and not ready to upstream as one PR.**

- **Design: pass** (G, `reviews/design-reviews.md`, "Final design review (pre-M8)").
- **Safety: ready for M8, not for in-vivo use** (E, `safety/safety-review.md`, "Final safety review (pre-M8)").
- **Architecture: approve with changes for M8** (C, `reviews/architecture-reviews.md`, "Final architecture review (pre-M8)").

## What is implemented

The scope is v1 per `architecture/requirements-and-scope.md`: Omnipod DASH and Dexcom G7, a Start on the watch with the phone nearby, End, Take Back, Closed Loop only, and the `TRIO_ON_WATCH` build flag (off by default).

| Area | Where | Milestones |
|---|---|---|
| Shared oref entry point `OrefInputs`/`OrefRun`; pure input mapping, TDD, selection rules; explicit time zone; `microBolusAllowed` input that matches JS | `Trio/Sources/APS/OpenAPSSwift/OrefRun/` | M1, M1b |
| Pure bolus calculator, glucose-alarm evaluation, glucose guard, `BolusSafetyEvaluator`, low-glucose bolus warning | shared, compiled for watch | M1b, M5, M6 |
| Watch target compiles the shared code; flag-gated plist and entitlements; watchOS 10.6; embedded kits with a load-command guard | project, `scripts/check-watch-frameworks.sh` | M2a, M5, embed fix |
| OmnipodKit: #177 plus scoped foreign-session refusal, accepted-SQN high-water mark, restored-link handshake, bounded adopt; LoopKit plus #687 | local kit branches `trio-on-watch` | M2b |
| Loan state machine (rows P1–P46, W1–W38, T1–T6), persisted state, three-layer phone pump gate | `Trio/Sources/APS/WatchLoan/` | M3 |
| Phone coordinator: grant snapshot, transport, merge with tombstones, odometer audit, silence alerts, Take Back, recovery | `Trio/Sources/Services/WatchManager/` | M4, M7 |
| Watch host: adopt, cycle, write-ahead intents, guards, alarms, bolus, carbs, controls, instrumentation, Closed-Loop-only gate | `Trio Watch App Extension/Loan/` | M5, M7 |
| UI on watch and phone, notifications, accessibility | watch `Views/`, phone `Modules/` | M6, M7 |

Size against the baseline: production Swift +11.8k / −1.5k lines; tests +7.5k; golden fixtures +48k (JSON); docs +8.4k.

## What is verified (simulator and unit level only)

- **Phone dosing unchanged with the flag off.** Characterization goldens were recorded from the original sources before each extraction and stay byte-identical (17 phone + time-of-day scenarios). The 14 parity goldens are unchanged. Mutation runs caught the injected faults (autosens choice, override fields, glucose window, tie order, time zone, `microBolusAllowed`).
- **Watch equals phone.** The watch input builder reproduces the phone goldens through the real wire format, including smoothing, TDD sufficiency and DST.
- **Ownership logic.** An exhaustive state search (epoch 2; two-Start stress variant passes) with a modelled kit found no reachable two-commander state and no no-dosing state without an alarm. It found and fixed four real races along the way.
- **Kit rules.** 53 hand-off tests plus 271 OmniTests pass against the pinned kit. Production-code mutations fail the tests, except two `BlePodComms` call sites that are verified by reading only.
- **Integration (M7).** Builds with the flag on and off pass. The watch app was installed on a paired simulator and stayed running. Watch tests 68/68. Full Trio Tests: 1209 passed, 0 failed. The time-zone escape test passes.

## What is not verified

- **Anything on hardware.** That covers:
  - Bluetooth wakes and the 5-per-24 h budget (E2);
  - whether a DASH command fits the wake window (E5);
  - the TestFlight upload with `bluetooth-central` (E1);
  - pod connect latency (StartDelay is broken on watchOS; V3-10);
  - the one-BLE-link-per-pod assumption;
  - the pod's behaviour with stale keys and resyncs;
  - G7 watch-slot adoption;
  - notification delivery under Silent and Focus;
  - file protection while the watch is locked;
  - `arm64_32` runs;
  - battery.
- **Device-only design checks D-1 to D-7:**
  - VoiceOver bolus confirm;
  - largest watch text;
  - Sleep Focus;
  - wrist-down glanceability;
  - double-tap never snoozes;
  - haptics;
  - pill timing during real hand-overs.
- **The CI job `watch-flag-build`** hasn't run on GitHub.
- **Each intermediate commit** isn't built on its own; only the tips were.

## Risks and open items

| # | Item | Owner | Blocks |
|---|---|---|---|
| R1 | ~~F1 (repeat SMB after a failed determination save) not merged~~ Resolved 2026-11-18: merged as `54c65f815` | — | — |
| R2 | Kit commits are on top of #177, which is still open. Mirrored 2026-11-18 to `dnzxy/LoopKit` and `dnzxy/OmnipodKit`, branch `feat/trio-on-watch` (OmnipodKit since moved to `dd0700f`, see the status doc). `.gitmodules` still points at loopandlearn | Maintainer: coordinate with #177 (proposal plus addendum) | fresh-clone builds, upstream |
| R3 | ~~Sync with dev for #1598~~ Resolved 2026-11-18: merged dev `7e2fa52cb` as `1cc46c299`; the loan queries are folded into #1598's reply handler | — | — |
| R4 | Platform risk BR-1: the documented 5 Bluetooth wakes per 24 h. Field logs show hundreds of wakes, but with a complication present. | M8 E2, with and without a complication | flag on for anyone |
| R5 | String catalogs: about 200 new keys, plus a watch catalog and InfoPlist extraction | Maintainer IDE build | upstream |
| R6 | CI flag job builds the kits uncached on every PR | Path-gate it | upstream |
| R7 | Debug screenshot harness lives inside production views | Keep it off upstream PRs | upstream |
| R8 | Minor:<ul><li>pod-lifetime audit uses today's basal profile</li><li>worst-case snapshot size, about 7 % under its budget</li><li>no automatic retry of a stuck Take Back</li><li>G-R3 parses "N min" text</li><li>G-F1 to G-F4</li></ul> | Follow-ups | — |

## M8 plan (maintainer, hardware)

From `research/watchos-platform-research.md` (E1–E14), `research/kristinkand-test-log-1784.md` (T1–T12), E's list and G's D-1 to D-7:

1. **E1:** TestFlight upload of a flag-on build.
2. **E2:** 24 h unattended G7-on-watch run, phone off. Count cycles, with and without a complication.
3. **E5 and pod connect latency:** timestamps from wake to command.
4. **In-vitro DASH on a test pod with water, no person:**
   - Lend, End, and Take Back with the watch both alive and off;
   - relaunches and a watch reboot;
   - process kill mid-bolus on each device;
   - out of range mid-command;
   - a pod fault and sensor expiry during a loan;
   - two-controller characterization: resyncs and stale keys.
5. **Overnight endurance** on target watches, including a 32-bit SE 2: battery, alarm delivery under Sleep Focus, G7 slot reliability.
6. **D-1 to D-7** design checks on a device.

Before any in-vivo use, all of these must hold (E):
- M8 passed, with written results;
- F1 merged;
- kit SHAs reviewed and pinned;
- a plain-language tester brief, which is not medical advice and asks testers to involve their care team;
- attended daytime sessions first;
- overnight only after E2 passes.

## Upstream PR series (C)

1. Characterization goldens (tests only).
2. `OrefRun` extraction.
3. Pure bolus, alarm and glucose-guard extractions.
4. Algorithm compiled in the watch app (after #1749).
5. Kit PRs: OmnipodKit #177 plus the fixes; LoopKit #687.
6. Loan state machine and phone pump gate.
7. Phone coordinator.
8. Watch loop host behind the flag.
9. Screens.

PRs 1–4 and 6 can go before the hardware results; 7–9 wait for E1 and E2. When the PRs are squashed, every commit gets the four co-author trailers.
