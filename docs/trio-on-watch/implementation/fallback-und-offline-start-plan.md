# Plan: Start ohne iPhone und Fallback-Loop in Trio on Watch

Stand 2026-11-19, Branch `dev-watch-cgm-trio-on-watch`. Entwurf, nichts davon ist gebaut.

Ziel: Die beiden Funktionen aus dem Watch-Loop-Stapel (`feat/watch-loop-5/5`, `Documentation/WatchLoop/Control.md`,
Abschnitt „Without the phone“) in dnzxys Loan-Modell bringen, ohne die Fehler zurückzuholen, wegen derer dnzxy sie
abgelehnt hat (`requirements-and-scope.md` F-1 und O-3, `research/kristinkand-test-log-1784.md`).

| Funktion | Watch Loop (unser Stapel) | Trio on Watch (dnzxy) | Hier |
|---|---|---|---|
| Start ohne iPhone | „Allow Without iPhone“, aus der Standing Copy, Control-Zeile 2 | abgelehnt, F-1 „Future“ | einbauen, eigene Einstellung, aus |
| Fallback-Loop | „Fallback Loop“, `WatchLoopFallback`, startet selbst | abgelehnt, O-3 | einbauen, eigene Einstellung, aus, braucht die erste |
| iPhone holt bei stiller Uhr zurück | Zeile 10 | abgelehnt (O-3), nur Alarm | **nicht** übernehmen, dnzxys Alarm bleibt |

## 1. Warum dnzxy es abgelehnt hat, und was hier dagegen hilft

| Vorfall (Kristins Log) | Ursache | Gegenmittel in diesem Plan |
|---|---|---|
| #49: iPhone und Uhr dosierten ~3 h abwechselnd | automatischer Start neben loopendem iPhone; der Stop erreichte die schlafende Uhr nicht | (a) Fallback nur bei iPhone-Stille **und** unbeantworteter Rückfrage, (b) **Pod-Treiber**: nimmt die Uhr den Pod ohne Freigabe, findet die nächste Session des iPhones eine fremde Session und `refusesSessions` sperrt das iPhone (`d5606d6`). Ping-Pong endet nach einem Befehl. Das gab es bei Kristin nicht |
| #46: Uhr dosierte aus 27 min alter Kopie, ein SMB des iPhones fehlte (< 0,2 U) | veraltete Kopie | Kopie nach jeder iPhone-Dosis erneuert; beim Start liest die Uhr den Pumpenzähler und bucht **jede** nicht erklärte Abgabe ab einem Puls (ohne 0,2-U-Toleranz) als Bolus, so dosiert sie zu wenig statt doppelt |
| #98 u. a.: Pod-„Looks“ sperrten iPhone-Befehle | Fallback schaute am Pod nach | keine Looks; Bedingungen nur aus iPhone-Stille und eigenen CGM-Werten |
| `f587d1f9b`: Records einer aufgegebenen Session gelöscht | Auto-Retake auf Stille + „niedrigere Epoche ignorieren“ | iPhone holt nie automatisch zurück; Records einer Offline-Session werden immer gespeichert, auch bei abweichender Epoche |

Zusätzlicher Fall, den nur dieses Modell hat: Ein Offline-Start innerhalb von 6 h nach einem Take Back. Dann hält das
iPhone ein Superseding-Fenster (`takeControl(supersedingAnotherControllerUntil:)`) und kommandiert trotz fremder
Session weiter, während die Uhr erst beim nächsten iPhone-Befehl gesperrt wird. **Regel: kein Offline-Start und kein
Fallback, solange die Kopie ein laufendes `supersededUntil` trägt.**

## 2. Was dieser Branch schon mitbringt

- **Eigene CGM-Werte ohne Loan**: `WatchCGMHost` liest den G7 immer, wenn das iPhone teilt. Der Fallback braucht genau
  das (dnzxys Original las den Sensor nur im Loan).
- **Pod-Treiber** (`OmniPumpManager+DeviceHandoff.swift`): `takeControl()` ohne Datum funktioniert ausdrücklich auch ohne
  Freigabe („a watch's offline start“); nur das iPhone nimmt mit Datum. Fremde Sessions sperren den jeweils anderen.
- **Zustandsmaschine** `WatchLoan.decide` (rein, mit Effekten, erst speichern, dann handeln), Epochen, Alarme
  (`watchNotLooping`, `phoneNotLooping`, `phoneNoWatchUpdates`), Audit pro Loan und über die Pod-Laufzeit.
- **Rückfrage** `WatchLoanStartFacts` und das Ereignis `requestTimedOut` auf der Uhr: der natürliche Einstieg für
  „iPhone antwortet nicht, ohne iPhone starten?“.

## 3. Entwurf

### 3.1 Standing Copy (iPhone → Uhr)

- `WatchLoanSnapshot` um eine Variante ergänzen, die **ohne** `releaseControl()` gebaut wird: `pumpExport` aus
  `exportConfiguration()` des haltenden iPhones, dazu die Records bis jetzt, die Epoche, `lastLoan.supersededUntil`
  und der Pumpenzähler zum Zeitpunkt der Kopie (`refreshDeliveredUnits`).
- Senden über `transferUserInfo` (nur die neueste wartet), nach jeder eigenen Dosis (Loop, Bolus, Temp), nach Änderung
  von Kohlenhydraten oder Einstellungen und alle 30 min. Größe wie der Grant unter `grantBudgetBytes`.
- Nur wenn eine der beiden neuen Einstellungen an ist und das iPhone im Zustand `home` ist.
- Vorlage: `WatchLoopStanding` (`refreshInterval` 30 min, gültig 60 min, höchstens Insulinwirkdauer).

Dateien: `Trio/Sources/Services/WatchManager/WatchLoanPhoneHost.swift` (bauen, Takt),
`Trio/Sources/APS/WatchLoan/WatchLoanSnapshot.swift` (Typ), `WatchLoanMessage.swift` (neue Nachricht `standingCopy`).

### 3.2 Uhr: Kopie halten

- `Loan/WatchLoanFiles.swift`: neue Datei `standing-copy.plist`, nur die neueste.
- Verfallen lassen bei Alter > 60 min oder > Insulinwirkdauer, bei laufendem `supersededUntil` und wenn ein Grant kommt.

### 3.3 Start ohne iPhone (manuell)

Neue Zeilen in `WatchLoan.decide` (Uhr), mit Tests wie die bestehenden `W…`-Zeilen:

| Zustand | Ereignis | Nächster Zustand | Effekte |
|---|---|---|---|
| `requesting(e, id)` | `requestTimedOut`, gültige Kopie, Einstellung an | — | Alert „iPhone antwortet nicht, ohne iPhone starten?“ |
| `idle(e)`/`requesting` | `startWithoutPhoneTapped` | `holding(max(e, copy.epoch) + 1)` | persist, neuer Effekt `adoptFromStandingCopy`, `takeControl` (ohne Datum), `refreshDeliveredUnits`, neuer Effekt `bookUnexplained(since: copy)` |
| `holding` (offline) | erste Antwort des iPhones | — | Records senden, Status wie beim normalen Loan |

- Der erste Zyklus dosiert nichts, bis Zählerstand gelesen und Fehlbetrag gebucht ist (wie
  `WatchLoopSession.pumpTotalIsExplained`).
- `WatchLoanHost` (Loan-Ordner) führt die neuen Effekte aus; `WatchLoanPump` bekommt „Manager aus Kopie bauen“.
- CGM: `WatchLoanCGM.adopt` mit der Konfiguration aus der Kopie; `WatchCGMHost.lend` hat den Fall schon (baut nur,
  wenn er keinen eigenen Manager hat).

### 3.4 iPhone: Rückkehr nach Offline-Start

Neue Zeilen in `WatchLoan.decide` (iPhone):

| Zustand | Ereignis | Nächster Zustand | Effekte |
|---|---|---|---|
| `home(e)` | `holding(e')` mit `e' > e`, Kopie war draußen | `lent(e')` | arm `phoneNoWatchUpdates`, persist, disarm `phoneNotLooping`, Alert „Uhr hat ohne iPhone übernommen“ |
| `home(e)` | `foreignPodSession`, Kopie draußen | — | Uhr fragen (`StartFacts`); antwortet sie mit `holding(e')`: wie oben. Sonst wie heute `unexpectedPodSession` |
| beliebig | `records` einer Offline-Session | — | **immer speichern** (Lehre aus `f587d1f9b`), auch bei niedrigerer Epoche |

Das iPhone ist danach vom Treiber gesperrt (`refusesSessions`), bis Take Back (Take mit Datum) oder End. Beides gibt es.

### 3.5 Fallback-Loop

- Reine Funktion, übernommen aus `WatchLoopFallback` (`Trio/Sources/Models/WatchLoop/WatchLoopStanding.swift`) nach
  `Trio/Sources/APS/WatchLoan/WatchLoanFallback.swift`. Start, wenn **alle** gelten:
  - iPhone hat seit 10 min weder gelesen noch geloopt (aus `WatchState`: letzter Loop, neuester iPhone-Wert),
  - zwei eigene Live-Werte (kein Backfill) im Abstand von 5 min aus den letzten 12 min, die das iPhone nicht hat,
  - seit 15 min kein Sensorproblem (`WatchCGMHost.hasSensorProblem`, „Sensor issue“),
  - Kopie gültig, kein laufendes `supersededUntil`,
  - Rückfrage (`StartFacts`, 10 s) unbeantwortet,
  - einmal pro Ausfall.
- Auslöser: jeder eigene Wert in `WatchCGMHost` (`.newData`), solange kein Loan läuft. Dann derselbe Weg wie 3.3,
  mit Grund `fallback` (für Alarm und Rückgabe).
- **Rückgabe**: eine vom Fallback gestartete Session bietet End an, sobald das iPhone wieder antwortet und eigene
  frische Werte hat. Offene Entscheidung, siehe 5.

### 3.6 Alarme

- Uhr ohne Loan, Kopie vorhanden, iPhone 25 min still: einmal melden (wie `notHearingFromPhone` im Stapel), mit
  „Ohne iPhone starten“ als Aktion, wenn die Einstellung an ist.
- Fallback gestartet: zeitkritische Meldung auf der Uhr; das iPhone meldet es bei Rückkehr (3.4).

### 3.7 Einstellungen

- `TrioSettings`: `watchLoanStartWithoutPhone`, `watchLoanFallback` (Standard aus, `decodeIfPresent`).
- Zu sehen in der Apple-Watch-Konfiguration, nur mit `TRIO_ON_WATCH`. Fallback nur wählbar mit Start ohne iPhone.
- Zur Uhr über Grant und Standing Copy, nicht über den normalen WatchState.

## 4. Reihenfolge

1. **Pod-Treiber prüfen** (vor allem anderen): Test in `OmniTests/DeviceHandoffTests.swift`. Uhr adoptiert einen
   **nicht freigegebenen** Export, nimmt ohne Datum. Erwartet: Uhr kommandiert; die nächste iPhone-Session sieht die
   fremde Session und sperrt. Dazu mit laufendem Superseding-Fenster des iPhones: Uhr gesperrt nach dem nächsten
   iPhone-Befehl. Wenn das nicht hält: zuerst im Treiber lösen.
2. Standing Copy senden und halten (3.1, 3.2), ohne Verhalten. Tests: Takt, Verfall, Größe.
3. Start ohne iPhone (3.3, 3.4) mit Entscheidungstabellen-Tests und Zähler-Buchung. Test „SMB 34 s vor dem Start“
   (#46) mit Werten unter 0,2 U.
4. Fallback (3.5) als reine Funktion mit zeilenweisen Tests, dann der Auslöser.
5. Alarme, Einstellungen, iPhone-Banner.
6. Hardware-Tests (wie dnzxys M8): iPhone Flugmodus / aus / zu Hause liegen gelassen; iPhone stirbt während SMB;
   Rückkehr während Offline-Session; Offline-Start kurz nach Take Back (muss verweigert werden); Uhr neu gestartet
   während Offline-Session.

## 5. Offene Entscheidungen

1. **Rückgabe nach Fallback**: automatisch (wie unser Stapel) oder nur angeboten (dnzxys Haltung zu automatischen
   Wechseln)? Vorschlag: anbieten, mit Erinnerung; automatisch erst nach Hardware-Tests.
2. **Gültigkeit der Kopie**: 60 min (Stapel) oder kürzer, z. B. 30 min? Kürzer heißt seltener startbar.
3. **Zählerprüfung in jedem Zyklus** (unsere „watch's check“) zusätzlich zum Treiber-Sperrmechanismus? Vorschlag:
   nein, der Treiber sperrt schon; nur beim Start buchen.
4. Upstream-Weg: dnzxy hat F-1 und O-3 bewusst so festgelegt. Als eigene PR erst nach seinen M8-Tests anbieten.

## 6. Risiken

- Der Pod-Link der Uhr im Hintergrund (Kristin F3) betrifft Offline-Sessions stärker, weil niemand übernehmen kann.
  Mit iPhone-Rückkehr und Take Back gelöst; ohne iPhone läuft nach dem Temp das Basalprofil.
- Zwei Controller mit derselben Insulinhistorie in Kopie: IOB auf der Uhr ist nach der Buchung zu hoch, Dosis zu
  niedrig. Gewollt.
- Uhrenzeit: Gültigkeit und Fenster über monotone Zeit prüfen, wo möglich (wie dnzxys `1450b24` im Treiber).
