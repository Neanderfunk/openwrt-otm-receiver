# mt76 (MediaTek MT7981) und ITS-G5: was nicht ging

Versuch vom 16.10.2026: Lässt sich ein MediaTek-Funkteil mit mt76-Treiber auf 10-MHz-Kanäle
bei 5.9 GHz bringen, wie ath9k? **Ergebnis: nein**, jedenfalls nicht mit dem unten genannten
Chip und Firmware-Stand. Die Angaben gelten genau für diese Kombination. Eine andere
Chip-Revision oder eine neuere Firmware kann sich anders verhalten; dann den Versuch mit
denselben Schritten wiederholen.

## Stand, auf den sich alles bezieht

| | |
|---|---|
| Gerät | Cudy WR3000 v1 (`cudy,wr3000-v1`) |
| SoC / WLAN | MediaTek MT7981, Treiber `mt7915e` (`mt798x-wmac 18000000.wifi`) |
| Chip (Treiber-Meldung) | `HW/SW Version: 0x8a108a10, Build Time: 20240823161240a` |
| EEPROM (Partition `Factory`, Bytes 0-15) | `81 79 00 00 00 0c 43 26 60 20 00 00 00 00 00 00` (Chip-ID 0x7981) |
| WM-Firmware | `WM Firmware Version: ____000000, Build Time: 20240823161304` |
| WA-Firmware | `WA Firmware Version: DEV_000000, Build Time: 20240823161841` |
| Firmware-Paket | `kmod-mt7981-firmware 6.12.87.2026.03.19~39c960c3`, dazu `mt7981-wo-firmware 20260221-r1` |
| Firmware-Dateien (sha256) | `mt7981_rom_patch.bin` f6338f757dfd1f6c9693bd7df1949195a282e919a23c509468f4ee37c0ac48ee<br>`mt7981_wm.bin` 98dd939dfeedd1249e68186e42e5e05531a3b96f3f26aa5f40598929a1f4a496<br>`mt7981_wa.bin` 96b35d4bf944f7e21cc85ac97a8471da77a71c2afa8c8bd0631d20c8e832af8a<br>`mt7981_wo.bin` 2d69d4cb56d4808727e8ab1bf9a9abfc61657f9803c284bf39017f1872af9dd1 |
| Treiber | mt76 `39c960c3ada558b4c2e7915772483d3731573d09` (2026-03-19), wie in OpenWrt 25.12.4 |
| OpenWrt / Kernel | 25.12.4 (`r32933-4ccb782af7`), Linux 6.12.87 |
| Unsere Änderungen | `patches/openwrt-25.12/mt76/900-…` (ITS-Kanäle 172-184, OFDM-Raten für 5/10 MHz, `WIPHY_FLAG_SUPPORTS_5_10_MHZ` für mt7915), `901-…` (Zustand `tx_cont` in `mt76-test`) |
| Images | Normalbetrieb: Commit f0cd376 (`OTM_VARIANT=mt76test`); Testmodus: Commit 1f482a9 (`OTM_VARIANT=mt76tm OTM_TESTMODE=1`, mit `CFG80211_TESTMODE` und `mt76-test`) |

Prüfen, ob ein Gerät dieselbe Kombination hat:

```sh
dmesg | grep -E "HW/SW Version|WM Firmware|WA Firmware"
sha256sum /lib/firmware/mediatek/mt7981_*.bin
hexdump -C /dev/mtd$(sed -n 's/^mtd\([0-9]*\):.*"Factory"/\1/p' /proc/mtd) | head -1
```

## Aufbau

- Sender: TP-Link CPE510 (ath9k) mit einer OCB-Schnittstelle auf **5745 MHz** (außerhalb des
  ITS-Bands, dort darf gesendet werden), wahlweise mit 10 oder 20 MHz; 15 bis 20 Pings an eine
  Adresse, die es nicht gibt. Die ARP-Anfragen gehen als Broadcast hinaus.
- Empfänger: die WR3000, `mon0` auf 5745 MHz; dazu als Gegenprobe ath9k-Empfänger
  (WDR4300, WDR3600, FRITZ!Box 3390, CPE510).
- Auswertung: Alles, was `mon0` empfängt, geht über die otm-bridge an den MQTT-Proxy; dort nach
  Absender-MAC gezählt. Auf 5745 MHz senden außerdem neun normale 20-MHz-Access-Points
  (Beacons alle 102.4 ms), die als ungewollte Referenz dienen.

Die Funkstrecke CPE510 → WR3000 funktioniert: Mit 20 MHz gesendete Rahmen kamen jedes Mal an.

## Was nicht ging

| # | Versuch | Ergebnis |
|---|---|---|
| 1 | Normalbetrieb: `iw dev mon0 set freq 5745 10MHz`, CPE510 sendet 3 × 20 Rahmen **mit 10 MHz** | **0** Rahmen der CPE510. Gleichzeitig ~3500 Beacons der 20-MHz-Access-Points in 40 s, die ein echter 10-MHz-Empfänger nicht dekodieren könnte. |
| 2 | wie 1, CPE510 sendet **mit 20 MHz** (Gegenprobe) | 22 Rahmen der CPE510 empfangen. Die Firmware empfängt also mit 20 MHz, obwohl 10 MHz eingestellt ist und `iw` `width: 10 MHz` meldet. |
| 3 | Testmodus-Empfang: `mt76-test phy1 set state=rx_frames` bei 5745/10 MHz, CPE510 sendet mit 10 MHz | **0** Rahmen der CPE510 (`rx_packets` ~2200, alles Beacons). |
| 4 | wie 3, CPE510 sendet mit 20 MHz | 19 Rahmen der CPE510. Auch im Testmodus nur 20 MHz. Die Rahmen erreichen dabei `mon0` und die Bridge wie im Normalbetrieb. |
| 5 | Testmodus-Senden `state=tx_frames` (500 Rahmen, OFDM 6 Mbit/s, 200 Byte, `tx_power=14`, mit und ohne `tx_antenna=3`), mit 10 und mit 20 MHz | Die WR3000 meldet `tx_done=500`, aber **keiner** der vier ath9k-Empfänger sah einen Testrahmen, auch nicht mit 20 MHz, während sie die Access Points auf demselben Kanal hörten. Nicht auswertbar: Ob die Hardware 10 MHz senden kann, bleibt offen. |
| 6 | Testmodus-Dauersenden `state=tx_cont` mit 20 MHz | Die WR3000 startete neu. |
| 7 | `state=tx_cont` mit 10 MHz | Kein Empfänger sah etwas. Im Kernel-Log (zeitlich zugeordnet): `Message 000026ed (seq 12) timeout`, Firmware neu geladen, `Hardware restart was requested` für beide phys. |
| 8 | `iw … set freq` nach dem Firmware-Neustart aus 7 | Kernel-Warnung in mac80211 (`WARNING: … Comm: iw`), ohne Absturz. |

## Was ging

- Der Treiberpatch wirkt: `iw` nimmt 5900 MHz mit 10 MHz an, die Kanäle 172 bis 184 sind
  vorhanden, die Firmware meldet keinen Fehler. Der Treiber übersetzt 10 MHz in
  `CMD_CBW_10MHZ` (`mt76_connac_chan_bw`) und schickt das beim Kanalwechsel an die Firmware.
- Der Normalbetrieb als Empfänger mit 20 MHz, auch im Testmodus.

## Folgerung

Nicht der offene Treiber begrenzt, sondern der geschlossene Teil: Die Firmware nimmt die
10-MHz-Einstellung an und empfängt trotzdem mit 20 MHz, im Normal- wie im Testmodus. Ob
zusätzlich die Hardware 10 MHz nicht kann, ließ sich nicht klären, weil der Testmodus in
diesem Aufbau gar nicht messbar sendete. Für ITS-G5 ist diese Kombination unbrauchbar.

## Wiederholen

```sh
# Images
OWRT_VER=25.12.4 TARGET=mediatek SUBTARGET=filogic OTM_VARIANT=mt76test PROFILES=cudy_wr3000-v1 ./build.sh
OWRT_VER=25.12.4 TARGET=mediatek SUBTARGET=filogic OTM_VARIANT=mt76tm OTM_TESTMODE=1 PROFILES=cudy_wr3000-v1 ./build.sh

# Sender (ath9k), hier phy0
iw phy phy0 interface add ocb0 type ocb && ip link set ocb0 up
iw dev ocb0 ocb join 5745 10MHz && ip addr add 10.99.0.1/24 dev ocb0
ping -I ocb0 -c 20 -i 1 -W 1 10.99.0.2
iw dev ocb0 ocb leave; iw dev ocb0 del

# Empfänger (MT7981), 5-GHz-phy ist phy1
iw dev mon0 set freq 5745 10MHz
mt76-test phy1 set state=rx_frames        # Testmodus-Empfang
mt76-test phy1 dump stats
mt76-test phy1 set state=off
```

Die Rahmen nach Absender-MAC zählen, z. B. am MQTT-Proxy (`its/<node>/packet`). Die Zähler
von `mt76-test` allein unterscheiden nicht zwischen den eigenen Testrahmen und dem übrigen
Verkehr auf dem Kanal.
