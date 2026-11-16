# Architecture decision log

Entries are never deleted. A changed decision gets a new entry, and the old one is marked `Superseded by ADR-n` with the reason.

| ID | Date | Status | Decision |
|---|---|---|---|
| ADR-001 | 2026-11-15 | Accepted | Baseline is `nightscout/dev` @ `ad6c66876`. Experimental and Loop work are research only; nothing cherry-picked. |
| ADR-002 | 2026-11-16 | Accepted (maintainer), risk open | Watch run model: Bluetooth alert wakes (CGM-driven), as in Loop Sport Mode. No workout session, no extended runtime session. |
| ADR-003 | 2026-11-16 | Proposed | Kits: upstream pins only. LoopKit and G7SensorKit as pinned; OmnipodKit via loopandlearn/OmnipodKit#177 (or its merged successor). No Trio-owned kit forks. |

## ADR-002: Watch run model

- **Area:** architecture, safety.
- **Problem:** the watch must wake for each CGM reading, run oref and command the pump without the phone.
- **Decision:** rely on `bluetooth-central` with the system-retained connection and `WKBluetoothAlertRefreshBackgroundTask` wakes on CGM notifications, the model Loop Sport Mode uses at `jeremybarnum/Loop` 5aeb4703.
- **Alternatives rejected:**
  - Workout session. It's the only documented continuous mechanism, but the brief rules it out, Apple calls it an App Review risk, and a real workout ends it (D).
  - Extended runtime sessions. They are capped at 10-60 min and can only be started in the foreground (D).
  - Background App Refresh. It's too sparse and not guaranteed (D).
  - Parking untethered mode. The maintainer chose not to.
- **Known conflict:** Apple's "Using background tasks" doc caps background-scan plus timely-alert opportunities at five per rolling 24 h, refreshed when the user opens the app (verified 2026-11-16). A 5-min loop needs 288 a day. The experimental branch logs pod-link stalls of 26 to 311 min.
- **Consequences the architecture must carry:**
  - Any loop cycle may be missed, including mid-command.
  - Before dosing, the pump state is read. Commands are tracked as requested, accepted, executed or confirmed.
  - The pump is the fail-safe: oref temps are bounded (high temps 30 min at most, zero temps 120 min at most). There is no catch-up dosing.
  - A dead-man alarm on the watch is pushed forward on every good cycle, and on the phone where reachable.
  - The watch may own the pump only once a physical-hardware run shows it wakes on every cycle overnight, screen off and without a debugger (E SR-17, D E2). Until then untethered mode is not claimed to run continuously.
- **YAGNI:** no fallback execution mechanisms are built speculatively.
- **Evidence:** `research/watchos-platform-research.md`, `research/loop-implementation-inventory.md`, `research/cross-project-comparison.md` (BR-1).

## ADR-003: Kit dependencies (proposed)

- **Problem:** dosing from the watch needs a pump kit with a watchOS target and a safe hand-off.
- **Proposal:**
  - LoopKit#626 hand-off protocols and the G7SensorKit#80 watch target are already in Trio's pins.
  - OmnipodKit#177 provides the watchOS target and pod lending, and it refuses release while a command is unconfirmed (A2, B).
  - Kristin's forks drop `unacknowledgedCommand` on export and release unconditionally (A2 §2). They are rejected.
- **Open:** #177 is open and moving (BR-3). Pin strategy until it merges is undecided.
- **Review:** pending (C, E).

## Entries after the review round (2026-11-16)

| ID | Status | Decision |
|---|---|---|
| ADR-003 | **Accepted with amendments** (was Proposed) | Pins per V2-29. LoopKit "as pinned" was wrong: OmnipodKit #177 needs LoopKit#687. Moving to the LoopKit next-dev tip would break Dana, Medtrum, Minimed and Libre (A2-1). |
| ADR-004 | Accepted (maintainer) | Time zone pinned to the grant's time zone for the whole loan (V2-23). Rejected: stop and alert on a time-zone change. |
| ADR-005 | Accepted (maintainer) | Port the bolus calculator to the watch as a pure extraction (V2-24). Rejected: no recommendation in v1. |
| ADR-006 | Accepted (maintainer) | The watch evaluates the user's configured glucose alarm list (V2-16). Rejected: urgent low and low only. |
| ADR-007 | Accepted (maintainer) | Trio-local OmnipodKit safety patch (refuse insulin-adding commands after a foreign session, report it to the host) on #177 @ `3d21d9c`, with the proposal drafted for upstream and posted by the maintainer. Rejected: dropping the unreachable-watch Take Back; waiting for upstream. |
| ADR-008 | Accepted (maintainer) | No complication work in v1. Use #1723's complication when it merges. |
| ADR-009 | Accepted (maintainer, 2026-11-16) | Known Swift vs JS oref difference R2-02 is accepted as is. JS `meal/total.js` rounds `mealCOB`; the Swift meal stage doesn't. In the 10 recorded cases this moves minPredBG and eventual BG by 1–2 mg/dL and insulinReq by 0.02 U, with equal doses. Not fixed. The JS-parity suite masks the COB value in the reason and points to this entry. |
