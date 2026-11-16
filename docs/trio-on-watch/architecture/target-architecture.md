# Target architecture (v1)

Status: proposed 2026-11-16, pending review. Scope: `requirements-and-scope.md`. Decisions: `architecture-decisions.md`. Details: `state-and-synchronization.md`, `lifecycle-and-execution.md`.

## 1. Shape in one paragraph

The phone lends the pod and the G7 to the watch: a **loan**. One shared, pure state machine decides every loan transition on both devices. Each device persists its loan state before it acts on it. The watch compiles Trio's existing oref Swift code and runs it each G7 reading, through the same pure entry point the phone uses (`OrefRun`), on inputs it holds locally (grant snapshot plus its own records). Pump and CGM drivers move between devices through LoopKit's existing `ExclusiveDeviceControl` / `DeviceConfigurationSharing` (LoopKit#626, already in Trio's pin). OmnipodKit gets those through loopandlearn/OmnipodKit#177. There is no parallel architecture on the phone: APSManager, DeviceDataManager and the stores stay as they are, plus one gate and one coordinator.

## 2. Components

| Component | Where | New or changed | Responsibility |
|---|---|---|---|
| `OrefInputs` + `OrefRun` | `Trio/Sources/APS/OpenAPSSwift/` (shared: phone, watch, AlgorithmPackage) | New, extracted from `OpenAPS.determineBasal` / `createProfiles` / `autosense` | Pure function: inputs → profile → autosens → IOB → meal → determination. The phone's `OpenAPS` gathers the inputs from Core Data and JSON as today, then calls it. Parity goldens stay byte-exact. |
| `WatchLoan` (state machine, messages, records) | `Trio/Sources/APS/WatchLoan/` (shared) | New | `WatchLoan.decide(state, event, context) -> (state, [Effect])`. No IO. Codable messages with protocol version, epoch and message id. Record types: dose, carb, glucose, pump event, with stable sync identifiers. |
| `WatchLoanGate` | phone, `Trio/Sources/APS/` | New, small | `phoneMayCommandPump` from the persisted phone loan state. It fails closed: if the state is unreadable, it answers false. Checked by `APSManager.loop`, `enactBolus`, `enactTempBasal`, `cancelBolus`, and every DeviceDataManager path that commands the pump. |
| `WatchLoanCoordinator` (phone) | `Trio/Sources/Services/WatchManager/` | New | Lend: preconditions, cancel the running temp, release control, export, snapshot, grant. Take back: merge records, take control, odometer audit, resume. Uses `AppleWatchManager`'s WCSession, with no second session. |
| Watch loan host | `Trio Watch App Extension/Loan/` | New | Adopts the pump and CGM managers from the grant. Persists the loan state and records (JSON files, atomic writes). Runs the loop on each reading. Schedules dead-man notifications. Streams records. |
| Watch UI | `Trio Watch App Extension/Views/` | Changed (F's G1–G11) | Control indicator, Start/End, status page, bolus progress, hand-off confirmation. |
| Phone UI | Home + Settings | Changed, minimal | "Apple Watch is in control" banner with Take Back. Pump actions disabled with a reason. |

## 3. Device ownership (SR-1..SR-3)

- **Phone states:** `home(epoch)`, `lending(epoch)`, `lent(epoch)`, `takingBack(epoch)`. **Watch states:** `idle`, `requesting`, `holding(epoch)`, `returning(epoch)`, `stopped(epoch, reason)`.
- **Who may command:** only phone `home` and watch `holding` with the current epoch. Every other state means zero commanders.
- **Release before acquire:** the phone persists `lending(e+1)`, cancels the running temp, calls `releaseControl()` and verifies `isControlReleased`, then exports and sends the grant. The watch persists `holding(e+1)` and only then calls `takeControl()`.
- **Hand-back:** the watch releases first and persists `returning`. The phone takes control only after it has persisted the records.
- **No autonomous takeover.** Timeouts produce messages to the user, never ownership.
  - A grant the watch never confirms leaves the phone in `lending`. It shows "Apple Watch didn't confirm" with Take Back.
  - Take Back is a user tap. It bumps the epoch, takes control (a fresh EAP handshake on the pod), audits the odometer, and resumes.
- **Stale watch:** a watch that sees a higher epoch (message) or a foreign pod session (OmnipodKit#177 SQN-resync detection) stops all pump commands at once, persists `stopped`, and alerts.

## 4. Grant snapshot (SR-5, SR-19, SR-20)

The grant contains:
- the protocol version, app build and per-kit state schema identifiers;
- phone time and time zone;
- the pump `rawState` export and the G7 `SharedDeviceConfiguration`;
- the `OrefInputs` sources: settings, preferences, profile inputs, basal, ISF, CR and targets, active override and temp target with their end times, TDD history for DynISF, and 24 h of glucose, pump events and carbs (with deletions excluded);
- the pod odometer reading at release.

The watch refuses the grant if any part is missing, the versions differ, the clock offset is over 60 s, or the time zone differs.

## 5. Loop cycle on the watch (SR-7, SR-11, SR-12, SR-14, SR-24)

On each G7 reading (wake: `WKBluetoothAlertRefreshBackgroundTask`, ADR-002):
1. Restore checklist: `holding` with the current epoch, no unresolved dose intent, pump status fresh, glucose fresh (12 min, same rule as `APSManager`).
2. Read pump status through the kit (`ensureCurrentPumpData` equivalent).
3. Build `OrefInputs` from the snapshot plus local records. Run `OrefRun`.
4. Refuse insulin-adding commands while delivery is uncertain or a write-ahead intent is unresolved (Trio-level gate, SR-11). Suspends and reductions stay allowed.
5. Persist the dose intent, then enact the temp basal and SMB through the `PumpManager`.
6. Persist the outcome and the pump events. Reschedule the dead-man notifications. Queue a record batch to the phone.
7. Complete the background task.

Manual bolus and carbs on the watch go through `BolusSafetyValidator` with the watch's own IOB. They carry an id and are persisted as an intent before transmit.

## 6. Phone during a loan

- `WatchLoanGate` blocks every pump command path, Take Back excepted. The UI shows why.
- The phone keeps reading the G7 and keeps its glucose alarms.
- `NotLoopingMonitor` doesn't fire for the phone's own loop. Instead the phone alerts when the watch is reachable but has sent no record for 20 min (SR-15).
- Overrides, temp targets, settings, remote commands, Shortcuts and watch-remote boluses are refused with a reason (F-5).
- Records from the watch are merged by sync identifier (SR-6). Nightscout upload continues for what the phone has stored.

## 7. Platform seams (only what the watch build needs)

- The watch target compiles `OpenAPSSwift` and its models, `WatchLoan`, and the record types. It links `LoopKit-watchOS`, `OmnipodKit-watchOS` (#177) and `G7SensorKit-watchOS`.
- Watch Info.plist: `bluetooth-central`. Entitlements: time-sensitive notifications. Deployment target watchOS 10.6 (the LoopKit-watchOS requirement).
- No UIKit is moved and no iOS service is ported. The watch does not compile `APSManager`, `DeviceDataManager`, `CoreDataStack` or Swinject assemblies. Its host is small, and the shared pieces are pure.

## 8. Alerts on the watch (SR-15, SR-16)

- **Dead-man:** pre-scheduled local notifications at +20 and +40 min after the last successful cycle, moved forward every cycle. They fire even if the app never wakes again.
- **Glucose:** urgent low and low, using the phone's alarm thresholds from the snapshot. Time-sensitive level (the watch has no critical alerts, as in Loop).
- **Kit alerts:** pump and CGM alerts issued by the kits, through a minimal watch `AlertIssuer`.

## 9. What this deliberately does not do

It does not add an offline start, a forced takeover from the watch, watch-side Nightscout, settings sync, a Core Data stack on the watch, workout sessions, or support for more than one pump or CGM. See `requirements-and-scope.md`.

## 10. Testing

- **Unit (Swift Testing, TrioTests):** `WatchLoan.decide` decision table, with one test per transition and a crash or message loss at each hand-off step. Also: snapshot completeness, merge by identifier, the gate on every phone pump path, the clock and version gates, and the uncertain-delivery gate.
- **Parity:** existing goldens through `OrefRun` (phone). The same fixture through the watch input builder gives an identical determination.
- **Build:** the watch target for the watchOS simulator and `arm64_32` device.
- **Simulator:** the watch host with a test pump double that fails the test if two commanders exist.
- **Hardware (owner: maintainer):** D's E1 (TestFlight upload), E2 (24 h G7 wake count), E5 (a DASH exchange fits the wake window), and in-vitro DASH hand-off tests. Untethered use stays disabled behind a build flag until E2 passes (SR-17).

## 11. Build flag

`TRIO_ON_WATCH` (xcconfig, off by default). When it's off, no loan UI is shown and the phone never lends. This keeps experimental code from reaching users who build `dev`.
