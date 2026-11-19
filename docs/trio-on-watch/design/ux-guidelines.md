# UX guidelines for Trio on Watch (v1)

Status: proposed 2026-11-16 by Agent F. Agent G review: pending. Supersedes nothing; refines §"Draft UX guidelines" of `trio-design-language.md` (G1–G11) to the v1 scope R-1..R-10 of `../architecture/requirements-and-scope.md`.

Audience: contributors. Every user-facing string that comes out of this is for people managing their own or a family member's diabetes: plain language, every safety caveat kept, no dosing advice. Nothing here is medical advice.

## Summary

- Two rules carry most of the safety weight. First, the user always knows which device gives insulin (R-7). Second, every "freshness" the user sees is computed on the device that shows it, from timestamps (R-9, R-10).
- v1 needs one new watch page, two watch confirmations, one bolus progress view, a changed main page and a changed phone Home. That is all (see `screen-inventory.md`).
- Several architecture points cannot be supported by the UX as written. They are listed in "Architecture gaps" at the end and in `design-decision-log.md`.

## Vocabulary (fixed)

| Concept | User-facing term | Not |
|---|---|---|
| The feature | "Trio on Watch" | "untethered mode", "loan", "lend" |
| Watch `holding` | "Your watch is in control" (watch) / "Apple Watch is in control" (phone) | "owner", "commander" |
| Phone `home` | "Your iPhone is in control" (watch, only on the status page) | — |
| Start | "Start Trio on Watch" | "Take over" |
| End (watch, phone reachable) | "End Trio on Watch" | "Hand back" |
| Take Back (phone, watch unreachable) | "Take Back Pump" | "Force", "Emergency stop" |
| Watch `stopped` | "Trio on Watch stopped" | "Error" |
| Pump | "pump" (pod-specific words only where the kit already uses them, e.g. "Replace pod") | — |

Device names: "Apple Watch" and "iPhone" without "the" (Apple style), "your watch" / "this watch" on the watch itself.

## G1. Control authority (R-7, R-1, R-4, R-5)

1. The watch main page MUST show who is in control on every state, as a symbol plus a word: `applewatch` "Watch" or `iphone` "iPhone". Color is not the signal.
2. Phone Home MUST show it in the header, not only in a banner: while the phone is not `home`, the loop ring position shows the watch control indicator (`screen-inventory.md` P1). The banner can be displaced by "Notifications Disabled", so it cannot be the only place.
3. Transitional states are shown as such, in words, on both devices: "Starting…", "Ending…", "Taking back…". During them, every insulin action on that device is disabled, with the reason shown.
4. "Nobody is in control" is never shown as a neutral state. It always says what the pump does now: "Your pump keeps running the last temp basal until it ends (at most 2 hours), then your scheduled basal." (Pod fail-safe from `target-architecture.md` §Responsibilities.)
5. Messages name the device actually involved. The existing watch strings "No answer from iPhone…" and "iPhone not reachable. Nothing was sent." stay for the tethered remote only. While the watch is in control, watch actions never mention the iPhone unless the iPhone is required (End).

## G2. Loop freshness (R-9, R-10)

1. Watch in control: the watch computes the loop ring itself, with the iOS rules (`LoopView.ringColor`): green ≤ 5 min, yellow ≤ 10 min, red beyond, after a 30 s grace, from the last *enacted* cycle. Grey when nothing has been enacted. Open ring plus center symbol for Low Glucose Suspend and Basal Testing. Open Loop shows device health. Share the static helpers, don't re-implement them.
2. Values are recomputed at render time (`TimelineView`), never parsed from a string.
3. Phone while lent: the phone does not know the watch's loop age. It shows "last heard from watch" (R-10) instead and never draws its own red loop ring. A red phone loop ring while the watch is looping fine would push users toward Take Back.
4. Dosing mode is shown whenever it is not Closed Loop (frozen in the snapshot).
5. A failed or skipped cycle is reachable in one tap from the main page, with the existing wording "Loop at <time> failed." plus the reason.

## G3. Separate clocks (R-9)

The watch shows these as different things and never merges them into one "STALE DATA":
- reading age, next to the delta, with the 12-minute mask ("--");
- loop age, under the bobble, with the control symbol (G1);
- pump last contact and CGM last reading, on the status page.

"STALE DATA" stays only for the tethered remote (phone snapshot older than 5 min). It never shows while the watch is in control.

## G4. Pump and CGM state (R-9)

1. Status page: pump last contact age plus the kit's status highlight verbatim; reservoir with the iOS thresholds (≤ 30 U orange, ≤ 10 U red); pod time left. CGM last reading age plus the kit's status message verbatim. Tiers use secondary / orange / LoopRed, always with text.
2. Bluetooth off or not authorized on the watch is stated explicitly ("Bluetooth is off. Your watch can't reach your pump or sensor.").
3. While the phone is lent, its pump panel shows a Trio sheet, not the kit's settings UI (the kit UI offers commands the gate will refuse).

## G5. Bolus and carbs on the watch (R-3)

1. Keep the existing flow: crown dial in pump increments, crown-turn confirmation, `.click` per step, `.success` when confirmed, 2-minute entry expiry.
2. Show four outcomes in words: sent, accepted by pump ("Bolus started"), delivering ("0.40 of 1.00 U"), finished ("Bolus finished: 1.00 U"). Plus failed and uncertain. "Bolus enacted successfully." is never the last word.
3. Uncertain outcome (SR-10): "Trio can't tell if this bolus was given. Check your pump history before giving more insulin." No retry button.
4. Cancel during delivery: `xmark.app` with VoiceOver "Cancel bolus", as on iOS.
5. Low glucose confirmation (glucose < 54 mg/dL or forecast minimum < 54, when "confirm bolus" is on): same copy as iOS ("Glucose is very low." / "Glucose forecast is very low." / "Ignore Warning and Enact Bolus").
6. Recommendation: shown only if the watch runs the same bolus calculator as the phone. Otherwise the field starts at 0 with no "Recommended" line. The watch must not invent a recommendation from oref output (architecture gap A-4).
7. `.failure` haptic on any refusal, failure or uncertain outcome.

## G6. Stale and unknown values

"--" plus `.secondary` for unknown or expired values. A stale glucose is never shown in range colors. IOB and COB show their units ("U", "g").

## G7. Alerts (R-6, R-10)

1. Watch in control: the watch raises not-looping, urgent low, low, CGM signal loss and kit pump alerts. The phone keeps its own glucose alarms. Neither suppresses the other (SR-15). The user may get the same low alert on both devices; that is accepted and explained once at Start.
2. Not-looping uses the existing copy: title "Trio Not Active", body "Last loop was more than %d min ago". The watch body adds "Open Trio on your watch." because a rebooted watch does not relaunch Trio (`lifecycle-and-execution.md`).
3. Not-looping and pump alerts cannot be snoozed. Glucose alerts can, with the existing snooze choices, locally on the watch.
4. Start discloses that the watch has no critical alerts: "Your watch can't break through Silent Mode or Do Not Disturb the way your iPhone can. Keep your watch notifications on."
5. Start is refused if Trio's watch notifications are not allowed (gap A-3).

## G8. Accessibility

1. Every element added or changed for v1 gets a VoiceOver label with the iOS sentence pattern (exact labels in `screen-inventory.md`).
2. No state is conveyed by color alone.
3. New watch text uses text styles (`.footnote`, `.caption`, `.headline`), not fixed point sizes. Existing `WatchSize` tables stay for geometry only.
4. Confirmations that cost insulin keep a physical action (crown turn). VoiceOver users get an equivalent: the confirmation view exposes an accessibility action "Confirm bolus" (I: `digitalCrownRotation` is not operable with VoiceOver; verify on device).

## G9. Localization and units

All new copy via `String(localized:)`, English source only. Numbers formatted with the locale, glucose stored in mg/dL and converted at display. No pre-formatted strings in loan messages.

## G10. Visual tokens

Reuse existing named colors and the bobble, pill and dark gradient. Add `ManualTempBasal` and `warning` to the watch catalog with the iOS values. Carbs are orange on every new surface. No new hues.

## G11. Scope (YAGNI)

v1: the screens in `screen-inventory.md` only. Deferred: watch history, dosing mode selection on the watch, glance or workout screens, manual BG entry on the watch, complications (O-2), settings or override editing on the watch (F-5), a phone-initiated End.

## Architecture gaps the UX can't support as written

| ID | Gap | Why it matters | Proposed fix | Owner |
|---|---|---|---|---|
| A-1 | Overrides and temp targets "run to their end" and can't be stopped during a loan (F-5). An indefinite override can't be stopped at all without the phone. | A user whose activity ends early can't remove a 150 % profile override while the phone is away. | Start shows any active override or temp target with its end time. Start is refused while an indefinite override is active ("Stop your override on iPhone first, or set an end time."). | Orchestrator, E |
| A-2 | Dead-man notifications only at +20 and +40 min; the phone uses 20, 40, 60, 80, 100 and 120. | After 40 min nothing reminds the user, while the pod may still run a 2-hour zero temp or a 30-minute high temp, then scheduled basal. | Pre-schedule the same 20…100 min series on the watch (local notifications, no wake needed). | E |
| A-3 | Start preconditions don't include notification permission or time-sensitive delivery on the watch. | Alerts (R-6) silently don't arrive. | Add "watch notifications allowed" to SR-4 preconditions; refuse with copy. | C, E |
| A-4 | No bolus recommendation source on the watch is named. Today the watch asks the phone. | Meal & Bolus loses its prefill, or someone builds a watch-only calculator. | Either share the phone's bolus calculator (pure) with the watch target, or drop the recommendation on the watch in v1 (G5.6). | Orchestrator |
| A-5 | Pod change or sensor change during a loan isn't covered. The kit UI is on the phone and the phone is lent. | A pod expiring with the phone at home means no insulin control until End or Take Back. | Start shows pod and sensor time left and warns when either ends within 6 h. Status page shows them. Copy: "To change your pod, end Trio on Watch first." | Orchestrator |
| A-6 | "Out of resume horizon (> 6 h)" shows "Trio on Watch ended" while the watch is still `holding`. | "Ended" suggests the phone is back in control. It isn't. | Use watch state `stopped(reason: horizon)` and the stopped copy, with the pump fail-safe sentence. | C |
| A-7 | Battery < 20 % alert says "end Trio on Watch soon", but End needs the phone. No critical threshold is defined (SR-18 asks for Stop). | The advice is impossible with the phone away; no action at critical level. | Copy: "Watch battery low. Charge it soon, or end Trio on Watch when your iPhone is near." Define a critical level that stops (state `stopped`, reason battery) and alerts. | E |
| A-8 | Take Back confirmation text "Only do this if your watch is off or lost" is used for every Take Back, including "Apple Watch didn't confirm" during Start. | In that case the watch is fine; the text misleads. If the watch is reachable, End on the watch is the safe path (records come home first). | Context-specific copy (`screen-inventory.md` P2). When the watch is reachable, the dialog first points to End on the watch. | C |
| A-9 | Phone Home loop ring: nothing says what it shows while lent. | The phone's own `lastLoopDate` goes stale and the ring turns red. | P1: replace the ring with the watch control indicator while not `home`; disable pull-to-force-loop. | C |
| A-10 | The phone refuses carbs and all settings edits during the loan. | Users habitually log carbs on the phone. A silent refusal loses data. | Disable the action with a visible reason on every phone entry point (Treatments, Adjustments, Settings root, Shortcuts error text). | C |
