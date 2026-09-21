#!/bin/sh
# Zeichnet die Stoerfestigkeits-Regelung (ANI) von ath9k auf, dazu die
# Fehlausloesungen. Hintergrund: Mit Muensters Bau faellt die Fehlausloesungsrate
# der 3390 tagsueber auf ein Sechstel, mit unserem bleibt sie rund um die Uhr am
# Anschlag - das sieht nach einer ANI aus, die in einem Fall nachregelt und im
# anderen nicht. Schreibt nur nach $D (tmpfs).
#
# Start: PHY=phy0 start-stop-daemon -S -b -x /tmp/otm-ani/ani-log.sh
# Ende:  Datei $D/FERTIG; Abbruch: kill $(cat $D/run.pid)

D=${D:-/tmp/otm-ani}
PHY=${PHY:-phy0}
IFACE=${IFACE:-mon0}
DAUER=${DAUER:-86400}
INTERVALL=${INTERVALL:-60}

ANI=/sys/kernel/debug/ieee80211/$PHY/ath9k/ani
RECV=/sys/kernel/debug/ieee80211/$PHY/ath9k/recv

mkdir -p "$D"
echo $$ > "$D/run.pid"
rm -f "$D/FERTIG"
# Spalten: utc uptime ani_reset ofdm_level cck_level ofdm_errors cck_errors pkts_all crc_err phy_err busy_ms active_ms
[ -s "$D/ani.log" ] || echo "# utc uptime ani_reset ofdm_level cck_level ofdm_errors cck_errors pkts_all crc_err phy_err busy_ms active_ms" > "$D/ani.log"

ende=$(( $(cut -d. -f1 /proc/uptime) + DAUER ))
while [ "$(cut -d. -f1 /proc/uptime)" -lt "$ende" ]; do
	a=$(awk -F: '
		/ANI RESET/{r=$2} /OFDM LEVEL/{o=$2} /CCK LEVEL/{c=$2}
		/OFDM ERRORS/{oe=$2} /CCK ERRORS/{ce=$2}
		END{print r+0, o+0, c+0, oe+0, ce+0}' "$ANI")
	b=$(awk -F: '/PKTS-ALL/{a=$2} /^ *CRC ERR/{c=$2} /^ *PHY ERR/{p=$2} END{print a+0, c+0, p+0}' "$RECV")
	s=$(iw dev "$IFACE" survey dump 2>/dev/null |
		awk '/in use/{f=1} f&&/busy time/{b=$4} f&&/active time/{a=$4} f&&/receive time/{print b+0, a+0; exit}')
	echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $(cut -d. -f1 /proc/uptime) $a $b $s" >> "$D/ani.log"
	sleep "$INTERVALL"
done
date -u +%Y-%m-%dT%H:%M:%SZ > "$D/FERTIG"
