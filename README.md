# OTM-Empfänger auf OpenWrt

Passiver ITS-G5-Empfänger (802.11p, 5.9 GHz) für [opentrafficmap.org](https://opentrafficmap.org/)
auf Routern mit ath9k-Funkteil. Plain OpenWrt 25.12.4 (NanoStation M XM: 21.02.7), kein LuCI.
Nach dem Flashen läuft das Gerät ohne Handarbeit: Kabel an irgendeinen Port, fertig. Die
Daten gehen per MQTT durch einen fastd-Tunnel an einen Proxy, der sie per TLS an
OpenTrafficMap weiterreicht; die alten Geräte mit wenig Flash brauchen so keinen TLS-Stack.

Fertige Images: <http://firmware.ffnef.de/otm/stable/> (`sysupgrade/` für Geräte, auf denen
schon OpenWrt oder Gluon läuft; `factory/` liegt für Sonderfälle mit dabei, siehe
[Flashen](#flashen)). Statistik: <https://otm.ffnef.de>.
Wie die Teile zusammenhängen: [docs/architektur.md](docs/architektur.md).

Vorbild und Basis: [MPW1412/openwrt-otm-bridge](https://github.com/MPW1412/openwrt-otm-bridge)
und [MPW1412/avm-fritz3390-802.11p-otm](https://github.com/MPW1412/avm-fritz3390-802.11p-otm),
die Kanal-Patches gehen auf OpenWrt-V2X (Raviglione) bzw. Klingler/Pannu (CCS Labs) zurück.

## Bauen

```sh
./release.sh                                                  # alle Geräte, wie veröffentlicht
OWRT_VER=25.12.4 PROFILES="tplink_tl-wdr3600-v1" ./build.sh   # einzelnes Profil
OWRT_VER=25.12.4 TARGET=lantiq SUBTARGET=xrx200 PROFILES=avm_fritz3390 ./build.sh
```

`build.sh` baut ein Target und eine Liste von Profilen. Ohne Angaben nimmt es noch die alten
Vorgaben OpenWrt 21.02.7 und WDR4300 + WDR3600; für alles außer der NanoStation M XM
`OWRT_VER=25.12.4` setzen. `release.sh` ruft `build.sh` für alle Geräte auf, siehe
[Veröffentlichen](#veröffentlichen).

Kein Komplettbau. Das SDK baut nur die gepatchten und eigenen Pakete (mac80211,
wireless-regdb mit Paketrevision `91`, otm-bridge, otm-mgmt-vpn, otm-autoupdater, für
Ubiquiti XW kmod-otm-spinor-unlock), der ImageBuilder baut daraus mit dem Release-Kernel das Image.
Ergebnis unter `build/out/<release>/<profil>/`. Dort liegen Image, Manifest, sha256sums und `build-info`;
dieselbe Datei steht im Gerät unter `/etc/otm-build-info`.

### Optionen

| Variable | Werte | Bedeutung |
|---|---|---|
| `OTM_MQTT` | `proxy` (Vorgabe), `direct`, `auto` | Weg zum Broker, siehe unten |
| `OTM_VPN` | `1` (Vorgabe), `0` | Management-VPN (fastd) ins Image; `proxy` und `auto` brauchen es |
| `OTM_SSH_KEYS` | Pfad, `none` | `authorized_keys` fürs Image; Vorgabe `files/local/etc/dropbear/authorized_keys`, `none` = ohne Fernzugang |
| `OTM_AUTOUPDATER` | `1` (Vorgabe), `0` | Autoupdater ins Image, siehe unten |
| `OTM_BRANCH` | `stable` (Vorgabe) | Branch für Manifest und Upload-Verzeichnis |
| `OTM_VERSION` | Ziffern | Versionsnummer in Image und Manifest; Vorgabe Bauzeit `JJJJMMTThhmm` (UTC) |
| `OTM_VARIANT` | Text | Anhang für Image-Name und Ausgabeverzeichnis, damit Varianten sich nicht überschreiben |

Weg zum Broker:

- **`proxy`**: MQTT ohne TLS durch das Management-VPN an den Proxy auf der Gegenstelle,
  der per TLS an `cits1.opentrafficmap.org` weiterreicht. Im Image gibt es kein TLS und kein
  CA-Bundle, und es hängt nicht an einer gestellten Uhr. Paketquellen laufen per http
  (die Pakete sind signiert).
- **`direct`**: `mqtts` direkt an `cits1.opentrafficmap.org`, mit TLS und CA-Bundle im Image.
  Geht auch ohne VPN (`OTM_VPN=0`).
- **`auto`**: beides im Image. Steht der Tunnel binnen 2 Minuten, geht es über den Proxy,
  sonst direkt. Nach 10 Minuten ohne Verbindung beendet sich otm-bridge, und die Wahl
  beginnt von vorn.

`direct` und `auto` sind für Geräte mit Platz gedacht (FRITZ!Box 3390, WDR3600/4300,
NanoStation). LiteBeam M5 XW und CPE510 sind alte Geräte mit wenig Flash: Mit TLS bleiben
dort grob 300 KB Overlay, der erste Boot schreibt fast so viel. `build.sh` warnt dann.
Die veröffentlichten Images nutzen deshalb alle `proxy`.

Auf dem Gerät lässt sich der Weg später ändern: `uci set otm-bridge.main.transport=direct`
(bzw. `proxy`, `auto`), dann `/etc/init.d/otm-bridge restart`. `direct` und `auto` setzen
TLS im Image voraus.

```sh
OTM_MQTT=direct OTM_VPN=0 OTM_VARIANT=direkt ./build.sh
OTM_SSH_KEYS=none OTM_VARIANT=ohne-ssh ./build.sh
```

## Autoupdater

Wie bei Gluon: einmal am Tag (Uhrzeit je Gerät verschieden, aus der MAC) holt
`otm-autoupdater` das Manifest `<mirror>/<branch>.manifest`, prüft die Signaturen
(mindestens `good_signatures` gültige aus der Schlüsselliste, `ecdsaverify`) und spielt
ein neueres Image für das eigene Board per `sysupgrade` ein; die Konfiguration bleibt.
Vorgabe in `/etc/config/autoupdater`: Branch `stable`, Mirror
`http://firmware.ffnef.de/otm/stable/sysupgrade`, 3 von 5 Signaturen, Schlüssel wie in
den Neanderfunk-Sites (`buildkeys/ffnef.signkeys` in FirmwareConfigs). http genügt, die
Signatur schützt. Von Hand: `otm-autoupdater -n` (nur prüfen), `-f` (auch wenn abgeschaltet).
Die Mindestzahl lässt sich je Gerät senken, etwa für einen Test:
`uci set autoupdater.stable.good_signatures=2; uci commit autoupdater`. Sie bleibt bei
Updates erhalten.

Manifest-Zeilen: `<board_name> <version> <sha256> <größe> <datei>`, `board_name` wie in
`/tmp/sysinfo/board_name` (z. B. `tplink,cpe510-v1`).

### Ubiquiti XW: Flash-Schreibschutz

Der Ubiquiti-Bootloader lässt beim LiteBeam M5 XW den unteren Flash geschützt (Statusregister
`0x9c`: SRWD und BP0-2). Ohne Gegenmaßnahme meldet `sysupgrade` Erfolg, schreibt aber nur die
Konfigurationspartition; Kernel und System bleiben alt, die Konfiguration geht verloren.
`kmod-otm-spinor-unlock` (in allen Ubiquiti-XW-Images, ab 25.12) setzt beim Booten den
Schreibschutz-Pin des Flash (SoC-GPIO 0, unter 19.07 "SPI nWP", im ath79-Device-Tree als
PHY-Reset geführt) und löscht das Statusregister, wie Linux 4.14 es bei Macronix tat. Es lädt
aus `/etc/modules-boot.d`, also vor `mount_root`; sonst kann das Overlay nach dem Upgrade nicht
gelöscht werden, das System läuft mit RAM-Overlay und die Konfiguration kommt nicht zurück.
Damit liefen am LiteBeam `sysupgrade` (14.10.) und der Autoupdater (15.10.) vollständig durch.
Die übrigen XW-Boards sind elektrisch gleich aufgebaut und bekommen das Modul ebenfalls; dort
ist es ungetestet. Ein XW-Gerät mit älterem OTM-Image ohne dieses Modul braucht einmal
TFTP-Rescue oder das Modul von Hand (`insmod … wp_gpio=512 wp_level=0`). Einzelheiten:
[docs/litebeam-flash-schutz.md](docs/litebeam-flash-schutz.md).

### Veröffentlichen

`./release.sh` baut alle Geräte zweimal, ohne Key und mit Key, mit derselben Versionsnummer
(Vorgabe: Startzeit, sonst `OTM_VERSION=…`), und legt alles unter
`build/release-<version>/otm/` ab. Das Verzeichnis kommt so nach `firmware.ffnef.de/otm/`:

- `stable/sysupgrade/`: Images und `stable.manifest`, **unsigniert**
- `stable/factory/`: Images für den Erstumstieg von der Herstellerfirmware
- `stable-key/{sysupgrade,factory}/`: dieselben Images mit eingebauten SSH-Keys, ohne
  Manifest. Auch Geräte mit Key aktualisieren aus `stable`; ihre Keys stehen in der
  Konfiguration und bleiben erhalten.

Einzelne `build.sh`-Läufe legen ihr Ergebnis unter `build/out/otm<variante>/<branch>/` ab;
weitere Targets ergänzen das Verzeichnis, ein neu gebautes Profil ersetzt seine alten Dateien
und Manifest-Zeilen. Signiert wird wie bei Gluon:

```sh
gluon/contrib/sign.sh <secret> build/out/otm/stable/sysupgrade/stable.manifest
```

## Flashen

**Ausgangspunkt ist ein laufendes OpenWrt**, auch Gluon oder eine andere Freifunk-Firmware;
die meisten Geräte werden vorher als Freifunk-Knoten gelaufen sein. Wie ein Gerät von der
Herstellerfirmware zu OpenWrt kommt, steht im OpenWrt-Wiki auf der Seite des Geräts; diesen
Schritt beschreiben wir hier nicht. Die `factory`-Images liegen trotzdem im Release.

Umstieg per `sysupgrade` **ohne** alte Konfiguration:

```sh
scp -O openwrt-*-sysupgrade.bin root@<gerät>:/tmp/
ssh root@<gerät> 'sysupgrade -T /tmp/openwrt-*-sysupgrade.bin && sysupgrade -n /tmp/openwrt-*-sysupgrade.bin'
```

Die Host-Keys werden dabei neu erzeugt. Den alten `known_hosts`-Eintrag vorher entfernen.
Von Gluon aus geht die Gluon-Konfiguration (Domain, Mesh, VPN-Schlüssel) verloren; das Gerät
ist danach kein Freifunk-Knoten mehr. Ob der Umstieg geklappt hat, zeigt die Online-Tabelle
unter <https://otm.ffnef.de>.

**Ubiquiti XW:** Beim Umstieg schreibt noch das alte System den Flash, ohne unser
Entsperrmodul. Nach OpenWrt-Issues und -PRs:

| OpenWrt (Kernel) | XW-Flash |
|---|---|
| 19.07 ar71xx (4.14) | Board-Code steuert den Schreibschutz-Pin („SPI nWP“) selbst |
| 21.02 (5.4), 22.03 (5.10) | Kernel nimmt die Schutzbits beim Booten weg |
| 23.05.0-.2 (5.15) | Konfiguration wird nicht gespeichert ([#12882](https://github.com/openwrt/openwrt/issues/12882)), sysupgrade selbst klappt |
| ab 23.05.3 | behoben (`CONFIG_MTD_SPI_NOR_SWP_DISABLE`, [PR #14237](https://github.com/openwrt/openwrt/pull/14237)) |
| 24.10.0 (6.6) | Berichte über einen Rückfall, auch sysupgrade ([#17914](https://github.com/openwrt/openwrt/issues/17914)); betroffen dort AC-Geräte, keine XW |

Entscheidend ist eher der Bootloader als die Version:

- **Normaler Bootloader** (setzt nur die Schutzbits): `mtd` entsperrt beim sysupgrade selbst,
  der Umstieg sollte von jeder Version aus klappen; am sichersten von 22.03 oder älter bzw.
  23.05.3 oder neuer.
- **Strenger Bootloader** wie bei unserem LiteBeam (Statusregister `0x9c`, SRWD und
  Schreibschutz-Pin): Ein Kernel, der nur das Register beschreibt, kommt nicht durch; nachgestellt,
  das Register bleibt `0x9c`. Laut OpenWrt-Wiki braucht ein LiteBeam für 23.05 und neuer ein
  Bootloader-Downgrade. Ob 21.02/22.03 auf so einem Gerät schreiben, ist nicht belegt; ein
  Umweg über eine ältere Version bringt also nichts Gesichertes.

Vorgehen: erst `sysupgrade -n` vom laufenden System. Bootet danach das alte System wieder
(Gerät erscheint nicht unter <https://otm.ffnef.de>), TFTP-Rescue mit dem OTM-`factory`-Image:
Das schreibt der Bootloader selbst, der Schreibschutz spielt dabei keine Rolle (beim
LiteBeam dreimal so gemacht, darunter der erste Umstieg von 19.07 ar71xx). Fallen dabei: Der
Rescue-Modus (U-Boot, `192.168.1.20`) beantwortet ARP oft nicht, dann hilft ein statischer
ARP-Eintrag auf die eth0-MAC; erst Ping, dann TFTP. Danach ist das OTM-Image DHCP-Client,
ohne feste `192.168.1.1`. Ab dann entsperrt das Modul, Updates laufen über den Autoupdater.
Einzelheiten: [docs/litebeam-flash-schutz.md](docs/litebeam-flash-schutz.md).

**Updates** zwischen unseren Images macht der Autoupdater, mit erhaltener Konfiguration
(SSH-Keys, fastd-Schlüssel, Position). Von Hand geht dasselbe mit `sysupgrade` ohne `-n`.

Für die TP-Link CPE510 (Pharos-Bootloader, TFTP bzw. Weboberfläche) gibt es eine eigene
Feldanleitung: [docs/cpe510-aufbau.md](docs/cpe510-aufbau.md).

## SSH-Keys

Eigene Keys gehören nach `files/local/etc/dropbear/authorized_keys` (oder per
`OTM_SSH_KEYS=<datei>`). Der Ordner ist gitignored, `build.sh` legt ihn über `files/common`.
Ohne Key (`OTM_SSH_KEYS=none`) baut das Image trotzdem, SSH ist dann aber ganz aus:
dropbear startet nicht, lokal bleibt nur der Failsafe-Modus. Passwort-Logins sind immer
abgeschaltet, denn frisches OpenWrt lässt root ohne Passwort herein. Beim Update mit
erhaltener Konfiguration bleiben vorhandene Keys erhalten.

## Was das Gerät nach dem ersten Boot tut

- **Netz**: Alle Ports hängen in einer Bridge (STP an) und beziehen per DHCP IPv4 und IPv6.
  Dazu kommt **169.254.1.1/16** als Rückfalladresse, falls am Aufstellort kein DHCP-Server
  läuft; IPv4-Link-Local kollidiert mit keinem fremden Netz. Auf dem Gerät läuft kein
  DHCP- oder RA-Server (dnsmasq ist nur DNS-Forwarder, den ntpd ab 22.03 braucht).
  SSH ist nur erlaubt, wenn ein Key eingebacken ist, und dann nur per Key.
- **Funk**: Die Radios sind in `/etc/config/wireless` deaktiviert, damit netifd das
  Monitor-Interface nicht löscht. `/usr/libexec/otm-bridge-run` setzt die Regdomain (`DE`),
  sucht das phy mit 5900 MHz, legt `mon0` an (10 MHz, Half-Rate), wartet auf den Tunnel
  bzw. bei TLS auf NTP und startet `otm-bridge`. procd startet den Wrapper bei Bedarf neu, dabei wird auch `mon0` neu angelegt.
- **Knotenname**: `<Board-Kurzname>-<letzte 4 Hex der mon0-MAC>`, z. B. `WR4300-902f`.
  Mit `uci set otm-bridge.main.node=…` lässt er sich überschreiben.
- **MQTT**: `its/<node>/{status,info,packet,stats}` im selben Format wie die
  ESP32-C5-Referenzfirmware, je nach `OTM_MQTT` über den Proxy im Tunnel oder direkt an
  `mqtts://cits1.opentrafficmap.org`. Das Kommando-Topic der Referenzfirmware
  (`its/<node>/command`, Konsolenbefehle vom Server) ist bewusst nicht umgesetzt.
  Nur über den Proxy kommen dazu, retained und außerhalb von `its/#`, also nicht an
  OpenTrafficMap weitergereicht: `otm/<node>/build` (Build-Nummer, Commit, Bridge,
  Modell) und, wenn geteilt, `otm/<node>/location`. Dazu jede Minute
  `otm/<node>/health` (ab 0.16.0): Rahmen seit Start, die ath9k-Zähler aus debugfs (alle
  Rahmen, CRC-Fehler = Präambel erkannt, PHY-Fehler = Energie gesehen) und der Survey des
  Kanals (Rauschen, Belegtzeit). Im Grafana bewertet die Tabelle „Empfangs-Health (6 h)“
  jede Station: empfängt ITS, nur Rauschen (Radio lebt, kein Verkehr) oder taub (kein
  Zähler bewegt sich). Hintergrund: Es gibt Geräte, die 5.9 GHz trotz passendem Chip nicht
  empfangen, siehe [docs/geraete-kandidaten.md](docs/geraete-kandidaten.md).
- **Position** (wie bei Gluon, `gluon-node-info.@location[0]`): standardmäßig nicht geteilt.

  ```
  uci set otm-bridge.location.share_location=1
  uci set otm-bridge.location.latitude=51.2345
  uci set otm-bridge.location.longitude=6.789
  uci commit otm-bridge
  reload_config
  ```

  Komma oder Punkt gehen beide, `altitude` (Meter) ist freiwillig. Nach `reload_config`
  startet die Bridge neu und meldet die Position; `share_location=0` löscht sie wieder. Sie
  erscheint nur auf der Heatmap in unserem Grafana. Auf der Karte von OpenTrafficMap stehen
  Empfänger über deren Self-Service-Portal (dort pflegt OTM Position und Namen
  serverseitig), nicht über die Firmware.
- **WLAN-Rückfall** (nur Geräte mit eigenem 2.4-GHz-Radio, z. B. WDR3600/4300): Bekommt das
  LAN binnen 90 s kein DHCP, verbindet sich das 2.4-GHz-Radio als Client mit dem stärksten
  offenen Netz, dessen SSID mit „Freifunk“ beginnt (Groß-/Kleinschreibung egal), und holt
  dort per DHCP eine Adresse (Interface `wwan`). Das LAN hat Vorrang: Bekommt es wieder eine
  Adresse, geht das WLAN aus; bricht das WLAN ab, beginnt die Suche von vorn, LAN zuerst.
  Im Normalzustand wird nichts abgefragt, `otm-uplink` wartet auf Ereignisse von netifd.
  Einstellungen in `otm-bridge.uplink` (`wlan_fallback`, `ssid_prefix`, `lan_timeout`,
  `wlan_timeout`), Log unter `logread -e otm-uplink`. Einzelheiten und Testprotokoll:
  [docs/wlan-rueckfall.md](docs/wlan-rueckfall.md).
- **Management-VPN** (`OTM_VPN=1`): fastd zur Gegenstelle mit eigenem Schlüssel je Gerät,
  ohne Freischaltung; Adresse per DHCP, SSH dort unter `<knoten>.otm`. Die Standardroute
  bleibt am lokalen Uplink. Gegenstelle: [mgmt-vpn/server](mgmt-vpn/server). Protokoll,
  Versionen und Verhalten bei kaputtem IPv6: [docs/management-vpn.md](docs/management-vpn.md).
- **Autoupdater**: einmal am Tag, siehe [Autoupdater](#autoupdater).
- **Nur Empfang**: Die ITS-Regel in der regdb trägt `NO-IR`. Tunen im Monitor-Modus geht,
  OCB-Join und Injection sind gesperrt.

## Statistik

Die Gegenstelle ([mgmt-vpn/server](mgmt-vpn/server)) betreibt neben fastd den MQTT-Proxy
(mosquitto-Bridge nach `cits1.opentrafficmap.org`, nur ausgehend), `otm-stats.py`
(liest am Proxy mit, entdoppelt Frames über alle Empfänger, schreibt jede Minute nach
VictoriaMetrics) und Grafana unter <https://otm.ffnef.de>, ohne Anmeldung lesbar:

- **OTM Empfang**: Frames je Empfänger, nur von einem Empfänger gesehene Frames, Anteil,
  verschiedene Absender, Online/Uptime, Firmware je Empfänger, Empfangs-Health (6 h)
- **OTM Heatmap**: Absenderpositionen (aus dem GeoNetworking-Header, Raster ~100 m) über alle
  Empfänger, dazu geteilte Empfängerpositionen; Durchschnitts- und Höchstgeschwindigkeit je
  Rasterzelle (nur Fahrzeuge, keine RSU); Verkehrsmuster nach Wochentag und Stunde
  (Fahrzeuge je Minute, mittlere Geschwindigkeit, letzte 28 Tage). Kacheln von tiles.ffdus.de.
  Die Karten je Empfänger liegen wegen der Ladezeit auf einer eigenen Seite,
  **OTM Heatmap je Empfaenger**.
- **OTM Knoten**: alles zu einem Empfänger, mit Auswahl oben oder per Klick auf den Namen
  in den Tabellen von OTM Empfang: Firmware-Stände (höchster oben), Status, Uptime, Frames,
  „nur hier gesehen“, Anteil, Health, Funk-Zähler, Rauschen, Kanalbelegung und die Heatmap
  seiner Absender. Direkt: `https://otm.ffnef.de/d/otm-knoten?var-node=<name>`

Eine abgebaute Station verschwindet aus den Tabellen mit einer leeren retained Nachricht
auf `its/<node>/status` am Proxy.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `build.sh`, `release.sh` | Bau eines Targets bzw. des ganzen Release |
| `feed/net/otm-bridge/` | Fork von otm-bridge (inzwischen 0.17.0, mit WLAN-Rückfall `otm-uplink`), als `src-link`-Feed eingebunden |
| `feed/net/otm-mgmt-vpn/` | Management-VPN (fastd), uci-defaults |
| `feed/admin/otm-autoupdater/` | Autoupdater nach Gluon-Art |
| `feed/kernel/otm-spinor-unlock/` | Kernel-Modul gegen den Flash-Schreibschutz der Ubiquiti-XW-Boards |
| `patches/openwrt-{21.02,22.03,25.12}/` | ath9k-Kanäle 170–185, ath-regd bis 5925 MHz, Half-Rate, regdb DE ITS |
| `files/common/`, `files/local/` | Dateien fürs Image; `local` ist gitignored (SSH-Keys) |
| `mgmt-vpn/server/` | Gegenstelle: fastd, dnsmasq, nftables, MQTT-Proxy, Statistik, Grafana |
| `werkzeug/` | Messwerkzeuge der Testreihen (z. B. `baseline-24h.sh`, schreibt nur nach `/tmp`) |
| `docs/` | Architektur, Gerätekandidaten, Feldanleitung CPE510, LiteBeam-Flash-Schutz, WLAN-Rückfall, Management-VPN (fastd, Dual-Stack), mt76-Versuch (MediaTek), Testmatrix |
| `geraete/` | Config-Backups und Messdaten einzelner Geräte (gitignored) |

## Geräte

| Gerät | Stand |
|---|---|
| TP-Link TL-WDR3600 v1, TL-WDR4300 v1, CPE510 v1, AVM FRITZ!Box 3390, Ubiquiti LiteBeam M5 XW | im Betrieb, empfangen ITS-G5, Autoupdater |
| Ubiquiti NanoStation M5 (XM) | Image mit 21.02.7; beim einzigen getesteten Nachbau (AR9280) kam auf 5745 MHz Testverkehr an, ab 5825 MHz nichts mehr, siehe [docs](docs/geraete-kandidaten.md#taub-trotz-passendem-chip) |
| TP-Link CPE610 v1/v2, WBS510 v1/v2, TL-WDR3500 v1, TL-WDR4310 v1 | Images gebaut, ungetestet (ath9k, 5 GHz) |
| Ubiquiti NanoStation (Loco) M5 XW, PowerBeam M5 XW, Bullet M5 XW | Images gebaut, ungetestet; Flash-Entsperren wie beim LiteBeam |
| LiteBeam 5AC, UniFi AC Mesh, CPE710 | ungeeignet: 5 GHz nur über ath10k, keine 10-MHz-Kanäle |
| CPE210/220, WBS210, PowerBeam M2 | ungeeignet: nur 2.4 GHz |

Die vollständige Liste mit Verbreitung und Gebrauchtpreisen steht in
[docs/geraete-kandidaten.md](docs/geraete-kandidaten.md).

## Lizenz

- Eigene Teile (Build-Skript, Werkzeuge, Doku): BSD-3-Clause, siehe `LICENSE`
- `feed/net/otm-bridge/`: Fork, bleibt unter WTFPL (`feed/LICENSE.otm-bridge`)
- `patches/`: GPL-2.0 wie die Kernel- und regdb-Dateien, die sie ändern
