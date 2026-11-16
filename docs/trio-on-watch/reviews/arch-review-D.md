# Architecture review D: watchOS feasibility (Phase 3 gate)

Reviewer: Agent D. Date 2026-11-16. Read-only.

Scope:
- `architecture/requirements-and-scope.md`
- `architecture/target-architecture.md`
- `architecture/state-and-synchronization.md`
- `architecture/lifecycle-and-execution.md`
- `architecture/architecture-decisions.md`
- `implementation/roadmap.md`

Evidence IDs `E#` refer to the Evidence index in `research/watchos-platform-research.md`. Experiment IDs (E1–E14) refer to section 7.4 of the same document, written as "exp. E2" here to keep them apart from evidence.

Correction applied to the research doc: Loop PR #2545 head `5aeb4703` has no `HKWorkoutSession`. Only an `xcconfig` comment mentions one, and its watch runs on Bluetooth alert wakes, holding each task up to 25 s. The Loop lines in the research doc are now fixed. Loop's field reports (missed readings, overnight handbacks) therefore count as evidence **about the ADR-002 path itself** [E33].

## Verdict

**Approve with changes for M0–M5 as simulator work.** Two blockers must be fixed before anything merges into `dev` or any hardware run where the watch owns the pump.

The safety skeleton is right for this platform:
- write-ahead intents;
- the four-state delivery tracking;
- the uncertain-delivery gate;
- the pod as the fail-safe;
- no catch-up dosing;
- no autonomous takeover.

The platform claims in the lifecycle table are too optimistic in several rows. The ADR-002 wake model is still an unproven bet. SR-17 is the right gate, and the instrumentation below is what makes it decidable.

## Findings

| ID | Severity | Finding | Evidence | Concrete change |
|---|---|---|---|---|
| D-1 | **Blocker** | Target §7 / roadmap M2 add `bluetooth-central` (and entitlements) to the watch build unconditionally. If App Store Connect still rejects a watch bundle that declares `bluetooth-central` without `com.apple.developer.bluetooth-central-background`, every Trio browser build (fastlane `upload_to_testflight`) breaks, including flag-off builds. | Forum upload rejections 2018–2021 [E24][E25]. Trio uploads via `fastlane/Fastfile:230` [E47]. Current status Unverified (exp. E1) | Gate the background mode and the watch entitlements behind `TRIO_ON_WATCH`, as Loop gates `LOOP_WATCH_ENTITLEMENTS` (a separate `INFOPLIST_FILE`, or `INFOPLIST_KEY_*` set from the xcconfig). Run exp. E1 before M2 merges to `dev`. Note that open PR #1749 already adds the mode unconditionally, so exp. E1 decides that PR too. |
| D-2 | **Blocker** | §11: when `TRIO_ON_WATCH` is off "the phone never lends". Turning the flag off after a loan has started (rebuild, update, a different builder) must not strand a `lent` / `lending` / `takingBack` state. That would leave no Take Back and an open gate, or two commanders. | Target §11, state-and-sync "Take Back" | Compile `WatchLoanGate`, the persisted phone loan state and Take Back **unconditionally**. The flag gates only Start/lend and the watch loop host. A flag-off phone that loads a non-`home` state keeps the gate closed and shows Take Back. Add a decision-table test for "flag off with a persisted `lent`". |
| D-3 | Major | The lifecycle row "G7 reading arrives (`WKBluetoothAlertRefreshBackgroundTask`)" assumes one task per reading. The G7 disconnects after each reading. The documented model gives brief runtime on disconnect (to call `connect`) and a wake on characteristic change. Both, and background scans, may count against the 5/24 h budget. Readings also arrive with no task at all: foreground, frontmost, Background App Refresh, a WatchConnectivity wake. Several tasks can arrive in one `handle(_:)`. | Docs and WWDC22 [E2][E3][E4]. Loop's `finish(_:)` comment: "watchOS ends the app when one it handed over is released unfinished" (PR #2545 diff) | Trigger the cycle from the CGM manager's new-reading callback, independent of how runtime was obtained. Track *all* held tasks (any type) in one registry, and complete every one on cycle end or on expiry. Use either the SwiftUI `.backgroundTask` or the delegate `handle(_:)`, not both (the delegate receives every task [E2]). |
| D-4 | Major | The lifecycle table has no row for the documented budget. There is no handling for `CBError.leGattNearBackgroundNotificationLimit` / `leGattExceededBackgroundNotificationLimit` and no user path to reset it. | "five ... in a rolling 24-hour window ... the entire budget refreshes when the user launches your app" [E2]. After the limit: "revert back to watchOS 8 behavior" [E4]. watchOS 26.2 report of no recovery [E36] (Unverified) | Add a row. On Near: log it and raise a time-sensitive notice ("Open Trio on your watch to keep looping"). Opening the app resets the budget [E2]. On Exceeded: same notice, and state that cycles will be missed. xDrip4iOS does exactly this [E29]. |
| D-5 | Major | Holding the Bluetooth task for a full cycle (G7 auth and read, pump status read, oref, temp and SMB, persist) is **not documented as plausible**. Apple: the time per event is "very short ... enough to alert the user" [E4]. There is no API that returns remaining time for a `WKRefreshBackgroundTask`. The safety analysis wants "start a dose command only if there is runtime left" (FMEA), which can't be implemented exactly. Loop holds 25 s on a timer and xDrip4iOS 15 s; neither is documented as safe. A DASH exchange may need a fresh session per cycle. The per-app limit of two connections is exactly G7 + DASH [E4]. | [E4], PR #2545 diff, [E29], `safety/failure-mode-analysis.md:184` | Add an explicit **command deadline**: no insulin-adding command starts later than T seconds after the wake began. T comes from exp. E5's measured distribution and defaults to "no SMB in a background wake" until exp. E5 passes. Temp basal only (bounded by pod expiry) is the conservative first mode. Set `expirationHandler` and log when it fires. Never start a command inside the handler. |
| D-6 | Major | The "App terminated / relaunched" row implies a relaunch. watchOS documents no Bluetooth relaunch for a terminated app except background scans (budgeted). TN3115 is iOS-only, and willRestoreState behavior on watch is unverified. Force-quit (Dexcom warns against swipe-kill), the Bluetooth toggle and Airplane Mode have no rows. | [E30], [E4], [E27], research §3.6 | Reword: "No relaunch guaranteed. Nothing runs until a background task or the user opens Trio. The dead-man alarm covers it." Add rows for force-quit, Bluetooth off and Airplane Mode with that same outcome (exp. E3, exp. E4). Don't depend on `willRestoreState`. |
| D-7 | Major | The reboot row states "Dead-man notifications already scheduled still fire". That isn't verified on watchOS, especially before first unlock after a reboot. | Research §3.13, §3.14 (Inferred only) | Mark the row Unverified. Add the reboot and locked cases to exp. E12. |
| D-8 | Major | Watch locked or off-wrist (charging at night locks it [E44]). If loan state, records or kit keychain items use `complete` protection, cycles fail while locked. | [E44]. Data-protection effect Unverified (exp. E7) | Write loan files with `.completeUntilFirstUserAuthentication`. Make keychain items `AfterFirstUnlock`. Log read failures as `error`. Add a "Watch locked" row that cites exp. E7. |
| D-9 | Major | Dead-man reliability at night. `.timeSensitive` "obeys DND/silent" (Trio's own `DeviceAlertSeverity.swift:8` comment). Critical alerts need an Apple-issued entitlement that self-builders don't have [E43]. With Silent Mode or a Focus, the alarm is at best a haptic tap. The ladder stops at +40 min. A cycle that ran but enacted nothing (uncertain gate) must not count as "good". | [E43], `Trio/Sources/Models/GlucoseAlerts/DeviceAlertSeverity.swift:8`, target §8 | Extend the ladder: +20, +40, +60, then every 30 min while `holding`, with stable identifiers so each request replaces the last. Push it forward only when a cycle reached "confirmed" pump state. User copy must say watch alarms may only tap the wrist. exp. E12 covers silent, Sleep Focus, locked, off-wrist and reboot. |
| D-10 | Major | The phone's 20-min silence alert (R-10, target §6) is keyed on the watch being "reachable". On the iPhone, `isReachable` needs the watch app running and reachable. During a loan the watch app is mostly suspended, so "reachable" is rarely true and the alert almost never fires. | `WCSession.isReachable` doc [E40] | Key it on the last record batch received (`activationState == .activated && isPaired`), ignoring reachability. Accept false alarms when the user is away from the phone. |
| D-11 | Minor | WatchConnectivity: `sendMessage` when reachable, otherwise `transferUserInfo`, with dedupe by `messageID`, is correct. The existing `WatchNotificationHandler` falls back to `transferUserInfo` on a `sendMessage` error, which can deliver twice. Dedupe covers that. Phone-to-watch `sendMessage` never wakes the watch [E40], so a higher-epoch notice reaches the watch late. The design rightly relies on #177's foreign-session detection. The grant (24 h of data) may exceed live-message size. | [E40], `Trio Watch App Extension/Helper/WatchNotificationHandler.swift:56-64` | Send the grant with `transferFile` or `sendMessageData` behind a measured size check. State in state-and-sync that phone-to-watch messages are best-effort during a loan. |
| D-12 | Minor | Deployment target 10.6 is fine: every watchOS 10 device can update to it. But background alerts and scans need Series 6 or later [E4]. Series 4/5 and SE (1st gen) would accept a loan and never wake. Dexcom's list matches this floor [E28]. | [E4], [E28] | Refuse Start unless `hw.machine` is Watch6,x or later and the watch is not an SE (1st gen) (exact identifier list to verify). Show the reason. |
| D-13 | Minor | Restoration identifiers: PR #1749 found a new central sharing the old one's restore identifier never powered on. | PR #1749 body [E46] | One central per kit, each with a unique identifier. Release the old manager before creating a new one at sensor or pod change. Log `willRestoreState` calls (for exp. E3). |
| D-14 | Minor | The clock row says expiries use monotonic time. Monotonic clocks reset on reboot, and persisted expiries span reboots. | Lifecycle table | Persist wall-clock expiries with uptime sanity checks. Use monotonic time only within one process lifetime. |
| D-15 | Minor | Low Power Mode and the user's own workouts have no rows. Low Power Mode is prompted at 10% and can turn on automatically for Workout-app workouts. Background App Refresh and complications slow down, and Wi-Fi and cellular are off without the iPhone [E22]. Refresh is also throttled "when exercising" [E2]. | [E22], [E2] | Add rows (effect on Bluetooth wakes Unknown, exp. E9). Log the Low Power Mode state in every cycle. |
| D-16 | Minor | SR-17 gating: a builder can turn the build flag on, so the flag alone doesn't prove a hardware pass. | `safety/failure-mode-analysis.md:347` | Add a runtime warning on first Start that untethered mode is experimental and unproven on hardware. Track it in `implementation-status.md`. The decisive part is D-2 plus the logs below. |

## Minimum instrumentation for exp. E2 and exp. E5

The logs must let someone reconstruct every wake and every cycle from the logs alone:
- Use Trio's logger and the existing watch log ingest (`Trio/Sources/Logger/Watch/WatchLogIngest.swift`).
- Follow the CONTRIBUTING logging rules: plain sentences, units, no identifiers or secrets.
- Persist to a file on the watch, so a run without a debugger can be read afterwards.

1. **Process:** launch (cold vs resume), app state on each transition, watchOS version, hardware model, Low Power Mode, battery percent, thermal state. Include peak memory per cycle (jetsam risk).
2. **Wake:** every task received (type, count per `handle`), start uptime and wall time, `expirationHandler` fired (seconds since start), completed (seconds since start). Also log any reading processed with no task held, and its runtime source.
3. **Bluetooth:** central state changes. Per role (CGM or pump, no UUIDs): connect requested, didConnect, didDisconnect (with error domain and code), didUpdateValue. Every `CBError`, with the `leGatt...NotificationLimit` codes logged at `warning`. `willRestoreState` calls and the number of restored peripherals.
4. **CGM:** sensor timestamp, receipt time (latency in seconds), gap since the previous reading, and readings received vs expected (one per 5 min) in a rolling 24 h count.
5. **Cycle:** an ID per cycle. Durations for the restore checklist, pump status read, oref run and each enact. Outcome per command: requested, accepted, executed, confirmed or uncertain. Seconds from wake start to command start (exp. E5's deadline). Gate refusals with a reason.
6. **Safety net:** dead-man notifications rescheduled (next fire time, pending count), and a cycle counted "good" or not.
7. **Transport:** each WatchConnectivity send (method, size, success or error) and batch acks.
8. **Daily summary:**
   - readings expected and received;
   - cycles run and confirmed;
   - wakes per task type;
   - budget errors seen;
   - longest gap in minutes;
   - battery used per hour.

## Hardware experiments this review depends on

- **exp. E1** (upload check) blocks D-1.
- **exp. E2** (24 h wake count, budget behavior) and **exp. E5** (a DASH exchange within one wake, which sets T) are the SR-17 evidence.
- **exp. E3, E4, E7, E9 and E12** close D-6, D-7, D-8, D-15 and D-9.
