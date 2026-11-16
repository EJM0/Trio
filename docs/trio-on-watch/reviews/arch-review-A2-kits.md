# Architecture review A2: kit feasibility (LoopKit, OmnipodKit #177, G7SensorKit)

Reviewer: Agent A2 (kit inventory, `research/experimental-kit-forks-inventory.md`).

Reviewed: `architecture/{target-architecture,state-and-synchronization,architecture-decisions}.md` and
`implementation/roadmap.md` (M2). Kit code was read at the SHAs named below. All builds and tests ran in the A2
scratch directory (`/private/tmp/claude-501/-Users-dnzxy-workspaces-Trio/3f8cbd66-3ec5-4539-8f2f-f9e5df9ae9dc/scratchpad/A2/`);
nothing was built in a Trio checkout. **Verified** means I read the code or ran the build. **Inferred** means I
reasoned from verified code. **Unverified** means it is claimed elsewhere and I did not check it.

Severity: **blocker** = must change before the milestone that depends on it starts; **major** = must change before
that milestone is accepted; **minor** = fix when touched.

## Summary

- ADR-003 is right to reject the kristinkand forks and to use #177, but two of its claims are wrong.
  - "LoopKit as pinned" is wrong. Every #177 commit from `d2ea4ba` on needs LoopKit#687, and the #177 head needs
    LoopKit#695/#696 as well. Those two break five other Trio kits.
  - Taking the #177 head is wrong. The pin should be #177 @ `3d21d9c`, with LoopKit moved by #687 only. That
    combination builds for iOS, the watchOS simulator and `arm64_32`, and #177's 28 hand-off tests pass.
- #177 detects another controller's session internally, but it neither exposes that to the host nor refuses to send
  commands afterwards. Two places in the architecture assume it stops a stale watch: the "Stale watch" rule and
  Take Back step 3. It does not, so the Take Back design can leave two controllers dosing.
- A device that has released the pod can't read it, because the kit refuses every session while released. So the
  odometer readings at lend step 5 and hand-back step 2 must happen before `releaseControl()`.

## Build matrix (Verified)

The matrix uses Xcode 27.2 with `CODE_SIGNING_ALLOWED=NO`. RileyLinkKit is at `52a652c9`, the same pin as Trio dev.

| LoopKit | OmnipodKit | G7SensorKit | Result |
|---|---|---|---|
| `babddf04` (Trio pin) | #177 head `e8216cd` | — | **Fails** on iOS and watchOS. Missing: `PumpManagerPlugin` (#687), `doseId` (#695), async `PumpManagerDelegate.notify` (#696). Logs `r2/A-*.log` |
| `babddf04` + next-dev to `89f93e3a` (#687, #696, #695) | `e8216cd` | `08d48863` (Trio pin) | OmnipodKit builds on iOS and watchOS. **G7SensorKit fails**: `delegate.queue` was removed and calls are now `async` (#696). Logs `r2/B-*.log` |
| same as above | — | — | **DanaKit (20 errors), MedtrumKit (15), MinimedKit (2), LibreTransmitter (13) fail** at Trio's pins: `decisionId`, `PumpManager` conformance, `async`. Logs `r3/N-*.log` |
| `babddf04` + `a78fe3bb` (#687 and the 3 next-dev commits before it) | #177 `8259964` | `08d48863` | All build: OmnipodKit-watchOS, OmnipodKitPlugin (iOS), G7SensorKit-watchOS, G7SensorPlugin (iOS). Logs `r3/C-*.log` |
| same as above | #177 **`3d21d9c`** | `08d48863` | OmnipodKit-watchOS builds for the simulator and for the device (`arm64_32`). OmnipodKitPlugin (iOS) and OmniTests build. **`OmniTests/DeviceHandoffTests`: 28 tests, 0 failures** on a fresh iPhone 17 / iOS 27.2 simulator. Logs `r3/D-*.log`, `r3/T-handoff.log` |
| same as above | — | — | DanaKitPlugin, MedtrumKitPlugin, MinimedKitPlugin and LibreTransmitterPlugin build at Trio's pins. Logs `r3/K-*.log` |

Not run:
- the full Trio app or the watch app against the moved LoopKit (that belongs in M2);
- the other kits' tests;
- anything on hardware.

## Findings

### A2-01 (blocker for M2): ADR-003's "LoopKit as pinned" is wrong. The pin must move, by #687 only.

- **Evidence:**
  - #177 commit `d2ea4ba` ("The watch loads OmnipodKit at run time") adds `OmnipodKitWatchPlugin: PumpManagerPlugin`.
    `PumpManagerPlugin` comes from LoopKit#687, merged as `a78fe3bb` and not an ancestor of `babddf04`.
  - #177's later merges of upstream `next-dev` (#216 `doseId`, #220 async delegates) need LoopKit#695 and #696.
  - Build matrix rows 1 to 3.
- **Smallest move:** loopandlearn/LoopKit `trio-next-dev` = `babddf04` merged with LoopKit `next-dev` up to
  `a78fe3bb`.
  - This also brings #671 (VoiceOver), #689 (InsulinMath suspend overlay) and #691 (display placeholder), which sit
    before #687 on next-dev's first-parent line.
  - #689 changes `InsulinMath`. Trio's only `InsulinMath` user is `TidepoolManager.swift`, which is upload only, not
    dosing (Verified by grep). Cherry-picking #687 alone also works, if that is preferred.
  - #687's API changes are additive: `PumpManagerPlugin`/`CGMManagerPlugin`, and `isSearchingForSensor` /
    `shortStatusNote` with defaults. Trio's plugin registry doesn't use `pumpManagerType` (Verified).
- **Do not** take #695/#696 (LoopKit `next-dev` tip). They break G7SensorKit, DanaKit, MedtrumKit, MinimedKit and
  LibreTransmitter at their current pins (rows 2 and 3). This matches the house rule against fast-forwarding kits onto
  LoopKit next-dev.
- **Change:** amend ADR-003 and M2 as above. Add to M2's acceptance: the iOS app and **every** kit plugin build
  against the moved LoopKit. I only checked four kits plus G7 and Omnipod.

### A2-02 (blocker for M2): pin #177 @ `3d21d9c`, not the head

- **Evidence:**
  - `3d21d9c` ("Merge upstream next-dev", 2026-11-11) has parents `8259964` and next-dev `2a7ef46` (#219).
  - Every #177 safety commit is an ancestor of it: `8fe606c` (keep the pod while unconfirmed), `a96f5d0`,
    `8f2b4db` (no session before a handshake), `a002df5` (missing key), `b117532` (released pod sent nothing),
    `0af1bb3` (connect clock per manager), `6766e62` (simulator mocks only a mocked pod), `2a2f020`/`b6d251a`
    (faulted pod). It also has next-dev's #205, #209 (`a83ee11`: don't report a never-written message as
    unacknowledged), #211 and #214.
  - Compared with the head `e8216cd`, it lacks only next-dev's #216/#220 and #177's own adaptation to them (`e8216cd`).
    None of those is safety content (Verified with `git log 3d21d9c..e8216cd --no-merges`).
  - Trio's current OmnipodKit pin `6fdf0e0e` is an ancestor of it.
- **Hosting:** the head is `jeremybarnum/OmnipodKit` branch `sportmode/next-dev` (PR loopandlearn/OmnipodKit#177,
  open, MERGEABLE, last updated 2026-11-12).
  - `3d21d9c` is a commit in the middle of a personal branch, so a rebase there could make it unreachable.
  - Mirror it into a loopandlearn branch (for example `loopandlearn/OmnipodKit` `trio-sportmode`), as Trio already
    does with `trio-next-dev`. That is a pinned upstream branch, not a Trio-owned fork, so ADR-003's "no forks" holds.
- **Change:** in M2, replace "pin to the #177 head" with "pin to #177 @ `3d21d9c` (mirrored)".
  - Re-evaluate when Trio's kit set moves to LoopKit#696/#695. That move is a separate, whole-kit-set bump.
  - LoopKit#686 (open) is not needed to compile. `deactivateFailedDevice()` and `forgetDeviceDeactivatedElsewhere()`
    are plain methods at `3d21d9c` (Verified).

### A2-03 (blocker for the Take Back design, M3–M5): #177 does not stop a stale watch

- **Evidence (Verified at `3d21d9c`):**
  - On an EAP SQN resync, `BlePodComms.swift:384` calls `PodState.resolveAfterSessionResync()`. That drops an
    unconfirmed command with nothing booked, marks untracked delivery as foreign, and writes a device-log line.
    Then the session **continues**.
  - No property, delegate call or error reports the resync to the host. `lastForeignSessionAt`,
    `refusesForeignSessionsSince` and `lastSqnResync` don't exist in #177; upstream removed `lastForeignSessionAt`
    from LoopKit in `2aecef07`.
  - The only refusal in `runSession` is `podConnectionReleased` (`OmniPumpManager.swift:1769-1775`).
- **Consequence (Inferred):** after a Take Back while the watch is unreachable, the watch's next cycle handshakes,
  resyncs and then sends its temp basal or SMB anyway. Phone and watch then dose the same pod in turn. The
  experimental branch hit this in testing (`UntetheredWatchManager.swift:665-669` @ `a56170dc0`).
  - The host can't close this gap by itself. The resync shows up inside the same session that sends the command, so
    any check the host makes beforehand uses information that is one session old.
  - Loop#2545 handles the mirror case on the phone side (`c491bf7f`: the phone holds dosing while it asks the
    watch). It has no watch-side equivalent.
- **Wrong in the docs:**
  - `target-architecture.md` §3, "Stale watch: … a foreign pod session (OmnipodKit#177 SQN-resync detection) stops
    all pump commands at once".
  - `state-and-synchronization.md` Take Back step 3, "detects the foreign session at its next pod contact (#177)".
- **Change: pick one.**
  - (a) Ask #177 for an opt-in, fail-closed kit rule: an adopted or released manager refuses to start a session
    after a resync it didn't expect, checked between the handshake and the first command, plus a read-only signal for
    the host. This is the fork's mechanism. Upstream turned down the protocol surface, not necessarily a kit-internal
    rule. Raise it on #177 rather than forking.
  - (b) Until (a) lands, drop "Take Back while the watch is unreachable" from v1. Take Back then needs the watch's
    acknowledged release, and the user is told to power the watch off or remove the Trio watch app before a forced
    take.
  - Either way, add a test with the pump double: after the phone takes over, the watch's next command must fail.

### A2-04 (major, M3/M4): reading the odometer after `releaseControl()` always fails

- **Evidence (Verified):**
  - `refreshDeliveredUnits()` calls `getPodStatus`, which goes through `runSession`. `runSession` refuses with
    `podNotConnected` while `podConnectionReleased` is set (`OmniPumpManager.swift:1769-1775`,
    `+DeviceHandoff.swift:335-360` @ `3d21d9c`).
  - The export header's `deliveredUnits`/`asOf` is only the last status the manager already had
    (`sharedConfiguration`, `+DeviceHandoff.swift:65-77`). It is not a fresh read.
- **Wrong in the docs:**
  - Lend step 5 runs "reads the odometer" after step 4's release.
  - End step 2 sends `handBack(…, odometer)` after `releaseControl()`.
- **Change:** order both as `await refreshDeliveredUnits()` → (cancel temp) → `releaseControl()` → check
  `isControlReleased` → `exportConfiguration()`.
  - If the temp cancel comes after the read, either take a second read or count the cancel in the audit.
  - The device taking control reads the odometer after `takeControl()`, once
    `deviceManagerControlDidBecomeReady` fires.

### A2-05 (major, M4): the odometer audit formula is incomplete

- **Evidence:**
  - The pod delivers scheduled basal on its own. Trio's pump history records temp basals and boluses but no
    scheduled-basal dose events.
  - `deliveredUnits` is `(units, at)`, stamped with the pod status time.
  - `bolusUnderWayEndsAt` comes from the pod's own report, so it covers a bolus whichever device started it.
  - `deliveredUnitsAreFinal` is true for a faulted pod.
  - All Verified at `+DeviceHandoff.swift:316-332` @ `3d21d9c`.
- **Wrong in the docs:** `state-and-synchronization.md` says "expected delivery is the sum of booked doses since
  release". That leaves out scheduled basal, so any loan longer than a few minutes would book a large false "excess".
  (Inferred)
- **Change:** expected = scheduled basal from the snapshot profile over the interval, minus suspensions, plus temps
  (rate × time actually run) plus the delivered portions of boluses.
  - Don't judge while `bolusUnderWayEndsAt` is in the future.
  - Use the pulse size from `deliveryPulseUnits` for the tolerance.
  - Measure the interval between the two `deliveredUnits.at` stamps, not wall-clock time.
  - Have a safety reviewer and a test check the formula before M4.

### A2-06 (major, M3–M5): how a refused release is signalled, and how the host must check it

- **Evidence (Verified, `+DeviceHandoff.swift:95-104, 178-193` @ `3d21d9c`):**
  - `releaseControl()` is synchronous and doesn't throw. When `podState.unacknowledgedCommand != nil`
    (`mayReleaseControl`), it only writes a device-log line and returns.
  - Otherwise it sets `podConnectionReleased` synchronously through `setState`. The BLE drop is asynchronous: it waits
    up to `loanReleaseWaitLimit` = 20 s for a live exchange (`BluetoothManager.swift:248`), and no new command is sent
    meanwhile.
  - A running bolus does **not** block the release. Its `UnfinalizedDose` moves with the pod
    (`inFlightDosesInheritedAway`).
- **Host contract:**
  1. No loop or command may be in flight. The host serializes this; the kit doesn't wait.
  2. Call `releaseControl()`.
  3. Read `isControlReleased` immediately. False means refused because a command is unconfirmed. Stay the owner,
     keep dosing gated as "uncertain", and show the reason.
  4. Export only after a successful release.
- **Docs:** lend step 4 is correct. Hand-back step 2 must handle a refusal too: the temp cancel just before it can
  itself be the unconfirmed command, so the watch stays `holding` and says why. Add the "unconfirmed command"
  precondition to both lend and end.

### A2-07 (major, M5): adopting on the watch

- **Pump (Verified at `3d21d9c`):**
  - Build the manager with `OmniPumpManager(adopting: SharedDeviceConfiguration(rawValue:), localState:)`. It is
    failable (`OmniPumpManager.swift:198`).
  - `localState` is the `[String: Any]` this watch saved from an earlier `OmniPumpManager.localState`, keyed by
    `pluginIdentifier` (`"Omni"`). It holds `podAddress` + `bleIdentifier` and is ignored for a different pod.
  - When `localState` is nil, `ExclusiveDeviceControl.takeControlNeedsSearch(adopting:localState:)` is true and
    `takeControl()` scans by the advertised address. #177 says this first contact needs the wrist up "for a couple of
    seconds" (Unverified).
  - Then call `takeControl()`. It escalates by itself after 12 s (`takeEscalateAfter`).
  - Readiness arrives as `DeviceManagerDelegate.deviceManagerControlDidBecomeReady` when the session is established
    (`OmniPumpManager.swift:3539`). After that, save `localState` for the next loan.
- **After adopting:**
  - Persist the manager's own `rawState` on every `pumpManagerDidUpdateState`.
  - On relaunch, rebuild from that saved `rawState`. Never adopt the grant again: re-adopting brings back the
    exporter's in-flight doses and discards the watch's own (Inferred from `adopted(handle:)`,
    `+DeviceHandoff.swift:81-93`).
  - Target-architecture step 7 should say this.
- **G7 (Verified at Trio pin `08d48863`):**
  - `G7CGMManager` conforms to `DeviceConfigurationSharing` only, not `ExclusiveDeviceControl`.
  - `exportConfiguration()` carries `sensorID`, `activatedAt` and `pairingCode` (`G7CGMManagerState.swift:253-260`).
  - `init?(adopting:localState:)` ignores `localState` and builds a direct-mode manager in the watch display slot
    with `configuredByAnotherController` set (`G7CGMManager.swift:289-293`).
  - `isConfigurationSharingEnabled` is the user's "Read on Apple Watch" setting (`:1456`), and the phone should
    export only while it is on.
  - On wakes that aren't the sensor's own, the watch must call `recheckAcquisition()` (`:527`).
  - The phone and watch read the sensor at the same time in separate slots. There is no release or take for G7, so
    "lends the pod and the G7" (§1) should read "lends the pod; shares the G7".
  - Persist the adopted manager's `rawState`, which holds its bond and key, and don't re-adopt on every launch.
    Re-adopting resets pairing.
  - Reuse nightscout/Trio#1749's `WatchCGMHost` so there is a single G7 manager. Watch-side pairing needs the app
    on screen, per #1749's body (Unverified).
  - G7 needs no pin move: it builds against LoopKit + #687 (matrix row 4).

### A2-08 (major, M5): restore identifiers and one manager per device

- **Evidence (Verified):**
  - Each OmnipodKit `BluetoothManager` creates a central with the fixed restore identifier `com.OmnipodKit`
    (`BluetoothManager.swift:818` @ `3d21d9c`). There is one per `OmniPumpManager`.
  - G7SensorKit uses the fixed `com.loudnate.CGMBLEKit` (`G7BluetoothManager.swift:267` @ `08d48863`). That is the
    same string CGMBLEKit uses (`CGMBLEKit/BluetoothManager.swift:130`).
  - #1749's body records the failure mode: a new central that shared the restore identifier with the old one never
    powered on until relaunch.
  - The experimental host's comments record a second Omnipod manager that "never connected"
    (`UntetheredWatchManager.swift:817-860` @ `a56170dc0`).
- **What the watch host must avoid:**
  - Never keep two `OmniPumpManager`s or two `G7CGMManager`s alive in the watch process at once. The experimental
    branch's "witness", "meeting" and "look" managers do exactly that.
  - Before building a replacement (new grant, new pod, new sensor), release the old manager, drop every reference
    and let it deinit.
  - Don't vendor a second G7 BLE stack.
  - Don't link or instantiate CGMBLEKit on the watch.
  - Keep `bluetooth-central` in the watch Info.plist. Without it, a central with a restore identifier raises (comment
    at `G7BluetoothManager.swift:262-264`).
- **Change:** add these as host invariants in `target-architecture.md` §2/§7, and make one of them a
  simulator-test assertion.

### A2-09 (minor): simulator testing goes through a mocked pod

- **Evidence:** `mocksPod` is true in the simulator unless a CoreBluetooth bridge (ImpossiBLE) is present. A mocked
  pod fakes `isControlReady` and `refreshDeliveredUnits` (`OmniPumpManager.swift:1345-1351`,
  `+DeviceHandoff.swift:236, 337-349` @ `3d21d9c`). (Verified)
- **Change:** the simulator acceptance for M4/M5 shows only the host's state handling, never pod or BLE behaviour.
  Say so in the roadmap.

## Verdict on ADR-003

**Accept, with amendments.** These amendments are needed before M2:
1. Move LoopKit by #687 only, not "as pinned" (A2-01).
2. Pin OmnipodKit to #177 @ `3d21d9c`, mirrored into a loopandlearn branch, not the head (A2-02).
3. Record that #177 does not stop a stale watch after a foreign session. Either get a fail-closed rule into #177 or
   remove the unreachable-watch Take Back from v1 (A2-03).

Rejecting the kristinkand forks still stands: #177 has the unconfirmed-command release guard that the forks lack.
The "no Trio-owned kit forks" rule also still stands.

## Evidence index

- OmnipodKit #177 (`jeremybarnum/OmnipodKit` `sportmode/next-dev`):
  - head `e8216cd0601c6fe6edfcc58e6a14fdce5d99baaf`;
  - recommended pin `3d21d9c`;
  - files: `OmnipodKit/PumpManager/OmniPumpManager+DeviceHandoff.swift`, `OmniPumpManager.swift`,
    `Bluetooth/BlePodComms.swift`, `Bluetooth/BluetoothManager.swift`, `PumpManager/OmnipodKitWatchPlugin.swift`.
- LoopKit:
  - Trio pin `babddf04`;
  - PRs #626 (`dee2a369`, in pin), #673 (`e27b0ec2`, in pin), #685 (`c6192c6e`, in pin), #687 (`a78fe3bb`, not in
    pin), #696 (`1efbc416`), #695 (`89f93e3a`), #686 (open).
- G7SensorKit pin `08d48863`: `G7CGMManager.swift:289-293, 527, 1450-1457`, `G7CGMManagerState.swift:253-270`,
  `G7BluetoothManager.swift:262-268`.
- LoopKit/Loop#2545 commit `c491bf7f` (message and file list only).
- nightscout/Trio#1749 body. Experimental branch `a56170dc0`: `UntetheredWatchManager.swift:665-669, 817-860`.
- Scratch build logs: `r2/A-*.log`, `r2/B-*.log`, `r3/C-*.log`, `r3/D-*.log`, `r3/K-*.log`, `r3/N-*.log`,
  `r3/T-handoff.log` under the A2 scratch directory.
- Test simulator created for the hand-off tests: `A2-kit-test`, UDID `3F4F7B9B-704D-433F-950A-74A754019CAE`. It is
  still there; delete it on request.
