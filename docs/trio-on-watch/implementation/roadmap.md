# Implementation roadmap (v2, 2026-11-16)

Integration branch: `feat/trio-on-watch` (`~/workspaces/Trio-on-watch`). Each milestone is built on its own branch and worktree off the integration tip. It gets an independent review, then a local merge. Commits are local and signed; no pushes, no PRs. v1 of this roadmap is superseded: M2 is split into M2a and M2b, and M1b and M8 are added, per the review round.

| M | Branch | Depends | Objective | Acceptance | Status |
|---|---|---|---|---|---|
| M0 | integration | — | Record the baseline builds and tests | `implementation-status.md` | Done (`1a66735b9`) |
| M1 | `feat/tow-oref-run` | M0 | `OrefInputs` and `OrefRun`, plus pure input mapping and TDD math | Characterization goldens recorded through `OpenAPS` before the refactor stay byte-exact; full Trio Tests pass | Done, review pending |
| M1b | `feat/tow-pure-calcs` | M1 | Pure bolus calculator (ADR-005), pure glucose-alarm evaluation (ADR-006), explicit `timeZone` in oref inputs (V2-23) | Goldens unchanged with `TimeZone.current`; characterization tests for the bolus calculator and the alarms recorded before extraction | — |
| M2a | `feat/tow-platform` | M0 | Watch target compiles the shared pure code. Flag-gated plist and entitlement variant (V2-28). Deployment target 10.6 for all watch targets. Logging route for the algorithm on the watch | Watch builds for the simulator and `arm64_32` with the flag off and on; the iOS build is unchanged with the flag off | — |
| M2b | `feat/tow-kits` | M2a | LoopKit + #687 and OmnipodKit #177 @ `3d21d9c` as local submodule branches, plus the V2-6 foreign-session refusal patch with tests | #177 `DeviceHandoffTests` + new tests pass. Full iOS app builds; kit plugins (Dana, Medtrum, Minimed, Libre) build; iOS regression tests pass | — |
| M3 | `feat/tow-loan-core` | M1 | `WatchLoan` state machine and messages (V2-1/3/7/10/11), persistence, three-layer phone gate (V2-27), the no-dosing-state alarm invariant (V2-12) | Decision-table tests (one per transition, plus loss or crash at each step); gate tests for every listed path; invariant test | — |
| M4 | `feat/tow-phone` | M2b, M3 | Phone coordinator: lend (V2-2), grant, merge (V2-9), Take Back (V2-7), audit (V2-8), silence alert (V2-14) | Unit tests for the snapshot, merge, audit and recompute; simulator lend with a pump double | — |
| M5 | `feat/tow-watch-loop` | M1b, M2b, M3 | Watch host: adopt (V2-4/5), cycle (V2-19/20/21), write-ahead, alarms (V2-13/16/17/18), bolus (V2-24), controls (V2-25), relaunch (V2-11), logging (V2-31) | Input-builder parity with the phone; cycle guard tests; restore tests; simulator loop on injected readings | — |
| M6 | `feat/tow-ui` | M4, M5 | UI per `design/` and V2-26 | Simulator screenshots; G passes; VoiceOver labels | — |
| M7 | integration | M1–M6 | Integration, regression, independent code, safety, architecture and design reviews | Critical findings resolved; status updated | — |
| M8 | maintainer | M7 | Hardware: E1 TestFlight upload, E2 24 h wake count, E5 command window, in-vitro DASH hand-off | Results recorded; flag stays off until E2 passes | — |
