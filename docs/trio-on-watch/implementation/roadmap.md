# Implementation roadmap

Integration branch: `feat/trio-on-watch` (`~/workspaces/Trio-on-watch`). Each milestone is built on its own branch and worktree off the integration tip, reviewed independently, then merged. Local signed commits only. No pushes, no PRs.

| M | Branch | Depends on | Objective | Acceptance |
|---|---|---|---|---|
| M0 | (integration) | — | Baseline: iOS and watch build, `Trio Tests` scoped suites, algorithm package. Record the existing failures. | `implementation/implementation-status.md` lists the commands and results |
| M1 | `feat/tow-oref-run` | M0 | Extract `OrefInputs` + `OrefRun` from `OpenAPS`. The phone calls it. | Parity goldens byte-exact (`TZ=Europe/Berlin swift test --package-path AlgorithmPackage`). The phone loop behaves identically, and the existing tests pass. |
| M2 | `feat/tow-platform` | M0 | Watch target compiles `OpenAPSSwift`. It links LoopKit-watchOS, G7SensorKit-watchOS and OmnipodKit-watchOS (pin to the #177 head). It also gets the Info.plist, entitlements and deployment target, plus the `TRIO_ON_WATCH` flag. | The watch builds for the simulator and for `arm64_32`. The iOS app builds, and the pinned kit tests still compile. |
| M3 | `feat/tow-loan-core` | M0 | `WatchLoan` state machine, messages, records and the phone `WatchLoanGate`. Pure, plus the gate wiring on the phone. | A decision-table test covers every transition and loss/crash point. Gate tests prove every phone pump path refuses when the phone isn't owner. |
| M4 | `feat/tow-phone` | M1–M3 | Phone `WatchLoanCoordinator`: lend, snapshot, merge, Take Back, odometer audit, 20-min silence alert. | Unit tests for the snapshot, merge and audit. In a simulator, the phone lends and the pump double reports released. |
| M5 | `feat/tow-watch-loop` | M1–M3 | Watch host: adopt, persist, cycle, enact with write-ahead, uncertain gate, dead-man, records. | Unit tests for the input builder (parity with the phone), the cycle guards and the restore checklist. In a simulator, the watch host loops on injected readings with a pump double. |
| M6 | `feat/tow-ui` | M4, M5 | Watch and phone UI per `design/ux-guidelines.md`. Watch alerts. | Simulator screenshots. Agent G passes the review. Accessibility labels are present. |
| M7 | (integration) | M1–M6 | Integration, regression and reviews. | Code, safety, architecture and design reviews filed in `reviews/`, with critical findings resolved. Status doc updated. |
