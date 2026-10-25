# Statistik unter otm.ffnef.de: Seiten und Panels

Was die Seiten unter <https://otm.ffnef.de> zeigen. Ohne Anmeldung lesbar. Zum Projekt:
[README](../README.md).

Allgemein:

- **Frame:** eine ITS-G5-Nachricht (GeoNetworking), die ein Empfänger gehört und weitergegeben hat.
- **Doppelte:** Hören mehrere Empfänger denselben Frame, zählt er in „alle zusammen“ nur
  einmal (gleiche Absender-MAC, Sequenznummer und Inhaltsanfang innerhalb von 5 Sekunden).
- **Positionen und Geschwindigkeiten** kommen aus dem GeoNetworking-Header der Absender, im
  Raster von etwa 50 m.
- **Fahrzeug:** Stationstyp 1-11. Straßenseitige Sender (RSU) zählen nicht mit.
- **Zeitraum:** oben rechts wählbar, Vorgabe 7 Tage. Die Verkehrsmuster nutzen immer die letzten 28 Tage.
- **Wochentage:** 1-Mo bis 7-So, damit die Tabelle in der richtigen Reihenfolge sortiert.
- **Mehr Text:** Jedes Panel hat oben links ein „i“ mit der vollständigen Beschreibung.

## OTM Empfang (Startseite)

| Panel | Was es zeigt |
|---|---|
| ITS-Frames je Empfaenger pro Stunde | Frames je Empfänger und alle zusammen; nachts wenig Verkehr |
| Nur von diesem Empfaenger gesehen, pro Stunde | Frames, die kein anderer Empfänger hatte: der eigene Beitrag eines Standorts |
| Frames nach Zahl der Empfaenger, pro Stunde | wie viele Empfänger denselben Frame hatten (n=1, n=2, ...); viel Überlappung = gleiche Sender |
| Anteil an allen Frames (24 h gleitend) | Anteil je Empfänger an allen verschiedenen Frames (1 = alle) |
| Verschiedene Absender je Minute | verschiedene Absender-MACs; Obergrenze für Fahrzeuge, weil Stationen ihre MAC wechseln |
| Online | grün online, rot offline; nach 24 h offline fällt ein Empfänger aus den Tabellen |
| Uptime | Zeit seit dem letzten Start; Sprung auf 0 = Neustart, z. B. Update |
| MQTT-Nachrichten je Empfaenger pro Stunde (auch Nicht-ITS) | alles, was der Empfänger gemeldet hat, auch andere WLAN-Frames auf dem Kanal |
| Firmware je Empfaenger | Build, Commit, otm-bridge-Version, Modell; Klick auf den Namen öffnet OTM Knoten |
| Empfangs-Health (6 h) | Bewertung über 6 Stunden, siehe unten; Klick auf den Namen öffnet OTM Knoten |
| Geraete ohne Empfang | Geräte mit Tunnel, aber ohne passendes Funkteil (`no_its_radio`, dahinter die gefundenen Funkteile) |

Bewertungen in „Empfangs-Health“:

| Wert | Bedeutung |
|---|---|
| empfaengt ITS | mindestens ein ITS-Frame in 6 Stunden |
| nur Rauschen | Funkteil sieht Frames oder Fehler, aber kein ITS; Standort ohne Verkehr? |
| taub? | kein Zähler bewegt sich |
| kein 5-GHz-Radio (nur 2.4 GHz) | nur ein 2.4-GHz-Funkteil, z. B. NanoStation M2 |
| kein Funkteil erkannt | gar kein WLAN-Funkteil, defekt oder nicht erkannt |

## OTM Heatmap

| Panel | Was es zeigt |
|---|---|
| Alle Empfaenger (verschiedene Frames) | Karte: wo die Absender standen, jeder Frame einmal; Empfänger mit geteilter Position als Funkmast |
| Durchschnittsgeschwindigkeit | Karte: mittlere Geschwindigkeit je Rasterzelle; ohne stehende Fahrzeuge (unter 1 km/h), Zellen mit weniger als 5 Meldungen fehlen |
| Hoechstgeschwindigkeit | Karte: höchster Einzelwert je Rasterzelle; ein Einsatzfahrzeug reicht für Rot |
| Verkehrsmuster: Fahrzeuge pro Stunde | Tabelle Wochentag × Stunde (Ortszeit): verschiedene Fahrzeuge, gemittelt über die Stunden mit mindestens einem Empfänger online |
| Verkehrsmuster: Geschwindigkeit im Mittel in km/h | dasselbe Raster, mittlere Geschwindigkeit; blau = langsam |
| Verkehrsmuster: Hoechstgeschwindigkeit in km/h | dasselbe Raster, höchster Einzelwert; über 250 km/h gilt als unplausibel und fehlt |

Farben der Geschwindigkeit: blau unter 10, hellblau ab 10, grün ab 30, gelb ab 50, orange ab
70, rot ab 100, magenta ab 130, dunkelviolett ab 160 km/h.

## OTM Heatmap je Empfaenger

| Panel | Was es zeigt |
|---|---|
| (Name des Empfängers) | Karte der Absenderpositionen nur dieses Empfängers; Auswahl oben. Eigene Seite, weil viele Karten langsam laden |

## OTM Knoten

Alles zu einem Empfänger. Auswahl oben, per Klick auf den Namen in OTM Empfang oder direkt
`https://otm.ffnef.de/d/otm-knoten?var-node=<name>`.

| Panel | Was es zeigt |
|---|---|
| Firmware | alle gemeldeten Stände im Zeitraum, der höchste oben |
| Status | zuletzt gemeldeter Zustand (online/offline) |
| Uptime | Zeit seit dem letzten Start |
| ITS-Frames im Zeitraum | Zahl der Frames im gewählten Zeitraum |
| Nur hier gesehen | Frames, die kein anderer Empfänger hatte |
| Anteil an allen Frames | Anteil an allen verschiedenen Frames aller Empfänger |
| Empfangs-Health (6 h) | Bewertung wie in OTM Empfang |
| ITS-Frames pro Stunde | eigene Frames, davon exklusive, zum Vergleich alle Empfänger zusammen |
| Funk-Zaehler pro Stunde | Zähler des Funkteils: alle Frames, CRC-Fehler (Inhalt kaputt), PHY-Fehler (Energie, nichts Lesbares) |
| Rauschen | Grundrauschen des Kanals |
| Kanal belegt | Anteil der Zeit, in der der Kanal belegt war |
| Online | Verlauf grün/rot |
| Uptime | Verlauf; Sprung nach unten = Neustart |
| Heatmap: Absenderpositionen | Karte seiner Absender; blauer Funkmast = der Empfänger selbst, wenn er seine Position teilt |
| Durchschnittsgeschwindigkeit, Hoechstgeschwindigkeit | Karten wie in OTM Heatmap, nur aus seinen Frames |
| Verkehrsmuster (drei Tabellen) | wie in OTM Heatmap, nur aus seinen Frames, gemittelt über seine Online-Stunden |
| MQTT-Nachrichten pro Stunde (auch Nicht-ITS) | alles, was er gemeldet hat, auch Frames ohne GeoNetworking |

## Seit wann es Daten gibt

- Zeitreihen insgesamt: ab 10.10.2026.
- Geschwindigkeiten auf den Karten: ab 17.10.2026.
- Verkehrsmuster: ab 20.10.2026, die frühere Zählung war fehlerhaft.
- Health ab otm-bridge 0.16.0, Geräte ohne Empfang ab 0.18.3. Ältere Images liefern diese Werte nicht.
