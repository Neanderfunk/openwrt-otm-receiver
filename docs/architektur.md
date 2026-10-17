# Architektur

Wie die Teile ineinandergreifen: vom Funkrahmen auf 5.9 GHz bis zu OpenTrafficMap und
<https://otm.ffnef.de>. Einzelheiten stehen in den verlinkten Dokumenten.

## Überblick

```
  Fahrzeuge, RSUs: ITS-G5, 5.9 GHz, 10 MHz
          |
          v
+-- Empfänger (OpenWrt, ath9k) ---------------------------------+
|  mon0 (Monitor, Half-Rate-Patches, regdb nur Empfang)         |
|    -> otm-bridge (pcap, rohe 802.11-Frames ohne Radiotap)     |
|         its/<node>/{status,info,packet,stats}                 |
|         otm/<node>/{build,location,health}                    |
|    -> MQTT ohne TLS an 10.66.0.1:1883                         |
|    -> fastd (tap, salsa2012+umac)                             |
|  Uplink: LAN per DHCP, sonst otm-uplink (2.4 GHz Freifunk)    |
|  otm-autoupdater: täglich Manifest von firmware.ffnef.de      |
+---------------------------------------------------------------+
          |
          | fastd über UDP 10001, IPv6, sonst IPv4
          v
+-- Gegenstelle wgiot (Ubuntu) ---------------------------------+
|  fastd multitap -> br-otm 10.66.0.1/22                        |
|  dnsmasq: DHCP im Tunnelnetz, Namen <knoten>.otm              |
|  mosquitto :1883                                              |
|    -> Bridge its/#, nur ausgehend, TLS -----------------------+--> cits1.opentrafficmap.org:8883
|    -> otm-stats.py (its/# und otm/+/...)                      |
|         -> VictoriaMetrics 127.0.0.1:8428                     |
|              -> Grafana :3000 (nur lokal und Proxy-Netz)      |
+---------------------------------------------------------------+
          |
          v
  Reverse-Proxy (TLS) -> https://otm.ffnef.de
  Lesen ohne Anmeldung, Bearbeiten nach Login über Authentik,
  Kartenkacheln lädt der Browser von tiles.ffdus.de
```

## Datenwege

1. **Empfang.** Das ath9k-Radio hört im Monitor-Modus (`mon0`) auf einem ITS-Kanal mit 10 MHz.
   Dafür sorgen eigene Kanal-, Regdomain- und Half-Rate-Patches für mac80211 sowie eine
   wireless-regdb, deren ITS-Regel `NO-IR` trägt: Das Gerät kann nur empfangen.
2. **Aufbereitung.** `otm-bridge` liest die Frames per pcap und veröffentlicht sie roh (ohne
   Radiotap) im Format der ESP32-C5-Referenzfirmware unter `its/<node>/packet`; ausgewertet
   wird erst bei OpenTrafficMap bzw. in `otm-stats.py`. Dazu
   kommen, nur für den eigenen Proxy, `otm/<node>/build`, `…/location` (wenn geteilt) und
   `…/health`.
3. **Tunnel.** MQTT läuft ohne TLS durch fastd zur Gegenstelle. Die alten Geräte mit wenig
   Flash brauchen so keinen TLS-Stack, kein CA-Bundle und keine gestellte Uhr. Tunnel und
   Dual-Stack: [management-vpn.md](management-vpn.md).
4. **Weiterleitung.** mosquitto auf der Gegenstelle reicht nur `its/#` per TLS an
   OpenTrafficMap weiter, und nur in diese Richtung. `otm/#` bleibt beim Proxy.
5. **Statistik.** `otm-stats.py` liest am Proxy mit, entdoppelt Frames über alle Empfänger,
   wertet Positionen aus dem GeoNetworking-Header aus und schreibt jede Minute ins
   Influx-Line-Protokoll von VictoriaMetrics. Grafana zeigt daraus die Dashboards
   „OTM Empfang“ und „OTM Heatmap“.
6. **Betrieb.** Über den Tunnel ist jedes Gerät per SSH als `<knoten>.otm` erreichbar, sofern ein
   Key im Image ist. Der Autoupdater holt einmal am Tag das signierte Manifest von
   `firmware.ffnef.de`.

Andere Wege:
- `transport=direct`: `mqtts` direkt an OpenTrafficMap, ohne Tunnel. Braucht TLS im Image
  und ist nur für Geräte mit Platz gedacht.
- WLAN-Rückfall: Hat das LAN kein DHCP, geht der Uplink über ein offenes Freifunk-Netz auf
  2.4 GHz, siehe [wlan-rueckfall.md](wlan-rueckfall.md).

## Was wo liegt

Alles, was wir selbst bauen und betreiben, liegt in **einem** Repo,
[Neanderfunk/openwrt-otm-receiver](https://github.com/Neanderfunk/openwrt-otm-receiver):

| Teil | Verzeichnis |
|---|---|
| Build für die Router (SDK + ImageBuilder) | `build.sh`, `release.sh` |
| Treiber-Patches (ath9k, regdb, mt76-Versuch) | `patches/openwrt-<version>/` |
| Pakete fürs Image | `feed/` (`otm-bridge` mit `otm-uplink`, `otm-mgmt-vpn`, `otm-autoupdater`, `otm-spinor-unlock`) |
| Grundkonfiguration der Images | `files/` |
| Gegenstelle: fastd, Netz, Firewall, dnsmasq, mosquitto, otm-stats | `mgmt-vpn/server/` (Einrichtung `install.sh`) |
| Grafana: Datenquelle VictoriaMetrics, Dashboards | `mgmt-vpn/server/grafana/` (Einrichtung `install-grafana.sh`) |
| Mess- und Auswertewerkzeuge | `werkzeug/` |
| Dokumentation | `README.md`, `docs/`, `mgmt-vpn/server/README.md` |

VictoriaMetrics und Grafana kommen als fertige Pakete (Ubuntu bzw. apt.grafana.com). Im
Repo stehen nur ihre Einstellungen und die Dashboards als Provisioning-Dateien.

Nicht in diesem Repo:

| Teil | Wo |
|---|---|
| Vorlage für otm-bridge | [MPW1412/openwrt-otm-bridge](https://github.com/MPW1412/openwrt-otm-bridge); unser Fork liegt als Kopie unter `feed/net/otm-bridge/` |
| OpenWrt-SDK und -ImageBuilder | downloads.openwrt.org, `build.sh` lädt sie |
| Signierschlüssel für den Autoupdater | öffentliche Schlüssel wie in den Neanderfunk-Sites (`buildkeys/ffnef.signkeys` in FirmwareConfigs); signiert wird mit `gluon/contrib/sign.sh` |
| Firmware-Server `firmware.ffnef.de` | Webserver der Neanderfunk; dorthin kommt `build/release-<version>/otm/` |
| Reverse-Proxy und TLS für `otm.ffnef.de`, Authentik | Neanderfunk-Infrastruktur |
| Kartenkacheln `tiles.ffdus.de` | Kachelserver der Neanderfunk |
| Broker `cits1.opentrafficmap.org` | OpenTrafficMap |

## Schlüssel und Geheimnisse

Im Repo stehen nur öffentliche Schlüssel. Wo die geheimen liegen:

| Schlüssel | Geheimer Teil | Öffentlicher Teil |
|---|---|---|
| Signierschlüssel Autoupdater-Manifest | bei den Signierenden selbst; `release.sh` legt das Manifest unsigniert ab, signiert wird von Hand (`sign.sh`) | `feed/admin/otm-autoupdater/files/autoupdater.config`, wie `buildkeys/ffnef.signkeys` in FirmwareConfigs |
| fastd der Gegenstelle | wgiot `/etc/fastd/otm/secret.conf` (root, 600); `install.sh` erzeugt ihn nur, wenn die Datei fehlt | im Image: `feed/net/otm-mgmt-vpn/files/98-otm-mgmt-vpn`, Peer `mgmt_wgiot` |
| fastd der Empfänger | je Gerät beim ersten Boot erzeugt (`secret 'generate'`), in `/etc/config/fastd`, bleibt bei sysupgrade | - (die Gegenstelle nimmt jeden Schlüssel an) |
| SSH zu den Empfängern | bei den Betreuenden | `files/local/etc/dropbear/authorized_keys` (nicht im Repo), nur in den key-Images |
| Grafana-Login über Authentik (OAuth-Client-Secret) | wgiot `/etc/grafana/authentik-client-secret` (root:grafana, 640), per `$__file{…}` gelesen | - |
| Bridge zu OpenTrafficMap | keine Zugangsdaten: Client-ID `otm-wgiot-bridge`, Server-Zertifikat geprüft gegen `/etc/ssl/certs` | - |

Der fastd-Schlüssel der Gegenstelle ist der empfindlichste: Geht er verloren, traut kein
Empfänger einer neu aufgesetzten Gegenstelle. Ein neues Image käme dann nur noch per
Autoupdater auf die Geräte. Bei einer Neuinstallation `secret.conf` deshalb zurückspielen,
bevor `install.sh` läuft. Eine Sicherung liegt außerhalb des Repos.
