# OTM-Empfänger auf OpenWrt

Passiver ITS-G5-Empfänger (802.11p, 5,9 GHz) für [opentrafficmap.org](https://opentrafficmap.org/)
auf Routern mit ath9k-Funkteil. Plain OpenWrt 21.02.7, kein LuCI. Nach dem
Flashen läuft das Gerät ohne Handarbeit: Kabel an irgendeinen Port, fertig.

Vorbild und Basis: [MPW1412/openwrt-otm-bridge](https://github.com/MPW1412/openwrt-otm-bridge)
und [MPW1412/avm-fritz3390-802.11p-otm](https://github.com/MPW1412/avm-fritz3390-802.11p-otm),
die Kanal-Patches gehen auf OpenWrt-V2X (Raviglione) bzw. Klingler/Pannu (CCS Labs) zurück.

## Bauen

```sh
./build.sh                                   # WDR4300 + WDR3600
PROFILES="tplink_tl-wdr3600-v1" ./build.sh   # einzelnes Profil
```

Kein Komplettbau. Das SDK baut nur die gepatchten Pakete (mac80211, wireless-regdb, otm-bridge,
Paketrevision `91`), der ImageBuilder baut daraus mit dem Release-Kernel das Image.
Ergebnis unter `build/out/<release>/<profil>/`. Dort liegen Image, Manifest, sha256sums und `build-info`;
dieselbe Datei steht im Gerät unter `/etc/otm-build-info`.

## Flashen

Immer ohne alte Konfiguration, denn ein Image von 25.12 oder aus Münster passt nicht dazu:

```sh
scp -O openwrt-*-sysupgrade.bin root@<gerät>:/tmp/
ssh root@<gerät> 'sysupgrade -T /tmp/openwrt-*-sysupgrade.bin && sysupgrade -n /tmp/openwrt-*-sysupgrade.bin'
```

Die Host-Keys werden dabei neu erzeugt. Den alten `known_hosts`-Eintrag vorher entfernen.

## Was das Gerät nach dem ersten Boot tut

- **Netz**: Alle Ports hängen in einer Bridge (STP an) und beziehen per DHCP IPv4 und IPv6.
  Auf dem Gerät läuft kein DHCP- oder RA-Server. SSH ist erlaubt, aber nur per Key
  (`files/common/etc/dropbear/authorized_keys`).
- **Funk**: Die Radios sind in `/etc/config/wireless` deaktiviert, damit netifd das
  Monitor-Interface nicht löscht. `/usr/libexec/otm-bridge-run` setzt die Regdomain (`DE`),
  sucht das phy mit 5900 MHz, legt `mon0` an (10 MHz, Half-Rate), wartet auf NTP und startet
  `otm-bridge`. procd startet den Wrapper bei Bedarf neu, dabei wird auch `mon0` neu angelegt.
- **Knotenname**: `<Board-Kurzname>-<letzte 4 Hex der mon0-MAC>`, z. B. `WR4300-902f`.
  Mit `uci set otm-bridge.main.node=…` lässt er sich überschreiben.
- **MQTT**: `its/<node>/{status,info,packet,stats}` an `mqtts://cits1.opentrafficmap.org`,
  im selben Format wie die ESP32-C5-Referenzfirmware.
- **Nur Empfang**: Die ITS-Regel in der regdb trägt `NO-IR`. Tunen im Monitor-Modus geht,
  OCB-Join und Injection sind gesperrt.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `feed/net/otm-bridge/` | Fork von otm-bridge (0.11.1), als `src-link`-Feed eingebunden |
| `patches/openwrt-21.02/` | ath9k-Kanäle 170–185, ath-regd bis 5925 MHz, Half-Rate, regdb DE ITS |
| `files/common/` | Dateien, die ins Image eingebacken werden (authorized_keys) |
| `werkzeug/baseline-24h.sh` | 24-h-Messung am laufenden Empfänger, schreibt nur nach `/tmp` |
| `geraete/` | Config-Backups einzelner Geräte (gitignored, enthalten Host-Keys) |
| `UEBERGABE-openwrt-targets.md` | Wissen aus dem Neanderfunk-Build zu Targets und Patches |

## Geräte

| Gerät | Stand |
|---|---|
| TP-Link TL-WDR4300 v1 | Image gebaut, Test am Gerät steht aus |
| TP-Link TL-WDR3600 v1 | Image gebaut, ungetestet |
| Ubiquiti NanoStation/Bullet/Rocket M5 (XM, XW), TP-Link CPE510 | Kandidaten (ath9k, Images in 21.02.7) |
| LiteBeam M5 (XW) | Kandidat, fehlt in 21.02, braucht einen Backport |
| LiteBeam 5AC, UniFi AC Mesh | ungeeignet: 5 GHz nur über ath10k, keine 10-MHz-Kanäle |

Lizenz: Die otm-bridge-Teile stehen weiter unter WTFPL (`feed/LICENSE.otm-bridge`), die
Kernel-Patches unter GPL-2.0 wie die Dateien, die sie ändern.
