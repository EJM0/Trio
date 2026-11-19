# Lifecycle and execution

Status: proposed 2026-11-16. Run model: ADR-002.

| Event | Watch behaviour | Phone behaviour |
|---|---|---|
| G7 reading arrives (`WKBluetoothAlertRefreshBackgroundTask`) | Holds the task, runs one cycle (target-architecture §5), completes the task. No second cycle on the same reading. | Stores the reading, raises glucose alarms, no loop while lent |
| Missed readings | Nothing to do. The temp expires by itself; dead-man notifications fire at 20 and 40 min. No catch-up dosing. | If reachable and silent for 20 min: alert |
| App suspended mid-command | Write-ahead intent persisted. Next wake: resolve the intent through the kit (`unacknowledgedCommand`) before any new insulin. | — |
| App terminated / relaunched | Load the loan state. `holding`: restore checklist (epoch, pump fresh, glucose fresh, no unresolved intent), then wait for the next reading. `returning`: resend the hand-back. `stopped`: show it, never command. | Load the loan state. The gate follows it. |
| Watch reboot | Not relaunched by the OS (D). Dead-man notifications already scheduled still fire. The user opens Trio, then the restore checklist runs. The phone can Take Back. | — |
| Out of resume horizon (> 6 h since last cycle) | No resume. Shows "Trio on Watch ended" and asks to End or Take Back. | — |
| Battery < 20 % | Alert "Watch battery low, end Trio on Watch soon" | — |
| Battery < 30 % at Start | Refuse Start | — |
| App upgrade on one device | Version mismatch in any message → no new loan. A running loan continues on the watch; End is still accepted, because the records format is versioned. | Same |
| Clock or time-zone change during a loan | The watch uses monotonic time for expiries. A time-zone change is logged and doesn't change the snapshot's profile (oref uses the profile's own schedule). **Open: needs E's review.** | — |
| Watch removed from wrist / locked | Behaviour unknown (D). Covered by the dead-man notifications. | — |
