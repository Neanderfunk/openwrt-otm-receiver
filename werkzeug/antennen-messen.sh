#!/usr/bin/env bash
# Antennenvergleich ohne Messsender: zwei Empfaenger hoeren gleichzeitig dieselben
# fremden 5-GHz-Access-Points (Beacons, ~10/s). Je Access Point ergibt sich eine
# RSSI-Differenz - unabhaengig davon, wie viel Verkehr gerade ist.
#
#   antennen-messen.sh <host-a> <host-b> [freq] [sekunden] [name]
#     z. B. antennen-messen.sh 192.168.97.183 192.168.97.156 5540 120 vorher
#
# Waehrend der Messung stehen die Geraete auf <freq> und empfangen KEINE
# ITS-Frames. Danach stellt das Skript 5900 MHz / 10 MHz wieder her.
# Ergebnis: geraete/antennen/<name>/ plus Auswertung auf der Konsole.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
A=${1:?host-a}; B=${2:?host-b}; F=${3:-5540}; SEK=${4:-120}; NAME=${5:-$(date +%H%M)}
KEY="${OTM_KEY:-$HOME/.ssh/id_ed25519_otm}"
K=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR)
OUT="$HERE/../geraete/antennen/$NAME"; mkdir -p "$OUT"

td() { ssh "${K[@]}" root@"$1" 'command -v tcpdump || echo /tmp/otm-baseline/x/usr/bin/tcpdump'; }

for h in "$A" "$B"; do
	ssh "${K[@]}" root@"$h" "iw dev mon0 set freq $F 2>&1; iw dev mon0 info | grep channel"
done
echo "--- $SEK s Beacons mitschneiden"
for h in "$A" "$B"; do
	T=$(td "$h")
	ssh "${K[@]}" root@"$h" "LD_LIBRARY_PATH=/tmp/otm-baseline/x/usr/lib $T -i mon0 -s 256 -w /tmp/beacons.pcap 'type mgt subtype beacon' >/dev/null 2>&1 & echo \$! > /tmp/beacon.pid" &
done
wait
sleep "$SEK"
for h in "$A" "$B"; do
	ssh "${K[@]}" root@"$h" 'kill $(cat /tmp/beacon.pid) 2>/dev/null; sleep 1; iw dev mon0 set freq 5900 10MHz; iw dev mon0 info | grep channel'
done
scp -O -q "${K[@]}" root@"$A":/tmp/beacons.pcap "$OUT/a.pcap"
scp -O -q "${K[@]}" root@"$B":/tmp/beacons.pcap "$OUT/b.pcap"
ssh "${K[@]}" root@"$A" 'rm -f /tmp/beacons.pcap /tmp/beacon.pid'
ssh "${K[@]}" root@"$B" 'rm -f /tmp/beacons.pcap /tmp/beacon.pid'
python3 "$HERE/antennen-auswertung.py" "$A=$OUT/a.pcap" "$B=$OUT/b.pcap" | tee "$OUT/ergebnis.txt"
