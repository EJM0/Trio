# Untethered watch mode

Untethered watch mode lets the Apple Watch run the loop on its own for a while. The phone hands the pod and the G7 sensor over to the watch, and the watch then reads glucose, runs the same algorithm the phone runs, and sets temp basals and SMBs itself. When the phone is back, the watch hands everything back, together with a record of what it did.

It is meant for short stretches where the phone can't come along: sport, swimming with the phone in a locker, a walk without the phone. It is not meant to replace the phone.

Supported devices: Omnipod DASH and Dexcom G7. Other pumps and CGMs are refused with a message before anything is handed over.

## For users

### Starting

Any of these starts untethered mode. All of them need the watch app to be reachable and the phone close to the pod.

- **Settings › Apple Watch › Untethered Watch Mode** (the switch).
- **Start Untethered** on the watch's untethered page.
- **An override** that has *Show Untethered Watch Button* turned on. Starting the override shows a watch button next to it; untethered mode started that way ends when the override ends.
- **The Shortcuts action** *Start Untethered Mode*.

Before handing over, the phone checks that the pod answers, that there is a recent glucose reading (at most 12 minutes old), that no bolus is running, that pod delivery isn't uncertain and that no manual temp basal is running. If something is wrong, it says what and stays in charge.

### While the watch loops

- The phone keeps showing glucose but does not dose. Its home screen shows **Apple Watch** in the pump area and a band on the chart for the time the watch loops.
- Bolus, carbs, overrides and temp targets are entered on the watch. The phone refuses them (including remote commands and shortcuts) and says why.
- The therapy settings the watch doses with are locked on the phone until the hand-back. The dosing mode (closed loop, open loop, low glucose suspend, basal testing) can still be changed on either side.
- The watch alarms on its own: **Urgent Low** (at 54 mg/dL, every 5 minutes), **Low** and **High** (at the glucose range set in Trio), **No readings** (after 11 minutes) and **Not looping** (after 20 minutes). Pod alerts sound on the watch too.

### Ending

- **On the watch:** *Hand Back*. The watch finishes sending its history, reads the pod one last time and gives it back.
- **On the phone:** turn the switch off. The watch hands back as soon as it can be reached.
- **Take Back the Pump Now** (phone) is the emergency path: the phone takes the pod immediately, if it can reach it, and the watch stops.
- **Emergency Stop** (watch) lets go of the pod at once.

After a hand-back the phone reads the pod, compares what the pod says it delivered with the insulin records, and only then doses again. If the pod delivered more than the records explain (by more than 0.2 U), the difference is added as a bolus so insulin on board isn't underestimated, and a note appears on the home screen.

### Starting without the iPhone (optional, off by default)

**Settings › Apple Watch › Allow Start Without iPhone** is for the day you leave without starting untethered mode. While it is on, the phone keeps a copy of your settings, carbs and doses on the watch, renewed at least every 30 minutes. If the iPhone is then out of reach (off, forgotten at home), the watch's untethered page offers **Start Without Phone**. The watch never starts by itself; you have to tap and confirm.

The copy is only used while it is younger than your insulin's action time. Anything the pod delivered after the copy that the copy doesn't know about is counted as a bolus before the watch's first loop. When the phone comes back, it sees that the watch has the pod and stops dosing.

Turning the setting off deletes the copy on the watch and hides the button.

### Good to know

- A sensor the watch has never read before has to be paired with the watch first. Keep Trio open on the watch until the first glucose value shows, and accept the Bluetooth pairing request if one appears.
- The watch's battery drains faster while it loops. The untethered page shows the battery and the log records it at the start and end.
- This is new, experimental code. Test it while awake, with the phone nearby, and check insulin on board after each session.

## For reviewers

### Pieces

| Where | What |
| --- | --- |
| `Trio/Sources/Models/Untethered/UntetheredSession.swift` | The hand-over protocol as a pure state machine, one per device. All transitions are unit tested. |
| `Trio/Sources/Models/Untethered/UntetheredMessage.swift` | The messages and the grant (everything the watch needs to loop: settings, history, device configurations). |
| `Trio/Sources/Models/Untethered/UntetheredRecord.swift` | What the watch records while it loops, and the checksums used to sync it back. |
| `Trio/Sources/Models/Untethered/UntetheredAudit.swift` | Compares what the pod delivered with what the records explain. |
| `Trio/Sources/Services/Untethered/UntetheredPhoneManager.swift` | The phone's side: starts sessions, holds its own dosing, takes the pump back, stores the watch's history, runs the audit. |
| `Trio Watch App Extension/Untethered/` | The watch's side: device managers, the loop, history, alarms, screens. |
| `Trio/Sources/APS/OpenAPS/OrefPipeline.swift`, `GlucoseSmoothing.swift`, `Storage/TDDCalculator.swift`, `BolusCalculator/BolusCalculator.swift` | Code moved out of the phone-only services so the watch runs exactly the same steps. The phone calls the same functions as before. |

### Who may dose

Exactly one device commands the pod at any time. `UntetheredGate.phoneMayDose` is read by every phone path that can dose (loop, bolus, remote commands, shortcuts). It is false from the moment the phone hands the pod over until it has read the pod back and finished the audit.

Each session has an **epoch** (seconds since 1970 when it started). Every message carries it, and both sides ignore messages for another epoch. That keeps a late message from an earlier session from changing anything.

### Starting

1. The phone sends a **grant** with a short lease (2 minutes).
2. The watch checks it and answers **prepared**.
3. The phone finishes any loop in flight, hands a running temp basal over (a high one is cancelled), releases the pod and sends **commit**.
4. The watch takes the pod and reads it. Only after a successful read does it report **takeover complete**.

If the watch is silent, the phone keeps the pod. If the lease runs out mid-takeover, the watch lets go. If the phone loses track of the watch, it asks once and, without an answer, takes the pod back and audits.

### Ending

The hand-back has two phases: the watch keeps looping while its history drains to the phone, then stops looping, reads the pod and offers it. It holds the pod until the phone acknowledges, at most 60 seconds; after that it lets go anyway and keeps offering. Once let go, it never takes the pod back by itself, so a lost acknowledgement can't leave both devices dosing.

### Starting without the phone

The phone sends a **standing grant** (issued already expired, so it can't start a normal session) while the setting is on. The watch starts from it only on the user's tap, with an epoch of its own. Two guards cover the case where the phone is still alive somewhere:

- While a standing grant is out, the phone's pod connection refuses to command the pod once it sees that another controller has used it (OmniPodKit's foreign-session check). It then asks the watch, and stands aside on the watch's word.
- After any pause of 10 minutes or more in its own loops, the phone compares the pod's delivered total with its records and books what it can't explain.

### History

The watch records pump events, glucose, carbs, adjustments, determinations, TDD and autosens. Records go to the phone in small batches, paced around the sensor's reading window (watch Bluetooth is shared with WatchConnectivity). The phone compares 30-minute checksums with the watch and asks again for anything missing, so a session's history ends up complete even after relaunches or lost transfers.

### Submodules

This needs changes in four submodules. All commits are reachable through the loopandlearn forks:

- **LoopKit**: device hand-off protocols (`ExclusiveDeviceControl`, `DeviceConfigurationSharing`, `PumpDeliveryOdometer`) and the foreign-session refusal.
- **OmnipodKit**: pod hand-off, a watchOS target, deactivating a pod on the watch, refusing commands after foreign control.
- **RileyLinkKit**: watchOS targets.
- **G7SensorKit**: reading the sensor in its watch display slot, rebonding, and telling an unfinished pairing apart from a wrong code.

### Tests

`TrioTests/OpenAPSSwiftTests/UntetheredTests.swift` covers the state machine (start, end, lost acknowledgements, emergency paths, start without the phone, foreign sessions), the audit, the history checksums and the temp basal hand-over. They run with the algorithm package: `swift test --package-path AlgorithmPackage --filter Untethered`.

## Credits

Designed and written by Elias Maurer ([EJM0/Trio, `feat/direct-to-watch`](https://github.com/EJM0/Trio/tree/feat/direct-to-watch)), building on the hand-over design in [LoopKit/Loop#2545](https://github.com/LoopKit/Loop/pull/2545).
