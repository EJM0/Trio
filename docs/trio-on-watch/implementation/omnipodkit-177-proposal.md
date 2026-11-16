# Proposal for loopandlearn/OmnipodKit#177: stop a controller that lost the pod

This is a draft for the maintainer to post on #177. Until upstream decides, Trio carries it as a local patch on #177 @ `3d21d9c` (ADR-007). The patch is three commits on the local OmnipodKit branch `trio-on-watch`: `d5606d6`, `2e5f9bd` and `b647ea9`.

---

Hi @jeremybarnum,

Trio is building its watch mode on #177, and we found a gap we think belongs in the kit. Below are the problem, a proposed rule, and a small patch with tests. Happy to drop ours if you'd rather solve it differently.

**Problem**

After a take-back the other controller never heard about, that controller keeps dosing. For example, the user takes the pod back on the phone while the watch is out of range or asleep.

- At `3d21d9c`, the stale controller's next handshake gets an EAP SQN resync. `resolveAfterSessionResync()` drops its unconfirmed command and logs the resync, and then the session goes on: the retry handshake succeeds and the command is sent (`BlePodComms.establishNewSession`, `bleRunSession`).
- Nothing reaches the host: no property, no delegate call and no error, only the device log. The host can't stop the next command. Any check it makes runs before the handshake that would reveal the foreign session.
- So two controllers dose the same pod in turn until one of them hears from the other. A test fork of #177 hit exactly this in testing: "the phone took the pod back, its stop didn't reach the sleeping watch, and both dosed it in turn until the watch app was opened".

**Rule**

- A controller that adopted or took the pod expects one resync, from the other controller's sessions before that.
- Any later resync on a shared pod means another controller is using it now, and it is reported every time. What happens next depends on how this controller got the pod, and only the host knows that:
  - **It believed it held the pod alone.** It adopted it, or took it back after an acknowledged release. Then it runs no session and sends the pod nothing until its host takes control again.
  - **The host took the pod on purpose** from a peer that may not know yet, for example a Take Back while the watch is out of reach. Within that take's scope, the peer's late sessions are expected: they are reported so the host can audit and alert, and this controller keeps commanding. Otherwise the stale watch could lock out the phone that just took the pod back.
    - The scope ends when its expiry passes (Trio uses 6 h) or when the host says the peer has stopped. A foreign session after that stops this controller too. A take that isn't scoped (a normal hand-back or an adopt) is never superseding, so this can't fail open.
- "Nothing" includes reductions and suspends, not only insulin-adding commands. The controller that has the pod doesn't know about any of them:
  - A zero temp or suspend from the stale controller cancels the owner's temp or SMB plan without leaving a record on the owner's side.
  - A resume undoes a suspend the user just made on the owner.
  - Each is a second commander changing delivery behind the owner's back. While the stale controller is quiet, the pod's scheduled basal is the fail-safe.
- Status reads stop too. Each read is a handshake, which moves the pod's counter on, so the owner would see a foreign session of its own.
- No second handshake after the resync that found the foreign session, for the same reason.

**Patch** (about 90 lines plus tests, on #177 @ `3d21d9c`)

New persisted fields, none of them exported:
- `PodState.expectsSessionResync`: set by an adopt and by a take, cleared once a session is established.
- `PodState.foreignSessionDetectedAt`: set to the time of every unexpected resync on a shared pod.
- `PodState.supersedesAnotherControllerUntil`: the scope of a superseding take, set by the take from the host.
- `PodState.refusesSessions`: set by an unexpected resync outside that scope.

New public API on `OmniPumpManager`:
- `takeControl(supersedingAnotherControllerUntil: Date?)`. The protocol's `takeControl()` passes `nil`. Either form clears `foreignSessionDetectedAt` and `refusesSessions`, so taking control is the host's explicit claim.
- `stopSupersedingAnotherController()`, for when the peer has acknowledged that it stopped.
- Read-only `foreignSessionDetectedAt` and `refusesSessions`. Both live in `podState`, so every change reaches the host through `pumpManagerDidUpdateState`, with no log parsing.

While `refusesSessions` is set:
- `OmniPumpManager.runSession` refuses before dialling.
- `bleRunSession` refuses after the connect.
- `establishNewSession` makes no handshake.
- Each refusal returns the new `PodCommsError.podUsedByAnotherController`.

Other changes:
- A restored link (state restoration after a relaunch) on a shared pod handshakes again instead of reusing the saved session keys. Those keys may predate another controller's sessions. At `3d21d9c` a restored link reuses them without a handshake, so it would never see the resync.
- Pods never shared behave exactly as before: no flag and no refusal.

A host whose controller is refused should call `releaseControl()` and stop. Taking control again is a user decision.

**Tests** (`DeviceHandoffTests`, 9 new; OmniTests: 255 run, 3 skipped, 0 failures)

The tests use a small pod double. It follows `establishNewSession`: a handshake has to be above the pod's counter or it gets a resync. The double also keeps the latest session's keys.
- A lend and a hand-back find no foreign session on either side.
- Take-back while the watch is away: the watch's next session is refused, so no command of any kind is sent and not even a status read. The refusal is reported, and the pod's counter doesn't move. The phone keeps going unflagged.
- The race where the stale watch handshakes first after the phone's take: that one session runs, because nothing on the pod shows the take yet. That's a limit: the owner's delivered-total audit has to catch its insulin. The phone's resync is the expected one, the watch's next session is refused, and the phone is unaffected.
- A phone that superseded the watch keeps commanding through foreign sessions, and each one is reported with a newer time.
- After the scope's expiry, or after `stopSupersedingAnotherController()`, the same foreign session stops the phone.
- A phone that took the pod after an ordinary hand-back stops at a foreign session.
- Keys from before a takeover open nothing on the double, and the stale controller's new handshake is refused.
- The refusal survives a relaunch, and a take lifts it.
- An export carries none of the new fields. The adopter expects a resync and holds the pod alone.

Checked by mutation:
- Never refusing fails 14 assertions.
- Ignoring the scope's expiry fails the scope test.
- Not reporting fails 6 tests.

**Compatibility with the offline start** (the watch starts without the phone's release)

- The phone's first handshake after the watch's start gets flagged, and the phone stops instead of reading the pod.
- `foreignSessionDetectedAt` is the information that read was for. The host can then ask the watch and either release or take control again, as LoopKit/Loop#2545 does today.

**Not verified**

- None of this has run on hardware.
- The pod double is our reading of the EAP SQN behaviour, not a pod trace. Two pod-side points are unverified:
  - whether a resync-answered handshake leaves the pod's counter unchanged;
  - whether a message under stale session keys is dropped.
- The restored-link handshake can't be unit-tested, because a `BlePodComms` needs a Bluetooth central. It was checked by reading the code only.

Best,
Dan
