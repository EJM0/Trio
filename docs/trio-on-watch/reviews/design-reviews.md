# Design reviews

Reviewer: Agent G (independent UX and design judge). Phase 1, read-only. Code references are at baseline `ad6c66876` (the worktree HEAD `1a9dba899` adds only docs; no source under `Trio/Sources` or `Trio Watch App Extension` differs). Claims are marked **V** (verified: I read it), **I** (inferred) or **U** (unverified).

## Executive summary

- The architecture's UX shape is right: one new watch page, no new settings, the crown-to-confirm bolus kept, control state on both devices (R-7). Agent F's v1 docs (`ux-guidelines.md`, `screen-inventory.md`, `interaction-model.md`) are strong: fixed vocabulary, header (not banner) as the phone's control signal, and ten real architecture gaps (A-1..A-10). `design-decision-log.md` did not exist when I read the design folder.
- One blocker: states in which **nothing is dosing** are shown as screen text but never alarm, and in one case the watch tells the user "Nothing changed" while the phone has already released the pump (G-1).
- Ten majors, mostly about alerts that can be missed (2 s failure banners, snooze as the double-tap default, "silent" vs Silent Mode, an alarm subset that drops the user's own alarms), copy that overstates reliability or points to screens the watch lacks, a phone Home that shows stale insulin data during a loan, caregivers losing Nightscout and remote without warning, and no glanceable surface on the watch face.
- Verdict: **pass with changes**. G-1 changes the architecture (alerting and one message distinction) and must be fixed before M3/M4. G-2 needs one small record type. The rest are copy and screen changes for M6.
- Nothing here is medical advice. All user-facing copy proposed below is a draft for maintainer review.

## Architecture-phase review (G)

Inputs: `architecture/{requirements-and-scope,target-architecture,state-and-synchronization,lifecycle-and-execution,architecture-decisions}.md`, `design/trio-design-language.md`, F's `design/{ux-guidelines,screen-inventory,interaction-model}.md`, `reviews/arch-review-D.md` (read to avoid duplicates; cross-referenced where we agree), the watch extension source, iOS Home and alert code, and Apple's HIG pages (fetched as JSON on 2026-11-16).

### What is already right (keep)

- No new user settings. Thresholds (20 s, 60 s, 30 %/20 % battery, 6 h horizon, 20 min silence) are fixed in code. Good.
- F's vocabulary table: "Trio on Watch", "in control", no "loan / lend / owner / commander / dead-man" in user copy. Hold every later PR to it.
- F G1.2 / P1: the phone shows control in the header, not only in the one-slot banner that "Notifications Disabled" can displace.
- F G1.4: "nobody is in control" always says what the pump does now.
- F G5: the existing crown confirmation, haptics and 2-minute entry expiry stay. Bolus outcomes are split into sent, started, delivering, finished, failed and uncertain. "Bolus enacted successfully." is never the last word (it means the pump accepted, `APSManager.swift:635-676`, V via F).
- F G11 / W2: one status page instead of the experimental branch's devices, status, loop status, history, loop mode, glance and manual BG screens.
- F A-1..A-10 are all valid. I don't repeat them below unless I disagree or add something.

### Findings

| ID | Severity | Finding and rationale | Recommendation |
|---|---|---|---|
| G-1 | **Blocker** | **Zero-dosing states don't alarm, and one message is false.** (a) Start step 1 lost and step 5 lost look the same on the watch: both end in the 20 s timeout. F's copy for it is "Your iPhone didn't answer. Nothing changed." (`interaction-model.md` §1 step 3b, `screen-inventory.md` W3). After step 5 the phone has persisted `lending`, cancelled the temp and released the pump (state-and-sync, Start rows 3-5, V). So something did change: Trio is not looping on either device. (b) In `lending` (no confirm), `takingBack` with the pod unreachable, and watch `holding` before the first cycle, nothing schedules a not-looping alarm. The phone suppresses `NotLoopingMonitor` during a loan (target §6, V). The watch only schedules its dead-man after a successful cycle (target §8, V). The phone's 20-minute silence alert only fires when the watch is "reachable", and D-10 shows that is rarely true during a loan. The result is screen text only ("Apple Watch didn't confirm", "Can't reach your pump"), seen by nobody when the phone is in a bag or at home. That is the scenario this feature exists for. | 1. On the watch, tell apart "no reply to the request" and "no grant after the phone accepted". The phone acks the request before it persists `lending`. If the watch saw that ack and then timed out, the copy is: "Your iPhone may have stopped looping. Open Trio on your iPhone now." (`.failure` haptic, stays until tapped, see G-4). Keep "Nothing changed." only when no ack arrived. 2. Phone: keep the existing "Trio Not Active" ladder (`NotLoopingMonitor`, 20…100 min, then 120) armed in every phone state except `lent` with a recent watch cycle report (G-2). Anchor it on the later of the phone's last loop and the watch's last reported enacted cycle. 3. Watch: schedule the ladder when it persists `holding`, anchored at grant time, before the first cycle (with D-9's extension). 4. `stopped` and "Can't reach your pump" also post a time-sensitive notification, not only a screen (F's N table already has these two; make it a requirement in target §8). 5. Add a decision-table test: every state where neither device may command has a pending not-looping notification on at least one device. |
| G-2 | Major | **The phone shows stale insulin data during a loan, and its control pill means something different from the watch's.** F P1 colors the phone pill by "last heard from watch". The watch's W1 line with the same look (`applewatch` "Watch · 2 min") means *last loop*. Same element, two meanings. "Heard 3 min ago" can be green while the watch hasn't enacted anything for 40 min (uncertain gate, failed cycles). The architecture's record types are dose, carb, glucose and pump event (target §2, V). None carries the cycle outcome, so the phone can't show the watch's loop state or its last failure reason. Elsewhere on the phone Home, IOB and COB come from whatever has merged, so they under-count watch boluses between batches. The forecast lines and eventual glucose come from the phone's last own run. The phone's Live Activity keeps showing these on the lock screen and the watch Smart Stack (I). A person or caregiver looking at the phone can act on an IOB that is too low (for example, a pen injection or treating a low differently). F's P1 grey "unreachable" color also depends on `isReachable`, which D-10 shows is almost always false during a loan, so the pill would be grey nearly all the time. | 1. Add one record type, `CycleSummary` (time, enacted yes/no, failure reason, dosing mode, IOB), batched like the others. It also gives the phone's History and Loop Status the watch's reasons after hand-back. 2. Phone pill: draw the iOS ring rules on the watch's *last enacted cycle* from `CycleSummary`, with the text "as of 14:05". Key freshness on the last batch received, not on `isReachable` (D-10). 3. Phone Home while not `home`: IOB and COB show "--" with "From Apple Watch at 14:05" when the last batch is older than 10 min. Hide forecast lines. Eventual glucose "--" (F already does this). 4. The Live Activity follows the same rule, or is ended at lend. |
| G-3 | Major | **Uncertain delivery has no path forward, and the copy points to a screen the watch lacks.** F W6/W7 say "Check your pump history before giving more insulin." The watch has no history view (deferred, F G11), and the phone may be at home. End refuses while a command is unconfirmed (state-and-sync, End row 1, V). P2/P3 steer the user back to End while the watch is reachable. So a user can be stuck: new boluses blocked, End refused, Take Back discouraged. At night this is exactly the pump-error stress case. | Watch copy: "Trio can't tell if your last bolus was given. New boluses are paused until your pump answers." Then a second line by state: if the phone is near, "If this doesn't clear, take back your pump on your iPhone."; if not, "Your pump keeps running its basal." The architecture must name the way out: either End is allowed with an unresolved intent, handing the intent to the phone (the kit's `unacknowledgedCommand` travels with `rawState`; C to confirm), or P3 drops its "End is safer" text when the watch reports an unresolved intent. Don't suggest a retry, and don't tell the user to dose another way. |
| G-4 | Major | **Failure messages vanish after 2 s.** The watch hides every acknowledgment, success or failure, after 2 s (`WatchState.swift:222-225`, V). F W4 keeps "back to root after 2 s, as today" for Start refusals. Those include two-line reasons the user has to act on ("Your pump has an unconfirmed command. Open Trio on your iPhone…"). F W7 doesn't say how failed or uncertain bolus outcomes are dismissed. HIG: a short look "appears only briefly … If your notification information is critical, make sure you deliver it in other ways, too" (Notifications, watchOS). | Success may auto-dismiss after 2 s. Failure, refusal and uncertain results stay until the user taps "OK" (informational) or an action. They play `.failure` and stay reflected on W1/W2 until resolved. Apply this to W4 and W7 and to the tethered remote too (a cheap fix to `handleAcknowledgment`). |
| G-5 | Major | **Double-tap snoozes glucose alarms.** Trio's alert category registers snooze actions in the order "Snooze 15 min", 1 h, 3 h, 6 h (`NotificationIdentifiers.swift:8-12,47-66`, V). HIG: on double tap "the system selects the first nondestructive action", and watchOS shares the iPhone app's registered categories with the watch (Notifications, watchOS, V). If watch-originated urgent low or low alerts use this category, a reflexive double-tap (the gesture people use to dismiss) snoozes glucose alarms for 15 min. Whether every Trio alert uses this category: U. | Watch-raised Urgent Low, "Trio Not Active", pump and CGM alerts use a category with **no custom actions**. Snooze is reached in the app (the existing snooze page). For the low (non-urgent) alert, a snooze action is acceptable only if it isn't first. Verify double-tap behavior on device for a category with no actions (U). |
| G-6 | Major | **Alert copy and terminology that can be misread.** (a) F P1/N: "Apple Watch is silent" / "Apple Watch Is Silent". On watchOS "Silent Mode" is a system state, so at night this reads as "my watch is muted", not "Trio on the watch stopped reporting". (b) F W3/G7.4: "Your watch can't break through Silent Mode or Do Not Disturb the way your iPhone can." Time-sensitive notifications can break through a Focus when the user allows it, and the iPhone's ability depends on AlarmKit on iOS 26 or the audio fallback (`CriticalAlertAlarmScheduler.swift:12-21`, V). Trio's checked-in entitlements have time-sensitive only (`Trio.entitlements`, V). So the comparison is not reliably true. (c) target §8 says "the watch has no critical alerts". The platform research says critical alerts exist on watchOS with an Apple-issued entitlement (research §3.13 [E43]). The real limit is that self-builders don't have the entitlement (D-9). | (a) Title "No Update from Apple Watch", body "Trio on Watch hasn't reported for 20 min. Check your watch." (b) "On your watch, Trio's alarms may only tap your wrist when Silent Mode or a Focus is on. Keep your watch on and notifications allowed." State what happens, without a device comparison; confirm with D's exp. E12. (c) Fix target §8 to "no critical-alert entitlement in Trio builds". |
| G-7 | Major | **Copy overstates reliability.** ADR-002: "Until then untethered mode is not claimed to run continuously" (V). Any cycle may be missed, and the 5-per-24 h Bluetooth budget is a known conflict. Yet F W2 says "Your iPhone can be away." (IDLE footer) and "Your watch keeps looping until then." (PHONE UNREACHABLE). A person managing diabetes will read "keeps looping" as a promise. D-16 asks for an experimental warning too. | IDLE footer: "Your watch takes over your pump and sensor. It may miss some loops; when it does, Trio alerts you and your pump falls back to your scheduled basal." PHONE UNREACHABLE: "Bring your iPhone close to end. Your watch stays in control until then." Add D-4's budget notice on W1/W2 as a state: "Open Trio on your watch to keep looping." Avoid "looping" as a promise in any watch copy. |
| G-8 | Major | **Caregivers and followers lose visibility without warning.** In v1 there is no Nightscout upload from the watch and remote commands are refused (R F-4, target §6, V). Nightscout followers and follower apps will see loop status stop and alarm "not looping". A caregiver's remote bolus or carbs get a refusal through `RemoteNotificationResponseManager` (`RemoteNotificationResponseManager.swift:53,91`, V). F's P4 refusal text for that is "Trio on Watch is running. Use your watch." That is wrong for a caregiver who doesn't have the watch. F's W3 Start sheet doesn't mention any of this. | W3: replace "You may get the same glucose alarm on both devices." (low value) with "Nightscout and remote commands pause until you end." Remote refusal text: "Trio on Watch is running. Remote commands are paused until it ends." Cheap mitigation to decide: at Start and End, the phone uploads a Nightscout note ("Trio on Watch started / ended") through the existing uploader, so followers know why the loop data stopped. No devicestatus from the watch (F-4 stays future). |
| G-9 | Major (decision) | **No glanceable surface on the watch face.** Complications are out of scope (O-2). The existing complication is a static icon (`TrioWatchComplication.swift:12-101`, V via F). Without a workout session the app stays frontmost only about 2 min after wrist-down, unless the user changes Return to Clock (research §3.1, V). So checking "is my watch still dosing" means raising the wrist, pressing the crown and opening Trio, every time. HIG: complications show "relevant information that always feels up to date … A static complication that doesn't display meaningful data may be less likely to remain in a prominent position" (Complications); "Use complications to provide relevant, potentially dynamic data" (Designing for watchOS). A complication on the active face also raises the app's background priority (research §3.11 [E20]). | Move one data complication into v1, in the existing families (`accessoryCircular`, `accessoryCorner`): the control glyph plus the last enacted loop shown as a self-updating relative date (`Text(date, style: .relative)`, so it ages without reloads, I). Grey with a strikethrough after 12 min (the Live Activity convention, F G6). No glucose value is needed in v1. If the maintainer keeps O-2, document Return to Clock = 1 h for Trio as the user-side workaround. |
| G-10 | Major | **Pod or sensor faults during a loan, at night.** Kit alerts reach the watch through a minimal `AlertIssuer` (target §8, V) with the kit's own text. Pod kit text tells the user to deactivate or replace the pod (I, typical OmnipodKit copy). That needs the phone. F A-5 covers expiry warnings at Start but not a fault mid-loan. A faulted pod means no insulin at all, which is the worst stress case. | Every kit pump alert shown on the watch during a loan gets one Trio line under the kit text: "Replacing your pod needs your iPhone. Bring it close and end Trio on Watch, or take back your pump on your iPhone." If the kit reports that delivery stopped, also say "Your pod is not giving insulin." Keep the kit's acknowledgement. If a faulted pod makes End fail at the phone's `takeControl`, P2's "Can't reach your pump" is the wrong message. Route kit fault states to "Your pod has stopped. Replace it on your iPhone." (C to confirm the kit states). |
| G-11 | Major | **The watch drops alarms the user has set up.** The user configures Urgent Low, Low, Forecasted Low, High and Carbs Required (`GlucoseAlertType.swift:9-16`, V), each with its own sound and "override silence" flag (`GlucoseAlertCoordinator.swift:311`, V). The watch raises only urgent low and low (target §8, R-6). The watch runs oref, so it has the forecast and carbs-required inputs. Users who rely on a forecast low or a high alarm (for example, a failed pod site) lose it without being told. | Ship the user's configured `GlucoseAlert` list in the snapshot and evaluate all enabled types on the watch with the same thresholds (no new settings). If that's too much for v1, W3 must list the alarms that stop on the watch, and the High and Forecasted Low rows must say "iPhone only". |
| G-12 | Minor | **The W3 Start sheet is too long for a watch.** It has up to 3 conditional rows plus 3 fixed paragraphs on a 40/41 mm screen. HIG: "quick, glanceable, single-screen interactions". Users skim long confirmations. | Conditional rows (pod, sensor, override) plus at most two fixed lines: the G-6b alarm line and the G-8 line. "No phone changes" goes into P4 where it is enforced. Notification permission is already a refusal (A-3), so it needs no line. |
| G-13 | Minor | **Time format differs between devices.** F uses "Watch · 2 min" (W1) and "Watch · 3m" (P1). iOS uses "3m" (`formattedTimeAgo`). The watch today uses an unlocalized "N min" made on the phone (`AppleWatchManager.swift:214-220`, V via F). | One shared formatter, the iOS one, compiled into the watch target. Localized. |
| G-14 | Minor | **The bobble crowds on small cases, and text doesn't scale.** W1 adds reading age inside the bobble (82 pt on 40/41 mm, `GlucoseTrendView.swift:38-53`, V via F) next to value and delta. The existing labels are fixed 9-11 pt. HIG asks for at least 140 % text enlargement on watchOS (Accessibility, V). | Put reading age on the delta line ("+3 · 3m"), not as a third line. Check W1 on 40 mm and 41 mm at the largest watch text size before M6 sign-off (screenshot required). |
| G-15 | Minor | **End is disabled based on a reachability flag.** F W2 disables End when the phone is unreachable. A stale `isReachable` can block a valid End. | Keep End enabled. Tap, try, and refuse with "Bring your iPhone close to end." if there is no reply. Same for Start. |
| G-16 | Minor | **Redundant battery row.** W2 always shows "Watch battery 64 %", which watchOS already shows. | Show the row only below 30 % (the Start threshold), in orange or red with text. |
| G-17 | Minor | **Open Loop on the watch is a mode with no UI.** With the dosing mode frozen at Open Loop, the watch would compute and never enact, and v1 offers no way to accept a suggestion on the watch. | Refuse Start in Open Loop: "Trio on Watch needs Closed Loop, Low Glucose Suspend or Basal Testing." One fewer state to design and test. |
| G-18 | Minor | **Destructive style on deliberate actions.** F P3 marks "Take Back Pump" destructive in every context. HIG reserves the destructive style for "a destructive action people didn't deliberately choose". | Destructive only for "Take Back Anyway" (watch reachable). Plain style when the watch is unreachable or Start didn't confirm. |
| G-19 | Minor | **The audit insulin must be findable later.** F's notice wording is good ("…Trio counts it as insulin on board."). A one-time notice is easy to miss. | Show the audit entry in History with a plain label ("Unrecorded pod insulin, found at take back"). Pending the cross-project Q-1 test. |
| G-20 | Minor (open) | **No way to suspend insulin from the watch.** Suspend and resume are kit UI on the phone. During a loan the only insulin controls on the watch are cancel bolus and oref's own zero temps. | Decide explicitly. My view: not needed in v1 (YAGNI), since Closed Loop zero-temps on lows and the pod can be removed. State it on P2 / docs ("To suspend insulin, end Trio on Watch first."). |
| G-21 | Nit | **F's no-snooze rule for "Trio Not Active" differs from iOS**, where a snooze re-arms the ladder (`NotLoopingMonitor.swift` `SnoozeObserver`, V). | Fine as a deliberate choice on the watch. Record it in the decision log so nobody "fixes" it into parity. |

### Things I checked and found acceptable

- Two different return verbs ("End" on the watch, "Take Back" on the phone) match two different consequences. Keep both.
- "Enact Bolus" / "Ignore Warning and Enact Bolus" stay as existing Trio strings. The outcome screens (W7) carry the delivered/accepted distinction, so the button wording doesn't need to change.
- A 4th vertical page for W2, plus a tap on the W1 control line, is consistent with watchOS vertical paging and keeps depth at one level (HIG: "Minimize the depth of hierarchy").
- Override and temp target sheets read-only during a loan (W9), with A-1's refusal for indefinite overrides.
- Duplicate low alarms on both devices are acceptable. Neither device suppresses the other (SR-15).

### Verdict

**Pass with changes.**
- **Before M3/M4 (architecture):** G-1 (zero-dosing alarm coverage and the step 1 vs step 5 distinction on the watch), G-2 (the `CycleSummary` record, and phone freshness keyed on the last batch), G-3 (a defined way out of uncertain delivery), G-11 (alarm list in the snapshot, or a disclosure). Also correct target §8's critical-alert sentence (G-6c).
- **Before M6 (UI):** G-4 through G-10 copy and behavior. F should fold these into `ux-guidelines.md` / `screen-inventory.md` and log them in `design-decision-log.md`.
- **Maintainer decisions:** G-9 (one data complication versus O-2), G-8's Nightscout note, G-17, G-20.
- Minors and nits can land with M6.

I'll re-review F's docs when `design-decision-log.md` exists and the M6 screenshots are available (40 mm and 49 mm, largest text, VoiceOver captions).

## Open questions

1. Does a watch notification category with no custom actions make double-tap dismiss, or do nothing? (G-5, on device.)
2. Do time-sensitive notifications from a watch-only app break through Sleep Focus and Silent Mode, and with what haptic? (G-6b, D's exp. E12.)
3. Can an unresolved dose intent travel to the phone at End through the kit's exported `rawState`, so End can be allowed in that state? (G-3, Agent C.)
4. Does `Text(date, style: .relative)` in a watchOS WidgetKit complication keep updating without timeline reloads, and in Always On? (G-9, I.)
5. Which OmnipodKit alert texts tell the user to act in kit UI that only exists on the phone? (G-10, Agent C.)
6. Should the phone run the not-looping ladder when the watch is unreachable for a long time, accepting alarms at home when the phone is left behind? G-1 says yes in zero-dosing states. For `lent` with the watch out of range I lean to one notification, not a ladder (I).

## Evidence index

| Topic | Evidence |
|---|---|
| Lend/End step tables, timeouts | `docs/trio-on-watch/architecture/state-and-synchronization.md` Start rows 1-9, End rows 1-5, Take Back 1-3 (V) |
| Phone suppresses not-looping, watch alarms, record types | `architecture/target-architecture.md` §2, §6, §8 (V) |
| Not claimed continuous; budget conflict | `architecture/architecture-decisions.md` ADR-002 (V) |
| Scope F-4, F-5, O-2, R-6, R-10 | `architecture/requirements-and-scope.md` (V) |
| F's v1 design | `design/ux-guidelines.md`, `design/screen-inventory.md`, `design/interaction-model.md` (V, read 2026-11-16 02:48) |
| D's overlapping findings | `reviews/arch-review-D.md` D-4, D-9, D-10, D-16 (V) |
| 2 s acknowledgment dismissal | `Trio Watch App Extension/WatchState.swift:195-226` (V) |
| Crown confirmation, haptics | `Trio Watch App Extension/Views/BolusConfirmationView.swift:46-86` (V) |
| Ack view | `Trio Watch App Extension/Views/AcknowledgementPendingView.swift:14-57` (V) |
| Main view stale and reachability flags, toolbar | `Trio Watch App Extension/Views/TrioMainWatchView.swift:24-41,116-169` (V) |
| Snooze actions and order | `Trio/Sources/Models/NotificationIdentifiers.swift:8-12,47-66` (V) |
| Not-looping ladder and copy | `Trio/Sources/Services/Alerts/NotLoopingMonitor.swift:33,38,101-130` (V) |
| Glucose alarm types and levels | `Trio/Sources/Models/GlucoseAlerts/GlucoseAlertType.swift:9-16`; `Trio/Sources/Services/Alerts/GlucoseAlertCoordinator.swift:296-316` (V) |
| AlarmKit critical channel on iOS | `Trio/Sources/Services/Alerts/CriticalAlertAlarmScheduler.swift:1-21` (V) |
| Notification entitlement | `Trio/Resources/Trio.entitlements` (time-sensitive key only, V) |
| Remote command responses | `Trio/Sources/Services/RemoteControl/RemoteNotificationResponseManager.swift:53,91` (V) |
| BolusSafetyValidator rejections | `Trio/Sources/Services/BolusSafety/BolusSafetyValidator.swift:23-31` (V) |
| HIG: double tap selects first nondestructive action; short look | https://developer.apple.com/design/human-interface-guidelines/notifications (watchOS section, V) |
| HIG: glanceable single-screen, minimal depth, complications | https://developer.apple.com/design/human-interface-guidelines/designing-for-watchos (V) |
| HIG: dynamic complications | https://developer.apple.com/design/human-interface-guidelines/complications (V) |
| HIG: destructive style, button titles | https://developer.apple.com/design/human-interface-guidelines/alerts (V) |
| HIG: 140 % text on watchOS, not color alone | https://developer.apple.com/design/human-interface-guidelines/accessibility (V) |
| HIG: Always On | https://developer.apple.com/design/human-interface-guidelines/always-on (V) |
| Frontmost after wrist-down, critical alerts on watchOS, complication priority | `research/watchos-platform-research.md` §3.1, §3.11, §3.13 (V as cited there) |

## M6 implementation review (G)

Reviewer: Agent G, 2026-11-16. Branch `feat/tow-ui` (worktree `/Users/dnzxy/workspaces/Trio-tow-ui`), commits `24ebd69be`, `e1eaedf06`, `828b7fbb2`, `2d3d692f9`, `ce4161440`. File references below are relative to that worktree at `ce4161440`. Screenshot references are relative to `docs/trio-on-watch/design/screenshots/`. I looked at all 72 watch shots (41 mm and 46 mm) and the 14 phone-light shots, plus a sample of phone-largest-text, as contact sheets. I judged the UI only, not the launch crash. Claims are marked V (verified: I read the source or saw the shot), I (inferred) or U (unverified).

### Summary

- Much of the architecture review landed well:
  - Failure, refusal and uncertain results now stay until OK (G-4).
  - Loan glucose alarms use an unregistered category, so they have no snooze action that a double-tap could pick (G-5).
  - The phone banner now reads "No Updates from Apple Watch" (G-6a).
  - Reliability copy is honest: "It may miss some loops" (G-7).
  - The Nightscout and remote line is on the Start sheet (G-8).
  - The watch evaluates the user's configured alarms, including Carbs Required (G-11).
  - The Start sheet is short (G-12). Time is "3m" on both devices (G-13). Delta and reading age share one line (G-14). Battery shows only when low (G-16).
  - Phone Take Back uses the destructive style only when the watch is reachable (G-18).
  - The bolus outcome screens separate accepted, delivering, finished, cancelled and not confirmed.
- **Two blockers.**
  - The watch notification for a lost Start still says "Your iPhone still controls your pump". That is the G-1 false claim, now in the place the user is most likely to read it.
  - The watch shows no dosing mode anywhere, so Open Loop, Low Glucose Suspend or Basal Testing look the same as Closed Loop.
- **Majors**, mostly about insulin states and controls:
  - The main page doesn't show when the pump isn't delivering.
  - Suspend and Resume give no feedback and have no reminder.
  - The override cancel is one tap with no confirmation, and the sheet's footer contradicts it.
  - The low-glucose bolus warning is still missing while the watch now prefills a recommendation.
  - The snooze page snoozes only the phone.
  - The phone shows stale insulin values and lets the user change the dosing mode, which has no effect on the watch.
- **Verdict: pass with changes.** Not mergeable until G-M1 and G-M2 are fixed (both small). G-M3 to G-M10 must land before any on-body use.

### Findings

| ID | Severity | Ref | Finding | Recommendation |
|---|---|---|---|---|
| G-M1 | **Blocker** | `Trio Watch App Extension/Loan/WatchLoanAlerts.swift:66-71`; `Trio/Sources/APS/WatchLoan/WatchLoan.swift:406-409` | `requestTimedOut` fires for every `requesting` state. The protocol still can't tell a lost request from a lost grant. Yet the notification body says "Trio on Watch didn't start. Your iPhone still controls your pump." (V). The on-screen text was fixed ("Open Trio on your iPhone to check which device controls your pump", `handoff-no-answer.png`, V). A user whose wrist is down only sees the notification, and it can be false: the phone may be in `lending` with nothing dosing. The alarm half of G-1 (phone ladder in `lending`, watch ladder from grant time) is still open in M3–M5. | Use the screen's wording in the notification: title "iPhone didn't answer", body "Open Trio on your iPhone to check which device controls your pump." Keep G-1's alarm coverage as an M7 gate. |
| G-M2 | **Blocker** | No `dosingMode` reference in `Trio Watch App Extension/Views/TrioOnWatch*.swift` or `Loan/WatchLoanHost+UI.swift` (V by grep). `main-in-control.png` | F G2.4 / W2 require the dosing mode to be visible when it isn't Closed Loop. G-17 asked to refuse Start in Open Loop. Neither is done. With a snapshot frozen in Open Loop, the watch shows a green "Watch · 2m" as if it doses. Whether the watch loop actually honors Open Loop when it enacts is U; Agent C should check `OrefRun` / the watch enact path. | Smallest fix: refuse Start unless Closed Loop ("Trio on Watch needs Closed Loop."). That also removes the need for mode UI in v1. If LGS and Basal Testing stay allowed, show the mode name on W1's control line ("Watch · LGS · 2m") and in a W2 row with the existing `DosingMode` names and hints. |
| G-M3 | Major | `TrioOnWatchStatus.swift:150-169` (control line uses only `lastLoopAt`), `:393-418` (pump lines). `main-in-control.png` vs `status-pod-unreachable.png` | Insulin suspended, pod faulted ("Your pod has stopped. It is not giving insulin."), pod unreachable and insulin paused appear only on W2, the 4th page. The main page keeps a green "Watch · 2m" right after a pod fault or a suspend, because the loop tier is only loop age (V). On iOS, the pump status highlight replaces the pump pills on Home (`PumpView.swift`, via F). At night, during a pump error, W1 is the only screen a person looks at. | When any of these flags is set, the control line shows the pump state instead of the loop age: "Pod stopped" / "Insulin suspended" in LoopRed or orange with `exclamationmark.triangle.fill`, with VoiceOver to match. Same rule as iOS: the highlight wins. |
| G-M4 | Major | `TrioOnWatchStatusView.swift:236-266`; `Loan/WatchLoanHost+Treatments.swift:180-193` | Suspend and Resume (V2-25 supersedes my G-20; I accept the decision) are fire-and-forget. The outcome is only logged, and the user gets no success or failure screen (V). A suspend has no duration and no reminder. Trio's iOS pump flows go through the kit, which as far as I know offers suspend durations and reminders (I, verify OmnipodKit). A forgotten watch suspend means no basal at all, and Trio doesn't loop while suspended (the app's own confirmation copy says so). | Show the result with the W4 pattern: success auto-closes, failure stays and plays `.failure`. Show it on W1 (G-M3). While suspended during a loan, add a time-sensitive reminder every 30 min: "Insulin is still suspended. Trio isn't looping." Resume needs no confirmation. |
| G-M5 | Major | `TrioOnWatchTreatmentViews.swift:153-211`; `override-sheet.png`; iOS `Adjustments/View/AdjustmentsRootView.swift:161,176`, `Home/View/HomeRootView+BottomControls.swift:234,264,389` | The loan sheet offers "Cancel Override" / "Cancel Temp Target": one tap, red tint, no confirmation, no outcome. Its footer says "You can't start or change overrides or temp targets…" (V). Existing Trio wording is "Stop" ("Stop <name>" on the watch; "Stop Override" with the confirmation "Stop the Override "x"?" on iOS, V). Stopping an override or temp target can raise insulin delivery. | Label it "Stop Override" / "Stop Temp Target". Add a `confirmationDialog` reusing the iOS question ("Stop the Override "x"?"). Footer: "You can stop it here. Starting or changing overrides and temp targets needs your iPhone." Show the outcome, and on failure the "Trio on Watch can't save" text. |
| G-M6 | Major | `BolusInputView.swift` diff (watch recommendation via `host.recommendBolus`), DD-8 | The watch now prefills a computed recommendation, and while the watch has the pump it is the only bolus path. iOS's "Glucose is very low." / "Glucose forecast is very low." confirmation (when "confirm bolus" is on) is still not built (V). | Must land before untethered use beyond in-vitro tests, with the iOS copy and the existing crown confirmation. The watch has current glucose and the forecast minimum from its own oref run. |
| G-M7 | Major (U) | `BolusConfirmationView.swift:46-86`, DD-14 | The bolus confirmation needs a crown turn. Whether `digitalCrownRotation` works with VoiceOver on watchOS is U. If it doesn't, VoiceOver users can't bolus at all during a loan. | Add the accessibility action "Confirm bolus" (F G8.4), or verify on device that the crown works under VoiceOver and record the result in DD-14. |
| G-M8 | Major | `Views/AlarmSnoozeView.swift:84,101`; `WatchState+Requests.swift:216-221`; `Trio/Sources/Services/Alerts/GlucoseAlarmEvaluation.swift:164` | During a loan the snooze page (page 3) still sends the snooze to the iPhone and shows "Snoozed until …" (V). The watch's own loan alarms check the snapshot's `snoozedUntil` (V for the evaluator; frozen at grant, I). So a snooze set on the watch doesn't silence the watch's alarms, and a long phone snooze set before Start silences watch alarms with nothing on the watch saying so. F G7.3 asked for local snooze on the watch. | While the watch is in control, page 3 snoozes the watch's alarms locally, with the existing choices, and says "Alarms on this watch". It shows a snooze carried over from the iPhone. Urgent Low follows the iOS snooze rules. |
| G-M9 | Major | `phone-light/in-control.png`, `in-control+treatments.png`; `Treatments/View/TreatmentsRootView.swift` diff | This is the open part of G-2. Phone Home shows "0 U" IOB, "0 g" COB and the "0,1 U/hr" basal pill with no "as of" while the watch doses (V in shots). Treatments keeps carbs, bolus and a "Recommendation 0,05 U" active. Only the final button is disabled, and the note sits at the bottom, under the home indicator (V). A stale recommendation and IOB on the device a caregiver looks at can lead to dosing another way. The header shows "No Pod" with a warning in every phone shot. That may be a simulator artifact (I), but nothing in the diff replaces the pump panel's content while lent. | IOB, COB and the basal pill show "--" plus "From Apple Watch at 14:05" when the last batch is older than 10 min. Treatments: put the note at the top, hide the recommendation, disable the fields. Pump panel while lent: `applewatch` "On Apple Watch" instead of reservoir, battery or "No Pod". |
| G-M10 | Major | `Settings/View/SettingsRootView.swift` diff; `phone-light/in-control+settings.png` | Settings only gains a note. The Dosing Mode picker stays live (V in shot). Changes "reach your watch only after you end it". In a crisis, someone may switch the phone to Open Loop to stop automatic insulin, while the watch keeps dosing. | Disable the Dosing Mode picker while lent, with the P4 note beside it ("To stop automatic insulin now, use Suspend Insulin on your watch."). Other settings can stay editable under the existing note. |
| G-M11 | Major (a11y) | `phone-largest-text/no-updates.png`, `in-control.png` | At the largest text size the phone pill truncates to "Watch · 3…", which drops the minutes, the one number it exists for (V). | Drop the word "Watch" at large sizes (the `applewatch` glyph carries it) and keep the age. Or let the pill wrap under the bobble. |
| G-M12 | Minor | `WatchLoanAlerts.swift:166-169` | Notification fallback text "Check Trio on your iPhone (\(refusal.rawValue))" shows an internal code such as "indefiniteOverride" to users (V; the status notes say the same). | Reuse `TrioOnWatchStatus.refusalText` in the notifications, as the M6 notes already suggest. |
| G-M13 | Minor | `HandOffView` "Waiting for your watch's first sensor reading…" (`handoff-waiting-reading.png`) | While waiting for the first reading nothing is dosing, but only VoiceOver says so ("Your watch is not giving insulin yet"). The visible copy says "Keep Trio open. Your watch takes over once it gets a reading." | Add the visible line "Your watch isn't giving insulin yet." on W4 and W2. |
| G-M14 | Minor | `BolusInputView.swift`, `CarbsInputView.swift` diffs | "Carbs saved on your watch." shows before `addCarbs` has finished (fire-and-forget `Task`, V). A failure arrives later as a separate notification. | Await the save, then show "saved", or show "Saving…" first. |
| G-M15 | Minor | `WatchLoanAlerts.swift:49,76,85,258`; `TrioOnWatchStatus.swift:345,628,633` | Terminology drifts: "hand-over", "hand-off", "Can't hand back yet" (F's vocabulary is Start / End / Take Back). "Pod not found" and "Can't reach your pod" name the same condition. "Trio on Watch isn't looping" differs from iOS "Trio Not Active" (F G7.2). | One term per concept, following F's vocabulary table. Not-looping: title "Trio Not Active", with the watch-specific body. |
| G-M16 | Minor | `TrioOnWatchTreatmentViews.swift:56-67`; `bolus-delivering.png` | The bolus cancel is an icon-only `xmark.app` on a red pill (it has a VoiceOver label). "Bolusing" shows no amount delivered so far (F W7 "0.40 of 1.00 U"). | On the watch, label it "Cancel Bolus" (text plus icon). Show delivered progress if the kit reports it, otherwise leave it as is. |
| G-M17 | Minor | `TrioOnWatchStatusView.swift:186-195` | G-15 is marked resolved, but End is still gated on the `phoneReachable` flag at tap time rather than tried. | Send the End request and refuse on timeout. |
| G-M18 | Nit | `end-confirmation.png` | "End" uses the destructive role. The user chose it deliberately (HIG, Alerts). | Plain role. |
| G-M19 | Minor | `phone-light/taking-back-stuck+sheet.png` | "This iPhone won't, until Trio on Watch ends" is shown while taking back, when from the user's view it has already ended. | Hide the list in `takingBack`, or retitle it "This iPhone won't, until it reaches your pump". |
| G-M20 | Minor (evidence) | MD5 of `watch-46mm/status-in-control.png` = `status-phone-away.png` = `status-suspended.png`; 41 mm: `status-in-control.png` = `status-suspended.png`; `phone-largest-text/in-control+sheet.png` shows the launch screen | The states that differ (phone-away footer, "Insulin suspended" row, Resume button) are below the fold, so the shots don't show them. One phone shot failed to capture. `main-phone.png` shows tethered "STALE DATA", not the "iPhone · 2m" line. No watch shots at large text (simulator limit). | Re-capture W2 states scrolled to the pump row and the button, the phone sheet, and a tethered fresh main page. Check watch large text on a device before M7. |

### Verdict

**Pass with changes.**
- **Before merge:** G-M1 (one string) and G-M2 (refuse Start outside Closed Loop).
- **Before any on-body use:** G-M3 to G-M10.
- **With M7:** G-M11 to G-M20.
- **Still open from the architecture review:** G-1 alarm coverage (M3–M5), G-2 `CycleSummary`, and G-10 (the Trio line under kit pump alerts).

## M6 re-review (G)

Reviewer: Agent G, 2026-11-17. Branch `feat/tow-ui` at `24bb7187b`. This round covers fix commits `2a76e8d5e`, `1564b6854`, `366ec78fc` and `f3bb41259`, the integration merge `5ba7fa713` (`a93e7769d` Start only in Closed Loop, `d2a3b74e6` no enact when automation is off, `a42f4aa15` Dosing Mode lock), and `c0f84b18d` / `24bb7187b`. I read the source diff `ce4161440..24bb7187b` and the re-captured shots as contact sheets: the 41 mm set in full, the changed 46 mm states, phone-light, phone-largest-text, and phone-dark Treatments.

### Claim check

| ID | Status | Evidence |
|---|---|---|
| G-M1 | Fixed (V) | `WatchLoanAlerts.swift`: the `phoneDidNotAnswer` body is now "Open Trio on your iPhone to check which device controls your pump." It no longer says who controls the pump. |
| G-M2 | Fixed (V) | Start is refused outside Closed Loop on both sides (`WatchLoanPhoneHost.swift:87`, `WatchLoanSnapshot.swift:133`). `watch-41mm/handoff-not-closed-loop.png` shows the refusal copy and an OK button. The watch enacts nothing when automation is off (`d2a3b74e6`, read only as far as the commit title and tests; enact path for Agent C). |
| G-M3 | Fixed (V) | `TrioOnWatchStatus.pumpCondition` takes priority over loop age on W1. `main-pod-stopped.png` (red), `main-suspended.png` and `main-bolus-paused.png` (orange), `main-pod-unreachable.png` (red); each has a triangle plus words. |
| G-M4 | Fixed, one copy nit (V) | Suspend and Resume now report the pump's confirmation through `ActionResultView`. W1 shows "Insulin suspended". Reminders are scheduled. See G-R1. |
| G-M5 | Fixed (V) | The sheet uses "Stop Override" / "Stop Temp Target" with a `confirmationDialog` that reuses the iOS strings ("Override to Stop", "Stop the Override "x"?"; both keys exist in `Localizable.xcstrings`), shows the outcome, and has the new footer (`override-sheet.png`). |
| G-M6 | Fixed (V, code; no screenshot) | `LowGlucoseBolusWarning` in `BolusSafetyEvaluator.swift` is shared by iOS and the watch. The watch button reads "Ignore Warning and Enact Bolus" when confirmation is needed (`BolusInputView.swift:38`). The iOS Treatments refactor around it is large (`TreatmentsRootView.swift`, +/-169), so confirm the iOS warning behaves the same with the existing tests (I). |
| G-M7 | Code fixed; device check open | The accessibility action "Confirm bolus" is on `BolusConfirmationView.swift:75-77`. VoiceOver behavior is still for DD-14 on a device. |
| G-M8 | Fixed (V) | While the watch owns the alarms, the snooze page snoozes the watch's alarms, shows "Alarms on this watch", and reads the watch's `snoozedUntil` (`AlarmSnoozeView.swift`). |
| G-M9 | Fixed (V) | The phone pump panel shows "On Apple Watch". IOB and COB show "--" and the basal pill is gone (`phone-light/in-control.png`). Treatments shows only the note, at the top (`in-control+treatments.png`, light and dark). |
| G-M10 | Fixed in code; no shot (V) | The Settings Dosing Mode picker is disabled with the lock reason, and the setter re-checks the gate (`SettingsRootView.swift`, `SettingsStateModel.dosingModeLockReason`). Settings is the only place in `Trio/Sources` that changes the mode (grep). The `in-control+settings.png` capture shows the launch screen again. |
| G-M11 | Fixed (V) | The pill drops the word and keeps the age: "3m" green, "34m" red with a triangle (`phone-largest-text/in-control.png`, `no-updates.png`). |
| G-M12 | Fixed (V) | `WatchLoanAlerts.text(for:)` now calls `TrioOnWatchStatus.refusalText`. No raw codes remain. |
| G-M13 | Fixed (V) | "Your watch isn't giving insulin yet." appears on W4 (`handoff-waiting-reading.png`). |
| G-M14 | Fixed (V) | The carbs result waits up to 10 s for the save, shows "Saving carbs…", and on failure "Carbs not saved. Enter them again." with OK. |
| G-M15 | Fixed (V) | "Trio Not Active" (the iOS key), "Can't reach your pod" used everywhere, "Can't end Trio on Watch yet", and no "hand-over" / "hand-off" left in the changed strings. |
| G-M16 | Fixed (V) | The button is labelled "Cancel Bolus" with icon and text (`bolus-delivering.png`). No delivered-so-far amount is shown, which is acceptable (the kit doesn't report it). |
| G-M17 / G-M18 | Fixed (V) | End is attempted, and a refusal after no reply keeps the copy. The "End" button now uses the plain role (`end-confirmation.png`). |
| G-M19 | Fixed (V) | The "won't" list is gone while taking back (`taking-back-stuck+sheet.png`). |
| G-M20 | Mostly fixed (V) | No duplicate PNGs remain (MD5 check on both watch sizes). The W2 pump and actions states are captured scrolled. `main-phone-fresh.png` added. Still missing: the phone Settings lock, and watch largest-text (device). |
| G-10 | Fixed for the pump (V) | Every kit pump alert during a loan gets "Replacing your pod needs your iPhone. Bring it close and end Trio on Watch, or take back your pump on your iPhone." |

### Remaining findings

| ID | Severity | Ref | Finding | Recommendation |
|---|---|---|---|---|
| G-R1 | Minor | `WatchLoanHost+UI.swift:118-134`; Suspend success text | The success copy says "Trio reminds you every 30 minutes until you resume", but the reminders stop at 240 min (8 notifications). | Either "for the next 4 hours", or re-arm the series on each cycle while suspended. The second is better, because a forgotten suspend overnight outlasts 4 h. |
| G-R2 | Major, carried to M7 (not M6) | `Loan/WatchLoanCGM.swift:153-156` | The watch logs CGM kit alerts but never shows them ("The phone keeps the sensor's own alerts"). With the phone away, a failed or expired sensor has no alert on the watch. Glucose alarms then go quiet, and the user only hears about it from "Trio Not Active" about 20 min later. R-6 lists CGM signal loss as a required watch alert. | M5/M7: show sensor kit alerts on the watch while the watch holds the CGM (G-10 pattern, line "Replacing your sensor needs your iPhone."), or add a watch "No sensor reading for 15 min" alert. |
| G-R3 | Minor | `main-phone-fresh.png` | The tethered line reads "iPhone · 4 min" while the watch's own line reads "Watch · 2m". The "N min" text is the phone's pre-existing unlocalized snapshot string (G-13 asked for one shared formatter). | Have the phone send the loop date and format it on the watch with `formattedTimeAgo`. That also removes an unlocalized string. |
| G-R4 | Nit | `main-pod-stopped.png`, `main-bolus-paused.png` | "+" stays fully enabled when the pod has stopped or new insulin is paused. Carbs-only entry is still valid, so this is acceptable. "Bolus paused" undersells that SMBs and high temps are paused too. | Optional: "Insulin paused" as the label. Keep "+" enabled. |
| G-R5 | Nit (evidence) | `phone-light/in-control+settings.png` | Shows the launch screen. | Re-capture before M7 so the lock wording is on record. |

### Verdict

**Pass** for merging M6 into `feat/trio-on-watch`. Both blockers and every M6 major are fixed and verified in source or screenshots. G-R1 and G-R3 to G-R5 can land with M7.

M7 gates still open, unchanged:
- G-1 alarm coverage in zero-dosing states (phone ladder in `lending`, watch ladder from grant time).
- G-2 `CycleSummary`. The phone pill still means "last update", not "last loop".
- G-R2: CGM alerts on the watch.
- Device checks: DD-14 (VoiceOver crown confirmation) and watch largest text.
- A regression check that the iOS low-glucose bolus warning is unchanged after the Treatments refactor.

## Final design review (pre-M8)

Reviewer: Agent G, 2026-11-18. Integration branch `feat/trio-on-watch` @ `14b5d6c08` (`/Users/dnzxy/workspaces/Trio-on-watch`). I read the source diff `24bb7187b..14b5d6c08` and the re-captured screenshots (contact sheets of phone-light, phone-largest-text and watch 41 mm). Claims are marked V (verified) or I (inferred).

### M7 items

| Item | Status | Evidence |
|---|---|---|
| G-1 alarm coverage | Fixed (V) | The watch schedules the "iPhone didn't answer" notice when the request starts, so it fires even if Trio is suspended (`WatchLoanHost.swift`, `updateRequestTimeout`, `WatchLoanAlerts.requestTimeoutID`). The phone's `NotLoopingMonitor.setArmed(_:since:)` re-arms from an anchor in every state where no device may dose (`fbe3a81eb`). The hand-back is resent until the phone acks (`73a577af2`). |
| G-2 | Fixed, lighter than proposed (V) | The record batch carries `lastLoopAt`. The phone ledger keeps the newest per epoch (`WatchLoanCoordinator.swift`). The pill and VoiceOver show "last loop" (`TrioOnWatchPhoneStatus.swift:137-147`). "No Updates" stays keyed on the last batch. A full `CycleSummary` (failure reason, mode) is not needed for v1 UI: P2 and the watch show the reason. Accepted. |
| G-R1 | Fixed (V) | "Insulin suspended. Trio reminds you every 30 minutes, for up to 4 hours." matches the 30…240 min series. |
| G-R2 | Fixed (V) | While the watch reads the sensor, the kit's sensor alerts are posted on the watch with the line "Replacing your sensor needs your iPhone…". Delayed and repeating triggers are scheduled at the kit's time (a repeating alert is shown once). They are retracted at End (`WatchLoanCGM.swift`, `WatchLoanAlerts.postKitAlert`). |
| G-R3 | Fixed (V) | The tethered line reads "iPhone · 1m" (`watch-41mm/main-phone-fresh.png`). It does this by parsing the phone's "N min" string (`TrioOnWatchStatus.swift`, `controlLine`). That works but is brittle; sending the date would be better (follow-up, not blocking). |
| G-R4 | Accepted as changed (V) | "Extra insulin paused" (`main-bolus-paused.png`). The status line says "Boluses and extra automatic insulin are paused". The author's reason (it shouldn't read like a suspend) is sound. |
| G-R5 / G-M10 | Fixed (V) | `phone-light/in-control+settings.png` shows the disabled Dosing Mode picker with "Apple Watch is in control. End Trio on Watch to change Dosing Mode. To stop automatic insulin now, use Suspend Insulin on your watch." |

### Remaining findings (none blocking)

| ID | Severity | Ref | Finding | Recommendation |
|---|---|---|---|---|
| G-F1 | Minor | `TrioOnWatchPhoneStatus.swift:137-144` vs the watch's `TrioOnWatchRules.loopTier` | The same loop age gets different colors on the two devices. The phone pill is green to 10 min, then orange (red only with "No Updates"). The watch uses the iOS rules: green to 5 min, yellow to 10, red after. At 12 min the watch is red and the phone orange. | Share the one tier function (iOS `LoopView` rules) on both devices. Follow-up PR. |
| G-F2 | Nit | `phone-light/in-control+settings.png` | The fixture shows Dosing Mode "Open Loop" during a loan, which can't happen now that Start requires Closed Loop. | Set the screenshot fixture to Closed Loop. |
| G-F3 | Nit | `WatchLoanAlerts.sensorNeedsPhone` | The line "Replacing your sensor needs your iPhone…" is added under every sensor alert, including ones that don't need a replacement (for example a temporary signal loss). | Optional: add the line only to alerts the kit marks as needing a new sensor. Otherwise accept; it is still true. |
| G-F4 | Nit (pre-existing) | `main-phone-fresh.png` | Tethered IOB and COB show "0" without units (phone-made strings, F G6 SHOULD). | Out of scope. Track with the tethered watch remote work. |

### Overall design verdict

**Pass.** The branch meets F's v1 guidelines and every blocker and major from the architecture-phase, M6 and re-review rounds:
- Control is visible on both devices.
- Every state where nothing doses is stated in words and alarmed.
- Delivery copy separates accepted, delivering, finished and unconfirmed.
- Reliability copy doesn't overpromise.
- Phone surfaces don't show stale insulin data.
- The user's own glucose alarms and the sensor and pump kit alerts reach the watch.
- Terminology follows the fixed vocabulary and existing Trio strings.

What follows can't be judged from the simulator. It is the design part of the M8 gate.

### M8 design checks (device only)

| # | Check | Pass criterion |
|---|---|---|
| D-1 | VoiceOver bolus confirmation (DD-14) | With VoiceOver on, a bolus can be confirmed through the "Confirm bolus" action without turning the crown. The crown path still works with VoiceOver off. Cancel is reachable and labelled. |
| D-2 | Watch largest text (accessibility sizes) | On 41 mm and 46 mm (or 40/44 mm) at the largest text size, W1 still shows the glucose value, the delta and age line, and the control line with its age (the age not truncated). W2 rows wrap. The Start sheet, W4 and W7 buttons stay reachable by scrolling. |
| D-3 | Notification delivery under Silent Mode and Focus | Over one night with the watch on wrist, in Silent Mode and Sleep Focus: "Trio Not Active", urgent low, "iPhone didn't answer", sensor and pump kit alerts and the suspend reminder each arrive at least as a haptic. Record which play sound. The Start sheet's line ("may only tap your wrist") must match what is observed. Repeat with the watch locked and once after a reboot (D-7 / exp. E12). |
| D-4 | Wrist-down glanceability | With default Return to Clock, and again with 1 h for Trio: how long W1 stays up after wrist-down, and whether Always On dims it legibly (control line and age readable). Record whether the user has to open Trio to see that the watch is in control. That decides whether the one data complication (G-9, O-2) goes into v1.1. |
| D-5 | Double-tap on alarms | Double-tap on a watch-raised urgent low, "Trio Not Active" and a kit alert dismisses or opens. It must never snooze (G-5; these categories have no actions). |
| D-6 | Haptics | `.failure` on refusals and uncertain outcomes, `.start` / `.stop` on hand-off, and `.success` on bolus finished are felt and distinguishable on the wrist. |
| D-7 | Phone pill and banner in real hand-offs | During an in-vitro run: "Watch · Nm" follows the watch's loop. "No Updates from Apple Watch" appears about 20 min after the last batch. Take Back steers to End when the watch is reachable. |

Follow-ups (not gating): G-F1 to G-F4, G-R3's date-based format, and the complication decision after D-4.
