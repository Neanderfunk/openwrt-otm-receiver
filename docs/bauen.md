# Eigene Images bauen

Für alle, die die Images selbst bauen wollen, etwa mit eigenen SSH-Keys, Zusatzpaketen oder
eigenem Update-Server. Wie die Geräte danach arbeiten: [README](../README.md).

## Bauen

```sh
./release.sh                                                  # alle Geräte, wie veröffentlicht
OWRT_VER=25.12.4 PROFILES="tplink_tl-wdr3600-v1" ./build.sh   # einzelnes Profil
OWRT_VER=25.12.4 TARGET=lantiq SUBTARGET=xrx200 PROFILES=avm_fritz3390 ./build.sh
```

`build.sh` baut ein Target und eine Liste von Profilen. Ohne Angaben nimmt es noch die alten
Vorgaben OpenWrt 21.02.7 und WDR4300 + WDR3600; für alles außer der NanoStation M XM
`OWRT_VER=25.12.4` setzen. `release.sh` ruft `build.sh` für alle Geräte auf, siehe
[So veröffentlichen wir](#so-veröffentlichen-wir).

Kein Komplettbau. Das SDK baut nur die gepatchten und eigenen Pakete (mac80211,
wireless-regdb mit Paketrevision `91`, otm-bridge, otm-mgmt-vpn, otm-autoupdater, für
Ubiquiti XW kmod-otm-spinor-unlock), der ImageBuilder baut daraus mit dem Release-Kernel das Image.
Ergebnis unter `build/out/<release>/<profil>/`. Dort liegen Image, Manifest, sha256sums und `build-info`;
dieselbe Datei steht im Gerät unter `/etc/otm-build-info`.

## Optionen

| Variable | Werte | Bedeutung |
|---|---|---|
| `OTM_MQTT` | `proxy` (Vorgabe), `direct`, `auto` | Weg zum Broker, siehe unten |
| `OTM_VPN` | `1` (Vorgabe), `0` | Management-VPN (fastd) ins Image; `proxy` und `auto` brauchen es |
| `OTM_SSH_KEYS` | Pfad, `none` | `authorized_keys` fürs Image; Vorgabe `files/local/etc/dropbear/authorized_keys`, `none` = ohne Fernzugang |
| `OTM_AUTOUPDATER` | `1` (Vorgabe), `0` | Autoupdater ins Image, siehe unten |
| `OTM_BRANCH` | `stable` (Vorgabe) | Branch für Manifest und Upload-Verzeichnis |
| `OTM_VERSION` | Ziffern | Versionsnummer in Image und Manifest; Vorgabe Bauzeit `JJJJMMTThhmm` (UTC) |
| `OTM_EXTRA_PACKAGES` (oder `EXTRA_PACKAGES`) | Paketnamen, Leerzeichen-getrennt | zusätzliche Pakete ins Image (im ROM statt später ins Overlay), `-paket` nimmt eines heraus; Achtung: der Autoupdater spielt das Standard-Image vom Server ein, die Extras sind danach weg (dann `OTM_AUTOUPDATER=0` oder eigenen Server) |
| `OTM_AUTOUPDATER_MIRROR` | URL(s) | eigener Update-Server statt `http://firmware.ffnef.de/otm/stable/sysupgrade` (Verzeichnis mit `<branch>.manifest`); bei `OTM_MQTT=proxy` nur `http://`, die Signaturen sichern das Manifest |
| `OTM_AUTOUPDATER_PUBKEYS` | Datei | eigene Signierschlüssel (ecdsautils, 64 Hex-Zeichen je Zeile) statt unserer |
| `OTM_AUTOUPDATER_SIGNATURES` | Zahl | Mindestzahl gültiger Signaturen; mit eigenen Schlüsseln Vorgabe 1, sonst 3 |
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

## SSH-Keys

Eigene Keys gehören nach `files/local/etc/dropbear/authorized_keys` (oder per
`OTM_SSH_KEYS=<datei>`). Der Ordner ist gitignored, `build.sh` legt ihn über `files/common`.
Ohne Key (`OTM_SSH_KEYS=none`) baut das Image trotzdem, SSH ist dann aber ganz aus:
dropbear startet nicht, lokal bleibt nur der Failsafe-Modus. Passwort-Logins sind immer
abgeschaltet, denn frisches OpenWrt lässt root ohne Passwort herein. Beim Update mit
erhaltener Konfiguration bleiben vorhandene Keys erhalten.

## Autoupdater und eigener Update-Server

Wie der Autoupdater arbeitet: [README, Abschnitt Autoupdater](../README.md#autoupdater). Eigener
Server: `OTM_AUTOUPDATER_MIRROR`, `OTM_AUTOUPDATER_PUBKEYS`, `OTM_AUTOUPDATER_SIGNATURES`
(siehe [Optionen](#optionen)); `build.sh` legt Manifest und Upload-Verzeichnis unter
`build/out/otm<variante>/<branch>/` an, signiert wird wie unten beschrieben.

## So veröffentlichen wir

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
