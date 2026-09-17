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
| TL-WDR3600 v1 (AR9582, 2x2) | R1 | R2, R3 | | |
| TL-WDR4300 v1 (AR9580, 3x3) | | | | Referenz 14./15.09. (anderer Standort) |
| FRITZ!Box 3390 (AR9580) | – (nicht in 21.02) | R2 | | R1, R3 |
| ESP32 node749 | Referenz in jeder Runde | | | |

## Runden

| Runde | Zeitraum (UTC) | Belegung | Status |
|---|---|---|---|
| R1 | 14.09. 20:23 bis 15.09. 20:23 | WDR3600 21-ours · 3390 25-MPW · node749 | fertig, siehe unten |
| R2 | 15.09. 21:01 bis 16.09. 21:01 | WDR3600 22-ours · 3390 22-ours · node749 (+stats) | läuft: gleiche Software, reiner Hardwarevergleich |
| R3 | 16.09. 21:37 bis 17.09. 21:37 | WDR3600 22-ours · 3390 **25-MPW** · node749 (+stats) | fertig, siehe unten |
| R4 … | offen | WDR3600 auf 25-MPW (Gegenprobe), dazu WDR4300 und Antennen | geplant |

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
