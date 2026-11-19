# Trio on Watch

Working documentation for an untethered Apple Watch mode for Trio.
Status: **M0–M7 implemented and reviewed (2026-11-18). Ready for M8 hardware testing; not for in-vivo use.** See `implementation/readiness-assessment.md`.

## Baseline

| Item | Value |
|---|---|
| Upstream | `nightscout/Trio` `dev` |
| Baseline SHA | `ad6c66876e5ccca8b0a6e1c5b7626ed4caa65926` (2026-11-14, "CI: Bump APP_DEV_VERSION to 1.0.2.72") |
| Worktree | `~/workspaces/Trio-on-watch`, branch `feat/trio-on-watch` |
| Experimental reference | `kristinkand/Trio` `feature/untethered-watch-mode` @ `a56170dc020a1d1b7ce4490514027c6ae6c297a4` |
| Experimental merge base | `3f6b238b450d423f9aa2585e173d50d212d5273d` (2026-11-13) |
| Experimental size | 382 commits, 167 files, +29,724 / −1,465 |
| Experimental kit forks | LoopKit `kristinkand/untethered-next-dev` @ `8e8607db5`, G7SensorKit `kristinkand/untethered-personal` @ `48158d8c3`, OmnipodKit `kristinkand/untethered-personal` @ `9432ad4f0` |

The experimental branch and Loop's work are research material only. Nothing is cherry-picked from them.

## Related open upstream PRs (not in baseline)

#1598 (watch state updates), #1694 (Watch Usage Mode), #1723 (configurable complications), #1745 (LoopKit SmartwatchManager hosting), #1749 (G7 Direct-to-Watch), #1762 (unreliable G7 readings), #1775 (watch-agnostic command pipeline), #1648 (watch bolus safety check).

## Agent fleet

| Agent | Responsibility | Phase 1 deliverable |
|---|---|---|
| A1 | Experimental Trio branch: Trio repo diff | `research/experimental-trio-inventory.md` |
| A2 | Experimental Trio branch: kit forks (LoopKit, G7SensorKit, OmnipodKit) | `research/experimental-kit-forks-inventory.md` |
| B | Loop / LoopKit watch work | `research/loop-implementation-inventory.md` |
| C | Upstream Trio architecture | `research/upstream-trio-architecture.md` |
| D | watchOS platform and lifecycle | `research/watchos-platform-research.md` |
| E | Independent safety, failure modes | `safety/failure-mode-analysis.md` |
| F | Trio design language | `design/trio-design-language.md` |
| G | Independent UX judge | Starts in Phase 3 (needs proposals to judge) |

Orchestrator: consolidation (`research/cross-project-comparison.md`), scope, target architecture, decision logs.

## Layout

```text
research/        inventories, platform research, cross-project comparison
architecture/    scope, target architecture, state/sync, lifecycle, ADR log
design/          design language, UX guidelines, screens, interaction, design decision log
safety/          failure modes, safety requirements, safety review
implementation/  roadmap, status, testing strategy
reviews/         architecture, design and implementation reviews
```

Decisions are never silently overwritten. Superseded entries stay, marked with the reason.
