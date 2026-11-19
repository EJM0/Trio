# watchOS platform research: can an Apple Watch run an AID loop unattended?

Agent D, Phase 1 (read-only research). Sources fetched 2026-11-15. Baseline Trio `dev` @ `ad6c66876e5ccca8b0a6e1c5b7626ed4caa65926`.
Contributor-facing technical document. Not medical advice.

## Executive summary

1. No public watchOS mechanism (watchOS 10, 11, 26, 27) gives a third-party app a documented guarantee of a BLE cycle every ~5 minutes, 24/7, with the screen off and without user interaction. Apple DTS said in March 2026 that "continuously running a watchOS app in background hasn't been a supported use case from day one" [E20].
2. The public background-BLE model (watchOS 9+, Series 6+) keeps a connection open while the app is suspended and wakes the app on GATT notifications. Apple caps these wakeups, together with background scans, at **5 per rolling 24 hours** [E3][E4]. A G7 delivers 288 readings a day. The budget runs out after about 25 minutes of unattended 5-minute cycles.
3. Background App Refresh is periodic, not continuous. You get about 4 tasks per hour, only with a complication on the active face, a few seconds each, and nothing is guaranteed [E2][E5][E20]. It cannot carry a 5-minute loop.
4. Extended runtime sessions are capped at 10 min, 1 h, 1 h and 30 min, depending on type. They must be started while the app is active, and they cannot be chained from the background [E1]. They cover a bounded, user-started window, not 24/7.
5. `HKWorkoutSession` is the only public session with no documented time limit. It keeps the app executing with the wrist down [E8]. But Apple flags non-workout use as an App Review risk [E20]. Only one workout can run on the watch at a time, so a real workout ends the loop's session [E7]. It also brings workout UI and sensor behavior. A field report shows a BLE link still dropping while a workout keeps the app alive [E31]. (Corrected 2026-11-16: an earlier version also cited Loop PR #2545 here. Loop's head `5aeb4703` has no `HKWorkoutSession` [E32].)
6. Dexcom's own Direct-to-Watch runs 24/7 without a workout session. Per a community codesign inspection, it does this with **restricted, undocumented entitlements**: `com.apple.developer.bluetooth-central-background` and `...bluetooth-central-screen-off-scanning` [E26]. An Apple engineer said the first is "given out very selectively" and only to CGM apps [E24]. A self-built OS-AID app can't realistically get them. Each builder signs with their own team, so each team would need the grant (Inferred).
7. Architectural consequence: an untethered watch loop must treat every cycle as optional. It must stay safe across arbitrarily long gaps, keep the fail-safe in the pump (short temp basals that expire), and run a dead-man alarm that the loop keeps pushing out. A "24/7 without a workout" goal can't be met on the public platform. The realistic options are a phone-primary loop, or an explicit, bounded, user-started watch session.
8. Physical-hardware experiments are listed in "Experiments". Most of the open questions can't be settled from the simulator or from documentation.

## 1. Scope, method and labels

- Question: can a watch app, without a user-started and user-maintained workout, receive a CGM reading over BLE (G7: advertises, connects briefly, about every 5 min), run the algorithm, and send a BLE command to a pump (Omnipod DASH)? It has to do this reliably, 24/7, overnight, wrist on, screen off.
- Primary sources: Apple developer documentation (fetched as DocC JSON from `developer.apple.com/tutorials/data/documentation/...`), WWDC transcripts (2019 session 251, 2021 session 10005, 2022 session 10135, 2026 lab 8014), Apple Developer Forums answers from Apple staff, App Review Guidelines (last updated 2026-10-16), and Apple Support pages.
- Supplementary sources, for observed behavior: Dexcom's Direct-to-Watch HCP material, xDrip4iOS 7.2.0 Direct-to-Watch code and release notes, Loop PR #2545 field test reports, and developer forum reports. Trio experimental code was **not** used as platform evidence.
- Labels: **Verified** (I read the primary text), **Inferred** (my reasoning from verified facts), **Unverified** (a third-party claim or a report I couldn't confirm). In the mechanism tables, the "Documented guarantee", "Observed behavior" and "Assumption" columns are kept strictly apart.
- Periodic vs continuous: *continuous* means the process keeps executing (it is not suspended) for the whole window. *Periodic* means the system wakes the process for short bursts at times the system picks. A 5-minute loop needs either continuous execution or a periodic wakeup that is guaranteed and aligned with the sensor's own timing. watchOS offers neither without restrictions.

## 2. What the loop needs from the platform

| ID | Requirement | Notes |
|---|---|---|
| R1 | Wake within the G7's brief connection window about every 5 min, or keep a connection that delivers each reading | The G7 sends readings "only briefly, once every 5 minutes" (Dexcom FAQ, via search, Unverified wording) [E28] |
| R2 | CPU time to run the algorithm (oref determine-basal) after each reading | Seconds of CPU. Watch cores are slower (WWDC26 lab) [E21] |
| R3 | Outbound BLE connect to the pump and a full command/response exchange | DASH: connect, session, command, response. Exact duration not measured here (Unverified) |
| R4 | Do R1–R3 with the wrist down, screen off, overnight, without user input | Core requirement |
| R5 | Survive or recover from suspension, termination, reboot and watch lock | Including mid-command interruption |
| R6 | Alert the user when the loop stops | Must work while the app is not running |

## 3. Mechanism analysis

### 3.1 Foreground, frontmost and Always On

| Aspect | Documented guarantee | Observed behavior | Assumption |
|---|---|---|---|
| Wrist down | App goes *inactive* but stays frontmost "usually two minutes", then goes to the background and is suspended. The user can change Return to Clock per app, max **1 hour** (watchOS 8+). Pressing the crown or covering the screen ends frontmost immediately [E10] (Verified) | - | An inactive frontmost app keeps executing (Inferred from "before transitioning to the background and becoming suspended") |
| Always On | The UI keeps showing while frontmost or in a background session. Updates are low-frequency [E10] (Verified). The doc says Always On isn't on SE or Series 4 and earlier. That note may predate SE 3 (Unverified for SE 3) | - | - |

- Permits: full execution and BLE while the user looks at the app, plus up to 1 h frontmost after wrist-down, if the user sets that.
- Does not permit: anything past 1 h. Any dismissal ends it.
- Needs user interaction: yes. Continuous, but bounded. Doesn't survive suspension.
- Fit for AID: only as the "attended" path (setup, pairing, manual bolus). Not a loop host.
- Entitlements/review: none.

### 3.2 WKExtendedRuntimeSession

Verified from "Using extended runtime sessions", `WKExtendedRuntimeSession`, `start(at:)`, the error and invalidation enums, and `WKBackgroundModes` [E1][E6]:

| Type (WKBackgroundModes value) | Runtime | Schedulable | Time limit | Notes |
|---|---|---|---|---|
| Self care (`self-care`) | Frontmost | No | 10 min | Ends if the user leaves the app |
| Mindfulness (`mindfulness`) | Frontmost | No | 1 h | Ends if the user leaves the app |
| Physical therapy (`physical-therapy`) | Background | No | 1 h | Runs even if the user switches apps |
| Smart alarm (`alarm`) | Background | Yes, up to 36 h ahead, one at a time | 30 min | Must call `notifyUser(hapticType:)` during the session. Otherwise the system "displays a warning and offers to disable future sessions" |
| Underwater depth (`underwater-depth`) | Frontmost | Auto | Until >10 min unsubmerged | Ultra only, needs an Apple-supplied submersion entitlement [E9] |
| Health monitoring | - | - | - | Named in WWDC19 session 251 as entitlement-gated [E11]. It isn't in current docs, and DTS (Mar 2026) knows of no health-monitoring entitlement [E20] |

Rules (Verified [E1]):
- One extended-runtime type per app. It can be combined with `workout-processing` [E6].
- "You must always start or schedule the extended runtime session when your app state is in the `active` state." Error codes include `mustBeActiveToStartOrSchedule`, `barDisabled` (the user disabled Background App Refresh) and `exceededResourceLimits` (sustained CPU).
- Invalidation reasons include `expired`, `resignedFrontmost` and `suppressedBySystem`.
- During a session the app "can continue to communicate with a Bluetooth device, process data, or play sounds or haptics, even after the watch's screen turns off."
- "Select a session type based on the app's intended use—not based on the features that the session provides."
- A scheduled alarm session relaunches a terminated app (`handle(_:)`). If the delegate isn't set there, the session ends.

| Aspect | Documented guarantee | Observed behavior | Assumption |
|---|---|---|---|
| Duration | Hard caps per type (above) | Device-only bug (fixed in a later watchOS, per the reporter): after invalidating a session, new sessions failed with `sessionInProgress` until reboot [E35] (Unverified, single report, watchOS 10.4 era) | - |
| Chaining | Start or schedule only while active | - | No session can be started from inside an expiring background session, so unattended coverage ends when the cap is hit (Inferred) |
| Smart alarm overnight | Up to 36 h ahead, 30 min, haptic required | - | A loop disguised as an alarm would buzz the user, and only covers 30 min (Inferred) |

- Permits: continuous execution and BLE for a bounded window (max 1 h background, physical therapy).
- Does not permit: 24/7, chaining from the background, or a start without the app being active.
- Needs user interaction: yes (an active app at start). Continuous within the window. Doesn't survive expiry. A smart-alarm session survives app termination before its start time.
- Fit for AID: not as the loop host. At most it could cover a short, user-initiated bridge.
- Entitlements/review: background mode only, but using a type outside its "intended use" is a misuse and review risk (App Review 2.5.4 "intended purposes" [E19]) (Inferred).

### 3.3 HKWorkoutSession

Verified [E7][E8][E12][E13]:
- Requires the HealthKit capability, workout-type authorization, and the `workout-processing` background mode.
- "Your app continues to run throughout the entire workout session, even when the user lowers their wrist or interacts with a different app. When the user raises their wrist, your app reappears". A workout icon shows on the watch face.
- Sensors are tuned for the activity. "All workout sessions generate high-frequency heart rate samples."
- "Apple Watch runs one workout session at a time. If a second workout starts while your workout is running, your HKWorkoutSessionDelegate object receives an HKError.Code.errorAnotherWorkoutSessionStarted error, and your session ends."
- "If your app uses an excessive amount of CPU while in the background, watchOS may suspend it."
- It is started while the app is in the foreground [E5]. The phone can start it through `startWatchApp`, which needs the phone, so it's not untethered (Inferred).
- Crash during an active workout: the system relaunches the app and calls `handleActiveWorkoutRecovery()`. The app then calls `recoverActiveWorkoutSession` [E12][E13].
- An ended session can't be restarted or reused (Apple doc for `HKWorkoutSessionState.ended`, via search snippet; Unverified wording).
- No documented maximum duration (Verified absence in the pages read).
- Separating physical-therapy runtime from workouts "keeps the range-of-motion exercise from impacting the user's Move and Exercise rings" [E1]. This implies workout sessions do count toward the rings (Inferred).

| Aspect | Documented guarantee | Observed behavior | Assumption |
|---|---|---|---|
| Keeps executing wrist-down | Yes, for the session [E8] | 1 Hz BLE notifications kept arriving after backgrounding, so the app wasn't suspended [E31] | - |
| BLE during workout in background | Not stated beyond "foreground or during a background session" being allowed to connect (WWDC21) [E15] | Persistent BLE link torn down about 3 min 20 s after backgrounding, `error == nil`, despite `workout-processing` + `bluetooth-central` (no CGM entitlement). Single report, Sep 2026, no Apple answer [E31] (Unverified) | The background-BLE budget may apply on top of workout runtime (Unverified). Fresh short connections (G7 style) may behave differently from one long link (Unverified) |
| Loop-type use | - | Corrected 2026-11-16: Loop PR #2545 ("Sport Mode") head `5aeb4703` contains no `HKWorkoutSession`. Only an `xcconfig` comment mentions "HealthKit for the workout session", and the PR body calls a workout keepalive "a separate discussion" [E32]. Its watch runs on Bluetooth alert wakes, holding each task up to 25 s (`ExtensionDelegate`, PR diff). So its tester reports (about half of Direct-to-Watch readings missed on a walk, the phone repeatedly taking control back overnight because the watch "was not looping", heavy battery drain [E33]) are evidence for the public Bluetooth-alert path (3.6), not for workouts (Unverified, single tester, confounded) | - |
| Review | DTS: "using an active workout session in a non-workout app to extend the background execution time risks an App Review rejection" [E20] | - | Trio is self-built and not App Store distributed, so App Review is mostly moot. TestFlight internal testing has no Beta App Review (Inferred, not verified here). It's still a policy and ecosystem risk |
| Battery | Apple rates "workout tracking" at up to 7 h (SE 3), 10 h (Series 12), 18 h (Ultra 4) for GPS outdoor runs with HR on [E23] | Dexcom warns of battery impact even without a workout [E27] | A non-GPS workout costs less than these figures but much more than idle. An all-day workout probably doesn't last a waking day on non-Ultra models (Unverified, needs E8) |

- Permits: continuous execution with no documented time cap.
- Does not permit: starting without the app in the foreground (no phone), coexistence with the user's real workouts, or invisibility (icon, app returns on wrist raise, workout data and rings).
- Needs user interaction: yes, to start. Continuous. Survives a crash (recovery relaunch). Reboot: no documented recovery (Verified absence).
- Fit for AID: the only public candidate for hours of continuous runtime. It fails the task's own constraint (no user-maintained workout). It also has a documented single-session conflict and unresolved BLE-teardown reports.
- Entitlements/review: HealthKit plus a background mode. Rejection risk if App Store distributed.

### 3.4 Other background sessions: location, audio

- Verified [E5]: "Apps that support workouts, audio playback, or location updates can continue to run in the background until the current session ends", started in the foreground. With `allowsBackgroundLocationUpdates` and the `location` mode, "Core Location configures the system to keep the app running to receive continuous background location updates" [E14].
- Observed: an Apple DTS reply (Sep 2026) confirms Core Location delivery gives a phoneless watch app execution time to run an upload [E34].
- Assumption: continuous GPS to keep a dosing loop alive is a misuse (App Review 2.5.4 "intended purposes" [E19]). It shows a location indicator and costs a lot of battery. Background audio needs audio actually playing. Neither is a credible design (Inferred).

### 3.5 Background App Refresh (WKApplicationRefreshBackgroundTask / `.appRefresh`)

Verified [E2][E5][E16]:
- "approximately four tasks per hour for each app with a complication on the active watch face. All the complications on the current watch face share this budget."
- "only a few seconds of background execution time". Only one scheduled refresh at a time. The task fires "no earlier than" the preferred date and can be deferred or throttled: low battery, poor conditions, "high-priority activities, such as exercising".
- "don't expect the system to trigger every background task. Design a fallback mechanism".
- watchOS 8+: you can reconnect a known BLE peripheral during BAR. "Core Bluetooth would automatically terminate the connection at the end of the next Background App Refresh" if not finished (WWDC21) [E15].
- DTS (Mar 2026): without an active complication you may get "less than 4 updates per hour". Having one "adds the priority of the app ... no matter the complication is based on ClockKit or WidgetKit". Widget timeline reloads don't count against the app budget [E20].
- Low Power Mode: "Background app refresh happens less frequently" [E22].
- HealthKit background delivery shares this same budget on watchOS [E17].

| Aspect | Documented guarantee | Observed behavior | Assumption |
|---|---|---|---|
| Cadence | About 4/h, best effort | Irregular delivery reported (forum OP in [E20]) | Best case ≈ every 15 min. Below CGM cadence |
| Window | A few seconds | - | A G7 advertises briefly. A BAR window rarely overlaps the advertising window. WWDC21 says the accessory "must advertise frequently" for BAR to work [E15], and the G7 doesn't (Inferred) |
| DASH command | - | - | A full DASH session plus command may not fit in "a few seconds". Must be measured (E5) |

- Permits: periodic, short, unguaranteed work, including BLE.
- Does not permit: 5-minute cadence, guaranteed timing, long exchanges.
- Needs user interaction: no (complication needed). Periodic. Relaunches a terminated app (Verified, "launches your app in the background").
- Fit for AID: no, not as the primary loop. Usable as a supplementary "catch-up and status" wake.
- Entitlements/review: none.

### 3.6 Core Bluetooth on watchOS

Version history (Verified unless marked):

| watchOS | Background BLE capability | Source |
|---|---|---|
| ≤7 | "You can only connect to Bluetooth devices while your app is in the foreground or during a background session" | WWDC21 [E15] |
| 8 | Plus: connect to a known peripheral during Background App Refresh. A connection still open at the end of the next BAR is auto-terminated | WWDC21 [E15], doc [E2] |
| 9+ (Series 6 or later) | Plus: "the system can retain your connection to the peripheral, even after suspending your app". GATT notify/indicate changes wake the app (`WKBluetoothAlertRefreshBackgroundTask` / `.bluetoothAlert`). Background scanning for specific service UUIDs. Disconnect while backgrounded gives "brief" runtime to call `connect` again | WWDC22 [E4], doc [E2][E3] |
| 10, 11, 26, 27 | No change to these rules found in docs or WWDC sessions read | Absence of evidence. The current doc still states the 5/24 h budget (fetched 2026-11-15) [E2] |

watchOS 9+ limits (Verified [E2][E3][E4]):
- "The system limits your app to five background-scan or timely alert opportunities in a rolling 24-hour window. The opportunities become available 24 hours after their use, and the entire budget refreshes when the user launches your app."
- Near or over the limit: `CBError.leGattNearBackgroundNotificationLimit` / `leGattExceededBackgroundNotificationLimit`. Once exceeded, the app "will revert back to watchOS 8 behavior, where there will be no background connection and only background app refresh" (WWDC22).
- "The amount of time you get to process each event is very short ... enough to alert the user" (WWDC22).
- "there is a limit of two Bluetooth connections for each app" (WWDC22).
- A device "on the edge of Bluetooth range" that repeatedly disconnects gets a reduced reconnection range (WWDC22).
- Background timely alerts and background scanning "require Apple Watch Series 6 or later" (WWDC22).
- `allowDuplicatesKey` is foreground-only. First-time setup and pairing happen in the foreground (WWDC21/22).
- Apple's example use: "Use an opportunity to present time-sensitive information, such as a significant rise in blood glucose levels" [E2]. That is an alert use, not continuous data collection.

State restoration and relaunch:

| Aspect | Documented guarantee | Observed behavior | Assumption |
|---|---|---|---|
| Restoration API | `CBCentralManagerOptionRestoreIdentifierKey` and `centralManager(_:willRestoreState:)` are marked available on watchOS 2.0+ [E18] (Verified availability only) | Third-party summaries of the WWDC21 table list preservation/restoration as unsupported on watchOS (Unverified, table not in transcript text). xDrip4iOS 7.2.0 passes a restore identifier on watch and comments that "watchOS restoration can reuse the same pending connection after an app update" [E29] (Unverified behavior) | Availability ≠ behavior. Don't rely on restoration on watch until E3 is done |
| Relaunch rules | TN3115 is **iOS-only**. Since iOS 26, iOS relaunch requires AccessorySetupKit [E30]. No watchOS equivalent found (Verified absence) | Dexcom onboarding warns users not to swipe-kill the watch app [E27] | Force-quit probably stops BLE wakeups on watch too (Inferred, test E4) |
| Background-scan relaunch | "The Apple Watch discovers this peripheral and launches the app in the background" (WWDC22) [E4] (Verified) | - | Counts against the 5/24 h budget |
| Connection events | `registerForConnectionEvents(options:)` available watchOS 6+ [E18] (Verified availability) | - | No evidence that it wakes a suspended watch app (Unverified) |
| After the budget is exhausted | Reverts to watchOS 8 behavior until reset [E4] | watchOS 26.2: "once the system terminates the BLE connection after background allowance is exceeded, the app never regains background BLE capability, even after the user returns to the foreground" (single report, no Apple reply) [E36] (Unverified) | - |

Distribution caveat:
- Observed: 2018–2021 forum reports say App Store Connect rejected uploads of watch extensions declaring `UIBackgroundModes` `bluetooth-central` without `com.apple.developer.bluetooth-central-background` ("Missing entitlement") [E24][E25]. One developer reported that the mode worked in a debug (Xcode) build.
- Unverified: whether this upload validation still applies in 2026 to single-target watch apps. Trio users mostly build through GitHub Actions and upload to TestFlight (`fastlane/Fastfile:230` `upload_to_testflight`, Verified at baseline). Trio's baseline watch app declares no background modes and has no entitlements file (Verified: `Trio Watch App/Info.plist` at `ad6c668`). This must be checked before any design depends on `bluetooth-central` on the watch (E1).

Summary for the loop:
- Permits: a background connection plus wake on GATT changes, 5 times per 24 h unattended. Unlimited when the user interacts.
- Does not permit: 288 unattended wakes per day.
- Needs user interaction: to reset the budget. Event-driven, but budget-capped. Partially survives suspension (the system holds the link). Termination and force-quit: unknown.
- Fit for AID: not as the 24/7 loop driver. Fits "alert the user when something is wrong", which is exactly Apple's stated intent.

### 3.7 Restricted CGM entitlements (the Dexcom path)

| Aspect | Documented guarantee | Observed behavior | Assumption |
|---|---|---|---|
| `com.apple.developer.bluetooth-central-background` | Not in Apple's public entitlement reference (doc URL returns 404, Verified 2026-11-15) | Apple engineer (Aug 2019): "required for apps to use CoreBluetooth background capabilities on the watch ... a special entitlement given out very selectively, and currently it is only available to developers with watchOS apps communicating with Continuous Glucose Monitoring devices" [E24] | Still CGM-only (Unverified, 2019 statement). A Sep 2026 forum poster assumes the same [E31] |
| `com.apple.developer.bluetooth-central-screen-off-scanning` | Not documented (404, Verified) | Present in the Dexcom G7 watch extension next to the background entitlement and critical alerts. No workout and no extended-runtime entitlement found (codesign inspection by a Trio contributor, posted Apr 2026) [E26] (Unverified by me) | It lifts screen-off scanning restrictions (Inferred from the name) |
| How to obtain | No public request form found (Verified absence) | Not in Xcode capabilities or portal Capability Requests (forum report, via search) [E25] | Granted per App ID / team. Each self-builder's team would need it, which makes it impractical for OS-AID (Inferred). Pump control is likely outside a "CGM" grant (Inferred) |
| Behavior granted | - | Dexcom delivers readings and alerts 24/7 on Series 6+ / watchOS 10+, with a "keep the app running" warning and a battery note [E27][E28] | The entitlement removes or raises the 5/24 h budget (Inferred from Dexcom working all day) |

Fit for AID: this is the only observed mechanism that matches R1/R4 without a workout. It isn't available to Trio's distribution model, and it covers only the CGM side.

### 3.8 Other WKBackgroundTask types

Verified [E5][E2]: URLSession (wake on transfer events), WatchConnectivity (phone-to-watch transfers), Snapshot, IntentDidRun (Siri), RelevantShortcut, BluetoothAlert (3.6), ApplicationRefresh (3.5). Each gives "a few seconds" and is triggered by an external event.

- Fit: none provides periodic runtime independent of the phone or a server. URLSession needs network, and phoneless cellular background transfers were observed stalling until Wi-Fi was available [E34] (Unverified, single report).

### 3.9 Push and complication-driven wakeups

| Mechanism | Documented guarantee (Verified) | Fit |
|---|---|---|
| Background push (`content-available`) | "wakes or launches your app to the background and gives it 30 seconds". "low priority ... doesn't guarantee their delivery ... don't try to send more than two or three per hour" [E37] | No. Needs a server, network and a budget |
| PushKit complication push | Complication must be on the active face, 50/day, time counts against the complication budget [E38] | No |
| `WidgetPushHandler` (watchOS 26+) | Push-driven widget reloads and relevance refreshes [E39] | No app runtime (Inferred: it reloads widgets, not the app) |
| WatchConnectivity widget updates (watchOS 27) | Mentioned by Apple engineers in the WWDC26 watchOS lab [E21] (Verified via transcript summary) | Needs the phone |

### 3.10 WatchConnectivity

Verified [E40][E5]:
- The watch side is reachable when "running in the foreground, or ... with a high priority in the background (for example, during a workout session ...)".
- "Calling this method from your iOS app does not wake up the corresponding WatchKit extension."
- Background transfers wake the watch app through `WKWatchConnectivityRefreshBackgroundTask`.
- `transferCurrentComplicationUserInfo` is limited to 50/day with an active complication [E41].

Fit: only for tethered handoff and sync. Useless when the phone is absent, by definition.

### 3.11 Smart Stack, widgets, complications, Live Activities

- Verified: ActivityKit is listed for iOS/iPadOS/macOS only, not watchOS [E42]. Live Activities show "on a paired Apple Watch" when the iPhone app starts them [E42]. DTS: widget timeline reloads don't consume app background budget, and a complication on the active face raises the app's BAR priority [E20]. WWDC26 lab: watch-face widgets get "top tier" refresh budget, typically "every 15 to 20 minutes" [E21].
- Assumption: none of these execute app code on a schedule a loop could use. A complication's value is the BAR priority boost it gives (Inferred).
- Fit: display only, plus the BAR priority side-effect.

### 3.12 HealthKit background delivery

Verified [E17]:
- Needs `com.apple.developer.healthkit.background-delivery`.
- On watchOS "most data types have an hourly maximum frequency". `immediate` is only for listed event types (heart-rate events, falls, and similar), not glucose.
- Updates "share a budget with WKApplicationRefreshBackgroundTask tasks".

Fit: no.

### 3.13 Notifications (dead-man and alarms)

- Verified [E43]: Critical Alerts are available on watchOS 5+ with an Apple-issued entitlement ("ignore the mute switch and Do Not Disturb"). The Dexcom watch extension carries it [E26]. Loop's Sport Mode watch entitlements use `time-sensitive` instead [E32].
- Assumption: a local notification scheduled in advance fires without the app running (standard UserNotifications behavior, not re-verified for watchOS here). That makes it the right primitive for a "loop not running" dead-man alarm: schedule it N minutes ahead and push it out on every successful cycle (Inferred). xDrip4iOS ships a 20-minute "Missed Readings" watch notification [E29].
- Fit: needed for R6 regardless of execution model.

### 3.14 Termination, reboot, lock, Low Power Mode, battery

| Aspect | Documented guarantee | Observed behavior | Assumption |
|---|---|---|---|
| Crash during workout | Relaunch + `recoverActiveWorkoutSession` [E12][E13] | - | - |
| Crash or termination otherwise | Background tasks launch a purged app in the background [E5] | - | No relaunch until the next system-initiated task (Inferred) |
| Reboot | No documented auto-launch for any third-party watch app (Verified absence) | Loop Sport Mode handles a restart by asking the phone, else resumes at the first sensor reading [E32] (design statement, not platform proof) | After a reboot nothing runs until the user opens the app or a BLE/BAR event fires. Whether pending BLE connections survive a reboot is unknown (E6) |
| Wrist detection | With a passcode, the watch locks when removed (Apple Support) [E44] | - | Data-protection classes may make files or keychain items unreadable while locked (Unverified, E7) |
| Low Power Mode | Turns off Always On and background heart rate. BAR and complications update less often. Without the iPhone, Wi-Fi and cellular are off. Prompted at 10%, auto-on for Apple Workout app workouts [E22] | - | Effect on background BLE unknown (E9) |
| Battery | Apple workout-tracking figures above [E23] | Dexcom: "potential battery life impact" [E27]. Loop tester: an old Series 7 fully discharged overnight from 45% with control on the watch; another run with the watch mostly in control from noon to 08:00 ended at 57% [E33] (confounded) | Any continuous mechanism probably fails a 24 h day on small, older watches (Unverified) |

## 4. watchOS version and hardware matrix

| | watchOS 10 | watchOS 11 | watchOS 26 | watchOS 27 |
|---|---|---|---|---|
| ERS types / limits | As 3.2 | Same (no change found) | Same (no change found) | Same (no change found) |
| Background BLE (Series 6+) | watchOS 9 model, 5/24 h | Same | Same. Field report of not regaining background BLE after the budget is hit (26.2) [E36] | Same (no change found) |
| BAR | ≈4/h with complication. WidgetKit complications count [E20] | Same | Same | Same |
| New relevant APIs | WidgetKit complications, Smart Stack | Live Activities from iPhone shown on watch (Inferred from [E42]) | `WidgetPushHandler`, APNs widget refresh [E39][E21] | WatchConnectivity widget updates [E21] |
| Device floor | Series 4+ (not verified here) | not verified here | not verified here | Series 9–12, SE 3, Ultra 2–4 (apple.com/os/watchos, via search) [E45] |
| Notes | Trio watch deployment target is 10 (Verified `project.pbxproj`). Dexcom D2W needs watchOS 10 + Series 6 [E28] | - | Series 6–8, SE 2 and Ultra 1 stay on 26.x (Inferred from the 27 floor) | - |

"No change found" means I found no documentation or session describing a change. It is not proof of no change.

## 5. Implementation evidence (observed, not guarantees)

| Source | What it shows | Label |
|---|---|---|
| Dexcom G7 Direct to Watch [E27][E28] | Sensor to watch directly, phone optional after pairing. Series 6+, watchOS 10+. Onboarding warns "keep the app running" (no swipe-kill). Falls back to phone data when direct fails. Battery impact noted | Verified (Dexcom material) |
| Dexcom watch entitlements [E26] | Restricted BLE background and screen-off-scanning entitlements, critical alerts, no workout | Unverified (third-party codesign, not reproduced) |
| xDrip4iOS 7.2.0 Direct to Watch [E29] | Uses the public `.backgroundTask(.bluetoothAlert)` path with `bluetooth-central`. Handles the `leGatt...NotificationLimit` errors with "watchOS Bluetooth background limit reached. Open this app to reset it." Release note: "Background collection depends on watchOS. Test it on your Watch before relying on it" | Verified (code and release notes read) |
| Loop PR #2545 Sport Mode [E32][E33] | Watch loop on Bluetooth alert wakes, no workout session (corrected 2026-11-16), real DASH + G7 tested. Missed reads, overnight handbacks to the phone, battery drain | Unverified (single tester, early PR) |
| Forum: BLE in workout [E31] | Link dropped about 3:20 after backgrounding despite workout + `bluetooth-central` | Unverified |
| Forum: budget not regained [E36] | watchOS 26.2: background BLE lost permanently after the budget was exceeded | Unverified |
| Trio PR #1749 (G7 D2W) body [E46] | Author notes "watchOS shows the Bluetooth pairing request only while Trio is on screen" | Unverified (author statement). Consistent with the WWDC21 "first-time setup in foreground" rule |

## 6. Capability matrix against the requirements

| Mechanism | R1 5-min CGM | R2 CPU | R3 pump cmd | R4 unattended 24/7 | R5 recover | Continuous / periodic | Entitlement / review |
|---|---|---|---|---|---|---|---|
| Frontmost | Yes (≤1 h) | Yes | Yes | No | No | Continuous, bounded | None |
| ERS physical therapy | Yes (≤1 h) | Yes | Yes | No | No | Continuous, bounded | Intended-use risk |
| ERS smart alarm | 30 min | Yes | Yes | No (haptic, 1 scheduled) | Relaunch at start | Continuous, bounded | Intended-use risk |
| HKWorkoutSession | Unknown, untested (E8) | Yes | Probably | No by task definition. Ended by any other workout | Crash recovery only | Continuous, unbounded | Rejection risk (DTS) |
| Location / audio session | Unknown | Yes | Unknown | Technically, with abuse | No | Continuous | 2.5.4 misuse |
| BAR | No | Seconds | Unlikely | No | Yes (launches) | Periodic ≈15 min, best effort | None |
| Background BLE (public) | 5/day | "Very short" | Unlikely | No | Partial | Event-driven, capped | `bluetooth-central` (upload check open) |
| Restricted CGM entitlement | Yes (Dexcom) | Unknown | Not covered | Yes for CGM | Unknown | Event-driven, uncapped (Inferred) | Not obtainable for OS-AID |
| Push / WC / HealthKit | No | Seconds | No | No | Yes | Periodic or event, needs phone or server | Varies |

## 7. Architectural implications

### 7.1 Viable execution models

1. **Phone-primary loop, watch as display and alerts (status quo).** Fully viable. The watch can add Direct-to-Watch CGM display and alarms through the public background-BLE path, budget permitting. This needs nothing new from the platform.
2. **Bounded, explicitly user-started watch session ("untethered window").** The user starts it on the watch, it shows a clear running state, it has a defined end, and it hands back to the phone. The only public host for multi-hour continuous runtime is `HKWorkoutSession`. That is exactly what this task tries to avoid. It brings the documented single-workout conflict, workout UI and Health side effects, App Review risk if ever store-distributed, battery cost, and unresolved BLE-teardown reports. Extended runtime sessions could host at most a ≤1 h bridge. Viable only as an opt-in, time-limited mode with the phone loop as the default and fallback (Inferred).
3. **24/7 unattended watch loop without a workout.** Not viable on the public platform for watchOS 10–27. BAR is too sparse and unguaranteed. Background BLE is capped at 5 wakes per day. Extended runtime sessions are capped and can't be chained. The working precedent (Dexcom) uses CGM-only restricted entitlements that a self-built app can't get (Inferred from Verified facts).
4. Speculative (YAGNI until Apple changes policy): asking Apple for the CGM entitlement on behalf of the Foundation. Even if granted, it would be bound to one team's App ID, which conflicts with self-build distribution. It also wouldn't obviously cover pump control (Inferred).

### 7.2 What the loop must assume about missing cycles

- **Any cycle can be skipped, for any length of time, without notice.** That includes mid-exchange: the process can be suspended or killed between "command sent" and "response read".
- **Delivery state is four-valued.** Requested, accepted by the pump, executed, and confirmed by a later status read. After an interrupted window the watch may hold an unconfirmed command. The next run must read pump state (status and history) before any new dosing decision, and must never re-issue blindly.
- **The fail-safe lives in the pump, not the watch.** Temp basals must be short enough that a dead watch reverts to scheduled basal on its own. No dose may depend on a later cycle happening. Agent E and the safety docs should own the exact bounds. This document only establishes that the platform gives no continuity guarantee.
- **No catch-up dosing.** A run after a gap computes from fresh CGM data and confirmed IOB only. It doesn't "make up" missed cycles. CGM data older than the loop's freshness limit means no automated change.
- **The dead-man alarm is mandatory.** A local notification is scheduled ahead and pushed out each successful cycle, ideally a critical or time-sensitive alert where available. Silence must never mean "all good".
- **Unattended loss is expected after reboot, force-quit, budget exhaustion, a user's own workout (workout model), Low Power Mode, or battery death.** Each needs a visible state and a defined handback to the phone.
- **Two concurrent BLE connections per app** (WWDC22) exactly fits G7 + DASH. Any third (a second sensor during changeover, a Bluetooth glucometer) needs serialization (Inferred).

### 7.3 Must be verified on physical hardware

The simulator can't settle any of these. Background BLE, budgets, wrist-down, lock and Low Power Mode need real devices. WWDC21/22 samples "run only on physical devices" [E3].
- Series 6–8 on watchOS 26.x and Series 9+ on watchOS 27.x, at minimum one of each. Ultra and SE 3 if battery claims matter.
- Real G7 (or Stelo) and a real DASH pod or a pod emulator. Overnight, worn, phone out of range (powered off or in Faraday-isolated storage).

### 7.4 Experiments that would settle the open questions

| ID | Question | Method | Pass criterion |
|---|---|---|---|
| E1 | Does App Store Connect still reject a watch app with `bluetooth-central` and no CGM entitlement? | Upload a minimal single-target watch app via the Trio browser-build path (fastlane `upload_to_testflight`) | Upload accepted or rejected, with the ITMS code recorded |
| E2 | Real-world public background-BLE behavior with a G7 | Watch app with `.bluetoothAlert` and `bluetooth-central`. G7 connects every 5 min. Log every wake, every `leGatt*` error and every reading, 24 h unattended, wrist on, phone off | Count of readings received vs 288. Time to first limit error. Behavior after the limit (watchOS 8 fallback vs permanent loss, cf. [E36]) |
| E3 | Does CB state restoration relaunch a terminated watch app? | Same app with a restore identifier. Terminate from Xcode, then wait for a G7 cycle | `willRestoreState` called or not, and latency |
| E4 | Force-quit, reboot, and Bluetooth toggle effects | As E3, with swipe-kill, reboot (with and without unlock) and Bluetooth toggle | Which actions stop wakeups until the app is opened |
| E5 | Is a BAR or `.bluetoothAlert` window long enough for a full DASH command exchange? | Timestamp connect → session → command → response inside each runtime type | Exchange completes before expiry in ≥99% of attempts, or doesn't |
| E6 | Does a pending BLE connect survive reboot? | Pending `connect` to a pod or emulator, reboot the watch, don't unlock, then unlock | Connection observed before or after unlock, or never |
| E7 | Locked-watch behavior | Remove the watch (passcode on), run a BLE-woken cycle | Can the app read its stores and keychain while locked? |
| E8 | Workout-session cost and stability for 24 h | Indoor "other" workout, no GPS, loop-like duty cycle, worn | Battery % per hour per model. Session end events. BLE drops (cf. [E31]). Rings and Health side effects |
| E9 | Low Power Mode impact | Repeat E2/E8 with Low Power Mode on | Change in wake count and BLE behavior |
| E10 | Workout conflict | Start Apple's Workout app during a loop workout | Confirm `errorAnotherWorkoutSessionStarted` and the time to detect it |
| E11 | Extended runtime bridge | Physical-therapy session: BLE cycles for 60 min wrist-down, then expiry | Readings and commands during the window. Clean expiry handling |
| E12 | Dead-man alarm | Schedule a local notification 15 min ahead, kill the app, keep the watch locked and in Low Power Mode | Notification fires on time, with critical/time-sensitive behavior as configured |
| E13 | Two-connection limit | G7 + DASH + a third peripheral in background | Third connection refused or one dropped |
| E14 | Confirm Dexcom entitlements | Re-run the codesign inspection on a current Dexcom G7 IPA | Entitlement list matches [E26] or not |

### 7.5 YAGNI notes

- Needed now: a missed-cycle-tolerant loop design, a dead-man alarm, pump-side fail-safe assumptions, and experiments E1, E2, E5, E8 and E10 before any architecture decision.
- Speculative: designs that depend on CB state restoration on watch, on chaining extended runtime sessions, on push-driven wakeups, or on getting the CGM entitlement. Don't build for these without the experiments or an Apple policy change.

## Open questions

1. Does the 2018–2021 "Missing entitlement" upload rejection for watch `bluetooth-central` still apply in 2026 (E1)? This decides whether even the public background-BLE path ships through TestFlight.
2. Is `com.apple.developer.bluetooth-central-background` still CGM-only, and does it lift the 5/24 h budget? No current Apple statement found.
3. Does a running `HKWorkoutSession` exempt BLE from background limits? Apple hasn't answered [E31].
4. Does watchOS relaunch a terminated app for BLE events outside the background-scan case? No watchOS equivalent of TN3115 found.
5. Is there any maximum `HKWorkoutSession` duration or system auto-end? Not documented.
6. Does Low Power Mode or watch lock affect background BLE and file access?
7. Exact Omnipod DASH exchange time on watch hardware (E5). This decides whether short runtime windows are even theoretically usable.
8. Do watchOS 26.x or 27.x carry undocumented background changes? No release-note evidence was found. The Apple release notes themselves weren't read.

## Evidence index

All Apple doc URLs were fetched via the DocC JSON mirror at `https://developer.apple.com/tutorials/data/documentation/<path>.json` on 2026-11-15.

| ID | Source | Label |
|---|---|---|
| E1 | Using extended runtime sessions: https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions. Also `WKExtendedRuntimeSession`, `start(at:)`, `WKExtendedRuntimeSessionErrorCode`, `WKExtendedRuntimeSessionInvalidationReason` (same docs tree) | Verified |
| E2 | Using background tasks (incl. "Communicate over Bluetooth", 5/24 h budget): https://developer.apple.com/documentation/watchkit/using-background-tasks | Verified |
| E3 | `WKBluetoothAlertRefreshBackgroundTask`: https://developer.apple.com/documentation/watchkit/wkbluetoothalertrefreshbackgroundtask. Sample: https://developer.apple.com/documentation/watchkit/interacting-with-bluetooth-peripherals-during-background-app-refresh | Verified |
| E4 | WWDC22 10135 "Get timely alerts from Bluetooth devices on watchOS" transcript: https://developer.apple.com/videos/play/wwdc2022/10135/ | Verified |
| E5 | Background execution: https://developer.apple.com/documentation/watchkit/background-execution | Verified |
| E6 | `WKBackgroundModes` possible values: https://developer.apple.com/documentation/bundleresources/information-property-list/wkbackgroundmodes | Verified |
| E7 | `HKWorkoutSession` (one workout at a time): https://developer.apple.com/documentation/healthkit/hkworkoutsession | Verified |
| E8 | Running workout sessions ("Run in the background"): https://developer.apple.com/documentation/healthkit/running-workout-sessions | Verified |
| E9 | Accessing submersion data (underwater-depth session): https://developer.apple.com/documentation/coremotion/accessing-submersion-data | Verified |
| E10 | Designing your app for the Always On state: https://developer.apple.com/documentation/watchos-apps/designing-your-app-for-the-always-on-state | Verified |
| E11 | WWDC19 251 "Extended Runtime for watchOS apps" transcript mirror: https://nonstrict.eu/wwdcindex/wwdc2019/251/ | Verified via mirror (transcript may contain errors) |
| E12 | `handleActiveWorkoutRecovery()`: https://developer.apple.com/documentation/watchkit/wkapplicationdelegate/handleactiveworkoutrecovery() | Verified |
| E13 | `recoverActiveWorkoutSession(completion:)`: https://developer.apple.com/documentation/healthkit/hkhealthstore/recoveractiveworkoutsession(completion:) | Verified |
| E14 | `allowsBackgroundLocationUpdates`: https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates | Verified |
| E15 | WWDC21 10005 "Connect Bluetooth devices to Apple Watch" transcript: https://developer.apple.com/videos/play/wwdc2021/10005/ | Verified |
| E16 | `WKApplicationRefreshBackgroundTask` (≈4/h): https://developer.apple.com/documentation/watchkit/wkapplicationrefreshbackgroundtask. `scheduleBackgroundRefresh(...)` (one at a time) | Verified |
| E17 | `enableBackgroundDelivery(for:frequency:withCompletion:)`: https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:) | Verified |
| E18 | Core Bluetooth symbol availability: `CBCentralManagerOptionRestoreIdentifierKey`, `centralManager(_:willRestoreState:)`, `registerForConnectionEvents(options:)`, `CBConnectPeripheralOptionStartDelayKey` (developer.apple.com/documentation/corebluetooth/...) | Verified (availability only) |
| E19 | App Review Guidelines 1.4.1, 1.4.2, 2.5.1, 2.5.4 (last updated 2026-10-16): https://developer.apple.com/app-store/review/guidelines/ | Verified |
| E20 | Apple Developer Forums 816544 "Extended Runtime API - Health Monitoring", DTS Engineer replies Mar 2026: https://developer.apple.com/forums/thread/816544 | Verified (quotes copied verbatim via fetch) |
| E21 | WWDC26 8014 "watchOS Group Lab" transcript: https://developer.apple.com/videos/play/wwdc2026/8014/ | Verified via fetch summary (speakers partly inferred) |
| E22 | Apple Support "Use Low Power Mode on your Apple Watch" (published 2025-09-18): https://support.apple.com/en-us/108320 | Verified |
| E23 | Apple Watch battery page (Ultra 4, Series 12, SE 3 figures): https://www.apple.com/watch/battery/ | Verified (fetched 2026-11-15) |
| E24 | Apple Developer Forums 109947, Apple engineer reply Aug 2019 on `bluetooth-central-background`: https://developer.apple.com/forums/thread/109947 | Verified (forum text) |
| E25 | Forums 695905 and 692685 (upload "Missing entitlement", debug works): https://developer.apple.com/forums/thread/695905, https://developer.apple.com/forums/thread/692685 | Verified (reports), behavior Unverified |
| E26 | DiaBLE discussion #17, comment 2026-04-10 with Dexcom G7 watch extension entitlements: https://github.com/gui-dos/DiaBLE/discussions/17 | Unverified (third-party inspection) |
| E27 | Dexcom "Direct to Watch" HCP training PDF (MAT-3709 Rev001, 2025): https://dexcomtraining.com/wp-content/uploads/2025/08/G7-Direct-to-Watch-for-HCP_EN_mmol_DTC.pdf | Verified |
| E28 | Dexcom FAQs on watch compatibility and cellular: https://www.dexcom.com/en-us/faqs/what-apple-watches-are-compatible-with-dexcom-g7-direct-to-watch, https://www.dexcom.com/en-us/faqs/do-i-need-to-have-a-cellular-plan-for-my-apple-watch-to-be-able-to-use-direct-to-watch-feature | Verified via search summaries |
| E29 | xDrip4iOS `xDrip Watch App/DataModels/DirectWatchCollector.swift` @ `69d8794411eb4aaca86bdd1223d2d2ed6122df0b`, `xDrip Watch App/xDripWatchApp.swift:37`, `xDrip/Texts/TextsDirectWatch.swift`, `xDrip-Watch-App-Info.plist` (master `f7447f1c70a1`). Release PR: https://github.com/JohanDegraeve/xdripswift/pull/778 | Verified (code read). Behavior Unverified |
| E30 | TN3115 Bluetooth State Restoration app relaunch rules (iOS only, updated 2025-09-15): https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules | Verified |
| E31 | Forums 844843 "Maintaining a Core Bluetooth connection on watchOS for the duration of an HKWorkoutSession" (Sep 2026, no replies): https://developer.apple.com/forums/thread/844843 | Unverified (single report) |
| E32 | LoopKit/Loop PR #2545 body. `Loop.xcconfig` (`LOOP_WATCH_ENTITLEMENTS` comment), `WatchApp Extension/SportMode.entitlements`, `WatchApp/Info.plist` @ head `5aeb470345d7e652f1a84712f0271a91857db5ed`: https://github.com/LoopKit/Loop/pull/2545 | Verified (files read). Agent B owns the Loop analysis |
| E33 | Loop PR #2545 tester comments 2026-11-01, 2026-11-06, 2026-11-07 (public handle marionbarker): https://github.com/LoopKit/Loop/pull/2545 | Unverified (field report) |
| E34 | Forums 843751, DTS accepted answer Sep 2026 (Core Location execution time, phoneless upload): https://developer.apple.com/forums/thread/843751 | Verified (forum text) |
| E35 | Forums 748784 (ERS restart `sessionInProgress` until reboot, Mar–Apr 2024): https://developer.apple.com/forums/thread/748784 | Unverified (reported fixed) |
| E36 | Forums 809670 (watchOS 26.2, background BLE not regained): https://developer.apple.com/forums/thread/809670 | Unverified |
| E37 | Enabling Background Sessions: https://developer.apple.com/documentation/watchkit/enabling-background-sessions. Pushing background updates: https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app | Verified |
| E38 | `PKPushType.complication`: https://developer.apple.com/documentation/pushkit/pkpushtype/complication | Verified |
| E39 | `WidgetPushHandler` (watchOS 26.0+): https://developer.apple.com/documentation/widgetkit/widgetpushhandler | Verified |
| E40 | `WCSession.isReachable`, `sendMessage(_:replyHandler:errorHandler:)`: https://developer.apple.com/documentation/watchconnectivity/wcsession/isreachable | Verified |
| E41 | `remainingComplicationUserInfoTransfers`: https://developer.apple.com/documentation/watchconnectivity/wcsession/remainingcomplicationuserinfotransfers | Verified |
| E42 | ActivityKit (platforms iOS/iPadOS/Mac Catalyst/macOS): https://developer.apple.com/documentation/activitykit | Verified |
| E43 | Critical Alerts entitlement (watchOS 5.0+): https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.critical-alerts. `UNNotificationSound.defaultCritical` | Verified |
| E44 | Apple Support "Lock or unlock Apple Watch" / wrist detection: https://support.apple.com/guide/watch/lock-or-unlock-apple-watch-apd0e1e73b6f/watchos | Verified via search summary |
| E45 | watchOS 27 compatible models: https://www.apple.com/os/watchos/, https://support.apple.com/guide/watch/applewatch-models-apd2054d0d5b/watchos | Verified via search summary |
| E46 | nightscout/Trio PR #1749 body: https://github.com/nightscout/Trio/pull/1749 | Verified (text). Behavior Unverified |
| E47 | Trio baseline `ad6c668`: `Trio Watch App/Info.plist` (no background modes), `Trio.xcodeproj/project.pbxproj` (`WATCHOS_DEPLOYMENT_TARGET = 10`, no watch `CODE_SIGN_ENTITLEMENTS`), `fastlane/Fastfile:230` (`upload_to_testflight`) | Verified |
