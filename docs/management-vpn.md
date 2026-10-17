# Management-VPN (fastd): Protokoll und Dual-Stack

Jeder Empfänger baut einen fastd-Tunnel zur Gegenstelle wgiot auf. Darüber laufen MQTT (ohne
TLS, der Tunnel verschlüsselt schon) und SSH unter `<knoten>.otm`. Einrichtung im Image:
`feed/net/otm-mgmt-vpn/files/98-otm-mgmt-vpn`, Gegenstelle: `mgmt-vpn/server/fastd.conf`.

## Versionen

| Seite | fastd |
|---|---|
| Images OpenWrt 25.12.4 (ath79, lantiq, mediatek) | v23 |
| Image OpenWrt 21.02.7 (NanoStation XM) | v21 |
| Gegenstelle (Ubuntu 24.04, Paket `fastd 22-4build2`) | v22 |

Handshake und Methode sind in allen drei Versionen gleich, sie verstehen sich untereinander.

## Protokoll

| | |
|---|---|
| Transport | UDP, Port 10001 auf der Gegenstelle (`bind any:10001`, IPv4 und IPv6); Empfänger mit zufälligem Quellport |
| Handshake | `ec25519-fhmqvc` (Curve25519-Schlüssel, Schlüsseltausch nach FHMQV-C); jedes Gerät hat einen eigenen Schlüssel, die Gegenstelle nimmt jeden an (`on verify "/bin/true"`), freigeschaltet wird niemand einzeln |
| Methode | `salsa2012+umac`: Salsa20/12 zum Verschlüsseln, UMAC zur Authentisierung jedes Pakets. Kommt ohne AES-Hardware aus und ist auf den alten MIPS-SoCs schnell genug |
| Sitzungsschlüssel | neu nach 55 min (plus bis zu 5 min Zufall), gültig 60 min |
| Keepalive | alle 20 s; ohne Antwort gilt die Gegenstelle nach 90 s als weg |
| Schicht | Layer 2: Empfänger `mode tap`, Gegenstelle `mode multitap` (ein TAP je Empfänger, alle an `br-otm`, isolierte Ports) |
| MTU | 1312 |

## Dual-Stack

Im Image stehen zwei Gegenstellen, je mit fester Adressfamilie:

```
remote 'ipv6 "wgiot6.ffdus.de" port 10001'
remote 'ipv4 "wgiot.ffdus.de" port 10001'
```

Das Schlüsselwort `ipv4`/`ipv6` vor dem Namen beschränkt die DNS-Abfrage auf A bzw. AAAA. Dass
`wgiot.ffdus.de` auch einen AAAA-Eintrag hat, spielt deshalb keine Rolle; eigene Namen nur mit
A oder nur mit AAAA sind nicht nötig.

fastd kennt kein Happy Eyeballs, verlässt sich aber auch nicht auf die Reihenfolge des
Betriebssystems: Es schickt einen Handshake an die erste Gegenstelle (IPv6); kommt keine
Antwort, geht der nächste Handshake 20 s (±2.5 s) später an die zweite (IPv4), danach wieder
an die erste und so fort. Vor jedem Wechsel löst fastd den Namen neu auf. Steht der Tunnel,
bleibt fastd bei dieser Adresse; nach einem Uplink-Wechsel startet `otm-uplink` fastd neu
(siehe [wlan-rueckfall.md](wlan-rueckfall.md)).

### Test am WDR3600 (17.10.2026)

LAN mit IPv4 und IPv6 (Telekom, 2003:…/64). fastd jeweils neu gestartet, Zeit vom Neustart
bis `connection with <mgmt_wgiot> established`:

| Lauf | IPv6 zur Gegenstelle | Tunnel nach | über |
|---|---|---|---|
| A | Blackhole-Route `ip -6 route add blackhole 2001:41d0:303:d3f:8000::aaaa/128`: Senden scheitert sofort (`sendmsg: Invalid argument`) | 19 s | IPv4 |
| B | Antworten still verworfen (nft, Eingang, `ip6 saddr … udp sport 10001 drop`): Handshakes gehen hinaus, nichts kommt zurück | 20 s | IPv4 |
| C | ungestört, zweimal, je 40 s Abstand | 6 s | IPv6 |

In A und B ging IPv6 nicht, der Tunnel kann also nur über IPv4 gestanden haben; in C zeigten
nft-Zähler auf dem Gerät Verkehr nur über IPv6.

Offen: Ein ungestörter Neustart wenige Sekunden nach A bzw. B brauchte ebenfalls 22-27 s, und
nach B stand der Tunnel danach über IPv4. Der erste IPv6-Handshake blieb dort also
unbeantwortet. Mit 40 s Abstand (C) trat das nicht auf. Vermutlich Zustand aus den
unmittelbar vorangegangenen Versuchen; nicht weiter untersucht. Im Betrieb heißt das
schlimmstenfalls: Der Tunnel steht über IPv4 statt IPv6.

Das Verbindungsprotokoll der Gegenstelle (`/var/log/otm-mgmt-peers.log`, `on establish`)
verzeichnete keinen dieser Neuaufbauten; daran lässt sich die Adressfamilie nicht ablesen.
