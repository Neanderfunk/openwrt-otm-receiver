#!/bin/sh
# 24-h-Baseline am OTM-Empfaenger: Mitschnitt von mon0 plus Zaehler alle 5 min.
# Schreibt ausschliesslich nach $D (tmpfs), fasst Konfiguration und Flash nicht an.
# Erwartet tcpdump + passende libpcap unter $D/x (aus dem Paketfeed entpackt).
#
# Start:  setsid /tmp/otm-baseline/baseline-24h.sh </dev/null >/dev/null 2>&1 &
# Ende:   Datei $D/FERTIG; Abbruch: kill $(cat $D/run.pid)

D=${D:-/tmp/otm-baseline}
IFACE=${IFACE:-mon0}
PHY=${PHY:-phy1}
DAUER=${DAUER:-86400}
INTERVALL=${INTERVALL:-300}
MAX_PCAP=${MAX_PCAP:-20000000}	# Bytes; Schutz fuer tmpfs

export LD_LIBRARY_PATH=$D/x/usr/lib
RECV=/sys/kernel/debug/ieee80211/$PHY/ath9k/recv
STAT=/sys/class/net/$IFACE/statistics

up() { cut -d. -f1 /proc/uptime; }

# Spalten: utc uptime rx_packets rx_bytes pkts_all crc_err phy_err active_ms busy_ms rx_ms noise pcap_bytes
snap() {
	set -- $(awk -F: '/PKTS-ALL/{a=$2} /^ *CRC ERR/{c=$2} /^ *PHY ERR/{p=$2} END{print a+0, c+0, p+0}' $RECV)
	s=$(iw dev $IFACE survey dump 2>/dev/null | awk '/in use/{f=1} f&&/noise/{n=$2} f&&/active time/{a=$4} f&&/busy time/{b=$4} f&&/receive time/{r=$4; exit} END{print a+0, b+0, r+0, n+0}')
	echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $(up) $(cat $STAT/rx_packets) $(cat $STAT/rx_bytes) $1 $2 $3 $s $(wc -c < $D/its-24h.pcap 2>/dev/null || echo 0)"
}

echo $$ > $D/run.pid
rm -f $D/FERTIG
echo "# utc uptime rx_packets rx_bytes pkts_all crc_err phy_err active_ms busy_ms rx_ms noise pcap_bytes" > $D/counters.log

$D/x/usr/bin/tcpdump -i $IFACE -n -s 0 -U -w $D/its-24h.pcap 2>$D/tcpdump.err &
TP=$!
echo $TP > $D/tcpdump.pid
sleep 2
snap >> $D/counters.log

ende=$(( $(up) + DAUER ))
grund=Zeit
while :; do
	rest=$(( ende - $(up) ))
	[ $rest -le 0 ] && break
	[ $rest -lt $INTERVALL ] && sleep $rest || sleep $INTERVALL
	snap >> $D/counters.log
	kill -0 $TP 2>/dev/null || { grund="tcpdump weg"; break; }
	[ $(wc -c < $D/its-24h.pcap) -gt $MAX_PCAP ] && { grund="pcap > $MAX_PCAP"; break; }
done

kill $TP 2>/dev/null
sleep 1
snap >> $D/counters.log
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $grund" > $D/FERTIG
