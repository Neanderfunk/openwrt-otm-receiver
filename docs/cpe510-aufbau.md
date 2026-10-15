# TP-Link CPE510 als OTM-Empfänger aufbauen

Für Geräte, die an einen anderen Ort gehen. Die Images sind OpenWrt 25.12.4 mit unseren
ITS-Patches, `otm-bridge`, Management-VPN und Autoupdater, ohne LuCI. Sie liegen unter
<http://firmware.ffnef.de/otm/stable/> (ohne SSH-Key, SSH ist dann ganz aus) und
<http://firmware.ffnef.de/otm/stable-key/> (mit den Neanderfunk-Keys), jeweils:

| Verzeichnis, Datei | wofür |
|---|---|
| `factory/…-tplink_cpe510-v{1,2,3}-squashfs-factory.bin` (≈5.8 MiB) | Umstieg von der TP-Link-Firmware (Pharos) und Versuch über TFTP |
| `sysupgrade/…-tplink_cpe510-v{1,2,3}-squashfs-sysupgrade.bin` (≈7.4 MiB) | wenn schon OpenWrt läuft |
| `sha256sums` | Prüfsummen |

Danach hält der Autoupdater das Gerät aktuell, auch das Image mit Key.

**Die Hardware-Version steht auf dem Aufkleber** (v1, v2 oder v3). Im Zweifel erst
auslesen: Die Pharos-Oberfläche zeigt sie unter Status, ein laufendes OpenWrt unter
`cat /tmp/sysinfo/board_name`. **v1.1 nimmt das v1-Image**, OpenWrt führt sie nicht als
eigenes Gerät. v2 und v3 haben eigene Board-IDs (`CPE510V2`, `CPE510V3`) und brauchen
zwingend ihr eigenes Image.

**Erst ein Gerät, dann der Rest.** Für die CPE510 v1.1 gab es 2021 einen Bootloop
(openwrt/openwrt#7028, Absturz in `of_get_mac_address` beim Ethernet-Treiber). Das betraf
Kernel 5.4; 25.12.4 nutzt 6.12, in dem dieser Code umgebaut ist. Eine CPE510 v1 läuft mit
unserem Image seit Oktober 2026 im Betrieb, v2 und v3 sind ungetestet. Deshalb: erst ein
Gerät flashen, booten sehen und den Empfang prüfen, danach die übrigen.

Erfahrungswert aus der Neanderfunk-Flotte: 25 Pharos-Geräte (CPE210 v1, v1.1, v3 und eine
CPE510 v1) laufen dort mit eigener Firmware. Der Weg funktioniert also in der Praxis, eine
schriftliche Prozedur gab es dort bisher nicht.

## Vorher: Kennung des Geräts prüfen (Region!)

Die safeloader-Images tragen eine **support-list**. Bootloader und Weboberfläche vergleichen
damit die Kennung des Geräts, und darin steckt die **Region**. Passt sie nicht, wird das
Image abgewiesen („Incorrect File“), ganz gleich über welchen Weg.

Unsere Images (25.12.4) akzeptieren laut ihrer support-list:

| Image | Kennungen |
|---|---|
| v1 | `CPE510(TP-LINK\|UN\|N300-5):1.0`; Version 1.1 mit `UN`, `US`, `CA`, `EU`; dazu CPE520 1.1 (`UN`, `US`, `EU`) |
| v2 | Version 2.0: `EU`, `UN`, `US` ohne Regionscode und je mit Regionscode `00000000`, `45550000` (ASCII „EU“) und `55530000` („US“) |
| v3 | Version 3.0 wie v2; Version 3.20 nur `UN` mit `00000000`, `US` mit `55530000`, `EU` mit `45550000` |

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

Läuft auf dem Gerät schon ein anderes OpenWrt, ist beides unnötig: Dann reicht
`sysupgrade -n` mit dem sysupgrade-Image (`-n`, damit keine fremde Konfiguration bleibt).
Läuft schon unser Image, macht der Autoupdater die Updates.

## Zurück zur TP-Link-Firmware

Original-Firmware von TP-Link laden, nach `recovery.bin` umbenennen und Weg 1 gehen.
**Diese Datei gehört zum Gerät dazu, wenn es an einen entfernten Ort geht.** Sie ist der
einzige Rückweg, wenn dort etwas schiefgeht, und vor Ort hat niemand Erfahrung. Sie muss
zur Hardware-Version **und zur Region** passen.

## Nach dem Flashen

- **Adresse:** Das Gerät ist DHCP-Client auf beiden Ethernet-Ports (eine Bridge). Im
  DHCP-Server erscheint es als **`CPE510-<letzte 4 Stellen der MAC>`**, und genauso heißt
  es auch bei OTM. Ohne DHCP-Server ist es unter **169.254.1.1** erreichbar
  (IPv4-Link-Local, Rechner braucht eine Adresse aus 169.254.0.0/16).
- **Zugang:** SSH nur mit Key, Passwort-Login ist aus. Das Image aus `stable-key` enthält
  die Neanderfunk-Keys, das aus `stable` gar keinen (SSH aus). Wer eigene Keys braucht, baut
  selbst (`files/local/etc/dropbear/authorized_keys` bzw. `OTM_SSH_KEYS`). Über den
  Management-Tunnel ist das Gerät für uns unter `<knoten>.otm` erreichbar.
- **Prüfen, ob es empfängt:** am einfachsten im Grafana unter <https://otm.ffnef.de>
  (Online, Firmware je Empfänger, Empfangs-Health). Auf dem Gerät:
  ```sh
  iw dev mon0 info                       # channel 180 (5900 MHz), width: 10 MHz
  cat /sys/class/net/mon0/statistics/rx_packets
  logread | grep otm-bridge              # "mqtt connected", sobald der Tunnel steht
  cat /etc/otm-build-info                # welches Image läuft hier
  ```
- **Position teilen** (für die Heatmap, nur mit SSH): siehe README, Abschnitt „Was das
  Gerät nach dem ersten Boot tut“.
- **Ausrichtung:** Die CPE510 hat eine Sektorantenne mit etwa 13 dBi. Sie gehört auf die
  Straße gerichtet, nicht in den Raum. Der Unterschied ist größer als alles, was Software
  ausmacht.
