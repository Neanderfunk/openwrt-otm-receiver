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
| TL-WDR3600 v1 (AR9582, 2x2) | R1 | | | |
| TL-WDR4300 v1 (AR9580, 3x3) | | | | Referenz 14./15.09. (anderer Standort) |
| FRITZ!Box 3390 (AR9580) | – (nicht in 21.02) | Image fertig | | R1 |
| ESP32 node749 | Referenz in jeder Runde | | | |

## Runden

| Runde | Zeitraum (UTC) | Belegung | Status |
|---|---|---|---|
| R1 | 14.09. 20:23 bis 15.09. 20:23 | WDR3600 21-ours · 3390 25-MPW · node749 | läuft |
| R2 … | offen | Rotation, bis jede Zelle mindestens einmal belegt ist | geplant |

Jede Software kommt auf mindestens zwei Geräte und jedes Gerät bekommt mindestens zwei
Softwarestände. Nur so lassen sich die Einflüsse von Hardware und Software trennen.
Ein zweiter WDR3600 erlaubt zusätzlich Parallelvergleiche auf identischer Hardware.
