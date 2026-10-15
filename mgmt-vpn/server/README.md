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
| `fastd.conf`, `peer-up.sh`, `peer-log.sh` | fastd-Instanz `otm` (Multi-TAP), jeder Schlüssel darf sich verbinden; die TAPs hängen an `br-otm` |
| `otm-mgmt-net.service`, `nft.conf` | Bridge `br-otm`, Firewall (`table inet otm_mgmt`): aus dem Tunnel nur DHCP, DNS, MQTT und Ping zur Gegenstelle, keine Weiterleitung; Grafana-Port 3000 nur von localhost und dem Reverse-Proxy-Netz. `peer-up.sh` hängt jedes TAP als isolierten Bridge-Port an, die Empfänger sehen sich gegenseitig nicht |
| `dnsmasq.conf`, `dnsmasq-otm.service` | DHCP im Tunnelnetz 10.66.0.0/22, Namen `<knoten>.otm`; verteilt weder Router noch DNS, die Standardroute der Empfänger bleibt lokal |
| `mosquitto-otm.conf`, `mosquitto-otm.override` | Listener auf 10.66.0.1 und 127.0.0.1, Bridge `its/#` **nur ausgehend** an `cits1.opentrafficmap.org:8883` |
| `otm-stats.py`, `otm-stats.service` | liest `its/#` und `otm/+/{build,location,health}` mit, entdoppelt Frames über alle Empfänger, schreibt jede Minute ins Influx-Line-Protokoll von VictoriaMetrics; Metriken im Kopf der Datei |
| `grafana/` | Umgebungsvariablen, Datenquelle, Dashboards `OTM Empfang` und `OTM Heatmap` (Provisioning aus Dateien) |

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

VictoriaMetrics nur lokal und mit 24 Monaten Aufbewahrung, in `/etc/default/victoria-metrics`:

```
ARGS="-storageDataPath=/var/lib/victoria-metrics -httpListenAddr=127.0.0.1:8428 -retentionPeriod=24"
```

Grafana ist ohne Anmeldung lesbar (Rolle Viewer). Bearbeiten geht nach Anmeldung über
Authentik (OAuth, Gruppe `Freifunk` wird Admin). Das Client-Secret liegt nicht im Repo,
sondern in `/etc/grafana/authentik-client-secret` (root:grafana, 640) und wird per
`$__file{…}` gelesen. TLS endet an einem vorgeschalteten Reverse-Proxy
(`https://otm.ffnef.de`).

## Betrieb

- **Station abbauen:** leere retained Nachricht auf `its/<node>/status` am Proxy; otm-stats
  nimmt sie dann aus Online-, Firmware- und Health-Tabellen. Ihre bisherigen Messwerte
  bleiben.
- **Neue Dashboards oder Änderungen:** JSON unter `grafana/` ändern und neu installieren;
  Grafana liest die Dateien nach wenigen Sekunden neu.
