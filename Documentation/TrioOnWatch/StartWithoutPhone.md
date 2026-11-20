# Trio on Watch ohne iPhone starten – Plan

Portiert den Start ohne iPhone und den Fallback Loop aus `feat/watch-loop-5/5`
(`WatchLoopSession+WithoutPhone.swift`, `WatchLoopStanding.swift`, `Documentation/WatchLoop/Control.md`) in die
Leihe (`WatchLoan*`) dieses Branches. Zeilennummern wie in Sport Mode (LoopKit/Loop#2545) und 5/5.

## Was sich schon so verhält

- **Die Probe des iPhones stört die Uhr nicht.** `exportConfiguration()` markiert den Pod als geteilt. Hat seither
  ein anderes Gerät mit dem Pod gesprochen, antwortet der Pod auf den Handshake des iPhones mit seinem höheren
  Zähler. OmnipodKit erkennt die fremde Sitzung, verweigert den zweiten Versuch und schickt **keinen** Befehl
  (`BlePodComms.establishNewSession`, `resolveAfterSessionResync`). Der Zähler des Pods bleibt, wo die Uhr ihn
  hat; die Uhr loopt weiter.
- Das iPhone (`.home`) reagiert heute darauf mit `podSession(.refuse)`, Audit und „Unexpected pod session“. Es
  doset nicht mehr, bis man „Pod auf diesem iPhone verwenden“ tippt. Die Uhr behält also faktisch die Kontrolle,
  aber das iPhone weiß nicht, dass sie loopt (kein Banner, Aufzeichnungen nicht als Leihe).

## 1. Einstellungen (iPhone → Apple Watch → „Looping on the Watch“)

Wie 5/5, gespeichert in `TrioSettings` (jedes Feld `decodeIfPresent`), an die Uhr über den Watch-State:

| Einstellung | Wirkung |
|---|---|
| **Trio on Watch** | Laufzeit-Schalter zusätzlich zum Build-Flag `TRIO_ON_WATCH`; aus → Start wird mit `featureOff` abgelehnt. |
| **Allow Without iPhone** (nur wenn an) | iPhone schickt die Kopie (2.), Uhr zeigt den Start-Button (3.). |
| **Fallback Loop** (nur mit Allow Without iPhone) | Uhr startet selbst, wenn das iPhone nicht mehr loopt (6.). |

## 2. Die Kopie („standing copy“), bei jedem Loop

- Nach **jedem** erfolgreichen Loop des iPhones (Pod erreicht, Zustand `.home`, Allow Without iPhone an, CGM teilt
  seine Konfiguration) baut das iPhone denselben Snapshot wie für einen Grant, **ohne** den Pod freizugeben: Pod-
  Export mit Gesamtabgabe, oref-Eingaben, Einstellungen, Presets, Alarme.
- Gesendet live (wenn erreichbar) und in die Warteschlange; eine noch ausstehende ältere Kopie wird zurückgezogen
  (`cancelOutstandingLoanTransfers`), es wartet immer nur die neueste.
- Die Uhr speichert nur die neueste (Datei `standing-copy.data`), mit `issuedAt` und der Epoche des iPhones.
  Setting aus → Kopie gelöscht.

## 3. Start ohne iPhone per Button (Zeile 2)

- Auf der Trio-on-Watch-Seite erscheint **„Ohne iPhone starten“** nur wenn: Setting an, Leihe `idle`, die Uhr
  liest den Sensor selbst, eine Kopie liegt vor und ist **jünger als 15 min**. Darunter: „Einstellungen von 14:05“.
- Tippen → Bestätigung → Start aus der Kopie mit Epoche `max(eigene, Kopie) + 1`, durch denselben Weg wie ein Grant
  (Adopt + `takeControl`). Statt Uhr-/Ablaufprüfung des Grants gilt das Alter der Kopie. Persistiert:
  `startedWithoutPhone`.
- **Insulinprüfung vor der ersten Dosis:** Gesamtabgabe des Pods lesen, mit der Kopie vergleichen
  (`WatchLoanAudit.expectedDelivery` über Kopie-Historie + Basalprofil seit `asOf`). Was die Kopie nicht erklärt (die
  Dosen des iPhones nach der Kopie), wird auf der Uhr als Bolus gebucht, quittiert, also **nicht** ans iPhone
  geschickt (das hat die echten Dosen). Ohne Gesamtabgabe: keine Dosis in diesem Zyklus.
- Danach meldet die Uhr dem iPhone (live + Warteschlange): „ich halte Leihe n, gestartet um T“.

## 4. iPhone kommt zurück und die Uhr loopt (Zeile 17) – Kontrolle bleibt bei der Uhr

Zwei Wege, je nachdem was das iPhone zuerst erreicht:

- **Wort der Uhr zuerst** (iPhone erreicht die Uhr): Status oder Aufzeichnungen mit einer Epoche über der des
  iPhones → iPhone wechselt `.home → .lent(n)`, gibt den Pod frei, zeigt das Banner, speichert die Aufzeichnungen,
  zählt die Loops der Uhr als Loops. Keine Rückfrage.
- **Pod zuerst, Uhr nicht erreichbar** (deine Frage): der nächste Pod-Befehl des iPhones findet die fremde Sitzung
  (siehe oben, die Uhr bleibt ungestört). Ist eine Kopie draußen, heißt das: die Uhr hat ohne iPhone gestartet. Das
  iPhone geht ebenfalls nach `.lent(Epoche + 1)` – genau die Epoche, die die Uhr beim Start aus der Kopie nimmt –
  statt „Unexpected pod session“ zu melden: es doset nicht, gibt den Pod frei, Banner und Meldung „Apple Watch Is
  Looping“. Die Aufzeichnungen, die die Uhr bei jedem 5‑min‑Zyklus schickt, passen dann direkt zu dieser Leihe.
  - Ohne Kopie draußen bleibt es beim heutigen Verhalten (verweigern, „Unexpected pod session“).
- **Uhr loopt doch nicht (tot, abgelegt, Zeile 18):** keine automatische Übernahme. In `.lent` gilt die bestehende
  Warnung, wenn von der Uhr nichts kommt („Watch may not be looping“), und **Take Back** am iPhone übernimmt mit
  höherer Epoche und bucht per Audit, was die Aufzeichnungen nicht erklären. *Abweichung vom ersten Entwurf (20‑min‑
  Automatik):* Stille allein kann eine schlafende, aber loopende Uhr nicht von einer toten unterscheiden; ein Tipp
  entscheidet, wie in Sport Mode bei Zeile 10.
- **Uhr kommt nach der Übernahme zurück** (Zeile 19): ihre Epoche ist kleiner → Stop, wie heute.

Die Uhr muss sich nicht extra melden: jeder ihrer Zyklen schickt Aufzeichnungen mit ihrer Epoche (live oder in der
Warteschlange), und die erste davon stellt das iPhone auf `.lent`.

## 5. Ende

Ende auf der Uhr mit iPhone in der Nähe: normale Rückgabe. Ohne iPhone (Zeile 21): Ende abgelehnt wie heute, die
Uhr loopt weiter.

## 6. Fallback Loop (aus 5/5 übernommen)

Bei jeder eigenen Live-Messung der Uhr ohne laufende Leihe (`WatchLoanFallback.shouldStart`, Logik aus 5/5
unverändert):

- iPhone hat seit **10 min** weder den Sensor gelesen noch geloopt,
- zwei eigene Live-Messungen (kein Backfill) im Abstand 3,5–6,5 min aus den letzten 12 min, die das iPhone nicht hat,
- kein Sensorproblem jetzt und in den letzten 15 min,
- eine nutzbare Kopie, und das iPhone antwortet auf eine Live-Frage nicht.

Dann Start wie 3., mit Benachrichtigung „Fallback Loop gestartet“. Gibt den Pod von selbst zurück, sobald das iPhone
wieder mit frischen Messungen antwortet.

**Alter der Kopie für den Fallback:** Der Fallback braucht 10 min Stille, die Kopie ist dann schon ≥ 10 min alt.
Mit 15 min blieben nur 5 min Fenster; 5/5 nahm 60 min. Plan: Button 15 min (dein Wunsch), Fallback 60 min (5/5),
die Insulinprüfung deckt das Alter ab.

## 7. Tests

- Reducer (`WatchLoan`): Start aus der Kopie aus `idle`; iPhone `.home` + Wort der Uhr mit höherer Epoche → `.lent`;
  `.home` + fremde Sitzung mit Kopie → `.lent(Epoche + 1)`, ohne Kopie wie bisher; Take Back danach macht die Leihe
  der Uhr zur älteren. In `WatchLoanWithoutPhoneTests` (`TrioTests/WatchLoanTests/WatchLoanWatchDecisionTests.swift`).
- `WatchLoanFallback.shouldStart`: die Tests aus 5/5 übernommen.
- Kopie: nutzbar < 15 min (Button) / < 60 min (Fallback); Insulinprüfung bucht den Rest.

## Reihenfolge

1. Einstellungen + Watch-State-Schlüssel
2. Kopie senden/speichern
3. Button-Start + Insulinprüfung
4. iPhone übernimmt das Wort der Uhr (`.lent`), Uhr meldet sich bei Erreichbarkeit
5. fremde Sitzung mit Kopie → `.lent`
6. Fallback Loop
7. Tests

## Grenzen

- Kohlenhydrate und BZ, die nach der letzten Kopie am iPhone eingetragen wurden, fehlen der Uhr (sie doset dann
  weniger).
- Braucht „Read on Apple Watch“ für das CGM.
- Muss mit echtem Pod oder Emulator getestet werden, bevor es jemand benutzt.
