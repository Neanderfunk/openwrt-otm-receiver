# Einstellungen und Config-Mode

Ab otm-bridge 0.18.0. Der Empfänger hat keine Weboberfläche. Eingestellt wird per SSH mit
`uci`; dafür gibt es einen Config-Mode wie bei Gluon, nur ohne Web-UI.

## Config-Mode

**Hinein:**

- Reset-Taster etwa 10 Sekunden gedrückt halten (Auslösung wie bei Gluon), bis das Gerät neu
  startet. Das ist der Weg für alle, die noch keinen SSH-Schlüssel auf dem Gerät haben: Ohne
  Schlüssel ist SSH im Normalbetrieb zu, also kommt man auch nicht per SSH in den Config-Mode.
- per SSH im Normalbetrieb: `otm-configmode enter`. Nur mit Schlüssel möglich, und wer den hat,
  braucht den Config-Mode eigentlich nicht: Alle Einstellungen gehen per SSH genauso im
  Normalbetrieb (siehe unten). Der Befehl ist für Betreuende gedacht, z. B. zum Testen, und
  für die FRITZ!Box 3390 vor 0.18.5, die noch keinen Taster dafür hatte.

Ausgewertet werden die Taster `reset`, `wps` und `phone`, wie bei Gluon. Die FRITZ!Box 3390 hat
keinen davon; dort gilt der WLAN-Taster (ab otm-bridge 0.18.5), ebenfalls etwa 10 Sekunden
halten. OpenWrts eigene Belegung des Reset-Tasters (kurz = Neustart, ab 5 s = Werksreset) ist
stillgelegt, auch das wie bei Gluon. Ebenso stillgelegt ist die des WLAN-Tasters (WDR3600/4300/
4900, FRITZ!Box 3390): Sie würde die absichtlich ausgeschalteten Funkteile einschalten, den
Empfang beenden und OpenWrts offenes Standard-WLAN hochbringen. Der Power-Taster der 3390
schaltet weiter aus.

**Im Config-Mode:**

- Alle Ports: fest `192.168.1.1/24`, mit DHCP-Server für `192.168.1.2` bis `.254`. Laptop
  direkt anstecken, dann `ssh root@192.168.1.1`, ohne Passwort.
- Die Status-LED blinkt (wie bei Gluon).
- Es läuft nur SSH: keine Daten an den Broker, kein Tunnel, kein Autoupdater, kein
  WLAN-Rückfall, keine Firewall.
- Beim Login steht ein Hinweis, wie man wieder herauskommt.

**Heraus:**

- `otm-configmode exit`: startet neu in den Normalbetrieb.
- Jeder andere Neustart, auch Strom aus und wieder an, führt ebenfalls in den Normalbetrieb.
  Der Config-Mode gilt immer nur für einen Start.
- Von selbst nach **120 Minuten**: Dann startet das Gerät neu in den Normalbetrieb, falls der
  Config-Mode versehentlich ausgelöst wurde.

`otm-configmode` ohne Argument sagt, in welchem Modus das Gerät läuft.

## SSH-Keys

Keys stehen in `/etc/dropbear/authorized_keys`, einer je Zeile. Mit Key ist SSH im
Normalbetrieb offen, nur per Key; ohne Key ist SSH im Normalbetrieb zu. Das prüft das Gerät bei
jedem Start (ab otm-bridge 0.18.2; vorher nur bei `otm-configmode exit`). Ein im Config-Mode
eingetragener Key gilt deshalb nach jedem Weg hinaus auch im Normalbetrieb, auch auf Geräten,
deren Image ohne Key gebaut wurde. Keys bleiben bei Updates erhalten.

Schlüsseltypen: ed25519, RSA und ECDSA, auch auf den XM-Images mit OpenWrt 21.02.7 (dropbear
2020.81 mit ed25519).

### Wenn der Login mit Key nicht klappt

- **Dateirechte** von `/etc/dropbear` und `authorized_keys` korrigiert das Gerät ab otm-bridge
  0.18.11 bei jedem Start selbst (`logread -e otm-ssh`).
- **Format:** je Key genau eine Zeile `ssh-ed25519 AAAA… kommentar` bzw. `ssh-rsa AAAA…`. Das
  mehrzeilige PuTTY-Format (`---- BEGIN SSH2 PUBLIC KEY ----`) geht nicht; in PuTTYgen den
  Text aus „Public key for pasting into OpenSSH authorized_keys file“ nehmen. Keine
  Windows-Zeilenenden, keine Zeilenumbrüche im Key.
- **Privater Key am Rechner:** OpenSSH verweigert einen privaten Key, der für andere lesbar ist
  („UNPROTECTED PRIVATE KEY FILE“), also `chmod 600` auf die Datei.
- **Ältere Firmware (vor otm-bridge 0.18.2):** Ein im Config-Mode eingetragener Key gilt dort
  nur nach `otm-configmode exit`, nicht nach Neustart oder Strom aus/an.
- **Log am Gerät** (z. B. im Config-Mode): `logread -e dropbear`; bei falschem Format oder
  falschem Key steht dort ein fehlgeschlagener Pubkey-Versuch.

### Wenn 192.168.1.1 im Config-Mode nicht antwortet

- `br-lan` läuft mit STP: Nach dem Einstecken leitet die Bridge erst nach etwa 30 s weiter.
- Hat der Rechner keine Adresse per DHCP bekommen, fest `192.168.1.2/24` setzen.
- Bei Außengeräten mit PoE an die LAN-Buchse des PoE-Adapters.
- Link-lokal per IPv6 geht unabhängig von der IPv4-Einrichtung, dropbear lauscht auch dort:
  `ping -6 ff02::1%<if>` zeigt die Adresse des Geräts, dann `ssh root@fe80::…%<if>`
  (`<if>` = Netzwerkkarte des Rechners).
- Antwortet auch link-lokal nichts, liegt es an Kabel, Switch oder Treiber; dann hilft nur die
  serielle Konsole.

## Einstellungen (UCI)

`otm-help` zeigt die wichtigsten Schlüssel mit ihren aktuellen Werten, in beiden Modi; beim
Login steht ein Hinweis darauf.

| Schlüssel | Vorgabe | Bedeutung |
|---|---|---|
| `otm-bridge.main.node` | leer | Name des Empfängers im MQTT-Topic `its/<node>/…`; unter diesem Namen führen ihn der Broker von OpenTrafficMap und unser Grafana. Leer = `<Modell>-<letzte 4 Stellen der MAC>`, z. B. `WR4300-902f` |
| `otm-bridge.main.enabled` | `1` | `0` schaltet den Empfang ab |
| `otm-bridge.main.transport` | aus dem Bau (`proxy`) | `proxy` (MQTT durch den Tunnel), `direct` (TLS direkt zu OpenTrafficMap, braucht TLS im Image), `auto` |
| `otm-bridge.main.freq` | `5900` | Kanal in MHz (ITS-Kanal 180) |
| `otm-bridge.location.share_location` | `0` | `1` = Position an unseren Proxy melden: Funkmast mit Namen auf den Karten in <https://otm.ffnef.de> (öffentlich, so genau wie eingetragen), nicht an OpenTrafficMap; nach `0` spätestens 15 min später weg |
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

Unser Grafana erkennt den Empfänger an der MAC seines ITS-Radios wieder und führt den
Verlauf unter dem neuen Namen fort; der alte Name verschwindet (`otm-stats` schreibt die
Reihen in VictoriaMetrics um, siehe [mgmt-vpn/server/README.md](../mgmt-vpn/server/README.md)).
Für OpenTrafficMap ist ein neuer Name ein neuer Empfänger; dort entfernt man den alten mit
einer leeren retained Nachricht auf `its/<alter name>/status` am Proxy.
Der Hostname des Geräts (DHCP, SSH, `<hostname>.otm` im Tunnel) ändert sich dabei nicht, und
umgekehrt ändert ein neuer Hostname den Namen auf den Karten nicht.

## Weitere Befehle

| Befehl | Wirkung |
|---|---|
| `otm-help` | Einstellungen und Befehle anzeigen |
| `otm-configmode enter` / `exit` | Config-Mode an bzw. aus (Neustart) |
| `otm-autoupdater -n` | prüfen, ob es neue Firmware gibt, ohne einzuspielen |
| `logread -e otm` | Meldungen von otm-bridge, otm-uplink, otm-configmode, Autoupdater |
| `firstboot -y && reboot` | Werkszustand, alle Einstellungen und Keys weg |

## Test (17.10.2026, WDR3600 am Testplatz)

Testimage 202610171536 (Commit 94c05aa), WAN am NAT-Port, ein LAN-Port am Testplatz-PC
(192.168.1.66).

| Fall | Ergebnis |
|---|---|
| sysupgrade -n von Gluon | Normalbetrieb, Tunnel und otm-bridge 0.18.0 nach ~2 min |
| `otm-configmode enter` | nach ~80 s unter 192.168.1.1; nur SSH (kein otm-bridge, fastd, otm-uplink, keine Firewall), DHCP-Server läuft, Login ohne Key und Passwort, Hinweis beim Login |
| Reset-Taster gehalten (adorfer) | Config-Mode, SSH ohne Passwort |
| Status-LED im Config-Mode | per Kamera gemessen: ~1,0 s an, ~0,3 s aus (Gluons `status_led_set_timer 1000 300`) |
| `otm-configmode exit` | Normalbetrieb nach ~2 min |
| `reboot` im Config-Mode | Normalbetrieb |
| Strom 10 s aus (Tasmota-Dose) im Config-Mode | Normalbetrieb |
