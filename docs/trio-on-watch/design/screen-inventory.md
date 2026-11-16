# Screen inventory (v1)

Status: proposed 2026-11-16 by Agent F. Agent G review: pending. Scope R-1..R-10. Guidelines: `ux-guidelines.md`. Decisions: `design-decision-log.md`.

All copy is English source for Crowdin, plain language, no dosing advice. File references are at baseline `ad6c66876`. "Reuse" means the component exists today; "new" means it doesn't.

## Summary

| ID | Device | Screen | New or changed |
|---|---|---|---|
| W1 | Watch | Main page | Changed |
| W2 | Watch | Trio on Watch status page | New page |
| W3 | Watch | Start confirmation | New sheet |
| W4 | Watch | Starting / Ending progress | Reuse `AcknowledgementPendingView` pattern |
| W5 | Watch | End confirmation | New `confirmationDialog` |
| W6 | Watch | Bolus input and confirmation | Changed |
| W7 | Watch | Bolus delivery | New (revives the commented-out overlay) |
| W8 | Watch | Carbs input | Unchanged UI |
| W9 | Watch | Override / temp target sheets | Changed: read-only while in control |
| P1 | iPhone | Home header and banner | Changed |
| P2 | iPhone | Trio on Watch sheet | New (shown instead of Loop Status while lent) |
| P3 | iPhone | Take Back confirmation | New dialog |
| P4 | iPhone | "Apple Watch is in control" note on blocked actions | New small view |
| N | Both | Notifications | New alert content |

Nine watch items and four phone items, against roughly eight new screens plus complication work in the experimental branch.

## State key

| Key | Watch state | Phone state |
|---|---|---|
| IDLE | `idle` | `home` |
| STARTING | `requesting` | `lending` |
| IN CONTROL | `holding(e)` | `lent(e)` |
| RETURNING | `returning(e)` | `takingBack(e)` after a hand-back |
| TAKING BACK | — (watch absent) | `takingBack(e+1)` from Take Back |
| STOPPED | `stopped(e, reason)` | — |
| PHONE UNREACHABLE | `holding` + phone not reachable | — |
| WATCH SILENT | — | `lent` + watch reachable, no record for 20 min |
| STALE (tethered) | `idle`, phone snapshot > 5 min | — |

## W1. Watch main page (changed)

**Purpose:** glucose at a glance, plus who is in control and how fresh the loop is.
**Entry/exit:** app root, page 0 of the vertical `TabView`. Tap the control line to open W2.
**Reuses:** `GlucoseTrendView`, `TrendShape` (`Trio Watch App Extension/Views/`), toolbar and bottom bar from `TrioMainWatchView.swift:116-169`; ring rules from `LoopView.ringColor` / `ringGap` / `centerSymbol` (`Trio/Sources/Modules/Home/View/Header/LoopView.swift:29-69`).

**Content changes:**
- Inside the bobble, under the delta: reading age ("3m"), masked to "--" at 12 min.
- Control line under the bobble, replacing the "N min" text: symbol plus word plus loop age, colored by the ring rules.
- IOB "1.25 U" and COB "12 g" with units.
- Bottom bar while IN CONTROL: override and temp target buttons open W9 in read-only form; "+" stays.

| State | Control line | Ring | Glucose / IOB / COB | Actions |
|---|---|---|---|---|
| IDLE | `iphone` "iPhone · 2 min" | As today (phone loop age) | As today | As today |
| STALE (tethered) | "STALE DATA" (unchanged) | Grey | "--" | Disabled (unchanged) |
| STARTING | `applewatch` "Starting…" | Grey | Last values, secondary | Disabled |
| IN CONTROL | `applewatch` "Watch · 2 min" | Watch-computed rules | Watch's own values | Enabled ("+"); overrides read-only |
| IN CONTROL, no cycle yet | `applewatch` "Watch · --" | Grey | Watch values | Enabled |
| PHONE UNREACHABLE | Same as IN CONTROL | Same | Same | Same. The phone is not needed. |
| RETURNING | `applewatch` "Ending…" | Grey | Secondary | Disabled |
| STOPPED | `exclamationmark.triangle.fill` "Stopped" in LoopRed | Grey | Values, reading age kept | "+" disabled |

**VoiceOver:**
- Bobble: "Glucose 112 milligrams per deciliter, in range, rising slowly, delta plus 3, 2 minutes ago" (same pattern as `CurrentGlucoseView.swift:194-216`). Stale: "Glucose unavailable".
- Control line (button): label "Watch is in control, Closed Loop, looping normally, last loop 2 minutes ago"; hint "Opens Trio on Watch status". IDLE: "iPhone is in control, last loop 2 minutes ago". STOPPED: "Trio on Watch stopped. Your watch is not giving insulin."
- IOB: "Insulin on board, 1.25 units". COB: "Carbs on board, 12 grams".
- Buttons: "Add treatment", "Overrides", "Temp targets".

## W2. Trio on Watch status page (new)

**Purpose:** the one place for control, devices and Start/End.
**Entry/exit:** last page of the vertical `TabView` (after Snooze), or tap the W1 control line. Exit by crown or swipe.
**Reuses:** `List` sheet style from `OverridePresetsView.swift`; pill colors from `PumpView.swift:185-242`; `DosingMode.displayName` / `icon` (`Trio/Sources/Models/DosingMode.swift`).

**Content (top to bottom):**
1. Header: control symbol plus "Your watch is in control" / "Your iPhone is in control" / state text.
2. Loop: "Last loop 2 min ago" (or "Loop at 14:05 failed." plus reason in LoopRed). Dosing mode row when not Closed Loop: mode name plus `miniHint`.
3. Sensor: "Last reading 3 min ago" plus kit status text; "Sensor ends in 2 d 4 h".
4. Pump: "Last contact 4 min ago", reservoir "86 U", "Pod ends in 1 d 3 h", or the kit's status highlight verbatim (e.g. "Insulin Suspended").
5. Watch battery: "Watch battery 64 %".
6. Primary button: Start or End, per state.
7. Footer text, per state.

| State | Header | Button | Footer |
|---|---|---|---|
| IDLE, phone reachable | `iphone` "Your iPhone is in control" | "Start Trio on Watch" (bordered, Insulin tint) | "Your watch takes over your pump and sensor. Your iPhone can be away." |
| IDLE, phone unreachable | same | "Start Trio on Watch" disabled | "Bring your iPhone close to start." |
| STARTING | "Starting…" with `ProgressView` | none | "Keep your iPhone close." |
| IN CONTROL, phone reachable | `applewatch` "Your watch is in control" | "End Trio on Watch" (bordered) | "Ending moves your pump and history back to your iPhone." |
| PHONE UNREACHABLE | same | "End Trio on Watch" disabled | "Bring your iPhone close to end. Your watch keeps looping until then." |
| RETURNING | "Ending…" with `ProgressView` | none | "Keep your iPhone close." |
| STOPPED | LoopRed "Trio on Watch stopped" | none | Reason text (below), then: "Your watch is not giving insulin. Your pump keeps the last temp basal until it ends, at most 2 hours, then runs your scheduled basal. Open Trio on your iPhone to take back your pump." |

STOPPED reasons:
- higher epoch or foreign pod session: "Your iPhone took back your pump."
- resume horizon: "Your watch couldn't loop for over 6 hours."
- battery critical (gap A-7): "Watch battery too low."
- persistence fault (SR-13): "Trio couldn't save pump data on this watch."

**VoiceOver:** each row is one element: "Sensor, last reading 3 minutes ago, ends in 2 days 4 hours"; "Pump, last contact 4 minutes ago, reservoir 86 units, pod ends in 1 day 3 hours". Button labels as shown; disabled buttons get the footer as hint.

## W3. Start confirmation (new sheet)

**Purpose:** consent with the facts that matter, before the phone releases the pump.
**Entry:** W2 "Start Trio on Watch". **Exit:** "Start" leads to W4; "Cancel" back to W2.
**Reuses:** `.sheet` + `List`; no new components.

**Content:**
- Title: "Start Trio on Watch?"
- Rows (only the ones that apply):
  - "Pod ends in 3 h 10 min." (orange when under 6 h, gap A-5)
  - "Sensor ends in 4 h." (orange when under 6 h)
  - "Override “Exercise” runs until 16:30." / "Temp target “Eating soon” runs until 12:15." (gap A-1)
- Fixed text:
  - "While your watch is in control, you can't change settings, overrides or temp targets, or log carbs on your iPhone."
  - "Your watch can't break through Silent Mode or Do Not Disturb the way your iPhone can. Keep your watch notifications on."
  - "You may get the same glucose alarm on both devices."
- Buttons: "Start" (Insulin tint), "Cancel".

**Refusal (shown on W4 as failure, copy from the phone's precondition result):**

| Precondition | Copy |
|---|---|
| Bolus running | "A bolus is running. Try again when it's finished." |
| Unconfirmed command / delivery uncertain | "Your pump has an unconfirmed command. Open Trio on your iPhone and check your pump." |
| Pump status not fresh | "Your iPhone hasn't heard from your pump recently. Keep your iPhone close to your pump and try again." |
| Versions differ | "Update Trio on your iPhone and watch to the same version." |
| Clock or time zone differs | "Your watch and iPhone show different times. Check the time settings on both." |
| Watch battery < 30 % | "Charge your watch to at least 30 % to start." |
| Watch notifications off (gap A-3) | "Allow notifications for Trio on your watch to start." |
| Indefinite override (gap A-1) | "Stop your override on iPhone first, or give it an end time." |
| Phone didn't answer in 20 s | "Your iPhone didn't answer. Nothing changed." |

**VoiceOver:** sheet title is the header trait; each fact row is one element.

## W4. Starting / Ending progress (reuse)

**Purpose:** show a hand-off in progress, then the result.
**Reuses:** `AcknowledgementPendingView.swift` layout (spinner, status icon, message), with new messages; toolbar and back button hidden as today.
**Copy:** STARTING "Starting Trio on Watch…"; success "Your watch is in control." (`checkmark.circle`, LoopGreen, `.start` haptic); RETURNING "Ending Trio on Watch…"; success "Your iPhone is in control." (`.stop` haptic); refusal per W3 table (`xmark`, LoopRed, `.failure` haptic).
**Exit:** back to root after 2 s, as today. Unlike today, a STARTING or RETURNING state that outlives the view stays visible on W1 and W2.

## W5. End confirmation (new dialog)

**Entry:** W2 "End Trio on Watch" while the phone is reachable.
**Content:** `confirmationDialog` title "End Trio on Watch?", message "Your iPhone takes back your pump and sensor.", buttons "End" and "Cancel".
**Refusals:** "A bolus is running. Try again when it's finished." / "Bring your iPhone close to end. Your watch keeps looping until then."
**VoiceOver:** system dialog.

## W6. Bolus input and confirmation (changed)

**Reuses:** `BolusInputView.swift`, `BolusConfirmationView.swift`.
**Changes while IN CONTROL:**
- Limits and increments come from the snapshot, not the phone. Copy "Bolus limit cannot be fetched from phone!" is not shown in this state.
- Recommendation line shown only if the shared bolus calculator exists (gap A-4). Otherwise hidden.
- Low glucose warning before confirmation (when the "confirm bolus" setting is on): title "Glucose is very low." or "Glucose forecast is very low.", then the existing crown confirmation with the button text "Ignore Warning and Enact Bolus".
- Insulin-adding refused while delivery is uncertain (SR-11): "Trio can't confirm your last insulin. Check your pump history before giving more." Button disabled.
- Accessibility action "Confirm bolus" on the confirmation view (verify on device).

**VoiceOver:** amount "Bolus 1.00 units, adjustable" with crown; confirmation progress "Confirmation 40 percent"; carbs row "Carbs 30 grams".

## W7. Bolus delivery (new)

**Purpose:** what the pump is doing with this bolus.
**Entry:** after W6 confirmation while IN CONTROL. **Exit:** back to root when finished; also reachable from W1 while a bolus runs (a slim bar above the bottom toolbar).
**Reuses:** the design of the commented-out `BolusProgressOverlay.swift` (gradient bar, "x U of y U"); iOS wording from `HomeRootView+BottomControls.swift:458-512`.

| Stage | Copy | Icon / haptic |
|---|---|---|
| Sent to pump | "Sending to pump…" | `ProgressView` |
| Accepted | "Bolusing" + "0.00 of 1.00 U" | `cross.vial.fill` |
| Delivering | "Bolusing" + "0.40 of 1.00 U" + cancel | progress bar |
| Finished | "Bolus finished: 1.00 U" | `checkmark.circle` LoopGreen |
| Cancelled | "Bolus cancelled. 0.40 U given." | `xmark` |
| Failed (pump refused) | "Bolus not given. Your pump said: <kit message>" | `xmark` LoopRed, `.failure` |
| Uncertain | "Trio can't tell if this bolus was given. Check your pump history before giving more insulin." | `exclamationmark.triangle.fill` orange, `.failure` |

**VoiceOver:** "Bolusing, 0.40 of 1.00 units"; cancel button "Cancel bolus".

## W8. Carbs input (unchanged UI)

`CarbsInputView.swift` as is. While IN CONTROL the entry is stored on the watch. Success: "Carbs saved on your watch." (not "logged", because they reach the phone later).

## W9. Override / temp target sheets (changed)

While IN CONTROL: the sheets list the running preset with "runs until 16:30" and no buttons. Footer: "You can't change overrides or temp targets while your watch is in control." IDLE: unchanged.

## P1. iPhone Home header and banner (changed)

**Reuses:** `HomeRootView+Header.swift:147-199` (right panel), `LoopView.swift`, `panelBanner` and `MultiUsePanelState` (`HomeRootView+BottomControls.swift:657-781`, `MultiUsePanelState.swift`).

**Header right panel while not `home`:** the loop ring is replaced by a control pill in the same capsule style: `applewatch` plus "Watch · 3m", where the time is "last heard from watch". Colors:
- LoopGreen up to 10 min since last heard,
- secondary when the watch is not reachable (unknown, not failing),
- LoopRed with WATCH SILENT (reachable but silent for 20 min).
Eventual glucose below it shows "--". Pull-to-force-loop is disabled.

**Banner (new `MultiUsePanelState` case, ranked below "Notifications Disabled", above everything else):**

| State | Title | Subtitle | Tint |
|---|---|---|---|
| STARTING | "Starting Trio on Watch" | "Keep your iPhone close to your watch." | Insulin |
| STARTING, no confirm after 60 s | "Apple Watch didn't confirm" | "Tap to check, or take back your pump." | orange |
| IN CONTROL | "Apple Watch is in control" | "Last heard 3 min ago. Tap for details." | Insulin |
| WATCH SILENT | "Apple Watch is silent" | "No update for 20 min. Tap to check." | LoopRed, critical |
| RETURNING / TAKING BACK | "Taking back your pump" | "Keep your iPhone close to your pod." | Insulin |
| TAKING BACK, pod unreachable | "Can't reach your pump" | "Keep your iPhone close to your pod. Nothing is giving insulin automatically." | LoopRed, critical |

**Pump panel tap while not `home`:** opens P2, not the kit settings.

**VoiceOver:** control pill "Apple Watch is in control, last heard 3 minutes ago"; hint "Opens Trio on Watch details".

## P2. Trio on Watch sheet (iPhone, new)

**Purpose:** explain the state and offer Take Back.
**Entry:** header pill, banner, or pump panel while not `home`. **Exit:** "Done", or Take Back leading to P3.
**Reuses:** sheet chrome and "Got it!" style of `LoopStatusView.swift`.
**Content:** state title as in the banner; "Last heard from Apple Watch: 14:05 (3 min ago)"; latest glucose and IOB the phone has from records, labelled "From Apple Watch at 14:05"; a list of what the iPhone won't do now ("Give insulin or change basal", "Change settings, overrides or temp targets", "Log carbs"); "Your iPhone keeps showing glucose and sounding glucose alarms."
**Buttons:** while the watch is reachable: primary text "End Trio on Watch on your watch to bring everything back." and a secondary destructive "Take Back Pump". While not reachable: "Take Back Pump" primary (destructive role).

## P3. Take Back confirmation (new dialog)

**Reuses:** `GlassActionSheet` (`Trio/Sources/Views/GlassActionSheet.swift`) as used for the bolus warning.

| Context | Message | Action |
|---|---|---|
| Watch unreachable | "Take back your pump from Apple Watch? Do this if your watch is off, lost or out of battery. If your watch is still running, it will stop when it next reaches your pod." | "Take Back Pump" (destructive) |
| Watch reachable | "Your watch is still running Trio on Watch. Ending it on your watch is safer because your history comes back first. Take back anyway?" | "Take Back Anyway" (destructive) |
| Start didn't confirm | "Your watch didn't confirm the start. Take back your pump on this iPhone?" | "Take Back Pump" |

After any Take Back, if insulin was found that no record explains: notice "Your pod delivered 0.60 U that Trio on Watch didn't record. Trio counts it as insulin on board." (odometer audit; wording pending the open question on the audit bolus).

**Haptics:** `.success` when back to `home`, `.error` on failure.

## P4. Blocked-action note (iPhone, new small view)

**Purpose:** say why an action is off, where the action is.
**Reuses:** the pattern of `DosingModeOverrideNote.swift` (symbol plus footnote, secondary).
**Copy:** `applewatch` "Apple Watch is in control. <specific line>":
- Treatments: "Bolus and carbs are entered on your watch."
- Adjustments: "Overrides and temp targets can't be changed until you end Trio on Watch."
- Settings root: "Settings can't be changed until you end Trio on Watch."
- Shortcuts / remote command refusal text: "Trio on Watch is running. Use your watch."
Action buttons on those screens are disabled.

## N. Notifications

| Alert | Device | Title | Body | Level | Snooze |
|---|---|---|---|---|---|
| Not looping | Watch | "Trio Not Active" | "Last loop was more than %d min ago. Open Trio on your watch." | time-sensitive | No |
| Urgent low / low | Watch | Reuse the phone's glucose alert strings (U: exact strings to be taken from `GlucoseAlertCoordinator` in implementation) | | time-sensitive | Yes, local |
| CGM signal loss | Watch | Kit's alert content | | time-sensitive | No |
| Pump alerts | Watch | Kit's alert content | | per kit | No |
| Watch battery low | Watch | "Watch Battery Low" | "Charge your watch soon, or end Trio on Watch when your iPhone is near." | time-sensitive | No |
| Stopped | Watch | "Trio on Watch Stopped" | Reason line from W2 + "Open Trio on your iPhone." | time-sensitive | No |
| Watch silent (R-10) | iPhone | "Apple Watch Is Silent" | "No update from Trio on Watch for 20 min. Check your watch." | time-sensitive | No |
| Pod unreachable on take back | iPhone | "Can't Reach Your Pump" | "Keep your iPhone close to your pod." | time-sensitive | No |
