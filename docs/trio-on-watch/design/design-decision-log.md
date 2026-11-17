# Design decision log

Entries are never deleted. A changed decision gets a new entry; the old one is marked `Superseded by DD-n` with the reason.
Owner: Agent F. Reviewer: Agent G. Scope: v1 (R-1..R-10). Related: `ux-guidelines.md`, `screen-inventory.md`, `interaction-model.md`.

| ID | Date | Area | Decision | Status |
|---|---|---|---|---|
| DD-1 | 2026-11-16 | Copy | Fixed vocabulary: "Trio on Watch", "in control", Start / End / "Take Back Pump" | Implemented (M6); G re-review pending |
| DD-2 | 2026-11-16 | Watch main | Control symbol plus loop age replaces the "N min" line under the bobble | Implemented (M6); G re-review pending |
| DD-3 | 2026-11-16 | Watch nav | Status page is the last vertical page, also opened by tapping the control line | Implemented (M6); G re-review pending |
| DD-4 | 2026-11-16 | Phone Home | Control pill replaces the loop ring while not `home`; banner ranked below "Notifications Disabled" | Implemented with changes (M6, see notes); G re-review pending |
| DD-5 | 2026-11-16 | Freshness | Separate clocks; "STALE DATA" only for the tethered remote | Implemented (M6); G re-review pending |
| DD-6 | 2026-11-16 | Bolus | Outcome stages, delivery view with cancel, uncertain copy without retry | Implemented, partly (M6, see notes); G re-review pending |
| DD-7 | 2026-11-16 | Bolus | No recommendation on the watch unless the phone's calculator is shared | Superseded by ADR-005 (recommendation from the shared calculator, M5); shown in M6 |
| DD-8 | 2026-11-16 | Bolus | iOS low-glucose bolus warning on the watch | Not implemented (open) |
| DD-9 | 2026-11-16 | Take Back | Always available on the phone; context-specific copy; steer to End when the watch is reachable | Implemented (M6, G-18 applied); G re-review pending |
| DD-10 | 2026-11-16 | Start | Start sheet with facts and alert limits; extra refusals (indefinite override, notifications off) | Implemented (M6, G-6b/G-8/G-12 applied); G re-review pending |
| DD-11 | 2026-11-16 | Alerts | Snooze for glucose only, per device; not-looping series as on the phone | Architecture done in M5 (V2-13/V2-16); no M6 UI |
| DD-12 | 2026-11-16 | Phone | Blocked actions disabled with a note; pump panel opens a Trio sheet, not the kit UI | Implemented, partly (M6, see notes); G re-review pending |
| DD-13 | 2026-11-16 | Watch | One "Stopped" state with reason and pump fail-safe sentence; replaces "ended" | Implemented (M6); G re-review pending |
| DD-14 | 2026-11-16 | Accessibility | VoiceOver alternative to the crown confirmation | Not implemented (open) |

---

## DD-1. Vocabulary

- **Problem:** architecture terms (loan, lend, holding, epoch) are not words for users. Mixed terms across devices confuse who is in control.
- **Conventions:** iOS uses short state words ("Closed Loop", "looping"), Apple style "Apple Watch" / "iPhone" without "the" (I).
- **Solution:** "Trio on Watch"; "Your watch is in control" / "Apple Watch is in control"; "Start Trio on Watch", "End Trio on Watch", "Take Back Pump"; "Trio on Watch stopped". Table in `ux-guidelines.md`.
- **Alternatives rejected:** "untethered mode" (jargon); "hand back" / "lend" (implies the user moves something manually); "Emergency Stop" (experimental branch; it suggests insulin stops immediately, which isn't true while a temp runs).
- **YAGNI:** no glossary screen; the words explain themselves.
- **Accessibility:** short phrases read well with VoiceOver; no abbreviations.
- **Safety:** the word "control" answers "which device gives insulin". "Take Back" is reserved for the phone recovery path.
- **Assessment:** low risk; Crowdin can translate it.
- **Agent G review:** pending. **Final:** pending. **Status:** Proposed.

## DD-2. Watch control line

- **Problem:** R-7 requires constant visibility on the watch. The main page has no room for a new element.
- **Conventions:** the line under the bobble already shows loop age ("N min", `GlucoseTrendView.swift:151-158`); iOS pairs ring plus caption (`LoopView.swift`).
- **Solution:** that line becomes `applewatch`/`iphone` symbol plus "Watch"/"iPhone" plus loop age, colored by the iOS ring rules computed on the watch. It is a button to W2.
- **Alternatives rejected:** a toolbar badge (top corners hold IOB/COB; the clock owns the center); a full-screen color tint (color only, fails G8); a separate page only (not "always visible").
- **YAGNI:** no complication (O-2).
- **Accessibility:** one element, full sentence, button trait, hint.
- **Safety:** removes the phone-made "N min" string; freshness comes from the watch's own timestamps.
- **Assessment:** smallest change that meets R-7 on the watch.
- **Agent G review:** pending. **Final:** pending. **Status:** Proposed.

## DD-3. Status page placement

- **Problem:** Start/End and device state need a home without new navigation.
- **Conventions:** vertical paging with the crown (`TrioMainWatchView.swift:65-110`); snooze is a page today.
- **Solution:** append one page after Snooze; the W1 control line jumps to it.
- **Alternatives rejected:** inserting it as page 1 (reorders today's pages for every user, including those who never use Trio on Watch); a sheet from a toolbar button (one more button on a full bar); separate device and loop pages (experimental branch; three pages where one fits).
- **YAGNI:** hidden when the build flag is off.
- **Accessibility:** reachable by crown, swipe and the control line button.
- **Safety:** End and device status are two interactions away at most.
- **Assessment:** keeps existing muscle memory.
- **Agent G review:** pending. **Final:** pending. **Status:** Proposed.

## DD-4. Phone Home while lent

- **Problem:** the phone's own loop ring goes red while the watch loops fine. The banner slot can be taken by "Notifications Disabled".
- **Conventions:** header right panel holds `LoopView` (`HomeRootView+Header.swift:147-166`); banner priority in `MultiUsePanelState.swift:17-40`.
- **Solution:** while not `home`, a control pill (`applewatch` "Watch · 3m", last heard) replaces the ring. A new banner case sits second, below "Notifications Disabled". Pull-to-force-loop is off.
- **Alternatives rejected:** banner only (displaceable, fails R-7); ranking the banner first (hides "Notifications Disabled", but phone glucose alarms still matter during a loan); keeping the ring and greying it (looks like "not looping").
- **YAGNI:** no watch loop history on the phone; "last heard" is enough (R-10).
- **Accessibility:** pill has one label; banner as today.
- **Safety:** no false "not looping" signal that would push users toward Take Back.
- **Assessment:** needs `HomeStateModel` to read the loan state; small.
- **Agent G review:** pending. **Final:** pending. **Status:** Proposed.

## DD-5. Separate clocks

- **Problem:** the watch has one stale flag (phone snapshot age) that hides glucose, loop and device ages together.
- **Conventions:** iOS masks a reading at 12 min, colors loop age 5/10 min, tracks pump contact separately (`CurrentGlucoseView.swift:244-251`, `LoopView.swift:61-68`, `HomeStateModel.swift:147-150`).
- **Solution:** reading age in the bobble, loop age on the control line, pump and sensor ages on W2. "STALE DATA" only for the tethered remote.
- **Alternatives rejected:** one combined "freshness" score (hides which part failed).
- **YAGNI:** no per-signal history.
- **Accessibility:** ages spoken in the element labels.
- **Safety:** the user can tell "sensor gap" from "loop stuck" from "pump unreachable", each of which needs a different response.
- **Assessment:** depends on the watch having timestamps for each, which the architecture provides.
- **Agent G review:** pending. **Final:** pending. **Status:** Proposed.

## DD-6. Bolus outcome stages

- **Problem:** today the watch ends on "Bolus enacted successfully." (pump accepted) and has no progress or cancel (`BolusProgressOverlay.swift` is commented out).
- **Conventions:** iOS "Initiating…" / "Bolusing" / "x of y U" / `xmark.app` cancel (`HomeRootView+BottomControls.swift:458-512`); "Check pump history before repeating." (`APSManager.swift`).
- **Solution:** W7 stages: sending, bolusing with progress and cancel, finished, cancelled with amount given, failed with kit message, uncertain with "check your pump history" and no retry.
- **Alternatives rejected:** keep the 2-second acknowledgement only (hides delivery); auto-retry on uncertain (violates SR-10).
- **YAGNI:** no bolus history on the watch.
- **Accessibility:** progress spoken as "0.40 of 1.00 units"; cancel labelled.
- **Safety:** distinguishes requested, accepted, delivering and confirmed, as the brief requires.
- **Assessment:** the most safety-relevant UI change in v1.
- **Agent G review:** pending. **Final:** pending. **Status:** Proposed.

## DD-7. Bolus recommendation on the watch

- **Problem:** the watch asks the phone for a recommendation today. The architecture names no calculator on the watch (gap A-4).
- **Conventions:** iOS recommendation in Treatments; watch prefill (`BolusInputView.swift:160-175`).
- **Solution:** show "Recommended" only if the phone's bolus calculator is shared as pure code with the watch target. Otherwise start at 0 and hide the line.
- **Alternatives rejected:** derive a number from oref `insulinReq` (a "meta algorithm" on top of oref; not what the phone shows); keep asking the phone (fails when it's away).
- **YAGNI:** no new calculator.
- **Accessibility:** none specific.
- **Safety:** a recommendation that differs between devices is worse than none.
- **Assessment:** decision belongs to the orchestrator; UX supports either.
- **Agent G review:** pending. **Final:** pending. **Status:** Proposed, needs orchestrator.

## DD-8. Low-glucose bolus warning on the watch

- **Problem:** iOS warns when glucose or forecast minimum is below 54 mg/dL and "confirm bolus" is on; the watch never does (open upstream PR #1648).
- **Conventions:** `TreatmentsRootView.swift:529-596`.
- **Solution:** same condition and copy on the watch, before the crown confirmation, using the watch's own glucose and determination.
- **Alternatives rejected:** a hard block (iOS allows an informed override; parity matters).
- **YAGNI:** no new thresholds.
- **Accessibility:** warning read before the confirmation.
- **Safety:** parity with the phone for the one device that doses.
- **Assessment:** coordinate with #1648 to avoid two implementations.
- **Agent G review:** pending. **Final:** pending. **Status:** Proposed.

## DD-9. Take Back

- **Problem:** one confirmation text ("Only do this if your watch is off or lost") is used for every case, including a Start that didn't confirm (gap A-8). With the watch reachable, End is safer (records first).
- **Conventions:** destructive confirmation via `GlassActionSheet` (bolus warning).
- **Solution:** Take Back always offered while not `home`; three context texts (unreachable, reachable, start didn't confirm); P2 steers to End when reachable.
- **Alternatives rejected:** hide Take Back while the watch is reachable ("reachable" can be wrong, and the user may need control now); a phone-initiated End (scope; F-list).
- **YAGNI:** no remote-stop message to the watch beyond the epoch the architecture already has.
- **Accessibility:** system dialog, destructive role announced.
- **Safety:** SR-3 user action preserved; fewer audit boluses because End is encouraged.
- **Assessment:** copy change in architecture needed.
- **Agent G review:** pending. **Final:** pending. **Status:** Proposed.

## DD-10. Start sheet and extra refusals

- **Problem:** after Start the user can't change overrides, settings or the pod without the phone, and the watch can't sound critical alerts. Today none of this is shown before Start (gaps A-1, A-3, A-5).
- **Conventions:** iOS mini hints for constrained modes (`DosingMode.miniHint`).
- **Solution:** W3 shows pod and sensor time left (orange under 6 h), running override or temp target with end time, and three fixed statements. Refuse Start with an indefinite override or with watch notifications off.
- **Alternatives rejected:** allow stopping overrides on the watch (F-5, settings authority SR-25); no sheet (consent without the facts).
- **YAGNI:** no settings preview.
- **Accessibility:** each fact one element.
- **Safety:** prevents being stuck with an override or a dead pod while the phone is away.
- **Assessment:** needs two precondition additions in the architecture.
- **Agent G review:** pending. **Final:** pending. **Status:** Proposed, needs architecture change.

## DD-11. Alerts and snooze

- **Problem:** the watch dead-man series stops at 40 min; the phone's goes to 120 (gap A-2). Snooze behaviour during a loan is undefined.
- **Conventions:** phone not-looping at 20, 40, 60, 80, 100 and 120 min (`NotLoopingMonitor.swift:33-38`); snooze choices 15 min, 1, 3, 6 h (`NotificationIdentifiers.swift:9-12`).
- **Solution:** the watch pre-schedules the same 20…100 min series (time-sensitive; no critical on the watch). Glucose alerts snoozable locally per device; not-looping, pump and stopped alerts not snoozable.
- **Alternatives rejected:** sync snooze across devices (needs messaging both ways; YAGNI); a 20/40 series only (silent after 40 min).
- **YAGNI:** no alert settings on the watch.
- **Accessibility:** system notifications.
- **Safety:** no gap in reminders while a zero temp could still run.
- **Assessment:** cheap (local notifications), needs E's agreement.
- **Agent G review:** pending. **Final:** pending. **Status:** Proposed, needs architecture change.

## DD-12. Phone blocked actions

- **Problem:** the phone refuses pump commands, carbs, overrides and settings during a loan. Kit UI on the phone offers commands the gate will refuse (gap A-10).
- **Conventions:** `DosingModeOverrideNote.swift` (symbol plus footnote where a mode overrides stored values).
- **Solution:** P4 note plus disabled buttons on Treatments, Adjustments and Settings root; pump panel tap opens P2 instead of the kit settings.
- **Alternatives rejected:** let actions fail with an alert afterwards (data loss for carbs, surprise); hide the tabs (disorienting).
- **YAGNI:** one small view, reused.
- **Accessibility:** note is plain text next to the disabled control.
- **Safety:** no path that looks like it dosed but didn't.
- **Assessment:** the pod change limitation remains (A-5).
- **Agent G review:** pending. **Final:** pending. **Status:** Proposed.

## DD-13. Stopped state

- **Problem:** the architecture says "Trio on Watch ended" at the 6-hour horizon while the watch still holds the pump (gap A-6), and a low-battery alert advises End without the phone (A-7). "Nobody in control" has no wording.
- **Conventions:** iOS Open Loop description states plainly what Trio won't do (`DosingMode.swift:81-99`).
- **Solution:** one watch state "Trio on Watch stopped" with a reason line, always followed by "Your watch is not giving insulin. Your pump keeps the last temp basal until it ends, at most 2 hours, then runs your scheduled basal. Open Trio on your iPhone to take back your pump."
- **Alternatives rejected:** "ended" (implies the phone is back); error codes.
- **YAGNI:** no restart-on-watch path (F-2).
- **Accessibility:** reason and consequence in one VoiceOver element.
- **Safety:** tells the user insulin automation is off and what the pump does meanwhile.
- **Assessment:** "at most 2 hours" rests on the oref temp bounds in ADR-002; E to confirm for DASH.
- **Agent G review:** pending. **Final:** pending. **Status:** Proposed, needs architecture change.

## DD-14. VoiceOver and the crown confirmation

- **Problem:** the crown-turn confirmation may not be operable with VoiceOver (I, not verified).
- **Conventions:** iOS mirrors gestures as accessibility actions (`HomeRootView+Header.swift:99-108`).
- **Solution:** expose an accessibility action "Confirm bolus" on the confirmation view; it does the same as a full crown turn.
- **Alternatives rejected:** drop the crown confirmation (removes the deliberate physical step for everyone).
- **YAGNI:** only on the confirmation view.
- **Accessibility:** this is the point.
- **Safety:** still a deliberate, separate action after the amount screen.
- **Assessment:** verify on device with VoiceOver before relying on it.
- **Agent G review:** pending. **Final:** pending. **Status:** Proposed, unverified on device.

## M6 implementation notes (2026-11-16)

Branch `feat/tow-ui`. Details and how the screenshots were made: `../implementation/implementation-status.md` § M6. Screenshots: `screenshots/`.

| DD | What shipped | Differs from the entry |
|---|---|---|
| DD-1 | Vocabulary used in every new string. | — |
| DD-2 | `ControlLineView`: symbol + word + loop age ("Watch · 2m"), iOS ring thresholds with the 30 s grace from the watch's last confirmed cycle; button to the status page. | Age uses the iOS `formattedTimeAgo` (already compiled into the watch, G-13). |
| DD-3 | Status page is page 4; the control line opens it. The main page's toolbar is hidden on it. | — |
| DD-4 | Pill "Watch · 3m" replaces the loop ring in every phone state but `home`; banner second after "Notifications Disabled"; eventual glucose hidden; pull-to-loop off. | Age is the last record batch (V2-14), labelled "last update", not "last heard"; green to 10 min, orange after, red at 30 min with "No Updates from Apple Watch" (G-6a). G-2's `CycleSummary`, IOB/COB "--" and Live Activity rule are not built. |
| DD-5 | Reading age on the delta line ("+3 · 3m", G-14), loop age on the control line, pump and sensor ages on the status page; "STALE DATA" only tethered. | The phone's trend arrow is hidden while a loan runs (it describes the phone's readings). |
| DD-6 | Sending, started (accepted, "isn't delivered yet"), bolusing, finished, cancelled, not given, not confirmed (G-3 copy, no retry, Recent Doses list). Failures stay until OK (G-4). | No "x of y U" progress and no slim bar on the main page: the host doesn't expose a delivered amount. Cancelled says part may have been given. |
| DD-7 | `BolusCalculator` recommendation from the last watch determination; limits from the grant. | Superseded by ADR-005. |
| DD-8 | — | Low-glucose bolus warning not on the watch. |
| DD-9 | Three dialog texts; destructive role only for "Take Back Anyway". "Use the Pod on This iPhone" with its own confirmation when the kit refuses. | — |
| DD-10 | Facts from a live phone query (pod and sensor time left, override and temp target with end, indefinite override flagged), then two fixed lines (G-6b alarm wording, G-8 Nightscout and remote). "Unknown" when the phone doesn't answer. Start stays on screen until the first watch reading (V3-8). | The settings line moved to the phone's blocked notes (G-12). |
| DD-12 | Notes plus disabled actions on Treatments and Adjustments; note on Settings; quick-pick long press opens Treatments; pump panel opens the Trio on Watch sheet; remote commands refused with the G-8 text. | Settings other than pump settings stay editable (the note says they reach the watch only after End). |
| DD-13 | Stopped header, reason, fail-safe sentence, "Done" (W25) that ends glucose alarms on the watch. | — |
| DD-14 | — | No VoiceOver action on the crown confirmation. |

