# Watch Loop: who controls the pump

The Watch Loop lets Apple Watch run Trio's loop while the iPhone is away: the watch reads the CGM, runs the same
oref pipeline and drives the pump. This document says, for every situation, which device controls the pump. It
follows LoopKit/Loop#2545 (Sport Mode) and its control document; the row numbers are the same.

The decisions live in `WatchLoopControl` (`Trio/Sources/Models/WatchLoop/WatchLoopControl.swift`), one pure function
tested row by row in `WatchLoopControlTests`. The phone carries them out in `WatchLoopPhoneManager`, the watch in
`WatchLoopSession`.

## Principles

In priority order. Rule 1 is never traded.

1. **Insulin is conserved.** No device doses closed loop without every unit the pump delivered being in its records
   or counted conservatively first (booked as a bolus now, so dosing errs low). The pump's own delivered total
   (`PumpDeliveryOdometer`) is the independent check.
2. **Nobody takes the pump from a device that is looping it.** A tap names the device that loops; while it is awake
   and reaches the pump, only another tap changes that.
3. **Looping conservatively is safer than not looping.**
4. **When 2 and 3 conflict, a query decides.** The device that could loop asks the other. An answer settles it in
   the other's favour; silence (or "I hold it but cannot reach it", or "I hold nothing") counts as not looping.
5. **A device that was off queries before touching the pump.** An inferred takeover is not undone when it returns.
6. **The phone looping is the resting state; the Watch Loop is entered only by a tap.** The watch never takes a
   silent phone's pump: it cannot tell a dead phone from one left at home.
7. **Tell the looper.** Whatever a device inferred, it says so; a refusal names what can be done.

Control changes on evidence (a tap, the other device's word, a pump reading, silence after a query), never on a
clock. Clocks only decide when to ask.

Not fallbacks: noisy readings, a sensor warming up or failing. They are the CGM's business and never move the pump.

## The table

| # | Situation | Pump held by |
|---|---|---|
| 1 | Start on the watch, phone near | watch, by grant |
| 2 | Start on the watch, phone away | watch, from the standing copy, after the looper confirms |
| 3 | Phone dies, no session | nobody; the pump runs its schedule. The watch warns after 25 min |
| 4 | Phone back, no session | phone |
| 5 | A pump reading shows insulin the phone's records lack | phone, after asking (booked regardless) |
| 6 | Message from a closed session | phone; the watch gets the stop again |
| 7 | End on the watch, phone near | phone, by hand-back |
| 8 | End on the watch, phone away | watch; the End is refused |
| 9 | Take Back on the phone | phone, if it reaches the pump within 5 s |
| 10 | Watch silent for 6 min, phone sees the sensor | phone, after a query (30 s) |
| 11 | Watch silent, phone away | nobody; the pump runs its schedule |
| 12 | Watch back from off, phone holds the pump | phone; the watch stands aside |
| 13 | Watch back from off, nobody answers | watch carries on |
| 14 | Watch cannot reach the pump, phone near | phone: "holds it but cannot reach it" counts as silence |
| 15 | Watch out of reach, phone away | nobody |
| 16 | Phone moves during a session | watch; each checkpoint renews its hold |
| 17 | Phone returns, watch started alone and alive | watch; the phone stands aside |
| 18 | Phone returns, watch started alone and dead | phone, after a query |
| 19 | Watch back after the phone took over on silence | phone; a session older than the takeover gets a stop |
| 20 | Phone returns, watch started alone, watch can't reach the pump | phone |
| 21 | End, phone away, watch started alone | watch |
| 22 | Watch started alone dies, phone away | nobody |
| 23 | Both dead | nobody |

## Transfers

A transfer that does not complete returns to the state before it, or to the resting state if that is unknown.

- **Nobody takes the pump during a bolus, or with a command unconfirmed.** Start, End and Take Back are refused with
  the time the bolus has left, or with "The pod hasn't confirmed the last command yet." (the driver refuses
  `releaseControl()`).
- **Grant.** The phone checks Watch Loop is on, the CGM shares its configuration, no bolus runs; reads the pump's
  total; releases the pump; sends the grant. A request older than the 60 s lease is refused. If no report arrives
  within the lease the phone queries and takes the pump back on silence ("Watch Loop Didn't Start").
- **Checkpoints.** The watch sends one every cycle, records or not; it is the sign of life. A cycle that cannot
  reach the pump sends none (row 14). The phone stores each record once (by id), then acknowledges; the watch
  resends until acknowledged. Doses keep their pump `syncIdentifier`, so storing twice updates one row; a bolus
  under way is stored mutable and replaced by the finished one. Records of a session that is over are still stored
  (rule 1) except carbs, which can no longer be dosed for.
- **Hand-back.** The watch offers the pump with its last records, resending until acknowledged. The phone stores
  them, takes the pump (30 s), acknowledges, and audits: the pump's total since the grant against the records plus
  scheduled basal where no temp ran. With complete records a difference is only logged.
- **Take-back** (tap or silence). The phone takes the pump and sends the stop. The records may be incomplete, so
  insulin the records miss beyond 0.2 U is booked as a bolus now, with reminders after 2 and 4 h; insulin they
  overstate raises a warning.
- **Wire.** Messages carry a version and an id; both sides drop the second copy. What a person or a query waits
  through rides both channels (`sendMessage` and `transferUserInfo`), bookkeeping only the queued one; nothing above
  60 KB goes live.

## On the watch

`WatchLoopSession` holds the session: it asks for the pump (`start`), builds the phone's pump from the grant's export
and takes it within the lease, then runs a cycle on each CGM reading, with a background refresh 6 min after each
cycle as the backstop. A cycle reads the pump first; one that can't reach it doses nothing and reports nothing
(row 14). Otherwise it runs the phone's oref phases (`OrefPipeline`) on the grant's settings, the phone's last day of
history and the watch's own doses, carbs and readings, enacts as the phone does, and sends a checkpoint. Off, the
loop determines but enacts nothing (open loop). Bolus, carbs, overrides and temp targets entered on the watch during
a session go to the session, are recorded and sent with the next checkpoint. A pod deactivated or discarded on the
watch ends the session; the phone forgets the pod.

While it loops, every page of the watch app and its complications show the watch's own IOB, COB, last loop and
forecast. The phone shows a banner and a glow, locks treatments and the settings the watch doses with, draws its
chart without the forecast, pauses its glucose alarms (the watch raises them from its own readings), and counts the
watch's loops as loops, so Not Looping waits for them. Dead man's switches on the watch, scheduled ahead and pushed
out by each sign of life, warn when it hasn't looped for 20 min, when a hand-back goes unconfirmed for 2 min, and
with no session when the phone has been silent for 25 min (row 3). An End the pod driver refused with a command
unconfirmed is offered again after the next cycle reached the pod.

After a relaunch a session with its pump saved resumes, reports to the phone and doses nothing for 30 s: a phone
that holds the pump answers with the stop (rows 12, 13).

## Without the phone

Each behind its own setting, both needing Watch Loop.

- **Allow Without iPhone.** The phone leaves a copy of the grant with the watch (`standingCopy`), renewed after its
  own loops when insulin, carbs or settings changed and every 30 min; only the newest waits in the queue. When the
  phone doesn't answer a Start within 10 s, the watch offers to start from a copy younger than the insulin's action
  time (row 2). It takes the pump under a session above any it knows, reads the pump's total and counts what the
  copy's records don't explain as a bolus of its own (the phone's doses since the copy), so it doses low rather
  than twice.
- **Fallback Loop.** On each of its own live readings with no session, the watch starts from the copy by itself
  when the phone hasn't read the sensor or looped for 10 min, two of its own readings 5 min apart from the last
  12 min are ones the phone doesn't have, no sensor problem showed in the last 15 min, and the phone doesn't answer
  (`WatchLoopFallback`). Backfill doesn't count. The session goes back by itself once the phone answers with fresh
  readings.
- **The phone's check.** While a copy is out, each dose the phone sends (loop or bolus) waits for a pump reading
  whose total its own records explain. Insulin they don't means a watch dosed: the phone asks it; a watch holding a
  newer session gets the pump (row 17), anything else is booked as a bolus and the phone loops on (rows 5, 18).
- **The watch's check.** Each cycle compares the pump's total with the watch's records the same way. Insulin they
  don't explain is counted, the cycle doses nothing, and doses wait for the phone's word until it has answered once,
  as they do after a hand-back nobody answered.

## Retries

- A grant waits up to 20 s for the phone's own loop to finish talking to the pod; still looping, the Start is
  refused with "Your iPhone is looping right now".
- The phone sends a stop again on each overdue check, until the watch reports it holds nothing (at most 30 min): a
  watch that was off when it was sent hears it when it comes back.
- Standing aside, the phone asks its pod driver to let go until it does (30 s); a driver that keeps the pod for an
  unconfirmed command keeps the phone in charge.
- A takeover of a pod last held by another controller searches for it by its advertisement, which needs the radio:
  the watch asks the looper to keep its screen on and taps every 10 s until the pod answers.

## Known limits

- After a take-back the pump may not answer the audit's read; the phone then skips the audit and logs it.
- Rows 3, 11, 15, 22 and 23 leave nobody looping; the pump falls back to its schedule.
- The hand-back waits up to 45 s for the phone, which acknowledges only once it has the pump; Loop answers the
  first offer at once.
- The watch's bolus recommendation still comes from the phone.
