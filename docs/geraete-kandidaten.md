# Gerätekandidaten für den OTM-Empfänger

Stand 14.09.2026. Voraussetzung ist ein **5-GHz-Funkteil mit ath9k-Treiber**. Nur dort
lassen sich die ITS-Kanäle und 10 MHz (Half-Rate) nachrüsten. Geräte, deren 5 GHz über
ath10k, mt76 o. Ä. läuft, scheiden aus (siehe unten).

- **Verbreitung**: Gluon-Knoten in den Freifunk-Karten, jeweils das Maximum aus dem
  Darmstädter Census (`gluon_model_total`, 33k Knoten) und der föderierten ffmuc-Karte
  (28k Knoten mit Modell). Beide überschneiden sich stark. Die Zahl sagt, wie viele Geräte
  im Umlauf sind und bei Freifunkern herumliegen.
- **Hardware**: OpenWrt Table of Hardware (Dump vom 14.09.2026), dazu Device-Tree und
  Image-Liste von OpenWrt 21.02.7, ergänzt um die AR9580-Liste von Matthias Walther aus dem
  OTM-Chat (19.05.2026).
- **Preise**: Angebote auf Kleinanzeigen am 14.09.2026 abends (Festpreise und VB), gebraucht.
  eBay und Geizhals ließen sich nicht automatisch abfragen (Bot-Schutz, HTTP 403).
- **21.02.7**: ✔ = fertiges Release-Image vorhanden, das `build.sh` direkt nutzen kann.

Einschränkung für alle Geräte: Frontends und Antennen sind laut Datenblatt bis 5,85 GHz
spezifiziert. Wie viel bei 5,9 GHz verloren geht, muss man je Gerät messen
(`werkzeug/baseline-24h.sh`).

## Indoor

| Gerät | 5 GHz | RAM/Flash (MB) | 21.02.7 | Freifunk-Knoten | Kleinanzeigen | Bemerkung |
|---|---|---|---|---|---|---|
| **TP-Link TL-WDR3600 v1** | AR9582, 2x2 | 128/8 | ✔ | 660 | 10–30 € (7, u. a. 5 Stück à 15 € VB) | **am Gerät getestet**, läuft out of the box |
| **TP-Link TL-WDR4300 v1** | AR9580, 3x3 | 128/8 | ✔ | 644 | 15–25 € (7) | Referenz (lief 90 Tage unter 25.12), Image gebaut |
| **AVM FRITZ!Box 3370** (Rev. 2) | AR9380, wahlweise 2,4/5 | 128/NAND | ✔ | 19 | meist 10 €, 4–25 € (25) | am billigsten und am leichtesten zu bekommen; nur Rev. 2 (Hynix/Micron); AVM-Kalibrierdaten prüfen |
| **AVM FRITZ!WLAN Repeater 300E** | AR9382, wahlweise 2,4/5 | 64/16 | ✔ | 21 | 15–30 € (12) | Steckdosengerät, gut fürs Fenster zur Straße; Kalibrierdaten prüfen |
| TP-Link TL-WDR4900 v1 | AR9580 | 128/16 | ✔ (mpc85xx) | 165 | ~30 € (1) | PowerPC, eigenes Target |
| TP-Link TL-WDR4310 v1, Mercury MW4530R v1 | AR9580 | 128/8 | ✔ | ~0 | nicht abgefragt | Schwester bzw. Klon des WDR4300 |
| Enterasys WS-AP3710i | AR9590, 3x3 | 256/32 | ✔ (mpc85xx) | 75 | 29 €/Stück (Posten mit 30+) | Enterprise-AP, PoE; WS-AP3705i ✔ (6 Knoten), WS-AP3715i nur snapshot |
| Aerohive HiveAP-330 | AR9390 (mPCIe) | 256/64 | ✔ (mpc85xx) | 49 | keins | HiveAP-121: AR9382, ✔ (ath79-nand), 12 Knoten |
| Netgear WNDR3700 v1/v2, WNDR3800 | AR9220 | 64–128/8–16 | ✔ | ~60 | WNDR3700 8–25 € (10) | ältere 802.11n-Generation; v4 und WNDR4300 mit AR9580 (NAND) |
| Netgear WNDR4300 v2, WNDR4500 v3 | AR9580 (SoC QCA9563 nur 2,4 GHz) | 128/NAND | ✔ | ~0 | nicht abgefragt | |
| TP-Link TL-WDR3500 v1 | AR9582 | 128/8 | ✔ | 34 | Einzelstück | |
| Ubiquiti UniFi AP Pro (UAP-PRO) | AR958x-Familie (PCI 168c:0033), SoC AR9344 | 128/16 | ✔ | 28 | 1 Posten: 7 Stück 45 € | nicht mit UAP-AC-Pro (ath10k) verwechseln; die ToH nennt fälschlich AR9280 |
| AVM FRITZ!Box 3390 | AR9580-Klasse | 128/NAND | ✘ (erst ab 22.03) | ~0 | 8–39 € (13) | Münsters Referenzgerät (25.12); für uns braucht es einen Backport |
| D-Link DIR-825 B1/B2 · C1 | AR9220 · AR9382 | 64/8 · 128/16 | ✔ | ~10 | 5–30 € (3) | Revision steht selten in der Anzeige |
| Aruba AP-105 | AR9220 | 128/16 | ✔ | 7 | 4 Stück 20 € VB | |
| Buffalo WZR-HP-AG300H / WZR-600DHP | AR9220 | 128/32 | ✔ | 6 | nicht abgefragt | |
| Meraki MR16, Open-Mesh MR900 v1/v2 | AR9220 · AR9580 | 64/16 · 128/16 | ✔ | 4 · 5 | nicht abgefragt | selten |
| Linksys EA4500 v3, EnGenius ESR900 | AR9580 | 128 | ✘ (erst ab 22.03 bzw. 15.05/später) | ~0 | nicht abgefragt | |

## Outdoor

| Gerät | 5 GHz | RAM/Flash (MB) | 21.02.7 | Freifunk-Knoten | Kleinanzeigen | Bemerkung |
|---|---|---|---|---|---|---|
| **Ubiquiti NanoStation M5 / Loco M5 (XW)** | AR9342 | 64/8 | ✔ | ~230* | 35–70 €/Stück (7) | Sektorantenne, auf die Straße richten |
| Ubiquiti NanoStation M5 / Loco M5 (XM) | AR9280 | 32/8 | ✔ | 7+* | (s. o.) | 32 MB reichen ohne Gluon (WDR3600 belegt 17 MB) |
| **TP-Link CPE510 v1–v3**, CPE610 v1/v2, WBS510 v1/v2 | AR9344 | 64/8 | ✔ | ~65 | 30–40 €/Stück (3) | wird noch neu verkauft; auch Münster nennt ihn |
| Ubiquiti Bullet M5 (XM/XW) | AR9280 / AR9342 | 32/8 / 64/8 | ✔ | 17* | 1 Angebot | Antenne frei wählbar (N-Buchse) |
| Ubiquiti Rocket M5 (XM/XW) | AR9280 / AR9342 | 64/8 | ✔ | ~5 | keins | Antenne frei wählbar |
| Ubiquiti LiteBeam M5 (XW) | AR9342 | 64/8 | ✘ (Backport) | 0 | 50–70 € (2) | Richtantenne 23 dBi |
| Ubiquiti NanoBeam M5, PowerBeam M5 (XW) | AR9342 | 64/8 | ✘ (Backport) | 2 · 2 | keins | |
| Ubiquiti AirGrid M5 (XM) | AR9280 | 32/8 | ✘ | – | nicht abgefragt | |
| MikroTik SXT Lite5, LHG 5 | AR9344 | 64/16–NAND | ✘ (erst ab 22.03/23.05) | – | nicht abgefragt | werden noch neu verkauft |

\* Die Gluon-Modellnamen der Ubiquiti-M-Serie („Nanostation M (XW)“, „Loco M (XW)“,
„Bullet M“) unterscheiden **nicht zwischen M2 und M5**. M2 (2,4 GHz) ist ungeeignet und
bei Freifunk häufiger. Die Zahlen sind deshalb Obergrenzen.

## Sonderfälle (unerprobt)

- **x86 mit mPCIe-Karte** (PC Engines APU, alte Thin Clients) mit AR9280/AR938x/AR958x-Karte.
  Das war die Referenzplattform von OpenWrt-V2X. Dafür braucht es ein x86-Profil in `build.sh`.
- **USB-Sticks mit ath9k_htc und 5 GHz** (AR7010 + AR9280, z. B. Netgear WNDA3200). Die
  Patches betreffen den Code, den ath9k und ath9k_htc gemeinsam nutzen. Ob Half-Rate über
  die HTC-Firmware funktioniert, ist nicht geprüft.

## Ungeeignet (häufig gefragt)

| Gerät | Grund |
|---|---|
| UniFi AC Mesh / Lite / LR / Pro, LiteBeam 5AC (Gen1/Gen2), NanoStation 5AC, PowerBeam 5AC | 5 GHz über ath10k (QCA988x): keine 10-MHz-Kanäle, PHY in der Firmware |
| TP-Link Archer C7 (alle), FRITZ!Box 4040, sämtliche IPQ40xx-Geräte | 5 GHz über ath10k |
| Archer C50/C6 v3, alle MediaTek-Geräte | mt76 |
| NanoStation M2 / Loco M2, Bullet M2, Rocket M2, UniFi AP, AP Outdoor+ | nur 2,4 GHz |
| FRITZ!Box 7362 SL, 7412 | nur 2,4 GHz |
