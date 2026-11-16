# Proposal for loopandlearn/OmnipodKit#177: stop a controller that lost the pod

This is a draft for the maintainer to post on #177. Until upstream decides, Trio carries it as a local patch on #177 @ `3d21d9c` (ADR-007), on the local OmnipodKit branch `trio-on-watch` (commits listed in `implementation-status.md`, M2b).

---

Hi @jeremybarnum,

Trio is building its watch mode on #177, and we found a gap we think belongs in the kit. Below are the problem, a proposed rule, a patch and its tests. Happy to drop ours if you'd rather solve it differently.

**Problem**

After a take-back the other controller never heard about, that controller keeps dosing. For example, the user takes the pod back on the phone while the watch is out of range or asleep.

- At `3d21d9c`, the stale controller's next handshake gets an EAP SQN resync. `resolveAfterSessionResync()` drops its unconfirmed command and logs the resync, and then the session goes on: the retry handshake succeeds and the command is sent (`BlePodComms.establishNewSession`, `bleRunSession`).
- Nothing reaches the host: no property, no delegate call, no error, only the device log. The host can't stop the next command, because any check it makes runs before the handshake that would reveal the foreign session.
- So two controllers dose the same pod in turn. A test fork of #177 hit exactly this: "the phone took the pod back, its stop didn't reach the sleeping watch, and both dosed it in turn until the watch app was opened".

**Rule**

- A controller that adopted the pod, or took back a pod it had released, expects one resync: the other controller's sessions from before.
- Any other resync on a shared pod means another controller used it, and every one is reported. What happens next depends on how this controller holds the pod, which only the host knows:
  - **It believes it holds the pod alone.** Then it runs no session, sends the pod nothing and lets go of the pod's one BLE link, until its host makes an explicit superseding take (below).
  - **The host took the pod on purpose from a peer that may not know yet** (a Take Back while the watch is out of reach). Within that take's scope, the peer's late sessions are expected: they are reported so the host can audit the delivered total and alert, and this controller keeps commanding. Otherwise the stale watch could lock out the phone that just took the pod back.
- The scope ends at its expiry (Trio uses 6 h), when the host says the peer has stopped, or when this controller releases the pod. Within one boot it runs on `CLOCK_MONOTONIC_RAW`, which counts sleep (unlike `systemUptime`), so neither a clock change nor a mostly-asleep phone can stretch it.
- "Nothing" includes reductions and suspends, not only insulin-adding commands. The controller that has the pod doesn't know about any of them:
  - A zero temp or a suspend from the stale controller cancels the owner's temp or SMB plan without a record on the owner's side.
  - A resume undoes a suspend the user just made on the owner.
  - Each is a second commander changing delivery behind the owner's back. While the stale controller is quiet, the pod's scheduled basal is the fail-safe.
- Status reads stop too. Each read is a handshake, which moves the pod's counter on, so the owner would see a foreign session of its own and stop too. For the same reason there is no retry handshake after the resync that found the foreign session.
- This controller's own counter, saved late, is not a foreign session. The last EAP SQN the pod accepted from this controller is saved at once, outside the pod state the host persists. A resync at or below it is this controller's own counter catching up.
- An adopt is bounded by the release it came from. An export made after the exporter released the pod carries the EAP SQN at the release (`releasedEapSqn`). The adopter's resync up to it is expected; one beyond it is a session since the release, another controller's, so the adopter refuses. Without the bound, an adopt still in flight when the exporter takes the pod back (a Take Back between the export and the adopter's first handshake) would absorb the exporter's new session and both would command. An export made without a release (the offline start) carries no bound and works as before.

**Patch** (on #177 @ `3d21d9c`, about 230 lines of source plus tests)

`PodState` fields, all persisted and none exported:
- `expectsSessionResync`, `foreignSessionDetectedAt` and `refusesSessions`.
- `supersedingTake`: since, until, and the `CLOCK_MONOTONIC_RAW` reading and boot session at the take.

The handshake decisions are `PodState` methods, called by `BlePodComms.establishSession` / `establishNewSession`:
- `nextHandshakeSqn()`, which is nil while refusing;
- `handshakeResynced(to:lastAcceptedHere:)`;
- `sessionEstablished()`.

`PodState.releasedEapSqn` is set on an export made after a release, kept through the adopt and a relaunch, and spent by the adopter's first session. `handshakeResynced` treats a resync beyond it as foreign.

`AcceptedEapSqn` holds the last SQN the pod accepted from this controller, in this device's own `UserDefaults` (never exported), keyed by the pod's lot and sequence numbers. It is written right after the pod accepts a handshake and removed when the pod is forgotten.

`OmniPumpManager`:
- `takeControl(supersedingAnotherControllerUntil:)` lifts a refusal and starts a scope.
- `takeControlLiftingRefusal()` lifts a refusal without a scope, for when the other controller is known to have stopped.
- The protocol's `takeControl()` lifts nothing and keeps any scope. On a refused manager it stays off the radio: no re-arm and no search by address. It marks the next resync as expected only if this controller had released the pod.
- `stopSupersedingAnotherController()` and `releaseControl()` end a scope.
- `foreignSessionDetectedAt` and `refusesSessions` are read-only. Every change reaches the host through `pumpManagerDidUpdateState`.

While refusing:
- `OmniPumpManager.runSession` refuses before dialling.
- `establishNewSession` makes no handshake.
- `bleRunSession` refuses.
- The last two let go of the link (`releaseConnection()`), and a refused manager doesn't dial at launch.
- The error is the new `PodCommsError.podUsedByAnotherController`, which has a recovery suggestion.

On a shared pod a new process never trusts saved session keys (`BlePodComms.init`), so its first session handshakes. A link restored after a relaunch can't skip the rule.

Pods that were never shared behave exactly as before.

**Host contract**

- Call the plain `takeControl()` only right after `init(adopting:)`, or to take back a pod after an acknowledged hand-back. Never call it to "check" the pod; read `refusesSessions` / `foreignSessionDetectedAt` instead.
- Call `takeControl(supersedingAnotherControllerUntil:)` only for a user-confirmed takeover from a peer that hasn't acknowledged stopping. If you redo it after a relaunch, pass the original `until`.
- Only one side of a pairing ever makes a dated take (in Trio, the phone). Two scopes in opposite directions would leave both controllers commanding, and the kit can't detect that. A future takeover from the other side first needs this side's scope ended, by a release or an acknowledgement.
- To lift a refusal without superseding anyone (the other controller is known to have stopped), call `takeControlLiftingRefusal()`. Don't pass a future date for that: it would open a scope after a refusal whose source is unknown.
- Call `stopSupersedingAnotherController()` when the peer acknowledges that it stopped.
- On `refusesSessions`: stop, alert and call `releaseControl()`. Taking control again is the user's decision.
- `takeControl(…)` and `stopSupersedingAnotherController()` wait out a session in progress, so call them off the main thread.

**Tests** (`DeviceHandoffTests`, 22 new)

The pod double keeps the EAP counter and the latest session keys, and drives the same `PodState` handshake methods the kit does. The double tests cover:
- a lend and a hand-back, which find no foreign session;
- a take-back while the watch is away: the watch's next session is refused, nothing is sent and the counter doesn't move;
- the race where the stale watch handshakes first after the take;
- a superseding phone, which reports every foreign session and keeps commanding;
- the end of the scope at expiry, at the peer's stop, and with a clock set back across a reboot;
- a sole holder, which stops;
- this controller's own late-saved counter, which is not counted as foreign;
- stale keys, which open nothing;
- that only a superseding take lifts a refusal;
- that the refusal survives a relaunch;
- the scope's uptime and wall-clock rules.

Manager-level tests use an Eros-typed `OmniPumpManager`. The refusal is in `runSession`, which is the same for every pod type, and an Eros manager needs no Bluetooth central. They cover:
- a refusing manager, which fails a status read and a zero temp with `podUsedByAnotherController`, while the same manager without the refusal reaches the radio;
- a plain take, which keeps the refusal, and a superseding take, which lifts it;
- a plain take inside a scope, which keeps the scope, and a release, which ends it;
- a plain take without a release, which expects no resync.

Bounded adopt: the Take Back between export and adopt (the adopt refuses, the phone keeps commanding alone), an adopt with nothing after the release, an export without a release (no bound), and the manager's own export after a release carrying the bound.

**Limits**

- One stale session can still run. A stale controller that reaches the pod before the owner's first handshake after the take can't be told apart from the owner's expected resync, so its session runs. The owner's delivered-total audit has to account for its insulin.
- Handshake attempts that never reached the pod (a link drop mid-EAP) still advance the stale controller's counter. A stale controller with at least *n* such attempts is accepted after the owner's *n* handshakes. It runs one full session and is refused at the next one. A superseding owner reports it, and its audit covers it.
- Some kit guards are checked by reading only, because a `BlePodComms` can't be built without a Bluetooth central: the `init` condition, the refusals in `establishNewSession` and `bleRunSession`, letting go of the link, and saving `AcceptedEapSqn`.
- Our reading of the protocol, not a pod trace: that a resync-answered handshake leaves the pod's counter unchanged, and that a message under stale keys is dropped.
- None of this has run on hardware.

Best,
Dan
