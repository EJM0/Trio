# State and synchronization

Status: proposed 2026-11-16.

## Authoritative state

| Data | Authority during a loan | Authority otherwise |
|---|---|---|
| Who may command the pump | The persisted loan state on each device. Only phone `home(e)` or watch `holding(e)` may command. | Phone `home` |
| Pump driver state (`rawState`) | Watch | Phone |
| Doses, pump events | Watch records. The phone merges them by sync identifier. | Phone Core Data |
| Glucose | Both read the G7. Records share the sensor timestamp and sync identifier, so they dedupe. | Phone |
| Carbs | Watch for entries made during the loan. The phone refuses new entries. | Phone |
| Settings, profile, override, temp target | Snapshot frozen at grant. Active override and temp target run to their stored end. | Phone |

## Start (lend) step table

At each step the table shows what is persisted and what happens if a message is lost or a process dies. "Zero" means zero commanders: the pod runs out its temp, then scheduled basal.

| # | Actor | Action | Persisted after | Loss or crash here |
|---|---|---|---|---|
| 1 | Watch | User taps Start. The watch sends `request(knownEpoch)`. | watch `requesting` | Lost: the watch times out after 20 s and shows "iPhone didn't answer". Nothing changed. |
| 2 | Phone | Checks preconditions (SR-4): no bolus running, no unconfirmed command, delivery certain, pump status fresh, versions match, battery OK. | — | Refusal is sent with a reason. |
| 3 | Phone | Persists `lending(e+1)`, then cancels the running temp. | phone `lending(e+1)` | Crash: on relaunch `lending` still holds and the gate stays closed. The phone shows "Start didn't finish", with Take Back. |
| 4 | Phone | `releaseControl()`; checks `isControlReleased`. | — | Not released (unconfirmed command): goes back to `home(e)` and refuses Start. |
| 5 | Phone | Exports state, builds the snapshot, sends `grant(e+1, snapshot)` and reads the odometer. | — | Lost: the phone stays `lending`. After 60 s the user sees "Apple Watch didn't confirm" with Take Back (user tap). |
| 6 | Watch | Validates the grant: complete, versions match, clock and time zone OK. | — | Refusal is sent and the watch goes back to `idle`. The phone shows it, with Take Back. |
| 7 | Watch | Persists `holding(e+1)` and the snapshot, then adopts the managers and `takeControl()`. | watch `holding(e+1)` | Crash before persist: like step 5's loss. Crash after: relaunch resumes `holding` and runs the restore checklist. |
| 8 | Watch | Sends `holding(e+1)`. | — | Lost: the phone stays `lending`. The next record batch (it carries the epoch) moves the phone to `lent`. |
| 9 | Phone | Persists `lent(e+1)`. | phone `lent(e+1)` | — |

## End (hand-back) step table

| # | Actor | Action | Persisted after | Loss or crash here |
|---|---|---|---|---|
| 1 | Watch | User taps End. The watch checks that the phone is reachable and that preconditions hold (no bolus running, no unconfirmed command). | — | Unreachable: refused with "Bring your iPhone close to end". Still `holding`. |
| 2 | Watch | Cancels the temp. `releaseControl()`. Persists `returning(e)`. Sends `handBack(e, allUnsentRecords, odometer)`. | watch `returning(e)` | Crash after persist: relaunch resends the hand-back. The watch never takes control again in `returning`. |
| 3 | Phone | Persists the records (merge by identifier), then persists `takingBack(e)`, then sends the ack. | phone `takingBack(e)` | Ack lost: the watch resends and the phone re-acks idempotently. |
| 4 | Phone | `takeControl()`, odometer audit, persists `home(e+1)`, resumes the loop. | phone `home(e+1)` | Pod unreachable: stays `takingBack` and alerts. Zero commanders until the pod answers. |
| 5 | Watch | Receives the ack and persists `idle`. | watch `idle` | — |

## Take Back (phone, user tap, watch unreachable)

1. Confirmation dialog: "Take back the pump from Apple Watch? Only do this if your watch is off or lost."
2. Persist `takingBack(e+1)`, `takeControl()` (fresh EAP session), odometer audit (SR-21), persist `home(e+1)`, resume.
3. The watch, if alive, detects the foreign session at its next pod contact (#177) or receives the higher epoch. It stops, persists `stopped`, alerts, and sends its remaining records. The phone merges them; a placeholder audit bolus is replaced only by records covering the same interval.

## Odometer audit

At take-back, the expected delivery is the sum of booked doses since release. If the pod's `deliveredUnits` delta exceeds that sum by more than one pulse plus 0.15 U, the excess is booked as a bolus at audit time, tagged as an audit entry, so IOB errs high. A shortfall only logs a warning and shows a notice. **Open:** the effect of the audit bolus on oref's SMB interval needs a test before M4 is accepted (cross-project Q-1).

## Messages

All messages are Codable and carry `protocolVersion`, `epoch`, `messageID` (UUID) and `sentAt`. Transport: `sendMessage` when reachable, otherwise `transferUserInfo`. Receivers dedupe by `messageID` (persisted) and ignore lower epochs. Record batches carry a monotonic sequence and are resent until acked. The phone acks only after it has persisted the batch.
