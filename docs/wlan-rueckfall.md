# WLAN-Rückfall über 2.4 GHz (`otm-uplink`)

Ab otm-bridge 0.17.0. Ein Empfänger, der am Aufstellort kein LAN mit DHCP bekommt, kann sich
über ein offenes Freifunk-Netz ins Internet verbinden und so den Management-Tunnel und den
MQTT-Proxy erreichen.

## Wo es greift

Nur auf Geräten mit **eigenem 2.4-GHz-Radio neben dem ITS-Radio** (5 GHz):

| Gerät | 2.4-GHz-Radio | Rückfall |
|---|---|---|
| TP-Link TL-WDR3600, TL-WDR4300, TL-WDR3500, TL-WDR4310 | im SoC (phy0) | ja (WDR3600 getestet) |
| AVM FRITZ!Box 3390 | hängt am Zweitprozessor, unter OpenWrt nicht nutzbar | nein |
| TP-Link CPE510/610, WBS510, Ubiquiti LiteBeam/NanoStation/PowerBeam/Bullet | keins (nur 5 GHz) | nein |

Erkannt wird das automatisch (`otm_24_phy` in `/lib/otm-bridge/functions.sh`: ein phy mit
2.4-GHz-Band, das nicht das ITS-phy ist). Ohne solches Radio startet der Dienst nicht.

## Ablauf

```
             +-----------------------------+
   Start --> | LAN (Interface wan) hat DHCP?|
             +-----------------------------+
               | ja (binnen lan_timeout)       | nein
               v                               v
        Uplink LAN                  2.4 GHz: stärkstes offenes Netz,
        warten auf "wan down"       SSID beginnt mit ssid_prefix
               |                    verbinden, DHCP auf wwan
               |                               |
               |                 klappt        |  klappt nicht
               |               +---------------+------------+
               |               v                            v
               |        Uplink WLAN                   WLAN aus, wieder
               |        warten auf "wwan down"        von vorn (LAN zuerst)
               |        oder "wan up"
               |               |
               +------<--------+  WLAN aus, wieder von vorn (LAN zuerst)
```

- **LAN hat Vorrang.** Solange das LAN eine DHCP-Adresse hat, ist das 2.4-GHz-Radio aus.
- **Kein Dauerabfragen.** Im verbundenen Zustand (LAN oder WLAN) wartet `otm-uplink` nur auf
  Ereignisse von netifd (`ubus listen network.interface`). Abgefragt wird nur während der
  Suche: bis zu `lan_timeout` Sekunden auf eine LAN-Adresse, danach ein WLAN-Scan.
- **LAN kommt zurück:** netifd fragt auf dem LAN ohnehin weiter DHCP an. Sobald dort eine
  Adresse kommt (Ereignis `ifup wan`), geht das WLAN aus.
- **WLAN bricht ab:** netifd meldet `ifdown wwan` (Verbindungsverlust), die Suche beginnt von
  vorn, LAN zuerst.
- **Netzwahl:** nur offene Netze (weder `Privacy` noch RSN/WPA im Scan), SSID beginnt mit
  `ssid_prefix`, Groß-/Kleinschreibung egal; also z. B. „Freifunk“, „freifunk-xyz“, aber nicht
  „Freifunk verschluesselt“ (verschlüsselt). Unter mehreren gewinnt das stärkste Signal.
- **Verbinden** per `iw … connect` ohne wpa_supplicant (offene Netze brauchen keinen), dann
  DHCP über das netifd-Interface `wwan` (Gerät `wlan24`, `auto 0`, Routen-Metrik 50, Zone
  `wan` der Firewall).
- **Tunnel:** Nach jedem Wechsel startet fastd neu, sonst hält es an der alten Quelladresse
  fest und merkt den Wechsel erst spät. Die otm-bridge verbindet sich danach von selbst neu.

## Einstellungen

`/etc/config/otm-bridge`, Abschnitt `uplink` (bei Updates mit alter Konfiguration legt
uci-defaults ihn an):

| Option | Vorgabe | Bedeutung |
|---|---|---|
| `wlan_fallback` | `1` | `0` schaltet den Rückfall ab |
| `ssid_prefix` | `Freifunk` | SSID muss so beginnen (ohne Gross/Klein) |
| `lan_timeout` | `90` | Sekunden, die auf DHCP im LAN gewartet wird |
| `wlan_timeout` | `60` | Sekunden, die auf DHCP im WLAN gewartet wird |

```sh
uci set otm-bridge.uplink.ssid_prefix='Freifunk'
uci commit otm-bridge
reload_config            # startet otm-uplink neu
logread -e otm-uplink    # was passiert ist
```

## Grenzen

- Nur offene Netze. Ein verschlüsseltes Netz bräuchte wpa_supplicant (wpad), das im Image
  fehlt, und Zugangsdaten.
- „LAN da“ heißt: IPv4 per DHCP auf `wan`. Ein reines IPv6-LAN zählt nicht als LAN.
- Das Freifunk-Netz muss UDP zur Gegenstelle (fastd, Port 10001) durchlassen; bei
  Neanderfunk ist das so.
- Der Empfang auf 5.9 GHz läuft unabhängig davon weiter (anderes Radio).

## Test am WDR3600 (17.10.2026)

Mit der Vorabfassung (Bind-Mount, Image 202610151119). LAN-Ausfall simuliert mit
`ifdown wan; ifdown wan6`, Sicherheitsnetz: nach 15 min `ifup wan`.

| UTC | Ereignis |
|---|---|
| 02:51:14 | LAN aus → sofort „LAN lost, searching“ |
| 02:52:46 | nach 90 s ohne DHCP: „trying WLAN“ |
| 02:52:48 | Verbindung mit „Freifunk“ (2412 MHz, −23 dBm, stärkstes offenes Netz) |
| 02:52:50 | DHCP auf `wwan`, Standardroute über WLAN |
| 02:53:12 | fastd-Tunnel steht über das WLAN, Gerät per `<knoten>.otm` erreichbar |
| 02:53:53 | LAN zurück (`ifup wan`) |
| 02:53:57 | „LAN is back, leaving WLAN“ |
| 02:54:03 | Tunnel wieder über das LAN |
| 02:57:01 | zweiter Durchgang: WLAN-Verbindung getrennt (`iw … disconnect`) → netifd meldet `wwan` down, sofort „WLAN lost, searching“ |
| 02:58:36 | nach 90 s ohne LAN: wieder WLAN, diesmal ein anderer AP (2437 MHz) |
| 03:00:26 | LAN zurück → WLAN nach 5 s aus, Tunnel nach weiteren 4 s über das LAN |

Im Ruhezustand lief jeweils genau ein `ubus listen`, sonst nichts.
