# Neuaufbau der Gegenstelle im Notfall

Was es braucht, um die Gegenstelle (bei uns `wgiot.ffdus.de`) auf einer frischen
Ubuntu-24.04-VM wieder aufzusetzen, etwa nach Verlust der Maschine. Grundlage für eine
Ansible-Rolle als Notfallweg: Sie ruft die Skripte dieses Verzeichnisses auf, statt sie
nachzubauen. Routinepflege bleibt bei den Skripten selbst ([README.md](README.md)).

Stand 24.10.2026. Wo Zugangsdaten liegen, steht hier nur als Pfad; die Werte liegen nicht in
diesem Repo, sondern in einer privaten Sicherung (Baum, der die Zielpfade spiegelt, dazu
`rechte.txt` mit Besitzer und Modus je Datei).

Die VM ist älter als OTM: Sie trägt außerdem das WireGuard-Netz `wg0` (ADS-B-Empfänger und
andere Clients), Konten weiterer Leute und den Checkmk-Agenten. Diese Teile richtet kein
Skript hier ein; sie stehen unten mit, damit ein Neuaufbau sie nicht vergisst.

## Reihenfolge

### 0. Maschine

- Ubuntu 24.04, 1 CPU, 1.3 GB RAM, Platte 21 GB (heute 6 GB belegt).
- Hostname `wgiot.ffdus.de`. Ändernde Befehle in der Pflege prüfen ihn vorab
  (`[ "$(hostname)" = wgiot.ffdus.de ]`).
- Netz per ifupdown (`/etc/network/interfaces`, IPv4 per DHCP, IPv6 statisch), nicht
  netplan. Die Datei ist Teil der Sicherung; auf einer frischen VM entweder ifupdown
  installieren und die Datei zurückspielen oder dieselben Werte in netplan eintragen.
- SSH auf Port 62954, nur Schlüssel, kein root-Login. Konten mit sudo: Verwalter und das
  Konto `otm-ad-cl` (Wartung), dazu weitere Konten. Die `authorized_keys` aller Konten sind
  in der Sicherung, die Passwörter nicht: Nach dem Neuaufbau setzt jedes Konto sein
  sudo-Passwort neu.

### 1. Pakete

```sh
apt-get install -y fastd dnsmasq-base nftables mosquitto python3-paho-mqtt victoria-metrics \
  wireguard-tools iptables socat nullmailer
```

- `dnsmasq-base`, nicht `dnsmasq`: Das volle Paket startet einen eigenen dnsmasq auf Port 53,
  der mit `systemd-resolved` und mit `dnsmasq-otm` kollidiert.
- Grafana aus apt.grafana.com (Schlüssel nach `/etc/apt/keyrings/grafana.gpg`, Quelle
  `deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main`).
  Vor dem `apt-get install grafana` erst `grafana/apt-pin` nach
  `/etc/apt/preferences.d/grafana` legen, sonst kommt die neueste Hauptversion.

### 2. Repo

```sh
git clone https://github.com/Neanderfunk/openwrt-otm-receiver
```

Zweig `main`, neuester Stand. Die Skripte installieren aus dem Verzeichnis, in dem sie liegen
(`mgmt-vpn/server/`).

### 3. Erhaltene Dateien zurückspielen, VOR den Skripten

`install.sh` erzeugt den fastd-Schlüssel, die fremden Empfänger und den VictoriaMetrics-
Schlüssel nur, wenn sie fehlen. Fehlt der fastd-Schlüssel beim Neuaufbau, entsteht ein neuer,
und **kein Empfänger im Feld verbindet sich mehr** (der öffentliche Schlüssel steht fest im
Image). Also erst die Sicherung zurückspielen, Besitzer und Modus nach `rechte.txt`, dann
die Skripte. Liste: Abschnitt "Zugangs- und Schlüsseldateien".

### 4. Skripte

Beide als root, unbeaufsichtigt (keine Rückfragen, `set -e`, Exit-Code ungleich 0 bei
Fehlern), beide wiederholbar:

| # | Aufruf | Voraussetzung | Ergebnis |
| --- | --- | --- | --- |
| 1 | `sudo ./install.sh` | Pakete aus Schritt 1, erhaltene Dateien liegen | `br-otm` mit Firewall, `dnsmasq-otm`, `fastd@otm`, mosquitto mit Bridge, VictoriaMetrics nur lokal, `otm-stats`, Journal-Grenze |
| 2 | `sudo ./grafana/install-grafana.sh` | Grafana-Paket installiert (das Skript ändert `/etc/default/grafana-server`), `/etc/grafana/authentik-client-secret` liegt | apt-Pin, Einstellungen, Datenquelle, Dashboards, Grafana läuft |

Danach, ohne Skript:

- **wg0:** `/etc/wireguard/` und `/etc/sysctl.d/90-ip-fwd.conf` sind zurückgespielt;
  `sysctl --system`, `systemctl enable --now wg-quick@wg0`. Die Namen der Clients stehen in
  `/etc/hosts` (Sicherung). `PostUp` erlaubt nur die Weiterleitung aus `wg0`; NAT gibt es
  keins (die frühere MASQUERADE-Regel auf `eth0` griff nie, weil die Netzkarte `ens18`
  heißt, und ist seit 24.10.2026 entfernt).
- **Checkmk:** Agent installieren (Paket vom Checkmk-Server), Drop-in für
  `cmk-agent-ctl-daemon` setzt die Ansible-Rolle in neanderfunk/ansible. `/etc/rc.local`
  (Sicherung) reicht IPv6-Port 6559 per `socat` an den Agenten auf 6556 weiter.
- **nullmailer:** `/etc/nullmailer/remotes` aus der Sicherung.

### 5. Daten zurückspielen

Bei gestoppten Diensten (`otm-stats`, `victoria-metrics`, `grafana-server`, `mosquitto`),
Besitzer wie unten, danach starten. Liste: Abschnitt "Daten".

## Zugangs- und Schlüsseldateien

| Pfad auf der VM | Besitzer, Rechte | Zweck | Neu erzeugen? |
| --- | --- | --- | --- |
| `/etc/fastd/otm/secret.conf` | root, 600 (Verzeichnis 700) | geheimer fastd-Schlüssel der Gegenstelle | **erhalten**: der öffentliche Teil steht in jedem Image (`98-otm-mgmt-vpn`, Peer `mgmt_wgiot`); ein neuer hieße neue Firmware für alle Empfänger |
| `/etc/fastd/otm/sperrliste`, `freigabeliste` | root, 644 (im Verzeichnis 700) | gesperrte und freigegebene Empfänger (heute leer) | erhalten, sonst sind Sperren weg |
| `/etc/otm/fremde-empfaenger` | root, 600 (Verzeichnis 700) | Lesezugänge zu fremden Empfängern bei OpenTrafficMap (otm-stats, `LoadCredential`) | erhalten; neu nur mit neuen Zugängen von OpenTrafficMap |
| `/etc/default/victoria-metrics` | root, 600 | Startargumente mit dem Schlüssel für die Verwaltungsfunktionen | darf neu entstehen (`install.sh`); außerhalb kennt ihn nur die Wartung |
| `/etc/grafana/authentik-client-secret` | root:grafana, 640 | OAuth-Client-Secret für die Anmeldung über Authentik | erhalten; neu nur mit neuem Secret in Authentik |
| `/etc/default/grafana-server` | root, 644 | Umgebung für Grafana, hinten der Teil aus `grafana/grafana-server.env` | entsteht aus Paket und Skript neu; Sicherung nur zum Vergleich |
| `/etc/wireguard/wg0.conf` | root, 600 (Verzeichnis 700) | WireGuard `wg0`: eigener privater Schlüssel, alle Peers | **erhalten**: jeder Client kennt unseren öffentlichen Schlüssel |
| `/etc/wireguard/<nr><name>.prv`, `.pub` | root, 600 | für Clients erzeugte Schlüsselpaare | erhalten; nur so lässt sich ein Client neu einrichten, ohne die Konfiguration hier zu ändern |
| `/etc/sysctl.d/90-ip-fwd.conf`, `/etc/hosts` | root, 644 | Weiterleitung für wg0, Namen der wg0-Clients | erhalten |
| `/etc/ssh/ssh_host_*_key` | root, 600 | Hostschlüssel | besser erhalten, sonst warnt jeder SSH-Client |
| `/home/<konto>/.ssh/authorized_keys` | Konto, 600 | Zugänge aller Konten | erhalten |
| `/etc/network/interfaces` | root, 644 | Netz (siehe Schritt 0) | erhalten oder neu eintragen |
| `/etc/rc.local` | root, 755 | `socat` für Checkmk (siehe oben) | erhalten |
| `/etc/nullmailer/remotes` | mail:mail, 600 | Mail-Relay mit Zugang | erhalten |
| Grafana-Admin | in `/var/lib/grafana/grafana.db` | Anmeldung als Admin | kommt mit der Datenbank; ohne sie `grafana cli admin reset-admin-password` |

Abgeleitet und nicht zu sichern: alles, was `install.sh` und `install-grafana.sh` aus dem
Repo installieren (fastd-, mosquitto-, dnsmasq-, nft- und systemd-Dateien, Dashboards).

## Daten

| Pfad | Größe (24.10.2026) | Inhalt | Bei Verlust |
| --- | --- | --- | --- |
| `/var/lib/victoria-metrics` | 18 MB | alle Zeitreihen seit 10.10.2026, Aufbewahrung 24 Monate | Grafana beginnt leer; die Frames liegen bei OpenTrafficMap, aber nicht unsere Statistik |
| `/var/lib/grafana/grafana.db` | 3 MB | Benutzer, Admin-Passwort, Einstellungen; die Dashboards kommen aus Dateien | Benutzer und Admin-Passwort neu |
| `/var/lib/private/otm-stats/namen.json` | 1 KB | Zuordnung MAC zu Name (Umbenennen) | lernt otm-stats neu; nur eine Umbenennung, die genau in die Lücke fällt, wird nicht zusammengeführt |
| `/var/lib/mosquitto/mosquitto.db` | 7 KB | retained Nachrichten (`its/<node>/status`, `otm/<node>/…`) | füllen die Empfänger beim nächsten Verbinden neu; abgebaute Stationen tauchen nicht wieder auf |
| `/var/lib/misc/dnsmasq-otm.leases` | 1 KB | Tunnel-Adressen und Namen `<knoten>.otm` | vergibt dnsmasq neu, Namen sind nach der nächsten Lease-Erneuerung zurück |

Der Rest von `/var/lib/grafana` (rund 930 MB) sind Plugins aus dem Paket. Eine eigene
Sicherung dieser Pfade gibt es nicht; ob der Hypervisor die VM sichert, steht hier nicht.
Für VictoriaMetrics ginge ein Snapshot über die Verwaltungsfunktion (Schlüssel in `/etc/default/victoria-metrics`).

## Abhängigkeiten außerhalb der VM

| Was | Wo | Bei neuer IP oder neuer Maschine |
| --- | --- | --- |
| DNS `wgiot.ffdus.de` (A und AAAA), `wgiot6.ffdus.de` (nur AAAA) | Zone `ffdus.de` | AAAA anpassen; die Namen stehen fest in jedem Image, also **nicht umbenennen** |
| fastd über IPv4 | Portweiterleitung UDP 10001 am Proxy davor (A von `wgiot.ffdus.de` zeigt auf ihn) | Ziel der Weiterleitung anpassen |
| WireGuard `wg0` | Clients verbinden sich auf UDP 51820 (IPv6 direkt; IPv4 abgeleitet über eine Weiterleitung am Proxy, weil das A von `wgiot.ffdus.de` auf ihn zeigt) | Ziel der Weiterleitung anpassen; Endpoint in den Clients nur, wenn sich der Name ändert |
| Grafana öffentlich | `https://otm.ffnef.de`, TLS am Reverse-Proxy, der an Port 3000 der VM weiterreicht | Ziel im Proxy anpassen; die Firewall (`nft.conf`) lässt 3000 nur von localhost und dem Proxy-Netz zu |
| Anmeldung an Grafana | Authentik (OAuth-Client für Grafana, Rückruf auf `https://otm.ffnef.de`) | nichts, solange `root_url` bleibt |
| Broker OpenTrafficMap | `cits1.opentrafficmap.org:8883`, Bridge nur ausgehend, anonym | nichts |
| Checkmk | Server holt per Pull (6556, IPv6 über 6559) | Host-Adresse im Checkmk anpassen; Freigaben im Drop-in setzt Ansible |

## Prüfungen am Ende

```sh
systemctl --failed
systemctl is-active fastd@otm otm-mgmt-net dnsmasq-otm mosquitto victoria-metrics otm-stats grafana-server wg-quick@wg0
otm-fastd verbunden
journalctl -u mosquitto --since -10min | grep -i bridge
curl -sf http://127.0.0.1:8428/health
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/api/health
nft list table inet otm_mgmt >/dev/null && echo nft ok
wg show wg0 latest-handshakes
```

- Keine fehlgeschlagenen Units, alle Dienste aktiv.
- `otm-fastd verbunden` listet die Empfänger mit Namen (nach wenigen Minuten; sie versuchen
  es laufend neu).
- Die Bridge zu cits1 ist verbunden, `otm-stats` schreibt (Journal ohne Fehler).
- Von außen: `https://otm.ffnef.de` zeigt Empfänger online, die alten Zeitreihen sind da
  (sonst fehlt die Rücksicherung).
- `wg0`: die Clients haben einen Handshake jünger als drei Minuten.
- Checkmk sieht den Host.
