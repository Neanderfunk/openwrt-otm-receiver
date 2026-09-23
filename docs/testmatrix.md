# Testmatrix: Hardware × Software

Frage: Hängt der Empfang am Gerät, an der OpenWrt-Version oder am Paket? Möglicherweise
ist das Ergebnis „Jacke wie Hose“. Auch das wäre eine Erkenntnis.

## Aufbau

- Alle Geräte stehen **gleichzeitig hinter demselben Fenster zur Straße**. Eine Runde
  dauert **24 h**, weil der Verkehr stark vom Tageslauf abhängt: nachts nichts,
  Spitzen morgens und nachmittags.
- **node749** (ESP32 mit OTM-Firmware, per LAN angebunden) läuft in jeder Runde als feste
  Referenz mit. Sein Mitschnitt kommt über den OTM-Broker (Subscribe mit
  Knoten-Zugangsdaten). Damit lässt sich jede Zelle normieren, unabhängig davon, wie
  viel an einem Tag los war.
- Messung je Gerät: `werkzeug/baseline-24h.sh` (pcap von `mon0` plus Zähler, nur tmpfs),
  Auswertung mit `werkzeug/baseline-auswertung.py`, dazu ein Frame-für-Frame-Abgleich.

## Vorab: Antennen

Die Antennen am WDR3600 sind unbekannt: TP-Link-Antennen ohne Angabe, womöglich
2,4-GHz-Dipole (etwa vom WR1043ND). Ein VNA über 3 GHz ist nicht vorhanden. Solange
das offen ist, lassen sich Software-Unterschiede nicht von Antennen-Unterschieden trennen.
Deshalb kommen die Antennen zuerst an die Reihe (weitere Dimension der Matrix):

- **Messsender sind fremde 5-GHz-Access-Points**: Deren Beacons (~10/s) werden
  gleichzeitig vom Prüfling und von einer festen Referenz (3390, interne Antennen)
  empfangen. Wir senden dafür nichts.
- **ΔRSSI je Access Point** zur Referenz, je Antennensatz einige Minuten. Dazu der RSSI je
  Empfangskette aus dem Radiotap, also je Antennenbuchse. Mit überkreuz getauschten
  Antennen lässt sich Buchse von Antenne trennen.
- **Nullmessung ohne Antennen** zeigt, wie viel die Antennen überhaupt bringen.

## Messgrößen

1. Gute ITS-Frames in 24 h (GeoNetworking 0x8947) und das **Verhältnis zu node749**.
2. **Frame-Abgleich**: gemeinsam empfangen, nur Gerät X, nur node749. Ein Frame gilt als
   gleich bei gleicher Absender-MAC, Sequenznummer und gleichem Inhalt im Zeitfenster.
3. **Signal bei gemeinsam empfangenen Frames**: RSSI-Differenz zwischen den Geräten.
   Das zeigt Empfindlichkeit bzw. Antenne unabhängig vom Verkehr.
4. Zweitrangig: Fehlauslösungen pro Minute (ath9k-CRC-Zähler, kein Verlustmaß),
   Kanalbelegung, Stabilität (Neustarts, MQTT-Abbrüche).

## Varianten

| Kürzel | Software |
|---|---|
| **21-ours** | OpenWrt 21.02.7, unser Image (`build.sh`, Patches 995–997 + regdb NO-IR, otm-bridge 0.11.1) |
| **22-ours** | OpenWrt 22.03.7, unser Image |
| **25-ours** | OpenWrt 25.12.x, unser Image (braucht `build.sh` für apk) |
| **25-MPW** | OpenWrt 25.12.4, Münsters `build.sh` und Paket wie veröffentlicht (ohne 610) |

## Matrix (Stand: siehe unten)

| Gerät | 21-ours | 22-ours | 25-ours | 25-MPW |
|---|---|---|---|---|
| TL-WDR3600 v1 (AR9582, 2x2) | R1 | R2, R3 | R4 | |
| TL-WDR4300 v1 (AR9580, 3x3) | | | | Referenz 14./15.09. (anderer Standort) |
| FRITZ!Box 3390 (AR9580) | – (nicht in 21.02) | R2 | R5 | R1, R3, R4 |
| NanoStation M5 (Klon, AR9280) | gebaut, steht noch im Keller | – (nur bis 22.03) | – | – |
| LiteBeam M5 XW (AR9342) | – (erst ab 25.12) | – | gebaut, noch nicht geflasht | – |
| ESP32 node749 | Referenz in jeder Runde | | | |

## Runden

| Runde | Zeitraum (UTC) | Belegung | Status |
|---|---|---|---|
| R1 | 14.09. 20:23 bis 15.09. 20:23 | WDR3600 21-ours · 3390 25-MPW · node749 | fertig, siehe unten |
| R2 | 15.09. 21:01 bis 16.09. 21:01 | WDR3600 22-ours · 3390 22-ours · node749 (+stats) | fertig, siehe unten |
| R3 | 16.09. 21:37 bis 17.09. 21:37 | WDR3600 22-ours · 3390 **25-MPW** · node749 (+stats) | fertig, siehe unten |
| R4 | 18.09. 00:15 bis 19.09. 00:15 | WDR3600 **25-ours** · 3390 25-MPW (unverändert) · node749 | fertig, siehe unten |
| R5 | 19.09. 00:58 bis 20.09. 00:58 | WDR3600 25-ours · 3390 **25-ours** · node749 | fertig, siehe unten |
| R6 | 20.09. 01:41 bis 21.09. 01:40 | 3390 mit 25-ours **ohne Patch 997** · WDR3600 unverändert | fertig, siehe unten |
| R7 | 21.09. 02:05 bis 22.09. 02:04 | 3390 zurück auf 25-MPW, ANI-Aufzeichnung auf beiden Geräten | fertig, siehe unten |
| R8 | 22.09. 02:16 bis 23.09. 02:15 | unverändert wie R7 | fertig, siehe unten |

### Ergebnis R1 (Randlage, 07:29–19:18 Verkehr, 703 verschiedene ITS-Frames)

| Empfänger | Frames | Anteil | RSSI Median |
|---|---|---|---|
| node749 (ESP32) | 474 | 67 % | – |
| FB3390, 25-MPW | 417 | 59 % | −80 dBm |
| WDR3600, 21-ours, unbekannte Antennen | 312 | 44 % | −84 dBm |

- Nur 164 Frames (23 %) hatten alle drei, jeder hat exklusive Frames (node749 194,
  3390 126, WDR3600 47). Am Rand der Reichweite ergänzen sich Empfänger.
- Bei gemeinsam empfangenen Frames liegt der WDR3600 im Median **5 dB unter der 3390**
  (Antennen unbekannt, siehe oben).
- Die 3390 hat rund um die Uhr Fehlauslösungen: 3,8 Mio. in 24 h, busy 45 %, nachts am
  meisten. Der WDR3600 daneben hat praktisch keine. In R2 unter 22-ours genauso
  (59 % busy), das liegt also an Hardware oder Umgebung, nicht an der Software. Ob das
  Frames kostet, ist offen.
- node749 hatte eine Lücke von 16:21 bis 17:32. In R2 zeigt der `stats`-Strom: kein
  Neustart, keine Lücke im Datenstrom, 35–37 °C. Die Lücke war also echter Empfangsausfall
  und kein Geräteproblem.

### Ergebnis R2 (beide Geräte 22-ours, 335 verschiedene Frames, schwächerer Verkehrstag)

| Empfänger | Frames | Anteil | RSSI Median | Fehlauslösungen | Kanal belegt |
|---|---|---|---|---|---|
| node749 (ESP32) | 271 | **81 %** | – | – | – |
| WDR3600, 22-ours | 136 | 41 % | −84 dBm | 770 | 0,04 % |
| FB3390, 22-ours | 101 | 30 % | −81 dBm | **6 203 524** | **93 %** |

**Das Bild aus R1 dreht sich.** Bei gleicher Software liegt die 3390 hinter dem WDR3600,
obwohl sie gemeinsame Frames weiterhin 3 dB lauter hört. Gemeinsam hatten beide nur 40
Frames, der WDR3600 hatte 96 exklusiv, die 3390 61.

Die naheliegende Erklärung sind die Fehlauslösungen: Der Empfänger der 3390 ist zu 93 % mit
Rauschen beschäftigt und verpasst dabei echte Präambeln. In R1 lag ihre Belegung bei 45 %,
und dort war sie noch besser als der WDR3600. Bewiesen ist der Zusammenhang nicht, R1 und
R2 unterscheiden sich auch in der Software und im Verkehrsaufkommen. Deshalb bekommt die
3390 in R3 wieder 25-MPW, bei sonst gleichem Aufbau.

Jede Software kommt auf mindestens zwei Geräte und jedes Gerät bekommt mindestens zwei
Softwarestände. Nur so lassen sich die Einflüsse von Hardware und Software trennen.
Ein zweiter WDR3600 erlaubt zusätzlich Parallelvergleiche auf identischer Hardware.

### Ergebnis R3 (3390 zurück auf 25-MPW, 244 verschiedene Frames, schwacher Verkehrstag)

| Empfänger | Frames | Anteil | RSSI Median | Fehlauslösungen | Kanal belegt |
|---|---|---|---|---|---|
| FB3390, **25-MPW** | 181 | **74 %** | −81 dBm | 4 633 578 | 58 % |
| node749 (ESP32) | 68 | 28 % | – | – | – |
| WDR3600, 22-ours | 65 | 27 % | −86 dBm | 1 257 | 0,04 % |

**Die Kernfrage von R3 ist beantwortet: Es liegt an der Software.** Dieselbe 3390, dasselbe
Fenster, nur ein anderes Image — und sie geht von 101 auf 181 Frames, während die beiden
unveränderten Empfänger daneben einbrechen (WDR3600 136 → 65, node749 271 → 68). Der Tag war
also insgesamt schwächer, und trotzdem ist die 3390 gestiegen. Normiert:

| Verhältnis | R2 (3390 = 22-ours) | R3 (3390 = 25-MPW) | Faktor |
|---|---|---|---|
| 3390 / WDR3600 | 0,74 | 2,78 | ×3,8 |
| 3390 / node749 | 0,37 | 2,66 | ×7,2 |

Beide Normierungen zeigen in dieselbe Richtung, im Betrag unterscheiden sie sich um fast das
Doppelte. Belastbar ist damit die Richtung, nicht die Zahl: **auf der 3390 ist unser
22.03-Image deutlich schlechter als Münsters 25.12.4.** In R1 war der Vorsprung derselben
Software gegenüber dem WDR3600 mit 1,34 allerdings viel kleiner als hier mit 2,78 — die
Streuung zwischen Tagen ist erheblich.

Die Fehlauslösungen sind auch unter 25-MPW da, aber schwächer: 4,6 Mio. statt 6,2 Mio., und
die Kanalbelegung sinkt von 93 % auf 58 %. Sie verschwinden also nicht mit der Software, aber
sie skalieren mit ihr, und der Empfang folgt derselben Richtung. Der vermutete Zusammenhang
„Belegung hoch → echte Präambeln verpasst“ hält damit weiterhin.

Was sich zwischen den Images unterscheidet und als Ursache in Frage kommt: Kernel 6.12 gegen
5.10 samt neuerem ath9k (Rauschflur-Kalibrierung, ANI), unser Patchsatz 995–997 gegen
Münsters, und die Regdomain (unser NO-IR für DE gegen Münsters Weltregeln). Getrennt ist das
noch nicht. Beide Geräte standen zum Messende auf `chanbw 0x0` und `ANI: ENABLED, OFDM LEVEL 3`,
daran liegt es also nicht.

node749 lief durchgehend: 1450 stats-Meldungen im Minutentakt, Laufzeitzähler lückenlos
+86 940 s, kein Neustart, 35 °C. Sein Einbruch auf 68 Frames ist echter Empfang.

Nächster Schritt (R4): **WDR3600 auf 25-MPW.** Wenn er dort ebenso springt, liegt es an der
Software allein; springt er nicht, ist es ein Zusammenspiel aus Chip und Software. Dafür muss
Münsters `build.sh` mit dem Profil des WDR3600 gebaut werden.

### Ergebnis R8 (Wiederholung von R7, nichts verändert)

| Empfänger | Frames | Anteil (von 362) | Fehlauslösungen | Kanal belegt |
|---|---|---|---|---|
| FB3390, 25-MPW | 254 | 70 % | 5 872 847 | 58 % |
| WDR3600, 25-ours | 160 | 44 % | 1 589 | 0,21 % |
| node749 (ESP32) | 102 | 28 % | – | – |

Verhältnis 3390/WDR3600: **1,59** — am Vortag mit identischem Aufbau 0,74. Zwei
aufeinanderfolgende Tage, dieselbe Hardware, dieselbe Software, Faktor 2,1 Unterschied.
Damit ist die Tagesschwankung noch einmal belegt.

Über alle acht Runden: unter Münsters Bau 0,74 / 1,34 / 1,59 / 2,02 / 2,78 (geometrisches
Mittel 1,55), unter unserem 0,53 / 0,74 / 1,21 (Mittel 0,78). Der Rangsummentest kommt auf
p ≈ 0,07 — ein Faktor 2 wäre also nicht auszuschließen, belegt ist er nicht, und er läge
in derselben Größenordnung wie der Unterschied zwischen zwei aufeinanderfolgenden Tagen.

node749 hatte mit 28 % seine schwächste Runde überhaupt; die 3390 hatte 180 Frames, die
sonst niemand sah. Auch das spricht dafür, dass an solchen Tagen die Richtung zählt, aus
der gesendet wird, und nicht die Software.

### Ergebnis R7 (3390 zurück auf 25-MPW, Verkehrstag mit 640 Frames) — zwei Korrekturen

Endlich ein Tag mit brauchbaren Zahlen:

| Empfänger | Frames | Anteil | Fehlauslösungen | Kanal belegt |
|---|---|---|---|---|
| node749 (ESP32) | 434 | 68 % | – | – |
| WDR3600, 25-ours | 397 | 62 % | 1 739 | 0,21 % |
| FB3390, **25-MPW** | 295 | 46 % | 6 188 310 | 58 % |

**Korrektur 1: Die Trennung „unser Bau schlecht, Münsters gut" hält nicht.** Mit Münsters
Bau und ordentlicher Statistik liegt die 3390 bei 0,74 gegenüber dem WDR3600 — demselben
Wert wie in R2 mit unserem Bau. Alle Runden im Überblick:

| Runde | Software 3390 | Frames 3390 / WDR3600 | Verhältnis |
|---|---|---|---|
| R1 | 25-MPW | 417 / 312 | 1,34 |
| R2 | 22-ours | 101 / 136 | 0,74 |
| R3 | 25-MPW | 181 / 65 | 2,78 |
| R4 | 25-MPW | 192 / 95 | 2,02 |
| R5 | 25-ours | 31 / 59 | 0,53 |
| R6 | 25-ours ohne 997 | 41 / 34 | 1,21 |
| R7 | **25-MPW** | **295 / 397** | **0,74** |

Die Streuung **innerhalb** der Münster-Gruppe (0,74 bis 2,78) ist größer als der Abstand
zwischen den Gruppenmitteln. Damit ist die Aussage aus R5 nicht haltbar: Was ich für einen
Software-Effekt gehalten habe, war überwiegend Tagesschwankung, verstärkt durch Runden mit
nur 30 bis 190 Frames. Die Runden mit den größten Zahlen — R1 (1,34) und R7 (0,74) — laufen
beide unter Münsters Bau und unterscheiden sich um Faktor 1,8.

**Korrektur 2: ANI ist nicht der Mechanismus, und der Tagesgang war ein Zufallsbefund.**
Das Minutenprotokoll zeigt auf **beiden** Geräten unter **beiden** Bauten 24 Stunden lang
unverändert `OFDM LEVEL 3`. Die Regelung rührt sich also gar nicht. Und die
Fehlauslösungsrate unter Münsters Bau bleibt in R7 den ganzen Tag bei 41 bis 87 pro
Sekunde — flach, genau wie bei uns. Die Tagesdelle aus R4 (Abfall auf 6/s) gehörte zu
jenem Tag, nicht zu jener Software.

**Was als robuster Unterschied übrig bleibt, ist einzig die Kanalbelegung:** unser Bau 82
bis 93 %, Münsters 45 bis 60 %, über sieben Runden und abwechselnde Tage. Dabei ist die
Zahl der Fehlauslösungen inzwischen gleich (R6 unser Bau 6,46 Mio. bei 82 %, R7 Münster
6,19 Mio. bei 58 %) — unter unserem Bau hält jede Fehlauslösung den Empfänger also länger
fest. Ob das überhaupt Frames kostet, ist nach R7 offen: Münster hatte hier die niedrigere
Belegung und trotzdem weniger Frames als der WDR3600.

**Konsequenz für die Matrix.** Der Softwarestand der 3390 ändert am Empfang nichts, was
über die Tagesschwankung hinausragt — „Jacke wie Hose", genau das Ergebnis, das als
Möglichkeit von Anfang an im Raum stand. Weitere Runden gegen dieselbe Frage lohnen nicht.
Was dagegen sauber messbar ist, sind **gleichzeitige Gerätevergleiche**: Alle Empfänger am
selben Fenster zur selben Zeit, damit der Tag als Störgröße herausfällt. Genau dafür kommen
die NanoStation M5 und der WDR4300 ans Fenster.

### Ergebnis R6 (3390 ohne Patch 997) — Hypothese widerlegt, dafür eine bessere Spur

| Empfänger | Frames | Anteil (von 80) | Fehlauslösungen | Kanal belegt |
|---|---|---|---|---|
| node749 (ESP32) | 49 | 61 % | – | – |
| FB3390, 25-ours **ohne 997** | 41 | 51 % | **6 462 567** | **82 %** |
| WDR3600, 25-ours | 34 | 43 % | 1 516 | 0,21 % |

**Patch 997 ist nicht die Ursache.** Ohne ihn liegen Fehlauslösungen und Kanalbelegung
praktisch unverändert bei 6,46 Mio. und 82 % (mit ihm: 6,07 Mio. und 86 %) und damit weiter
deutlich über Münsters Bau (4,6 bis 5,0 Mio., 58 bis 60 %).

Meine Stichprobe von 60 Sekunden direkt nach dem Flash hatte das Gegenteil nahegelegt
(3420/min, 53 %). Sie war schlicht zu kurz und lag nachts. **Lehre: Diese Rate schwankt
über den Tag um mehr als das Zehnfache, Stichproben unter einer Stunde sagen nichts.**

Das Frame-Verhältnis 3390/WDR3600 stieg von 0,53 auf 1,21. Bei 41 und 34 gezählten Frames
ist das etwa zwei Standardabweichungen und für sich genommen kein Beleg.

**Die eigentliche Erkenntnis steckt im Tagesgang.** Fehlauslösungen pro Sekunde, Mittel je
Stunde Ortszeit:

| Stunde | 00 | 03 | 06 | 09 | 12 | 15 | 18 | 21 |
|---|---|---|---|---|---|---|---|---|
| R4, **25-MPW** | 88 | 80 | 90 | **6** | 38 | 23 | 35 | 80 |
| R5, 25-ours mit 997 | 61 | 58 | 59 | 59 | 80 | 79 | 78 | 73 |
| R6, 25-ours ohne 997 | 69 | 77 | 76 | 73 | 81 | 76 | 77 | 73 |

Mit Münsters Bau **beruhigt sich der Empfänger tagsüber** und fällt von rund 85 auf 6 bis
45 Fehlauslösungen pro Sekunde. Mit unserem bleibt er rund um die Uhr bei etwa 78 pro
Sekunde, also am Anschlag. Das ist kein Unterschied im Pegel, sondern einer im **Verhalten**:
Etwas regelt dort nach und bei uns nicht.

Der naheliegende Kandidat ist **ANI**, die Störfestigkeits-Regelung von ath9k. Sie hebt die
Erkennungsschwellen, wenn zu viele Fehlauslösungen auftreten. Auf unserem Bau steht sie auf
`ENABLED`, `OFDM LEVEL 3`, mit 68 Resets in 24 h. Ob sie unter Münsters Bau tatsächlich
höher regelt, ist die Frage von R7: dieselbe 3390 zurück auf 25-MPW, dazu auf beiden
Geräten ein Minutenprotokoll der ANI-Stufen (`werkzeug/ani-log.sh`).

Was als Unterschied zwischen den Bauten übrig bleibt, nachdem 997 ausgeschlossen ist:
unsere regdb-Regel trägt **NO-IR**, Münsters nicht. Ein Kanal, auf dem nicht gesendet werden
darf, könnte im Treiber anders behandelt werden — belegt ist das nicht.

### Ergebnis R5 (beide Geräte 25-ours) — es liegt an unserem Bau

24 h auf den Geräten, dazu der Abgleich im Zeitfenster der Referenz (00:59 bis 21:43 UTC,
danach ist der lokale `mosquitto_sub` weggebrochen), 105 verschiedene Frames:

| Empfänger | Frames (Fenster) | Anteil | Frames (24 h) | RSSI Median | Fehlauslösungen | Kanal belegt |
|---|---|---|---|---|---|---|
| node749 (ESP32) | 60 | 57 % | – | – | – | – |
| WDR3600, 25-ours | 57 | 54 % | 59 | -86 dBm | 1 464 | 0,21 % |
| FB3390, **25-ours** | 30 | **29 %** | 31 | -80 dBm | **6 066 242** | **86 %** |

**Die 3390 bricht mit unserem Bau ein, bei jeder OpenWrt-Version.** Über alle fünf Runden,
normiert auf den danebenstehenden WDR3600:

| Runde | Software 3390 | 3390 / WDR3600 | Kanal belegt |
|---|---|---|---|
| R1 | 25-MPW | 1,34 | 45 % |
| R2 | **22-ours** | **0,74** | **93 %** |
| R3 | 25-MPW | 2,78 | 58 % |
| R4 | 25-MPW | 2,02 | 60 % |
| R5 | **25-ours** | **0,53** | **86 %** |

Die beiden Gruppen überschneiden sich nicht. Zwei OpenWrt-Versionen, fünf Runden, dieselbe
Hardware am selben Fenster: Mit Münsters Bau liegt die 3390 vorn, mit unserem hinten, und
die Kanalbelegung springt dabei von rund 60 auf über 85 Prozent. Das ist kein Rauschen mehr.

**Was sich zwischen den beiden Bauten überhaupt unterscheidet** (bei gleicher OpenWrt-Version
25.12.4, Patches Zeile für Zeile verglichen):

| | unser Bau | Münsters Bau |
|---|---|---|
| ath9k-Kanalliste (995 / 600) | identisch | identisch |
| ath-regd bis 5925 (996 / 450) | identisch | identisch |
| **Half-Rate erzwingen (997 / 610)** | **angewendet** | **nicht angewendet** |
| regdb-Regel | `(5850 - 5925 @ 20), (33), NO-IR` | `(5850 - 5925 @ 20), (33)` |

Der Code von 997 und 610 ist zeichengleich, Münsters `build.sh` kopiert den Patch nur nicht
mit. Damit bleibt genau ein Verdächtiger, der die Hardware anfasst: **wir erzwingen
`CHANNEL_HALF` in `ath9k_cmn_update_ichannel`, Münster nicht.** Und wir wissen aus dem
fcsfail-Mitschnitt vom 14.09., dass die 3390 auch ohne diesen Patch im Half-Rate läuft
(Radiotap-Kanalflags 0x4140, 3 Mbit/s) — auf 25.12 ist er schlicht überflüssig. Die
naheliegende Erklärung: Das erzwungene Umschreiben der Kanalflags bringt die
Rauschflur-Kalibrierung und ANI der AR9580 durcheinander, der Empfänger triggert sich
tot. Der zweite Unterschied, NO-IR, betrifft nur die Sendeerlaubnis und sollte die
PHY nicht berühren.

Bemerkenswert: **Der WDR3600 zeigt davon nichts** (0,21 % Belegung mit demselben Bau, 
demselben Patch). Der Effekt hängt am AR9580 der 3390. Der WDR4300 hat denselben Chip und
läuft an seinem Standort seit Monaten mit Münsters Bau unauffällig — er wäre die
Gegenprobe.

Nächster Schritt (R6): dieselbe 3390, derselbe Bau, **nur ohne Patch 997**. Ein einziger
Unterschied, und die Frage ist damit entschieden.

### Ergebnis R4 (WDR3600 auf 25-ours, 3390 unverändert, 283 verschiedene Frames)

| Empfänger | Frames | Anteil | RSSI Median | Fehlauslösungen | Kanal belegt |
|---|---|---|---|---|---|
| FB3390, 25-MPW (unverändert) | 192 | 68 % | −81 dBm | 4 956 532 | 59,7 % |
| node749 (ESP32) | 137 | 48 % | – | – | – |
| WDR3600, **25-ours** | 95 | 34 % | −85 dBm | 1 620 | 0,22 % |

**Der WDR3600 springt nicht.** Die 3390 hatte beim Wechsel auf 25.12 um den Faktor 3,8
zugelegt; hier ist nichts Vergleichbares zu sehen, und die beiden Normierungen
widersprechen sich sogar:

| Verhältnis | R3 (WDR3600 = 22-ours) | R4 (WDR3600 = 25-ours) | Faktor |
|---|---|---|---|
| WDR3600 / FB3390 | 0,36 | 0,49 | ×1,38 |
| WDR3600 / node749 | 0,96 | 0,69 | ×0,72 |

Bei 95 gezählten Frames beträgt allein die Zählunsicherheit rund ±10 %; der Unterschied
zwischen 0,36 und 0,49 liegt bei etwa 1,5 Standardabweichungen. **Das ist kein Befund,
das ist Rauschen.** Für den WDR3600 gilt zwischen 21.02, 22.03 und 25.12 bisher: Jacke
wie Hose.

Damit ist die naheliegende Erklärung für R3 vom Tisch: Es ist nicht einfach „25.12 ist
besser als 22.03". Der Effekt sitzt in der Kombination aus der 3390 und unserem
22.03-Bau. Dazu passt auch, dass der WDR3600 unter 25.12 weiterhin praktisch keine
Fehlauslösungen hat (1620 in 24 h, 0,22 % Belegung) — der neuere ath9k erzeugt sie also
nicht, und der alte verhindert sie nicht. Die Fehlauslösungen gehören zur 3390.

node749 lief wieder lückenlos (1439 Meldungen, kein Neustart, 33,6–37,8 °C), schwankt
aber zwischen den Runden am stärksten von allen dreien (474 → 271 → 68 → 137 Frames) und
taugt deshalb nur bedingt als Normierung.

Nächster Schritt (R5): **die 3390 auf 25-ours.** Das ist der einzige verbliebene
Einzelschritt, der unsere Patches und die NO-IR-Regdomain von der OpenWrt-Version trennt,
und zwar genau auf dem Gerät, auf dem der Effekt groß genug ist, um aus dem Rauschen zu
ragen.

### Antennenmessung (16.09. und 19.09.) — Methodikfehler

Die Wiederholung am 19.09. zeigt den WDR3600 bei denselben Access Points durchgängig
schlechter als am 16.09.:

| Frequenz | Access Point | 16.09. | 19.09. |
|---|---|---|---|
| 5500 MHz | 64:dd:68:ae:a3:7a | −1,0 dB | −4,0 dB |
| 5500 MHz | 66:7a:68:ae:a3:7b/7c | −2,0 dB | −5,0 dB |
| 5540 MHz | 8x:8a:20:b5:4f:a0 (fünf BSSIDs) | 0,0 dB | −1,0 dB |
| 5660 MHz | 60:63:4c:31:3f:38/39/3a | −1,0 dB | −2,0 … −3,0 dB |

**Daraus lässt sich nichts über die Antennen schließen**, denn zwischen beiden Terminen
hat sich auf *beiden* Seiten die Software geändert: der WDR3600 von 22-ours auf 25-ours,
die 3390 von 22-ours auf 25-MPW. Die Referenz war also nicht fest. Ob jemand zwischendurch
die Antennen umgesteckt hat, ist damit nicht von der Software zu trennen.

Lehre für die Methode: **Der Antennenvergleich muss unmittelbar vor und nach dem Umstecken
laufen, ohne jede Softwareänderung dazwischen** — am besten beide Messungen innerhalb einer
Stunde. Die Werte vom 19.09. dienen ab jetzt als neue Ausgangsbasis (`geraete/antennen/nachher-r4-*`).

### Vorab-Antennenmessung (16.09., vor einem möglichen Tausch)

Beacons fremder Access Points, je 120 s, WDR3600 gegen 3390 (`werkzeug/antennen-messen.sh`,
Rohdaten in `geraete/antennen/vorher-*`):

| Frequenz | WDR3600 gegen 3390 |
|---|---|
| 5500 MHz | −1,5 dB |
| 5540 MHz | 0,0 dB |
| 5660 MHz | −1,0 dB |
| 5900 MHz (ITS-Frames, R1/R2/R3) | −5, −3, −5 dB |

Unter 5,7 GHz sind die beiden praktisch gleich, bei 5900 MHz fällt der WDR3600 ab. Das passt
zu Antennen, die zu hohen Frequenzen hin abfallen — genau der Verdacht bei unbekannten
TP-Link-Dipolen. Unabhängig davon hat die 3390 **drei Empfangsketten** (`rx_chainmask 7`,
AR9580 3x3), der WDR3600 nur **zwei** (`rx_chainmask 3`, AR9582 2x2); das sind rechnerisch
etwa 1,8 dB, die kein Antennentausch ändert. Der geplante Tausch gegen die Antennen des
WDR4300 trennt beide Anteile, weil die Kettenzahl dabei gleich bleibt.
