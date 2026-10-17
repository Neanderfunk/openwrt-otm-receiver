# Einstellungen und Config-Mode

Ab otm-bridge 0.18.0. Der Empfänger hat keine Weboberfläche. Eingestellt wird per SSH mit
`uci`; dafür gibt es einen Config-Mode wie bei Gluon, nur ohne Web-UI.

## Config-Mode

**Hinein:**

- Reset-Taster etwa 10 Sekunden gedrückt halten (Auslösung wie bei Gluon), bis das Gerät neu
  startet, oder
- per SSH im Normalbetrieb: `otm-configmode enter`.

Ausgewertet werden die Taster `reset`, `wps` und `phone`, wie bei Gluon. Die FRITZ!Box 3390 hat
keinen davon, sie kommt nur per Befehl in den Config-Mode. OpenWrts eigene Belegung des
Reset-Tasters (kurz = Neustart, ab 5 s = Werksreset) ist stillgelegt, auch das wie bei Gluon.

**Im Config-Mode:**

- Alle Ports: fest `192.168.1.1/24`, mit DHCP-Server für `192.168.1.2` bis `.254`. Laptop
  direkt anstecken, dann `ssh root@192.168.1.1`, ohne Passwort.
- Die Status-LED blinkt (wie bei Gluon).
- Es läuft nur SSH: keine Daten an den Broker, kein Tunnel, kein Autoupdater, kein
  WLAN-Rückfall, keine Firewall.
- Beim Login steht ein Hinweis, wie man wieder herauskommt.

**Heraus:**

- `otm-configmode exit`: richtet SSH nach den hinterlegten Keys ein und startet neu.
- Jeder andere Neustart, auch Strom aus und wieder an, führt ebenfalls in den Normalbetrieb.
  Der Config-Mode gilt immer nur für einen Start.

`otm-configmode` ohne Argument sagt, in welchem Modus das Gerät läuft.

## SSH-Keys

Keys stehen in `/etc/dropbear/authorized_keys`, einer je Zeile. Mit Key ist SSH im
Normalbetrieb offen, nur per Key; ohne Key ist SSH im Normalbetrieb zu. Ein im Config-Mode
eingetragener Key gilt nach `otm-configmode exit` auch im Normalbetrieb, auch auf Geräten,
deren Image ohne Key gebaut wurde. Keys bleiben bei Updates erhalten.

## Einstellungen (UCI)

`otm-help` zeigt die wichtigsten Schlüssel mit ihren aktuellen Werten, in beiden Modi; beim
Login steht ein Hinweis darauf.

| Schlüssel | Vorgabe | Bedeutung |
|---|---|---|
| `otm-bridge.main.node` | leer | Name des Empfängers im MQTT-Topic `its/<node>/…`; unter diesem Namen führen ihn der Broker von OpenTrafficMap und unser Grafana. Leer = `<Modell>-<letzte 4 Stellen der MAC>`, z. B. `WR4300-902f` |
| `otm-bridge.main.enabled` | `1` | `0` schaltet den Empfang ab |
| `otm-bridge.main.transport` | aus dem Bau (`proxy`) | `proxy` (MQTT durch den Tunnel), `direct` (TLS direkt zu OpenTrafficMap, braucht TLS im Image), `auto` |
| `otm-bridge.main.freq` | `5900` | Kanal in MHz (ITS-Kanal 180) |
| `otm-bridge.location.share_location` | `0` | `1` = Position an unseren Proxy melden (Grafana-Karte), nicht an OpenTrafficMap |
| `otm-bridge.location.latitude` / `longitude` | leer | Dezimalgrad, Punkt oder Komma |
| `otm-bridge.location.altitude` | leer | Meter, freiwillig |
| `otm-bridge.uplink.wlan_fallback` | `1` | WLAN-Rückfall über 2.4 GHz, nur Dualband-Geräte, siehe [wlan-rueckfall.md](wlan-rueckfall.md) |
| `otm-bridge.uplink.ssid_prefix` | `Freifunk` | SSID muss so beginnen (Groß-/Kleinschreibung egal) |
| `otm-bridge.uplink.lan_timeout` / `wlan_timeout` | `90` / `60` | Sekunden bis zum Wechsel bzw. bis DHCP im WLAN |
| `autoupdater.settings.enabled` | `1` | `0` = keine automatischen Updates |
| `autoupdater.stable.good_signatures` | `3` | Mindestzahl gültiger Signaturen am Manifest |

Ändern und übernehmen:

```sh
# Position teilen
uci set otm-bridge.location.share_location=1
uci set otm-bridge.location.latitude=51.2345
uci set otm-bridge.location.longitude=6.789
uci commit otm-bridge
reload_config

# anderer Name
uci set otm-bridge.main.node='Hilden-Bahnhof'
uci commit otm-bridge
reload_config
```

`reload_config` startet die Bridge mit den neuen Werten neu. Im Config-Mode genügt
`uci commit`; wirksam wird es beim Neustart in den Normalbetrieb.

Ein neuer Name ist für OpenTrafficMap und unser Grafana ein neuer Empfänger. Der alte Name
bleibt im Grafana mit seinem Verlauf stehen und fällt aus den Tabellen, wenn er 24 Stunden
offline ist; ganz entfernen: leere retained Nachricht auf `its/<alter name>/status` am Proxy.
Der Hostname des Geräts (DHCP) ändert sich dabei nicht.

## Weitere Befehle

| Befehl | Wirkung |
|---|---|
| `otm-help` | Einstellungen und Befehle anzeigen |
| `otm-configmode enter` / `exit` | Config-Mode an bzw. aus (Neustart) |
| `otm-autoupdater -n` | prüfen, ob es neue Firmware gibt, ohne einzuspielen |
| `logread -e otm` | Meldungen von otm-bridge, otm-uplink, otm-configmode, Autoupdater |
| `firstboot -y && reboot` | Werkszustand, alle Einstellungen und Keys weg |
