# TP-Link CPE510 als OTM-Empfänger aufbauen

Für Geräte, die an einen anderen Ort gehen. Gebaut ist OpenWrt 22.03.7 mit unseren
ITS-Patches, `otm-bridge` und ohne LuCI. Die Images liegen unter
`build/out/22.03.7/tplink_cpe510-v{1,2,3}/`, je Verzeichnis:

| Datei | wofür |
|---|---|
| `…-squashfs-factory.bin` (≈6,0 MB) | Umstieg von der TP-Link-Firmware (Pharos) und Versuch über TFTP |
| `…-squashfs-sysupgrade.bin` (≈7,4 MB) | wenn schon OpenWrt läuft: `sysupgrade -n` |
| `sha256sums`, `build-info` | Prüfsummen und Herkunft (Commit, OpenWrt-Version, Patches) |

**Die Hardware-Version steht auf dem Aufkleber** (v1, v2 oder v3). Im Zweifel erst
auslesen: Die Pharos-Oberfläche zeigt sie unter Status, ein laufendes OpenWrt unter
`cat /tmp/sysinfo/board_name`.

## Vorher: Kennung des Geräts prüfen (Region!)

Die safeloader-Images tragen eine **support-list**. Bootloader und Weboberfläche vergleichen
damit die Kennung des Geräts, und darin steckt die **Region**. Passt sie nicht, wird das
Image abgewiesen („Incorrect File“), ganz gleich über welchen Weg.

Unsere Images akzeptieren:

| Image | Kennungen |
|---|---|
| v1 | `CPE510(TP-LINK\|UN\|N300-5):1.0`, `…UN…:1.1`, `…US…:1.1`, `…EU…:1.1`, dazu CPE520 |
| v2 | `EU`, `UN`, `US` je mit Regionscode `00000000`, `45550000` (ASCII „EU“) und `55530000` („US“), Version 2.0 |
| v3 | dieselben drei Regionen, Version 3.0 und 3.20 |

**Achtung bei v1:** Für Hardware **1.0** ist nur `UN` gelistet, **nicht** `EU`. Eine
europäische v1.0 nimmt unser Image also nicht an, eine v1.1 schon.

Kennung ablesen:
- Pharos-Oberfläche: Status, z. B. „CPE510(EU) 2.0“.
- Laufendes OpenWrt: `strings /dev/mtd$(sed -n 's/^mtd\([0-9]*\).*"product-info".*/\1/p' /proc/mtd) | grep -i cpe5`
  (sonst Partition `support-list` oder `product-info` in `/proc/mtd` suchen).

Fehlt die Kennung in der Liste, ließe sie sich ins Image aufnehmen. Dafür muss
`tplink-safeloader` aus den OpenWrt-Quellen angepasst und das Image damit neu gebaut
werden, der ImageBuilder allein reicht nicht.

## Weg 1: TFTP (erst probieren)

Die TFTP-Recovery des Pharos-Bootloaders ist eigentlich für die Rückkehr zur
Original-Firmware gedacht. Ob sie unser OpenWrt-Image annimmt, ist offen: Es gibt
Berichte für beides, und die widersprüchlichen Berichte erklären sich vermutlich über die
Region (siehe oben). Lehnt sie ab („Incorrect File. Writting error.“), passiert nichts
Schlimmes, dann geht es mit Weg 2 weiter.

1. Unser factory-Image nach **`recovery.bin`** umbenennen.
2. Rechner fest auf **192.168.0.100/24**, TFTP-Server mit `recovery.bin` im Wurzelverzeichnis.
3. Möglichst **einen Switch dazwischen**. Direkt am Gerät scheitert TFTP oft, weil der Link
   beim Bootvorgang kurz wegfällt.
4. Gerät stromlos machen, **Reset gedrückt halten**, Strom anlegen, Taste gedrückt lassen,
   bis der Server die Datei ausliefert.
5. Danach bootet das Gerät. Weiter bei „Nach dem Flashen“.

**TFTP-Fallen** (aus der Router-Werkstatt):
- Unter Windows landet ein Netz ohne Gateway im Profil „Öffentlich“, und dann blockiert die
  Firewall **UDP 69**. Das Gerät antwortet auf Ping, lädt aber nicht.
  Abhilfe: `Set-NetConnectionProfile -NetworkCategory Private`.
- Alternativ dnsmasq als reinen TFTP-Server benutzen.

## Weg 2: Pharos-Oberfläche (belegt)

1. Rechner auf **192.168.0.10/24**.
2. Browser auf **https://192.168.0.254**, Zertifikatswarnung annehmen, Anmeldung `admin`/`admin`.
3. Unser factory-Image nach **`factory.bin`** umbenennen. Der Dateiname darf höchstens
   68 Zeichen haben, unserer ist länger.
4. Unter `System` → `Firmware Update` hochladen und im Dialog **Restore** wählen.

Läuft auf dem Gerät schon OpenWrt, ist beides unnötig: Dann reicht
`sysupgrade -n` mit dem sysupgrade-Image (`-n`, damit keine alte Konfiguration bleibt).

## Zurück zur TP-Link-Firmware

Original-Firmware von TP-Link laden, nach `recovery.bin` umbenennen und Weg 1 gehen.

## Nach dem Flashen

- **Adresse:** Das Gerät ist DHCP-Client auf beiden Ethernet-Ports (eine Bridge). Im
  DHCP-Server erscheint es als **`CPE510-<letzte 4 Stellen der MAC>`**, und genauso heißt
  es auch bei OTM. Ohne DHCP-Server ist es unter **169.254.1.1** erreichbar
  (IPv4-Link-Local, Rechner braucht eine Adresse aus 169.254.0.0/16).
- **Zugang:** SSH nur mit Key, Passwort-Login ist aus. Wer vor Ort Zugriff braucht, muss
  seinen öffentlichen Key vorher ins Image bekommen (`files/local/etc/dropbear/authorized_keys`).
- **Prüfen, ob es empfängt:**
  ```sh
  iw dev mon0 info                       # channel 180 (5900 MHz), width: 10 MHz
  cat /sys/class/net/mon0/statistics/rx_packets
  logread | grep otm-bridge              # "mqtt connected" nach NTP-Sync
  cat /etc/otm-build-info                # welches Image läuft hier
  ```
- **Ausrichtung:** Die CPE510 hat eine Sektorantenne mit etwa 13 dBi. Sie gehört auf die
  Straße gerichtet, nicht in den Raum. Der Unterschied ist größer als alles, was Software
  ausmacht.
