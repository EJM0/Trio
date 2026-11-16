# Interaction model (v1)

Status: proposed 2026-11-16 by Agent F. Agent G review: pending. Steps map to the step tables in `../architecture/state-and-synchronization.md`. Screens and copy: `screen-inventory.md`.

Conventions: "W#" and "P#" are screens. Watch haptics are `WKHapticType`. Phone haptics are `UINotificationFeedbackGenerator` / `UIImpactFeedbackGenerator`, as Trio uses today. Every insulin-adding confirmation keeps a physical action (crown turn on the watch, tap on a destructive button on the phone).

## 1. Start (R-1)

Precondition for showing the button: build flag `TRIO_ON_WATCH` on, watch `idle`, phone reachable.

| # | User | Watch UI | Phone UI | Arch step | Haptic |
|---|---|---|---|---|---|
| 1 | Opens W2, taps "Start Trio on Watch" | W3 sheet with pod / sensor / override facts and the three fixed statements | — | — | — |
| 2 | Taps "Start" | W4 "Starting Trio on Watch…"; W1 control line "Starting…" | Banner "Starting Trio on Watch" | 1 (`requesting`) | — |
| 3 | — | — | Preconditions checked | 2 | — |
| 3a | — | Refused: W4 shows the precondition copy (W3 table) | Banner gone | 2 refuse | `.failure` |
| 3b | — | No answer in 20 s: "Your iPhone didn't answer. Nothing changed." | — | 1 lost | `.failure` |
| 4 | — | — | Phone `lending`; pump actions disabled with P4 note | 3-5 | — |
| 5 | — | Validates grant, persists `holding`, takes control | — | 6-7 | — |
| 5a | — | Grant refused: W4 shows reason (versions / clock / incomplete) | Banner "Apple Watch didn't confirm" with Take Back | 6 refuse | `.failure` |
| 6 | — | W4 "Your watch is in control."; W1 "Watch · --" until the first cycle | Header pill "Watch · now"; banner "Apple Watch is in control" | 8-9 | watch `.start` |
| 7 | — | First cycle on next G7 reading; W1 "Watch · 1 min" | Pill updates on next record batch | — | — |

Rules:
- The W3 sheet never auto-confirms. Its facts are read from the phone in the request round trip; if they're unknown, the row says "Unknown" in secondary, and Start is still allowed only if the architecture precondition passed.
- If the phone stays in `lending` for 60 s (lost grant or lost `holding`), the phone banner switches to "Apple Watch didn't confirm". Take Back follows §3 with the "Start didn't confirm" text. Nothing is automatic (SR-3).

## 2. End (R-4)

| # | User | Watch UI | Phone UI | Arch step | Haptic |
|---|---|---|---|---|---|
| 1 | Taps "End Trio on Watch" on W2 | W5 dialog "End Trio on Watch?" | — | — | — |
| 1a | — | Phone unreachable: button already disabled; footer "Bring your iPhone close to end. Your watch keeps looping until then." | — | 1 refuse | — |
| 1b | — | Bolus running: "A bolus is running. Try again when it's finished." | — | 1 refuse | `.failure` |
| 2 | Taps "End" | W4 "Ending Trio on Watch…"; W1 "Ending…"; "+" disabled | — | 2 (`returning`) | — |
| 3 | — | — | Banner "Taking back your pump" | 3 | — |
| 4 | — | — | Pump connected: header back to the loop ring, banner gone | 4 (`home`) | phone `.success` |
| 4a | — | — | Pod unreachable: banner "Can't reach your pump" (critical) plus notification | 4 stays | phone `.error` |
| 5 | — | W4 "Your iPhone is in control."; W1 "iPhone · …" | — | 5 (`idle`) | watch `.stop` |

Rules:
- While `returning`, the watch shows "Ending…" on W1 and W2 even if the user leaves W4, and resends silently. It never offers to "undo" an End.
- The phone never ends a loan from its side when the watch is reachable (no phone-initiated End in v1). P2 points to the watch.

## 3. Take Back (R-5)

| # | User | Phone UI | Watch UI (if alive) | Haptic |
|---|---|---|---|---|
| 1 | Taps the banner or header pill | P2 sheet | — | — |
| 2 | Taps "Take Back Pump" | P3 dialog with context text (watch unreachable / watch reachable / start didn't confirm) | — | — |
| 3 | Taps the destructive action | Banner "Taking back your pump" | — | — |
| 4 | — | Pump connected, audit done: back to the normal header; audit notice if unexplained insulin was found | — | phone `.success` |
| 4a | — | Pod unreachable: "Can't reach your pump" (critical) | — | phone `.error` |
| 5 | — | — | At next pod contact or message with higher epoch: STOPPED, W2 reason "Your iPhone took back your pump.", notification "Trio on Watch Stopped" | watch `.failure` |

Rules:
- Take Back is always available on the phone while not `home`. It is never hidden, because the watch may be gone (safety). When the watch is reachable, P2 and P3 steer to End first.
- The audit notice states the amount and what Trio did with it, without advice on what to do with insulin.

## 4. Bolus and carbs on the watch while in control (R-3)

| # | User | Watch UI | Haptic |
|---|---|---|---|
| 1 | Taps "+" on W1 | Treatment menu (unchanged) | — |
| 2 | Picks Bolus or Meal & Bolus; enters carbs on W8 if needed | W8 crown entry | crown detents |
| 3 | Dials insulin on W6 | Amount in pump increments, limit from snapshot, "Bolus Limit Reached!" at the limit | crown detents |
| 3a | — | Delivery uncertain or unresolved intent: entry disabled, "Trio can't confirm your last insulin. Check your pump history before giving more." | `.failure` |
| 4 | Taps "Enact Bolus" | If "confirm bolus" is on and glucose or forecast minimum < 54: warning first, button text "Ignore Warning and Enact Bolus" | — |
| 5 | Turns the crown to confirm | Progress bar fills (0.05 per detent, 0.5 with "Confirm Bolus Faster") | `.click` per detent, `.success` when full |
| 6 | — | Validator on the watch refuses: W4-style failure with the validator's reason | `.failure` |
| 7 | — | W7 "Sending to pump…", "Bolusing 0.40 of 1.00 U", cancel | — |
| 8 | Optionally taps cancel | "Bolus cancelled. 0.40 U given." | — |
| 9 | — | "Bolus finished: 1.00 U", back to root after 2 s | — |
| 9a | — | Uncertain: uncertainty copy, no retry | `.failure` |

Carbs-only ("Log Carbs"): steps 1-2, then "Carbs saved on your watch." Combo: carbs persisted first, then bolus from step 3. If the bolus part fails, the carbs stay saved and the message says so: "Carbs saved. Bolus not given."

The 2-minute entry expiry (`WatchState.entryLifetime`) still applies to every entry.

## 5. Alerts (R-6, R-10)

| Situation | Device | What the user sees | Action from the alert |
|---|---|---|---|
| No cycle for 20 min (and further, gap A-2) | Watch | "Trio Not Active" | Opens Trio on the watch (W1) |
| Urgent low / low | Watch and iPhone | Glucose alert on each | Snooze (glucose only), locally per device |
| CGM signal loss | Watch | Kit alert | Opens W2 |
| Pump alert from kit | Watch | Kit alert | Opens W2; acknowledge per kit |
| Watch battery low | Watch | "Watch Battery Low" | Opens W2 |
| Stopped | Watch | "Trio on Watch Stopped" | Opens W2 |
| Watch silent 20 min (reachable) | iPhone | "Apple Watch Is Silent" | Opens P2 |
| Pod unreachable on take back | iPhone | "Can't Reach Your Pump" | Opens P2 |

Rules:
- No alert offers an insulin action.
- Haptics come from the system notification; the app adds none.
