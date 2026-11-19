# Upstream Trio architecture as it bears on an untethered watch loop

Agent C, Phase 1 research. Baseline: `nightscout/Trio` `dev` @ `ad6c66876e5ccca8b0a6e1c5b7626ed4caa65926`, read at `~/workspaces/Trio-on-watch`. All `file:line` references are at that SHA unless a submodule SHA is given. The experimental branch was not consulted.

Legend: **V** = Verified (read the code or ran the check), **I** = Inferred from verified facts, **U** = Unverified.

## Executive summary

1. The watch app today is a pure remote control. It compiles 28 Swift files, links no frameworks (no LoopKit, no Core Data model, no algorithm, no Swinject), has no entitlements and no background modes, and refuses every write unless the iPhone is reachable over WatchConnectivity (V).
2. Every loop cycle is started by a newly stored CGM reading. The chain is CGM → `FetchGlucoseManager` → `DeviceDataManager.heartbeat` → `ensureCurrentPumpData` → `recommendsLoop` → `APSManager.loop`. Pump events never start a loop on their own; `pumpManagerRecommendsLoop` is dead code on dev (V).
3. The oref port (`OpenAPSSwift`) imports only Foundation and runs no JavaScript. I compiled its `AlgorithmPackage` source set for `arm64-apple-watchos10.0-simulator` in a scratch copy, and it built cleanly (V). The algorithm is the easiest part to move.
4. The loop around the algorithm is iOS-bound: `UIApplication` background tasks, `UIDevice`, `PumpManagerUI` (LoopKitUI) as the pump type, a `DeviceCatalog` that imports UIKit and every kit, and a `CoreDataStack` that imports UIKit for protected-data checks (V).
5. Pump drivers are the hard blocker. No pump kit in the tree (OmnipodKit, DanaKit, MedtrumKit, MinimedKit) has a watchOS target. LoopKit, CGMBLEKit (G5/G6), G7SensorKit, ShareClient and RileyLinkKit do have watchOS targets, but nobody builds them in Trio today, and LoopKit-watchOS leaves out 21 of the 187 LoopKit sources (V).
6. Pump and CGM managers persist as `rawValue` dictionaries in `Documents/PumpManagerState.plist` and `CGMManagerState.plist` and come back through `init(rawState:)` (V). This is the existing primitive any phone↔watch hand-over of pump control would have to build on.
7. Watch boluses skip `BolusSafetyValidator` on the phone. Max bolus is enforced only by the watch UI cap and by the limits Trio pushes to the pump manager; there is no phone-side max IOB or recent-bolus check (V). Watch commands carry no request ID or timestamp (V). Open PRs #1648 and #1775 address this.
8. Smallest viable direction: make the existing `APSManager`/storage/algorithm path compile for watchOS behind small platform seams, add watchOS targets to one pump kit and one CGM kit, and add an explicit single-owner hand-over of the pump. A second, watch-only loop implementation is not justified by anything found here (I; argued in "Conclusions").

---

## 1. Targets, entry points, entitlements

### 1.1 Native targets (V, `Trio.xcodeproj/project.pbxproj:5279-5421`)

| Target | Product type | SDK / deployment | Sources compiled | Frameworks / packages |
|---|---|---|---|---|
| `Trio` | application | iphoneos, iOS 17.6 (`:6887`) | the whole app incl. `OpenAPSSwift`, `Model/`, storage | Swinject, SwiftDate, Algorithms, SwiftCharts, MKRingProgressView, SlideButton, CryptoSwift, FirebaseCrashlytics, SwiftJWT, ConnectIQ, RoundWhiteDiscKit (`:5306-5318`), plus kit frameworks via the workspace |
| `TrioTests` | unit-test bundle | iOS 17.6 | `TrioTests/**` | host app `Trio` |
| `LiveActivityExtension` | app-extension | iOS 17.6 | 5 files: `LiveActivity*.swift`, `Trio/Sources/Services/LiveActivity/LiveActivityAttributes.swift`, `LiveActivityGlucoseStyle.swift` | WidgetKit, SwiftUI |
| `Trio Watch App` | application | watchos, watchOS **10** (`:7174`) | 28 files (list below) | **none** (empty Frameworks phase, `BDFF79792D25AA870016C40C`) |
| `Trio Watch Complication Extension` | app-extension | watchOS 10 | 1 file: `Trio Watch Complication/TrioWatchComplication.swift` | none |
| `Trio Watch AppTests` | unit-test bundle | watchOS 10 | 1 file: `Trio Watch App Tests/Unit Tests.swift` | none |

Sources in the `Trio Watch App` target (V): every file under `Trio Watch App Extension/` (views, `WatchState.swift`, `WatchState+Requests.swift`, `WatchLogger.swift`, `WatchStateSnapshot.swift`, helpers, `TrioWatchApp.swift`) plus four files shared from the iOS tree: `Trio/Sources/Models/WatchMessageKeys.swift`, `Trio/Sources/Models/NotificationIdentifiers.swift`, `Trio/Sources/Logger/Watch/WatchLogEntry.swift`, `Trio/Sources/Logger/Watch/WatchLogRing.swift`.

Notes:
- **Naming trap (V).** The folder `Trio Watch App Extension/` holds the real watch app sources. The folder `Trio Watch App/` holds `TrioWatchApp.swift` (an `AppIntent`) and `TrioWatchAppExtension.swift` (`@main AppIntentsExtension`), plus an `Info.plist` for an App Intents extension. Their file references (`BDFF7A91…`, `BDFF7A92…`) belong to no Sources phase (`project.pbxproj:1987-1988, 4442-4443`, nothing else), so they are not compiled. There is no separate "Watch extension" target; the watch is a single-target SwiftUI app.
- Watch entry point: `Trio Watch App Extension/TrioWatchApp.swift:4` (`@main struct TrioWatchApp: App`), whose root view is `TrioMainWatchView`.
- iOS entry point: `Trio/Sources/Application/TrioApp.swift`. `loadServices()` resolves the long-lived services (`:68-92`). Core Data is initialised first, asynchronously (`deferredInitialization`, `:189-220`).
- The iOS app embeds the watch app (`Embed Watch Content`, `project.pbxproj:754, 1219`). The watch Info.plist is generated (`GENERATE_INFOPLIST_FILE = YES`) and sets only `WKCompanionAppBundleIdentifier` (`:7159`). There is no `WKRunsIndependentlyOfCompanionApp` and no `WKBackgroundModes` key (V). I take that to mean the app is installed as companion-dependent (I).

### 1.2 Entitlements, App Group, background modes (V)

- Only one entitlements file is in use: `Trio/Resources/Trio.entitlements`, referenced by the `Trio` target alone (`project.pbxproj:6877, 6923`). It grants APNs, HealthKit (+ background delivery), NFC tag reading, time-sensitive notifications and the App Group `$(APP_GROUP_ID)` (`Trio.entitlements:5-22`).
- `APP_GROUP_ID = $(TRIO_APP_GROUP_ID)` = `group.org.nightscout.$(DEVELOPMENT_TEAM).trio.trio-app-group` (`Config.xcconfig:18`, `project.pbxproj:6743`). It is used for the xDrip4iOS shared defaults (`AppGroupSource.swift:37-38`) and is available to `Disk` (`Disk+InternalHelpers.swift:41-57`). Core Data, the settings JSON and the device state do **not** live in the App Group.
- **The watch targets have no entitlements at all**: no App Group, no HealthKit, no keychain group.
- iOS `UIBackgroundModes`: `bluetooth-central`, `bluetooth-peripheral`, `fetch`, `processing`, `remote-notification`, `audio` (`Trio/Resources/Info.plist:107-115`). One BGTask identifier, for the critical event log (`Info.plist:9-12`).

## 2. Loop orchestration

### 2.1 What starts a loop cycle (V)

```text
CGM plugin:  PluginSource.cgmManager(_:hasNew:)            PluginSource.swift:155-163
             └─ FetchGlucoseManager.newGlucoseFromCgmManager FetchGlucoseManager.swift:145
Pull sources: 1-min DispatchTimer → glucoseSource.fetch()   FetchGlucoseManager.swift:58, 99-134
             (Nightscout, xDrip App Group, simulator)
   └─ glucoseStoreAndHeartDecision                          FetchGlucoseManager.swift:302-368
        filterTooFrequentGlucose (3.5 min, Config.filterTime) :336, GlucoseStorage.swift:45
        store → smoothing → updatePumpBLEHeartbeat
        └─ deviceDataManager.heartbeat(date:)              FetchGlucoseManager.swift:364
             guards: no pump update running, no loop running DeviceDataManager.swift:287-302
             └─ updatePumpData → pumpManager.ensureCurrentPumpData   :306-320
                  └─ updateUpdateFinished → recommendsLoop.send()    :322-329
                       └─ APSManager.loop()                         APSManager.swift:224-229, 289
```

Other triggers:
- The user's "loop now" on Home calls `apsManager.heartbeat` (`Modules/Home/HomeProvider.swift:15-20`).
- When a manual temp basal ends, `APSManager` calls `loop()` directly (`APSManager.swift:268-280`).

What does **not** start a loop (V):
- `pumpManagerRecommendsLoop` only fulfils `pumpUpdatePromise` (`DeviceDataManager.swift:631-638`). That promise is never set to anything but `nil` (`:72, 324`), so the callback is a no-op.
- `pumpManagerBLEHeartbeatDidFire` only logs; its comment says "never used" (`:395-398`).
- I infer the pump's BLE heartbeat matters only because it keeps the process awake, which lets the 1-minute glucose timer fire for pull sources (I).

`updateUpdateFinished` sends `recommendsLoop` even when the pump update did not run (`:322-329`). The loop then decides for itself whether to proceed.

### 2.2 APSManager flow (V, `Trio/Sources/APS/APSManager.swift`)

1. `loop()` (`:289-374`) consumes the "user initiated" flag, then:
   - returns early if no pump is configured (`:306-309`);
   - takes the `LoopGuard` actor (`:80-121`) through `tryStart(minInterval: Config.loopInterval = 3 min, …)` (`:313-319`, `Config.swift:7`). That refuses a second concurrent loop and a loop within 3 min of the previous **start** when the previous one completed;
   - begins a `UIApplication` background task (`:330`).
2. `executeLoop` (`:376-389`): `determineBasal()`, then `enactDetermination()` only if `settings.dosingMode.automation != .off`.
3. `determineBasal()` (`:488-580`):
   - `calculateAndStoreTDD()`, which needs `pumpManager` (`:472-486`);
   - glucose validation on a Core Data context: at least 3 readings in the last hour (`:512-519`) and the newest at most 12 min old (`:522-527`);
   - `openAPS.createProfiles(for: dosingMode)`, `fetchCurrentTempBasal` (prefers the live `pumpManager.status.basalDeliveryState`, `:739-781`), `autosense()`;
   - `openAPS.determineBasal(...)` with `supportedBasalRates` taken from the live pump manager (`:620-626`);
   - only **after** that does the glucose-validation result throw (`:550-552`). A determination can therefore be computed and stored (for IOB/COB display) even when glucose is invalid; it just isn't enacted.
4. `enactDetermination()` (`:783-817`):
   - loads the latest `OrefDetermination` from the last 30 min;
   - requires a pump (`:790-792`);
   - **skips** without error if the pump is suspended (`:794-797`);
   - **throws** if a manual temp basal is running (`:800-802`);
   - `performBasal` → `pump.enactTempBasal` (`:839-847`), then `performBolus` → `pump.enactBolus(…, automatic: true)` when `smbToDeliver > 0` (`:849-852`).
5. `finalizeLoop` (`:419-439`) releases the guard. On success it sets `lastLoopDate`; on error it calls `processError`. In any non-off dosing mode it calls `reportEnacted(wasEnacted:)`, which stamps `enacted` on the determination (`:854-884`).

`determineBasalSync()` (`:582-595`) waits for any running loop and then recomputes without enacting. It runs after manual boluses (`:684-690`).

### 2.3 Determine-basal: Swift only (V)

- `OpenAPS.swift:235-369` gathers inputs in parallel: pump history and carbs from Core Data, glucose from `GlucoseStorage`, `trio_custom_oref_variables`, and `profile.json`, `basal_profile.json` and `autosense.json` from `FileStorage`.
- It then calls the native generators: `MealGenerator`, `IobGenerator`, `DeterminationGenerator` (`:591-702`). No JavaScript runs.
- `JavaScriptCore` survives only as an import in `Services/Network/Nightscout/NightscoutAPI.swift:4`. `trio-oref/lib` is reference source, and no `.js` file is a bundle resource (`grep -c ".js in Resources"` = 0).
- `profile.supportedBasalRates` and `profile.suspendOnly` are injected at call time and never persisted (`OpenAPS.swift:298-302`).

### 2.4 Safety guards on the loop and bolus paths

| Guard | Where | Behaviour | Status |
|---|---|---|---|
| Stale glucose (app) | `APSManager.swift:522-527` | newest reading > 12 min old → `glucoseError`, no enactment | V |
| Too few readings | `APSManager.swift:512-519` | < 3 readings in last hour → error | V |
| Stale/future/flat/noisy BG (oref) | `OpenAPSSwift/DetermineBasal/DetermineBasalGenerator.swift:557-631` | BG < 38 or > 600 rejected; age > 12 min or < −5 min, `bg <= 10`, `38`, noise ≥ 3, or unchanged CGM → temp-basal-only handling (cancel high temps) | V |
| Max IOB | `DosingEngine.swift:637-648` (IOB > max_iob), `:679-692` (insulinReq capped at `maxIob − iob`) | caps SMB/insulinReq | V |
| Max safe basal | `TempBasalFunctions.swift:29-59`, `DosingEngine.swift:876-880` | min(maxBasal, 3×max daily, 4×current) | V |
| SMB spacing / duplicate SMB | `DosingEngine.swift:818-843` | `smbInterval` (1–10 min, default 3) from `iobData.first?.lastBolusTime`, i.e. pump history | V |
| Loop concurrency / min interval | `LoopGuard`, `APSManager.swift:80-121, 313-319` | one loop at a time; 3 min spacing | V |
| Pump suspended (loop) | `APSManager.swift:794-797` | determination not enacted, logged | V |
| Manual temp basal | `APSManager.swift:800-802` | loop throws `manualBasalTemp` | V |
| Pump bolusing (loop) | not checked on the loop path; `verifyStatus` is called only from `enactBolus` (`:441-456, 643`) | relies on the kit to refuse or queue | V (absence) |
| Pump busy (manual bolus) | `verifyStatus`, `APSManager.swift:441-456` | rejects when no pump, bolusing or suspended | V |
| Bolus amount > 0 / rounds to > 0 | `APSManager.swift:637-669` | rejects and answers the callback | V |
| Max bolus (manual) | **not in `enactBolus`**. `roundBolus` (`:628-633`) caps but `enactBolus` doesn't call it. Trio pushes `DeliveryLimits(maxBasal, maxBolus)` into the pump manager each time one is set (`DeviceDataManager.swift:118-132`) | enforcement depends on each kit honouring `syncDeliveryLimits` | V for Trio, U per kit |
| Pump events over max basal | `DeviceDataManager.swift:581-585` | drops temp-basal events above `maxBasal` before storing (MDT bug filter) | V |
| Max IOB / recent bolus for external boluses | `Services/BolusSafety/BolusSafetyValidator.swift:43-59` (max bolus, IOB unavailable, IOB + bolus > maxIOB, ≥ 20 % within 6 min) | used **only** by `TrioRemoteControl` and Shortcuts (`BaseIntentsRequest.swift:21`, `TrioRemoteControl.swift:14`), **not** by the watch or the in-app bolus screen | V |
| Failed enactment | `enactDetermination` throws → `finalizeLoop(error:)` → `processError`, `reportEnacted(false)` (`APSManager.swift:419-439`) | temp basals are time-bounded (oref uses 30 min), so a missed loop falls back to scheduled basal | V for Trio; the fallback depends on the kit's temp-basal expiry (I) |
| Failed bolus | `APSManager.swift:691-705` | `bolusFailed` alert: "Check pump history before repeating." | V |
| Not looping | `Services/Alerts/NotLoopingMonitor.swift:8, 101-102` | warnings at 20/40/60/80/100 min, critical at 120 min, scheduled as local notifications from `lastLoopDate` | V |
| Pump required to loop | `APSManager.swift:306-309`; rule in `.claude/rules/algorithm-safety.md` | must stay | V |

Delivery states (rule from the fleet brief): the loop path records *requested* (determination stored), *accepted* (`pump.enactTempBasal` / `enactBolus` returned without throwing), and *executed/confirmed* only when pump events arrive later through `hasNewPumpEvents` (`DeviceDataManager.swift:568-603`). `determination.enacted = true` means "the enact calls didn't throw" (`APSManager.swift:854-884`). It does not mean "delivery confirmed" (V for the code path; what each kit means by success is U).

## 3. What could compile on watchOS

### 3.1 Algorithm (V, compile-tested)

- `AlgorithmPackage/Package.swift` is a shadow package. Its `Sources` and `OpenAPSSwiftTests` are symlinks into `Trio/Sources` and `TrioTests/OpenAPSSwiftTests`. It declares `platforms: [.macOS(.v14)]` and compiles `APS/OpenAPSSwift`, `APS/Extensions/DecimalExtensions.swift`, 17 model files and 8 helper files, with `TRIO_ALGORITHM_PACKAGE` defined (`Package.swift:22-73`).
- All 45 Swift files under `Trio/Sources/APS/OpenAPSSwift` import only `Foundation` (V). `AlgorithmLoggingShim.swift:12` replaces the app logger in the package build.
- **Compile test.** I copied the manifest into my scratchpad, added `.watchOS(.v10)`, dropped the test target and excluded `Localizations`. Then I ran `swift build --triple arm64-apple-watchos10.0-simulator --sdk <watchsimulator 27.2>` (Xcode 27.2). Result: `Build complete`, `exit=0`, object files stamped `platform 9` (watchOS simulator), `minos 10.0`.
- Caveat: with the string catalog included, SwiftPM fails in `xcstringstool generate-symbols` on duplicate keys in `Localizable.xcstrings`. That is a resource-generation issue, not a code one, but the same toolchain may hit it in the macOS `swift test` (U).
- Not tested: a device (arm64_32) build, performance on watch hardware, or the parity goldens on watchOS.

### 3.2 Storage layer (V for structure, I for portability)

- Core Data: `Model/CoreDataStack.swift` uses an `NSPersistentContainer` named `TrioCoreDataPersistentContainer` at the default location (app container, not the App Group).
  - Persistent history tracking and remote-change notifications are on (`:38-69`).
  - The model is loaded from `Bundle(for: CoreDataStack.self)` (`:101-112`).
  - It `import UIKit`s and gates opening on `UIApplication.shared.isProtectedDataAvailable` / `protectedDataDidBecomeAvailableNotification` (`:335, 358`).
- 20 entities: BolusStored, CarbEntryStored, ContactImageEntryStored, DeletedGlucoseStored, Forecast, ForecastValue, GlucoseStored, LoopStatRecord, MealPresetStored, OpenAPS_Battery, OrefDetermination, OverrideRunStored, OverrideStored, PumpEventStored, PumpStatusStored, StatsData, TDDStored, TempBasalStored, TempTargetRunStored, TempTargetStored.
- Settings and algorithm inputs that are not in Core Data are JSON in `Documents` through `BaseFileStorage` → `Disk(.documents)` (`Services/Storage/FileStorage.swift:28-118`): `preferences.json`, `settings/*.json` (profile, basal profile, ISF, CR, targets, autosense, pump settings), and some `monitor/*.json` (`OpenAPS/Constants.swift:2-29`).
- Pump and CGM manager state: `@PersistedProperty(key: "PumpManagerState")` / `"CGMManagerState"`, stored as `Documents/<key>.plist` (`Helpers/PropertyWrappers/PersistedProperty.swift:52-69`, `DeviceDataManager.swift:211`, `FetchGlucoseManager.swift:68`).
- Many `@Persisted` values are in `UserDefaults.standard` (`lastLoopDate`, `lastLoopStartDate`, `isManualTempBasal`, …; `APSManager.swift:137-167`).
- UIKit/LoopKitUI coupling inside storage: `GlucoseStorage` imports SwiftUI and AVFAudio, and `TDDStorage` imports LoopKitUI because `calculateTDD(pumpManager:)` takes the UI type (V, imports at file top). Core Data itself is available on watchOS (platform fact; Agent D to confirm limits).

### 3.3 DI (V)

- Swinject assemblies (`Trio/Sources/Assemblies/*.swift`) and the `@Injected`/`Injectable` wrapper. `APSAssembly` registers DeviceLogStore, DeviceDataManager, APSManager, FetchGlucoseManager, FetchTreatmentsManager, BluetoothStateManager, PluginManager and CalibrationService (`APSAssembly.swift:5-13`).
- Swinject's manifest declares `.watchOS(.v4)` (checked in the resolved checkout's `Package.swift:7-13`).
- `ServiceAssembly` pulls in HealthKit, WatchManager, Garmin, LiveActivity, Telemetry and others (`ServiceAssembly.swift`), so a watch build needs its own reduced assembly list (I).

### 3.4 Coupling that blocks a watchOS build of the loop (V unless marked)

- `APSManager.swift:330` and `FetchGlucoseManager.swift:311`: `UIApplication.beginBackgroundTask`.
- `DeviceDataManager.swift:1-15, 233, 237`: imports LoopKitUI, MockKitUI, DanaKit, MedtrumKit, MinimedKit, OmnipodKit, ShareClient; uses `UIDevice.current.isBatteryMonitoringEnabled` and `UIApplication.didBecomeActiveNotification`; the pump is typed `PumpManagerUI?`.
- `DeviceDataManager.swift:135-170, 503-560`: concrete-kit casts (`MedtrumPumpManager`, `OmniPumpManager`, `MockPumpManager`) in the pump setter.
- `Devices/DeviceCatalog.swift:3-27`: imports UIKit and every kit and its UI module; `PluginManager.swift` returns `CGMManagerUI.Type`.
- `Model/CoreDataStack.swift:5, 335, 358`: UIKit protected-data gate.
- `AppleWatchManager` wraps iOS-only `WCSessionDelegate` methods in `#if os(iOS)` (`AppleWatchManager.swift:786-791`). That is the only `os()` conditional seen in this area. There is no platform abstraction layer today.

## 4. Pump and CGM integration

### 4.1 Pump (V)

- `BaseDeviceDataManager` owns `pumpManager: PumpManagerUI?` (`DeviceDataManager.swift:74-209`). When a pump is set it:
  - points the delegate queue at its own `processQueue`;
  - registers the manager with `TrioAlertManager`;
  - persists `rawPumpManager = pumpManager.rawValue`;
  - writes `bolusIncrement` into `preferences.json`;
  - calls `syncDeliveryLimits` with Trio's max basal and max bolus (`:118-132`).
- Restore: `setupPumpManager()` (`:251-257`) → `pumpManagerFromRawValue` (`:335-343`) looks up `managerIdentifier` in `DeviceCatalog.pumpEntry(forPersistedIdentifier:)` (legacy Omnipod identifiers map to OmnipodKit, `:345-353`) and calls `Manager.init(rawState:)`.
- Persistence: `pumpManagerDidUpdateState` writes `rawPumpManager` on every state change (`:387-393`). Pump events reach `PumpHistoryStorage.storePumpEvents` serially (`:568-603`). The reservoir level goes out over the broadcaster.
- The BLE heartbeat request is aligned to the CGM schedule (`updatePumpBLEHeartbeat`, `:272-285`). When the CGM provides its own heartbeat, the pump is relieved (`:263-270`, `pumpManagerMustProvideBLEHeartbeat` `:400-402`).
- `automaticDosingEnabled` is true for any dosing mode other than off (`:359-361`).

### 4.2 CGM (V)

- `BaseFetchGlucoseManager` owns `cgmManager: CGMManagerUI?`, persisted as `CGMManagerState` (`FetchGlucoseManager.swift:61-68`). It is restored with `cgmManagerFromRawValue` (`:293-300`).
- Glucose sources: plugin (`PluginSource`), xDrip App Group, Nightscout, simulator (`:268-285`).
- Whether the CGM wakes the app (BLE heartbeat) is decided at `:287-290`.
- `HeartBeatManager` (`APS/CGM/HeartBeatManager.swift`) piggybacks on xDrip4iOS's transmitter through the App Group for a BLE wake-up.
- There is a known split: the pump lives in DeviceDataManager, while the CGM lives in FetchGlucoseManager plus PluginSource (project CLAUDE.md; unification is a future plan in memory).

### 4.3 Kit platform support (V, parsed each `project.pbxproj` / `Package.swift`)

| Submodule @ SHA | watchOS target? | Notes |
|---|---|---|
| LoopKit @ `babddf04` | `LoopKit-watchOS` (watchOS 10.6) | 166 of 187 LoopKit sources. It **omits** `StatefulPluggable.swift`, `Service.swift`, `RemoteDataService.swift`, `TherapySettings.swift`, `AlertSoundPlayer.swift`, `CgmEventStore.swift` and 15 more. It has `PumpManager.swift`, `CGMManager.swift`, `PumpManagerStatus.swift`. No LoopKitUI-watchOS. No MockKit-watchOS (so no simulator pump on the watch). `Package.swift` declares only `.iOS("17.6")`. Whether it compiles at this SHA: U |
| CGMBLEKit @ `5bde830` | `CGMBLEKit-watchOS` (49 files) | G5/G6 |
| G7SensorKit @ `08d4886` | `G7SensorKit-watchOS` (49 files) | PR #1749 builds on this |
| dexcom-share-client-swift @ `e7eda40` | `ShareClient-watchOS` | |
| RileyLinkKit @ `52a652c` | `RileyLinkBLEKit-watchOS`, `RileyLinkKit-watchOS` | radio bridge only |
| MinimedKit @ `008aab0` | no | iOS only |
| OmnipodKit @ `6fdf0e0` | no | iOS (plus macOS test targets) |
| DanaKit @ `787a639` | no | |
| MedtrumKit @ `eee17b0` | no | |
| LibreTransmitter @ `fb8e4ad`, LibreLoop @ `dbe4f9c` | no | |
| AccuChekKit, EversenseKit, SyaiKit, TidepoolService | no | |
| RoundWhiteDiscKit @ `7dd6396` | no (`Package.swift` `.iOS(.v17)`) | |

Consequence: **no supported pump can be driven from a watch without porting a pump kit** (V for the absence of targets; the porting effort is U).

## 5. WatchConnectivity today

### 5.1 Phone side (V, `Trio/Sources/Services/WatchManager/AppleWatchManager.swift`)

- `BaseWatchManager` is the `WCSessionDelegate` (`:15`). It is set up at `:150-162`.
- State push: `setupWatchState()` (`:175-430`) builds a `WatchState` from Core Data.
  - It sends with `sendMessage` when the watch is reachable and falls back to `transferUserInfo` (`:551-590`).
  - It returns early unless the watch is paired, reachable and installed.
  - Contents: glucose, trend, delta, IOB, COB, last loop time, the chart, forecasts, override and temp-target presets, maxBolus, maxCarbs, bolusIncrement and others (`WatchMessageKeys.swift:1-67`).
- Commands the watch can send (`session(_:didReceiveMessage:)`, `:626-766`):

| Command | Keys | Handler | Phone-side validation |
|---|---|---|---|
| Bolus | `bolus` (Double) | `handleBolusRequest` → `apsManager.enactBolus(isSMB: false)` (`:812-826`) | only what `enactBolus` does: >0, `verifyStatus`, rounding. **No `BolusSafetyValidator`, no max bolus, no max IOB, no recent-bolus check** |
| Carbs | `carbs` (Int) + `date` | `handleCarbsRequest` writes `CarbEntryStored` (`:830-878`) | none (no max carbs on the phone) |
| Carbs + bolus | all three | `handleCombinedRequest` (`:882-958`) | as above. The current watch sends carbs and bolus as two messages (`WatchState+Requests.swift:9-18`), so this path is not reached from today's watch (PR #1648 says the same) |
| Override start / cancel | `activateOverride` (preset name) / `cancelOverride` | `AdjustmentManager.activateOverride(.presetName, source: .watch)` (`:985-1011`) | preset lookup by name |
| Temp target start / cancel | `activateTempTarget` / `cancelTempTarget` | `:1013-1067` | preset lookup by name |
| Bolus recommendation | `requestBolusRecommendation` + `carbs` | `BolusCalculationManager.handleBolusCalculation` using the last 30-min determination's `minPredBG` (`:714-764`) | read-only |
| Snooze | `snoozeDuration` | `notificationsManager.applySnooze` (`:651-654`, also via userInfo `:768-780`) | |
| State request | `requestWatchUpdate` | `:636-648` | |
| Logs | `watchLogs`, file transfer | `WatchLogIngest` (`:627-630, 782-784`) | |

- Acknowledgements go back through `sendMessage` with an `AcknowledgmentCode` (`:592-607, 1156-1167`). There is no reply handler, and nothing is sent when the watch is unreachable.

### 5.2 Watch side (V)

- `WatchState` (`Trio Watch App Extension/WatchState.swift`) is the watch's `WCSessionDelegate`. It sets `maxBolus` (default 10) and `maxCarbs` (default 250) from the phone's payload (`:49-50, 563-572`); `BolusInputView.swift:16` and `CarbsInputView.swift:15` cap the input at those values.
- Every write goes through `reachableSession(...)` and is refused when the phone isn't reachable (`WatchState+Requests.swift:127-135`).
- Entries older than `entryLifetime` = 2 min are refused (`WatchState.swift:42`, `WatchState+Requests.swift:28-35`).
- The acknowledgement timeout is 15 s (`WatchState.swift:75`).
- A message carries **no request ID and no timestamp** for a bolus (`WatchState+Requests.swift:39-51`), so the phone has no idempotency key (V). WatchConnectivity does not redeliver `sendMessage` on its own (platform; Agent D).

Implication (I): every safety decision for a watch-originated command happens on the phone today, and the bolus path is the weakest. In an untethered mode, whatever replaces the phone must run the full validator and the pump-side guards locally.

## 6. Background execution on iOS today (V for configuration, I for runtime)

- Modes: BLE central and peripheral, fetch, processing, remote notification, audio (`Info.plist:107-115`). `audio` is used for critical-alert playback (`Services/Alerts/CriticalAlertAudioPlayer.swift:71`). I found no silent-audio keep-alive (V by grep for `AVAudioSession`).
- The loop keeps running because BLE wakes the app:
  - a plugin CGM with its own BLE heartbeat (`FetchGlucoseManager.swift:287-290`); otherwise
  - a pump heartbeat aligned to the expected CGM interval (`DeviceDataManager.swift:272-285`); or
  - the xDrip transmitter piggyback (`HeartBeatManager`).
- Inside each wake the work is wrapped in `beginBackgroundTask` (`APSManager.swift:330`, `FetchGlucoseManager.swift:311`).
- There is no `BGAppRefreshTask` for looping. The only `BGTaskSchedulerPermittedIdentifiers` entry is the critical event log (`Info.plist:9-12`).
- Remote notifications drive `TrioRemoteControl` (`TrioApp.swift:209`, `AppDelegate.swift:35`). That is not a loop trigger.
- After a reboot, Core Data waits for protected data (`CoreDataStack.swift:335-358`). PR #1745's body describes a cold background launch before first unlock for BLE restoration.
- Rule of thumb from project rules: iOS caps background CPU for BLE apps, and an attached debugger bypasses that cap (`.claude/rules/algorithm-safety.md`).

## 7. Testing infrastructure (V)

- Targets: `TrioTests` (iOS, host app `Trio`) and `Trio Watch AppTests` (watchOS, 23 `@Test`s in one file).
- `TrioTests` has 69 top-level entries; 118 files `import Testing` and 1 file `import XCTest`.
- Algorithm tests: `TrioTests/OpenAPSSwiftTests/**` (DetermineBasal, IOB, meal/COB, autosens, profile, DynISF), also run as `swift test --package-path AlgorithmPackage`.
- Parity harness: `TrioTests/OpenAPSSwiftTests/Parity/` holds 14 golden scenarios compared byte-exactly (`ParityHarness.swift:21-40`). It is pinned to Europe/Berlin and skips otherwise (`:12-20, 69`). The `Trio Tests` scheme sets `TZ=Europe/Berlin` (`Trio Tests.xcscheme:18-19`).
- CI (`.github/workflows/unit_tests.yml`, called from `upstream_automation.yml` on pushes and PRs to `dev`, gated on `repository_owner == 'nightscout'`):
  - job 1: `swift test --package-path AlgorithmPackage` on `macos-26` / Xcode 26.2 (`:9-36`). It does **not** set `TZ`, so I infer the parity goldens skip in this job unless the runner happens to be on Europe/Berlin (I);
  - job 2: `build-for-testing` + `test-without-building` for the `Trio Tests` scheme on an iPhone 17 / iOS 26.2 simulator with ad-hoc signing (`:68-245`). The scheme only includes `TrioTests` (`Trio Tests.xcscheme:24-33`).
- **The watch tests do not run in CI** (V). Nothing builds the kits' watchOS targets (V by absence).

## 8. Open upstream PRs touching the watch (not in dev; read with `gh pr view`)

| PR | Author | What it changes | Interaction with an untethered mode |
|---|---|---|---|
| [#1598](https://github.com/nightscout/Trio/pull/1598) | EJM0 | Coalesced phone→watch pushes; `transferUserInfo` → `updateApplicationContext`; request/reply; `WatchState.shared` singleton; removes `WatchStateSnapshot` (+323/−227, 10 files) | Good basis for the tethered display/sync path; fixes the watch-side delegate lifetime bug. One-directional (phone → watch), so it does not cover watch → phone loop results. Touches `AppleWatchManager` heavily, so expect merge conflicts with any watch-loop work |
| [#1694](https://github.com/nightscout/Trio/pull/1694) | kjassman | "Watch Usage Mode" (Companion / Adjustments / View), enforced on the phone (`WatchUsageMode.swift`, `AppleWatchManager` +25) | The permission model must also hold when the phone is absent, so the watch needs a local copy of the mode, and the phone's rejection can't be the only enforcement |
| [#1723](https://github.com/nightscout/Trio/pull/1723) | paulingham | Configurable complications; **adds App Group entitlements to both watch targets**; `ComplicationState` in the App Group; WC background tasks; `.backgroundTask(.appRefresh)` | Provides the watch App Group and background-refresh plumbing an untethered mode also needs. Complications would read watch-local loop state when untethered |
| [#1745](https://github.com/nightscout/Trio/pull/1745) | dabear | Hosts LoopKit `SmartwatchManager` plugins (Pebble). Moves the LoopKit submodule to `dabear/LoopKit smartwatch-manager-review` | Not about Apple Watch. Its host-side remote-action rules (max bolus/IOB/carbs, the plugin's pacing) are design input. The LoopKit pin change conflicts with any LoopKit-watchOS work |
| [#1749](https://github.com/nightscout/Trio/pull/1749) | EJM0 | G7 Direct-to-Watch: the watch builds its own CGM manager from the phone's exported config (`WatchCGMHost`), links LoopKit + G7SensorKit into the watch, adds a watch `Info.plist` with `bluetooth-central`, raises the watch to watchOS 10.6, renames the watch module to `Trio`, adds watch alarms | **Most relevant.** It is the CGM half of an untethered mode and proves LoopKit/G7SensorKit linking on the watch. Display and alarms only: it does not store readings for an algorithm or feed a loop |
| [#1762](https://github.com/nightscout/Trio/pull/1762) | kristinkand | Shows G7 "unreliable" readings (display, NS treatment), never looped or dosed on | Low relevance. A watch loop must keep the same exclusion. Author's code is treated as unverified per fleet rules ("Completely clauded" in the body) |
| [#1775](https://github.com/nightscout/Trio/pull/1775) | mountrcg | Watch-agnostic command pipeline: request cache (at most once, `in_progress`), 2 min freshness window, revocation counter, `finalCheck()` right before the effect. No callers yet | Directly reusable semantics for watch-originated commands, and for any ownership hand-over message (idempotency + freshness). Phone-side today |
| [#1648](https://github.com/nightscout/Trio/pull/1648) (draft) | jwoglom | Runs `BolusSafetyValidator` on watch boluses; overridable checks with crown confirmation; max bolus stays blocking | Closes the phone-side gap in section 5.1. In untethered mode the same validator has to run on the watch, which needs IOB and pump history locally |

## 9. Conclusions

### 9.1 What already exists and could support untethered operation

- **Algorithm.** `OpenAPSSwift` plus its models compile for watchOS today with no code change (V, section 3.1). Parity goldens exist to prove the watch build computes byte-identical results (V for the harness; running it on watchOS is U).
- **One loop pipeline with explicit guards.** `APSManager` (LoopGuard, glucose staleness, suspend/manual-temp handling, enact reporting) and oref's own guards are platform-neutral in logic. Only the UIKit calls listed in 3.4 are iOS-specific (V).
- **Device persistence primitive.** `rawValue` / `init(rawState:)` for pump and CGM managers, persisted on every state change (V). This is the natural carrier for moving pump control between devices.
- **Watch-capable kits.** LoopKit-watchOS, G7SensorKit-watchOS and CGMBLEKit-watchOS targets exist (V), and PR #1749 shows LoopKit + G7SensorKit running on the watch (per its description, U for this baseline).
- **Transport.** WatchConnectivity is wired both ways, with acknowledgements (V). PR #1598 and PR #1775 improve delivery semantics and idempotency.
- **Swinject** supports watchOS (V), so the DI pattern can be reused with a reduced assembly.

### 9.2 Hard limitations

1. **No pump driver on watchOS.** None of OmnipodKit, DanaKit, MedtrumKit or MinimedKit has a watchOS target (V). This alone blocks untethered dosing.
2. **Single controller per pump.** A pump/pod session is held by exactly one `PumpManager` instance, whose `rawState` carries session and sequence state (I, from the restore path; per-kit details U). Two devices issuing commands, or one device using a stale `rawState`, is a safety hazard (I). Trio has no ownership hand-over today (V by absence).
3. **The watch has no data.** The algorithm inputs are Core Data history (glucose, carbs, pump events, overrides, temp targets, TDD), JSON settings in the phone's `Documents`, and live pump status (`supportedBasalRates`, `basalDeliveryState`) (V). None of it exists on the watch today.
4. **The watch app is phone-dependent by construction:** no entitlements, no background modes, no frameworks, every write refused when unreachable (V).
5. **The loop needs a CGM reading on the same device.** It is triggered only by stored glucose (V), so a watch loop needs a watch-hosted CGM (#1749-style) or another local reading source.
6. **No CI coverage** of watch code or watchOS kit targets (V).
7. **Unknowns for Agent D:** watchOS background BLE runtime, whether a 5-min cadence is sustainable, CPU limits, and Core Data size and IO on the watch.

### 9.3 Minimum architectural changes (no parallel architecture)

The existing pipeline can serve if it compiles for watchOS. Nothing found requires a separate watch loop. The logic is platform-neutral; the blockers are imports and UIKit calls. So the minimum set is:

1. **Platform seams, not a rewrite.**
   - Replace `UIApplication.beginBackgroundTask` (APSManager, FetchGlucoseManager), `UIDevice` and `didBecomeActive` in DeviceDataManager, and the UIKit protected-data gate in CoreDataStack with small injected protocols (`BackgroundTaskRunner`, `ProtectedDataGate`).
   - Type the dosing path against `PumpManager` / `CGMManager` (LoopKit), not the `…UI` variants. `TDDStorage` and `DeviceCatalog` are the main offenders.
   - Cost: moderate review burden on safety-critical files. Behaviour must stay identical on iOS (verifiable by the existing TrioTests and parity suites).
2. **Shared, multi-platform code membership.** Compile `OpenAPSSwift` + models (already portable), `Model/` (Core Data stack and model), the APS stores, `APSManager` and a slim `DeviceDataManager` into the watch target, or into a framework both apps link. `AlgorithmPackage` already shows the shadow-package pattern for the algorithm.
3. **One pump kit and one CGM kit with watchOS targets.** CGM: G7SensorKit-watchOS exists. Pump: none exists; picking the first kit is an open question.
4. **Explicit single-owner hand-over of pump control** between phone and watch:
   - transfer `rawState`, the pending dose and the recent pump history atomically;
   - only the owner may command;
   - fail closed (the scheduled basal continues) on any ambiguity.

   This is new, and it is the core safety design item. #1775's idempotency and freshness rules are a template.
5. **Settings and history replication** from phone to watch (profile, preferences, pump settings, recent glucose/carbs/pump events, overrides and temp targets), and reconciliation back. #1598's `updateApplicationContext` covers snapshots but not durable history (I).
6. **Watch entitlements and capabilities:** App Group (#1723 adds it), a `bluetooth-central` background mode (#1749 adds it), and a watchOS deployment target ≥ 10.6 for LoopKit-watchOS.
7. **Safety parity on the watch:** `BolusSafetyValidator` (#1648), Watch Usage Mode (#1694), not-looping alerts and pump alerts must all run locally when untethered.
8. **CI:** build the watch target and the kits' watchOS targets. Run the algorithm suite for watchOS with TZ pinned.

YAGNI, not needed for a first untethered loop: Garmin/Pebble hosting (#1745), Live Activity, Nightscout/Tidepool upload from the watch, HealthKit export, new complications beyond #1723, the unreliable-reading display (#1762), xDrip/App Group CGM sources, the simulator pump on the watch (MockKit has no watchOS target).

## Open questions

1. Which pump kit is the first watchOS port candidate? A BLE pump that needs no RileyLink bridge (I), but feasibility and the maintainers' willingness are U.
2. Does `LoopKit-watchOS` compile at `babddf04` with its 21 omitted files, given that `PumpManager`/`DeviceManager` conform to `Pluggable` (`DeviceManager.swift:26`)? Not built here.
3. Hand-over semantics: who owns the pump while both devices are reachable, and how is an in-flight bolus or temp basal accounted for during transfer? This is for the safety agent (E) and the ADR log.
4. Do `TrioApp`'s service graph and `ServiceAssembly` split cleanly into a "loop core" assembly, or do hidden dependencies (Broadcaster observers, TrioAlertManager, NightscoutManager via the lazy resolver in DeviceDataManager `:55, 594`) pull in iOS-only services?
5. Does the CI algorithm job actually run the parity goldens, given that `TZ` is unset there?
6. Does the `xcstringstool generate-symbols` failure also hit `swift test --package-path AlgorithmPackage` on Xcode 27?
7. How much history must the watch hold for oref? Autosens uses up to 24 h of glucose (`OpenAPS.swift:626-670`), and the glucose fetch spans maxMealAbsorptionTime + 0.5 h (`:258`). What is the Core Data cost on the watch?
8. Loop-on-pump-event: `pumpManagerRecommendsLoop` is dead on dev. Is that intentional, and would a watch with a less reliable CGM link need it?

## Evidence index

Repository `~/workspaces/Trio-on-watch` @ `ad6c66876e5ccca8b0a6e1c5b7626ed4caa65926`:

- Targets/build: `Trio.xcodeproj/project.pbxproj:754, 1219, 1987-1988, 4413-4450, 5279-5421, 6743, 6793-7261 (deployment, SDKROOT, INFOPLIST, entitlements)`; `Config.xcconfig:1-30`; `Trio/Resources/Info.plist:5-12, 96, 107-115`; `Trio/Resources/Trio.entitlements:5-22`; `Trio Watch App/Info.plist`; `Trio Watch App Extension/TrioWatchApp.swift:4-22`.
- App: `Trio/Sources/Application/TrioApp.swift:68-92, 189-220`; `Trio/Sources/Assemblies/{APS,Storage,Service}Assembly.swift`.
- Loop: `Trio/Sources/APS/APSManager.swift:80-121, 137-167, 210-282, 289-374, 376-456, 472-595, 620-633, 635-706, 739-852, 854-884`; `Trio/Sources/Config/Config.swift:7`.
- Devices: `Trio/Sources/APS/DeviceDataManager.swift:55, 72, 74-209, 211, 233-257, 263-343, 359-402, 568-603, 631-638`; `Trio/Sources/APS/FetchGlucoseManager.swift:58-68, 99-163, 268-300, 302-368`; `Trio/Sources/APS/CGM/PluginSource.swift:155-163`; `Trio/Sources/APS/PluginManager.swift`; `Trio/Sources/APS/Devices/DeviceCatalog.swift:3-27, 350-474`; `Trio/Sources/Helpers/PropertyWrappers/PersistedProperty.swift:52-69`.
- Algorithm: `Trio/Sources/APS/OpenAPS/OpenAPS.swift:235-369, 591-720`; `Trio/Sources/APS/OpenAPS/Constants.swift:2-61`; `Trio/Sources/APS/OpenAPSSwift/DetermineBasal/DetermineBasalGenerator.swift:557-631`; `…/DosingEngine.swift:637-648, 679-692, 818-843, 876-880`; `…/TempBasalFunctions.swift:29-59`; `…/AlgorithmLoggingShim.swift:12`; `AlgorithmPackage/Package.swift`.
- Storage: `Model/CoreDataStack.swift:1-112, 335-358`; `Model/TrioCoreDataPersistentContainer.xcdatamodeld`; `Trio/Sources/Services/Storage/FileStorage.swift:21-118`; `…/Disk/Disk+InternalHelpers.swift:41-57`; `Trio/Sources/APS/Storage/GlucoseStorage.swift:1-8, 45`; `…/TDDStorage.swift:1-4`.
- Safety: `Trio/Sources/Services/BolusSafety/BolusSafetyValidator.swift:5-105`; `Trio/Sources/Services/Alerts/NotLoopingMonitor.swift:8, 101-102`.
- Watch: `Trio/Sources/Services/WatchManager/AppleWatchManager.swift:15, 150-162, 175-430, 551-607, 626-791, 812-1067, 1156-1167`; `Trio/Sources/Models/WatchMessageKeys.swift:1-67`; `Trio Watch App Extension/WatchState.swift:42-101, 563-572`; `…/WatchState+Requests.swift:9-70, 127-150`; `…/Views/BolusInputView.swift:16`; `…/Views/CarbsInputView.swift:15`.
- Tests/CI: `.github/workflows/unit_tests.yml:1-245`; `.github/workflows/upstream_automation.yml:36-55`; `Trio.xcodeproj/xcshareddata/xcschemes/Trio Tests.xcscheme:18-33`; `TrioTests/OpenAPSSwiftTests/Parity/ParityHarness.swift:12-40, 69`; `Trio Watch App Tests/Unit Tests.swift`.
- Kits (submodule SHAs in 4.3): `LoopKit/LoopKit.xcodeproj/project.pbxproj` (target `LoopKit-watchOS`), `LoopKit/Package.swift:14`, `LoopKit/LoopKit/DeviceManager/DeviceManager.swift:26`, `CGMBLEKit/CGMBLEKit.xcodeproj`, `G7SensorKit/G7SensorKit.xcodeproj`, `dexcom-share-client-swift/ShareClient.xcodeproj`, `RileyLinkKit/RileyLinkKit.xcodeproj`, `MinimedKit/…`, `OmnipodKit/…`, `DanaKit/…`, `MedtrumKit/…`, `RoundWhiteDiscKit/Package.swift:7-8`.
- Swinject platforms: resolved checkout `Package.swift:7-13` (`.watchOS(.v4)`).
- Compile test (scratch, not in repo): `/private/tmp/claude-501/-Users-dnzxy-workspaces-Trio/3f8cbd66-3ec5-4539-8f2f-f9e5df9ae9dc/scratchpad/agent-c/algo-watch/Package.swift`, log `…/agent-c/algo-watch-swiftbuild.log` (`Build complete`, exit 0, target `arm64-apple-watchos10.0-simulator`, SDK watchOS 27.2, Xcode 27.2 / 27B52).
- PRs: https://github.com/nightscout/Trio/pull/1598, /1694, /1723, /1745, /1749, /1762, /1775, /1648 (bodies and file lists via `gh pr view --json body,files`, 2026-11-15).
