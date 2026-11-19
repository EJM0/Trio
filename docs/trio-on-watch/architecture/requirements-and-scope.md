# Requirements and scope (v1)

Status: proposed 2026-11-16, pending architecture review (`../reviews/architecture-reviews.md`).

## Goal

The user starts Trio on Watch while the iPhone is nearby. The watch then takes over the pod and the G7, runs Trio's oref loop and doses, and keeps doing so with the iPhone switched off, left at home or out of range. When the iPhone is back, the user ends it from the watch, the history returns to the iPhone, and the iPhone loops again.

## Categories

| ID | Item | Category |
|---|---|---|
| R-1 | Lend the pump (Omnipod DASH) and the CGM (Dexcom G7) from iPhone to watch. Started by a tap on the watch while the iPhone is reachable | Required |
| R-2 | The watch runs Trio's oref (same Swift code, same inputs) on each G7 reading and enacts temp basal and SMB | Required |
| R-3 | Manual bolus and carb entry on the watch while it is in control, checked by `BolusSafetyValidator` on the watch | Required |
| R-4 | End on the watch while the iPhone is reachable: the history returns and the iPhone takes the pump back | Required |
| R-5 | Take Back on the iPhone with confirmation when the watch is unreachable (dead battery, lost watch) | Required for safety |
| R-6 | Watch alerts while in control: not looping (dead-man), urgent low and low glucose, CGM signal loss, pump alerts from the kit | Required for safety |
| R-7 | Who is in control is always visible on both devices; the iPhone refuses every pump command while the watch is in control | Required for safety |
| R-8 | Hand-off preconditions, versions and clock checks, write-ahead state, uncertain-delivery gate (SR-1..4, 7..13, 15..17, 19, 23, 24) | Required for safety |
| R-9 | Watch status: loop freshness, glucose age, pump and CGM state, bolus progress | Supporting |
| R-10 | Phone shows "last heard from watch"; alerts if the watch is reachable but silent for 20 min | Supporting |
| F-1 | Start while the iPhone is already absent ("offline start" from a standing grant) | Future |
| F-2 | Watch-initiated forced takeover from a dead iPhone | Future |
| F-3 | Other pumps (Dana, Medtrum, Medtronic, O5) and CGMs (G6, Libre) | Future, per-kit qualification (SR-23) |
| F-4 | Nightscout upload from the watch; remote commands while the watch is in control | Future |
| F-5 | Editing settings, overrides or temp targets during a loan (active ones run to their end) | Future |
| O-1 | Workout or extended runtime sessions (ADR-002) | Out of scope |
| O-2 | Complications, Live Activity, Garmin/Pebble, new watch redesign | Out of scope |
| O-3 | Shadow loops, more than one watch, automatic takeover | Out of scope (rejected) |

## Responsibilities

| Party | Responsibility while the watch is in control |
|---|---|
| Apple Watch | Sole pump commander. Reads G7 directly. Runs oref every reading. Persists its loan state and records before acting. Raises alerts. Streams records to the phone when reachable. |
| iPhone | Data home. Builds the grant snapshot. Holds no pump control (released). Refuses all pump commands, boluses (all paths) and loop enactment. Keeps receiving G7 for display and its glucose alarms. Merges records. Offers Take Back. |
| Shared Trio code | oref (`OpenAPSSwift`), the pure oref run over an inputs struct, the loan state machine and messages, the record types. |
| Pump (pod) | Fail-safe: temp basals expire (30 min high, 120 min zero), then scheduled basal. One BLE session at a time (kit claim, unverified). Delivered-units odometer. |
| CGM (G7) | Paired on the phone; the watch reads it in the watch display slot via `DeviceConfigurationSharing`. Its 5-min BLE link is the watch's wake source. |
| External services | None in v1. Nightscout and Tidepool upload happen from the phone after the history returns. |

## Behaviour with the iPhone completely unavailable

- The watch keeps looping as long as it wakes for G7 readings. If cycles are missed, the running temp expires by itself, and the dead-man notifications fire at 20 and 40 min.
- Manual bolus and carbs work on the watch.
- End is refused, with the message "Bring your iPhone close to end". The watch keeps looping.
- If the watch dies, nobody loops. The pod runs scheduled basal once the last temp expires. The phone's Take Back (R-5) recovers, books any unexplained insulin from the pod odometer, and resumes looping.
