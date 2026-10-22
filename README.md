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

## Empfänger aufstellen

**Ausgangspunkt ist ein laufendes OpenWrt**, auch Gluon oder eine andere Freifunk-Firmware;
die meisten Geräte werden vorher als Freifunk-Knoten gelaufen sein. Wie ein Gerät von der
Herstellerfirmware zu OpenWrt kommt, steht im OpenWrt-Wiki auf der Seite des Geräts; diesen
Schritt beschreiben wir hier nicht. Die `factory`-Images liegen trotzdem im Release.

### Geräte

| Gerät | Stand |
|---|---|
| TP-Link TL-WDR3600 v1, TL-WDR4300 v1, CPE510 v1, AVM FRITZ!Box 3390, Ubiquiti LiteBeam M5 XW | im Betrieb, empfangen ITS-G5, Autoupdater |
| TP-Link CPE610 v1/v2, WBS510 v1/v2, TL-WDR3500 v1, TL-WDR4310 v1 | Images gebaut, ungetestet (ath9k, 5 GHz) |
| Buffalo WZR-HP-AG300H, WZR-600DHP | Images gebaut, ungetestet; AR7161, 128 MB RAM, 32 MB Flash, zwei ath9k-Funkteile (AR9220/AR9223), 5 GHz über AR9220 |
| TP-Link TL-WDR4900 v1 und v2 | Images gebaut, ungetestet; 5 GHz bei beiden über AR9580 (ath9k). v1 ist PowerPC (Target mpc85xx), v2 eine QCA9558-Platine (ath79) |
| Ubiquiti M5-Serie (NanoStation, Loco, NanoBeam, PowerBeam, Bullet, Rocket) | siehe die Tabelle unten |
| LiteBeam 5AC, UniFi AC Mesh, CPE710 | ungeeignet: 5 GHz nur über ath10k, keine 10-MHz-Kanäle |
| CPE210/220, WBS210, alle Ubiquiti M2 | ungeeignet: nur 2.4 GHz |

#### Ubiquiti: welches Image?

Die Ubiquiti-M-Geräte gibt es mit zwei Platinen. **XW** ist die neuere (SoC AR9342, 64 MB RAM)
und bekommt OpenWrt 25.12.4. **XM** ist die ältere (AR724x mit AR9280); die meisten XM-Geräte
haben 32 MB RAM, dafür baut OpenWrt seit 22.03 keine Images mehr, deshalb 21.02.7. Rocket M
und PowerBridge M XM haben 64 MB und bekommen 25.12.4. Von außen sehen beide gleich
aus, auf dem Aufkleber steht nur „NanoStation Loco M5“ o. ä. Nur die **M5**-Geräte (5 GHz)
taugen, M2 (2.4 GHz) nicht.

So erkennt man die Platine:

- **AirOS**: Die Firmware-Version beginnt mit `XW.` oder `XM.` (z. B. `XW.v6.3.11`), zu sehen
  auf der Hauptseite der Weboberfläche bzw. im Dateinamen der Ubiquiti-Firmware.
- **Gluon/OpenWrt**: `cat /tmp/sysinfo/board_name` zeigt `ubnt,nanostation-loco-m-xw` (XW)
  oder `ubnt,nanostation-loco-m` (XM); das Modell auf der Statusseite endet auf XW bzw. XM.

| Gerät | XW: Image (OpenWrt 25.12.4) | XM: Image |
|---|---|---|
| NanoStation M5 | `ubnt_nanostation-m-xw` | `ubnt_nanostation-m` (21.02.7) |
| NanoStation Loco M5 | `ubnt_nanostation-loco-m-xw` | `ubnt_nanostation-loco-m` (21.02.7) |
| NanoBeam M5, PowerBeam M5 300, AirGrid M5 HP | `ubnt_nanostation-loco-m-xw` (dasselbe Image) | – |
| PowerBeam M5 (400) | `ubnt_powerbeam-m5-xw` | – |
| LiteBeam M5 | `ubnt_litebeam-m5-xw`, **im Betrieb** | – |
| Bullet M5 | `ubnt_bullet-m-xw` | `ubnt_bullet-m-ar7240` bzw. `-ar7241` (21.02.7) |
| Rocket M5 | `ubnt_bullet-m-xw` (dasselbe Image wie Bullet) | `ubnt_rocket-m` (25.12.4) |
| PowerBridge M5 | – | `ubnt_powerbridge-m` (25.12.4) |

Die Image-Dateien heißen `openwrt-…-<Profil>-squashfs-sysupgrade.bin` (bzw. `-factory.bin`).
Außer dem LiteBeam ist keines davon getestet. Die XW-Images bringen das Entsperren des
Flash-Schreibschutzes mit (siehe [Ubiquiti XW](#ubiquiti-xw-flash-schreibschutz)). Bei der
einzigen getesteten NanoStation M5 XM (ein Nachbau) kam ab 5825 MHz nichts mehr an, siehe
[docs/geraete-kandidaten.md](docs/geraete-kandidaten.md#taub-trotz-passendem-chip);
`otm/<node>/health` zeigt, ob ein Gerät taub ist.

Vorsicht bei Ubiquiti XM: NanoStation M2 und M5, Bullet M2 und M5 usw. melden denselben
Board-Namen, das M5-Image lässt sich also ohne Fehlermeldung auch auf das 2.4-GHz-Gerät
spielen. Es läuft dann mit Tunnel, empfängt aber nichts (siehe `otm/<node>/problem` oben).

Die vollständige Liste mit Verbreitung und Gebrauchtpreisen steht in
[docs/geraete-kandidaten.md](docs/geraete-kandidaten.md).

### Flashen

Umstieg per `sysupgrade` **ohne** alte Konfiguration:

```sh
scp -O openwrt-*-sysupgrade.bin root@<gerät>:/tmp/
ssh root@<gerät> 'sysupgrade -T /tmp/openwrt-*-sysupgrade.bin && sysupgrade -n /tmp/openwrt-*-sysupgrade.bin'
```

Die Host-Keys werden dabei neu erzeugt. Den alten `known_hosts`-Eintrag vorher entfernen.
Von Gluon aus geht die Gluon-Konfiguration (Domain, Mesh, VPN-Schlüssel) verloren; das Gerät
ist danach kein Freifunk-Knoten mehr. Ob der Umstieg geklappt hat, zeigt die Online-Tabelle
unter <https://otm.ffnef.de>.


**Updates** zwischen unseren Images macht der Autoupdater, mit erhaltener Konfiguration
(SSH-Keys, fastd-Schlüssel, Position). Von Hand geht dasselbe mit `sysupgrade` ohne `-n`.

Für die TP-Link CPE510 (Pharos-Bootloader, TFTP bzw. Weboberfläche) gibt es eine eigene
Feldanleitung: [docs/cpe510-aufbau.md](docs/cpe510-aufbau.md).

### Statistik unter otm.ffnef.de

Die Gegenstelle ([mgmt-vpn/server](mgmt-vpn/server)) betreibt neben fastd den MQTT-Proxy
(mosquitto-Bridge nach `cits1.opentrafficmap.org`, nur ausgehend), `otm-stats.py`
(liest am Proxy mit, entdoppelt Frames über alle Empfänger, schreibt jede Minute nach
VictoriaMetrics) und Grafana unter <https://otm.ffnef.de>, ohne Anmeldung lesbar:

- **OTM Empfang**: Frames je Empfänger, nur von einem Empfänger gesehene Frames, Anteil,
  verschiedene Absender, Online/Uptime, Firmware je Empfänger, Empfangs-Health (6 h)
- **OTM Heatmap**: Absenderpositionen (aus dem GeoNetworking-Header, Raster ~50 m) über alle
  Empfänger, dazu geteilte Empfängerpositionen; Durchschnitts- und Höchstgeschwindigkeit je
  Rasterzelle (nur Fahrzeuge, keine RSU; im Durchschnitt ohne stehende unter 1 km/h);
  Verkehrsmuster nach Wochentag und Stunde (verschiedene Fahrzeuge pro Stunde, mittlere
  Geschwindigkeit, letzte 28 Tage). Empfänger, die ihre Position teilen, als Funkmast. Kacheln von tiles.ffdus.de.
  Die Karten je Empfänger liegen wegen der Ladezeit auf einer eigenen Seite,
  **OTM Heatmap je Empfaenger**.
- **OTM Knoten**: alles zu einem Empfänger, mit Auswahl oben oder per Klick auf den Namen
  in den Tabellen von OTM Empfang: Firmware-Stände (höchster oben), Status, Uptime, Frames,
  „nur hier gesehen“, Anteil, Health, Funk-Zähler, Rauschen, Kanalbelegung, die Heatmap
  seiner Absender und, nur aus seinen Frames, Durchschnitts- und Höchstgeschwindigkeit je
  Zelle sowie das Verkehrsmuster nach Wochentag und Stunde. Direkt: `https://otm.ffnef.de/d/otm-knoten?var-node=<name>`

Eine abgebaute Station verschwindet aus den Tabellen mit einer leeren retained Nachricht
auf `its/<node>/status` am Proxy.

## Mit SSH

- **Config-Mode** (ab otm-bridge 0.18.0): Reset-Taster (FRITZ!Box 3390: WLAN-Taster) etwa 10 Sekunden halten oder
  `otm-configmode enter`; dann alle Ports fest `192.168.1.1/24` mit DHCP-Server und SSH für
  root ohne Passwort, sonst nichts. Verlassen mit `otm-configmode exit`, jedem Neustart oder von selbst nach 120 Minuten.
  `otm-help` zeigt die wichtigsten UCI-Schlüssel (Name, Position teilen, WLAN-Rückfall,
  Autoupdater) mit ihren Werten. Einzelheiten: [docs/einstellungen.md](docs/einstellungen.md).

## Eigene Images bauen

Siehe [docs/bauen.md](docs/bauen.md): Bauen, Optionen, SSH-Keys im Image, Zusatzpakete,
eigener Update-Server; am Ende, wie wir veröffentlichen.

## Technik

### Was das Gerät nach dem ersten Boot tut

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
  Findet der Wrapper gar kein Funkteil für 5900 MHz, meldet er das stündlich retained an
  `otm/<node>/problem` (ab 0.18.3), samt der vorhandenen Funkteile (`phy0:2.4GHz` oder
  `none`); im Grafana steht das Gerät dann unter „Geraete ohne Empfang“ und in „Empfangs-Health“
  als „kein 5-GHz-Radio“. Ubiquiti-M-Geräte ohne 5-GHz-Funkteil heißen ab 0.18.10 `…M2…`
  statt `…M5…` (z. B. `NSM2XM-xxxx`; vorher Hostname `opentrafficmap`).
- **Position** (wie bei Gluon, `gluon-node-info.@location[0]`): standardmäßig nicht geteilt.

  ```
  uci set otm-bridge.location.share_location=1
  uci set otm-bridge.location.latitude=51.2345
  uci set otm-bridge.location.longitude=6.789
  uci commit otm-bridge
  reload_config
  ```

  Komma oder Punkt gehen beide, `altitude` (Meter) ist freiwillig. Nach `reload_config`
  startet die Bridge neu und meldet die Position; `share_location=0` löscht sie wieder (nach
  spätestens 15 Minuten weg). Sie erscheint nur in unserem Grafana (<https://otm.ffnef.de>, ohne
  Anmeldung lesbar) als blauer Funkmast mit dem Empfängernamen auf den Karten von OTM Heatmap,
  OTM Heatmap je Empfaenger und OTM Knoten, so genau wie eingetragen. Auf der Karte von OpenTrafficMap stehen
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

### Autoupdater

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

**Umstieg auf XW-Geräten** (vom alten System aus, noch ohne Entsperrmodul):

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

### Aufbau des Repos

| Pfad | Inhalt |
|---|---|
| `build.sh`, `release.sh` | Bau eines Targets bzw. des ganzen Release, siehe [docs/bauen.md](docs/bauen.md) |
| `feed/net/otm-bridge/` | Fork von otm-bridge (inzwischen 0.17.0, mit WLAN-Rückfall `otm-uplink`), als `src-link`-Feed eingebunden |
| `feed/net/otm-mgmt-vpn/` | Management-VPN (fastd), uci-defaults |
| `feed/admin/otm-autoupdater/` | Autoupdater nach Gluon-Art |
| `feed/kernel/otm-spinor-unlock/` | Kernel-Modul gegen den Flash-Schreibschutz der Ubiquiti-XW-Boards |
| `patches/openwrt-{21.02,22.03,25.12}/` | ath9k-Kanäle 170–185, ath-regd bis 5925 MHz, Half-Rate, regdb DE ITS |
| `files/common/`, `files/local/` | Dateien fürs Image; `local` ist gitignored (SSH-Keys) |
| `mgmt-vpn/server/` | Gegenstelle: fastd, dnsmasq, nftables, MQTT-Proxy, Statistik, Grafana |
| `werkzeug/` | Messwerkzeuge der Testreihen (z. B. `baseline-24h.sh`, schreibt nur nach `/tmp`) |
| `docs/` | Architektur, Einstellungen und Config-Mode, Gerätekandidaten, Feldanleitung CPE510, LiteBeam-Flash-Schutz, WLAN-Rückfall, Management-VPN (fastd, Dual-Stack), mt76-Versuch (MediaTek), Testmatrix |
| `geraete/` | Config-Backups und Messdaten einzelner Geräte (gitignored) |

## Lizenz

- Eigene Teile (Build-Skript, Werkzeuge, Doku): BSD-3-Clause, siehe `LICENSE`
- `feed/net/otm-bridge/`: Fork, bleibt unter WTFPL (`feed/LICENSE.otm-bridge`)
- `patches/`: GPL-2.0 wie die Kernel- und regdb-Dateien, die sie ändern
