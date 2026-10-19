# Gegenstelle: Management-VPN, MQTT-Proxy, Statistik

Läuft auf einem Server (bei uns Ubuntu 24.04) und ist für die Empfänger der einzige
Ansprechpartner: Sie bauen einen fastd-Tunnel hierher auf, schicken ihre Frames per MQTT
ohne TLS an den Proxy, und der reicht sie per TLS an OpenTrafficMap weiter.

```
Empfänger --fastd--> br-otm 10.66.0.1/22 --> mosquitto :1883 --TLS--> cits1.opentrafficmap.org:8883
                                               |
                                               +--> otm-stats.py --> VictoriaMetrics --> Grafana
```

## Teile

| Datei | Zweck |
|---|---|
| `fastd.conf`, `peer-up.sh`, `peer-log.sh`, `fastd-verify.sh`, `otm-fastd` | fastd-Instanz `otm` (Multi-TAP), jeder Schlüssel darf sich verbinden außer der Sperrliste, wahlweise nur freigegebene (s. u.); die TAPs hängen an `br-otm` |
| `otm-mgmt-net.service`, `nft.conf` | Bridge `br-otm`, Firewall (`table inet otm_mgmt`): aus dem Tunnel nur DHCP, DNS, MQTT und Ping zur Gegenstelle, keine Weiterleitung; Grafana-Port 3000 nur von localhost und dem Reverse-Proxy-Netz. `peer-up.sh` hängt jedes TAP als isolierten Bridge-Port an, die Empfänger sehen sich gegenseitig nicht |
| `dnsmasq.conf`, `dnsmasq-otm.service` | DHCP im Tunnelnetz 10.66.0.0/22, Namen `<knoten>.otm`; verteilt weder Router noch DNS, die Standardroute der Empfänger bleibt lokal |
| `mosquitto-otm.conf`, `mosquitto-otm.override`, `mosquitto-otm-tunnel.acl` | Listener auf 10.66.0.1 (mit ACL, s. u.) und 127.0.0.1, Bridge `its/#` **nur ausgehend** an `cits1.opentrafficmap.org:8883` |
| `otm-stats.py`, `otm-stats.service` | liest `its/#` und `otm/+/{build,location,health}` mit, entdoppelt Frames über alle Empfänger, schreibt jede Minute ins Influx-Line-Protokoll von VictoriaMetrics; Metriken im Kopf der Datei |
| `grafana/` | Umgebungsvariablen, Datenquelle, Dashboards `OTM Empfang`, `OTM Heatmap`, `OTM Heatmap je Empfaenger` und `OTM Knoten` (je Empfänger, verlinkt aus den Tabellen) (Provisioning aus Dateien) |

Topics außerhalb von `its/#` (`otm/<node>/build`, `…/location`, `…/health`) bleiben beim
Proxy; die Bridge reicht sie nicht an OpenTrafficMap weiter.

## Einrichten

Pakete: `fastd`, `dnsmasq`, `nftables`, `mosquitto`, `python3-paho-mqtt`,
`victoria-metrics` (Ubuntu-Paket) und Grafana aus apt.grafana.com.

```sh
sudo ./install.sh                 # fastd, Netz, dnsmasq, mosquitto, otm-stats
sudo ./grafana/install-grafana.sh  # Grafana-Einstellungen, Datenquelle, Dashboards
```

Beide Skripte sind wiederholbar. `install.sh` erzeugt den fastd-Schlüssel nur, wenn noch
keiner da ist; dessen öffentlicher Teil gehört in
`feed/net/otm-mgmt-vpn/files/98-otm-mgmt-vpn` (Peer `mgmt_wgiot`). Die Gegenstelle erreicht
die Empfänger per SSH unter `<knoten>.otm`, sofern ein Key im Image ist.

VictoriaMetrics nur lokal und mit 24 Monaten Aufbewahrung, in `/etc/default/victoria-metrics`
(root, 600):

```
ARGS="-storageDataPath=/var/lib/victoria-metrics -httpListenAddr=127.0.0.1:8428 -retentionPeriod=24 \
  -deleteAuthKey=<k> -snapshotAuthKey=<k> -forceMergeAuthKey=<k> -forceFlushAuthKey=<k> \
  -flagsAuthKey=<k> -metricsAuthKey=<k> -pprofAuthKey=<k> -search.resetCacheAuthKey=<k> -configAuthKey=<k>"
```

Die Schlüssel sind Pflicht: Grafana reicht als Datenquelle per Proxy auch GET-Anfragen an
beliebige VictoriaMetrics-Pfade durch, und ohne Schlüssel könnte jeder anonyme Besucher von
otm.ffnef.de per `/api/v1/admin/tsdb/delete_series` alle Zeitreihen löschen (so am 17.10.2026
vorgefunden). `<k>` ist ein zufälliger Schlüssel, nicht im Repo.

**MQTT im Tunnel:** Der Listener auf 10.66.0.1 hat eine ACL (`mosquitto-otm-tunnel.acl`):
Ein Client darf nur schreiben, und nur unter seiner Client-ID (`its/<id>/#`, `otm/<id>/#`),
lesen darf er nichts. Jeder kann einen Tunnel aufbauen, so liest niemand fremde Daten mit
und schreibt niemand unter fremdem Namen (die Client-ID selbst ist nicht geprüft).

Grafana ist ohne Anmeldung lesbar (Rolle Viewer). Bearbeiten geht nach Anmeldung über
Authentik (OAuth, Gruppe `Freifunk` wird Admin). Das Client-Secret liegt nicht im Repo,
sondern in `/etc/grafana/authentik-client-secret` (root:grafana, 640) und wird per
`$__file{…}` gelesen. TLS endet an einem vorgeschalteten Reverse-Proxy
(`https://otm.ffnef.de`).

## Betrieb

- **Station umbenennen** (`otm-bridge.main.node`): otm-stats kennt jeden Empfänger an der MAC
  seines ITS-Radios (`emac` aus `its/<node>/info`, ab 0.18.4 auch `mac` in
  `otm/<node>/build`; Zuordnung in `/var/lib/otm-stats/namen.json`). Meldet sich eine MAC
  unter neuem Namen, schreibt otm-stats nach 90 s alle Reihen `node=<alt>` in
  VictoriaMetrics auf den neuen Namen um (Export, Import, `delete_series`; Werte ab dem
  ersten des neuen Namens fallen weg) und ignoriert retained Reste des alten Namens.
  Grafana bleibt bei `by (node)`. Den `deleteAuthKey` bekommt der Dienst per
  `LoadCredential` aus `/etc/default/victoria-metrics`. Von Hand (Dienst vorher anhalten):
  `systemctl stop otm-stats; python3 /usr/local/lib/otm/otm-stats.py --umbenennen <alt> <neu>; systemctl start otm-stats`.
- **Station abbauen:** leere retained Nachricht auf `its/<node>/status` am Proxy; otm-stats
  nimmt sie dann aus Online-, Firmware- und Health-Tabellen. Ihre bisherigen Messwerte
  bleiben.
- **Station sperren** (z. B. flutet sie mit Unsinn): `otm-fastd sperren <knoten> <grund>`,
  `<knoten>` als Name (`WR4300-902f`), Tunnel-IP oder Schlüssel; `otm-fastd verbunden` zeigt
  Name, Tunnel-IP, Schlüssel und Absenderadresse aller Tunnel. Die Sperre wirkt beim nächsten
  Handshake (spätestens nach etwa einer Stunde, wenn fastd den Sitzungsschlüssel erneuert),
  mit `--sofort` sofort (fastd startet neu, alle anderen sind nach ~20 s wieder da).
  Aufheben: `otm-fastd entsperren <schlüssel>`. Die Liste steht in `/etc/fastd/otm/sperrliste`,
  Abweisungen im Journal (`journalctl -t fastd-otm-verify`, höchstens einmal je Stunde und
  Schlüssel). Am 17.10.2026 mit einem Test-Client am Testplatz geprüft: gesperrt abgewiesen,
  entsperrt sofort wieder verbunden.
- **Registrierung** (vorbereitet, aus): Sollen nur noch bekannte Empfänger herein, erst
  `otm-fastd freigabe-aus-log` (gibt alle verbundenen und je im Log gesehenen Schlüssel frei),
  dann `otm-fastd modus nur-freigegebene`. Neue Empfänger dann mit `otm-fastd freigeben
  <schlüssel> <notiz>`; den Schlüssel zeigt ein Empfänger mit
  `/etc/init.d/fastd show_key mgmt` (z. B. im Config-Mode).
  Zurück: `otm-fastd modus offen`. Die Sperrliste gilt in beiden Modi.
- **Neue Dashboards oder Änderungen:** JSON unter `grafana/` ändern und neu installieren;
  Grafana liest die Dateien nach wenigen Sekunden neu.
