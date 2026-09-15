#!/usr/bin/env bash
# Startet eine Messrunde auf einem Empfaenger: holt tcpdump (+ libpcap) und fuer
# den Referenzmitschnitt mosquitto_sub (+ cJSON) passend zur OpenWrt-Version des
# Geraets aus dem Paketfeed, kopiert alles nach /tmp und startet
# baseline-24h.sh per start-stop-daemon. Nichts landet im Flash.
#
#   runde-starten.sh messung <host> <phy>
#   runde-starten.sh referenz <host> <topic-praefix> <credfile> <ende-UTC>
#       z. B. referenz 192.168.97.183 its/node749 ~/.config/otm/node749-mqtt "2026-09-16 21:05"
#       schneidet <praefix>/packet und <praefix>/stats in getrennten Prozessen mit.
#
# SSH-Key: $OTM_KEY (Standard ~/.ssh/id_ed25519_otm).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="${OTM_KEY:-$HOME/.ssh/id_ed25519_otm}"
K=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR)
CACHE="$HERE/../build/messwerkzeug"

# Paket aus dem Feed der Geraeteversion holen und entpacken (ipk: tar.gz, apk: via tar)
hole() { # version arch feed paketpraefix
	local d="$CACHE/$1" url f
	mkdir -p "$d/x"
	url="https://downloads.openwrt.org/releases/$1/packages/$2/$3"
	f=$(curl -fsS "$url/" | grep -oE "\"$4_[^\"]*\.ipk\"" | tr -d '"' | head -n 1) ||
		{ echo "kein $4 fuer $1/$2/$3" >&2; return 1; }
	[ -f "$d/$f" ] || curl -fsS -o "$d/$f" "$url/$f"
	(cd "$d" && tar xzf "$f" ./data.tar.gz && tar xzf data.tar.gz -C x && rm -f data.tar.gz)
}

geraeteversion() { # host -> "version arch"
	ssh "${K[@]}" root@"$1" '. /etc/openwrt_release; echo "$DISTRIB_RELEASE $DISTRIB_ARCH"'
}

case "${1:-}" in
messung)
	host=$2 phy=$3
	read -r ver arch < <(geraeteversion "$host")
	case "$ver" in 2[5-9].*) echo "OpenWrt $ver (apk) noch nicht unterstuetzt" >&2; exit 1 ;; esac
	hole "$ver" "$arch" base tcpdump-mini
	hole "$ver" "$arch" base libpcap1
	ssh "${K[@]}" root@"$host" 'mkdir -p /tmp/otm-baseline/x/usr/bin /tmp/otm-baseline/x/usr/lib'
	scp -O -q "${K[@]}" "$CACHE/$ver/x/usr/sbin/tcpdump" root@"$host":/tmp/otm-baseline/x/usr/bin/tcpdump 2>/dev/null ||
		scp -O -q "${K[@]}" "$CACHE/$ver/x/usr/bin/tcpdump" root@"$host":/tmp/otm-baseline/x/usr/bin/tcpdump
	scp -O -q "${K[@]}" "$CACHE/$ver"/x/usr/lib/libpcap* root@"$host":/tmp/otm-baseline/x/usr/lib/
	scp -O -q "${K[@]}" "$HERE/baseline-24h.sh" root@"$host":/tmp/otm-baseline/
	ssh "${K[@]}" root@"$host" "chmod +x /tmp/otm-baseline/baseline-24h.sh /tmp/otm-baseline/x/usr/bin/tcpdump &&
		PHY=$phy start-stop-daemon -S -b -x /tmp/otm-baseline/baseline-24h.sh; sleep 4;
		echo \"\$(cat /proc/sys/kernel/hostname): \$(tail -1 /tmp/otm-baseline/counters.log)\""
	;;
referenz)
	host=$2 praefix=$3 cred=$4 ende=$5
	read -r ver arch < <(geraeteversion "$host")
	hole "$ver" "$arch" packages mosquitto-client-ssl
	hole "$ver" "$arch" packages cJSON
	# shellcheck disable=SC1090
	. <(sed 's/^/local_/' "$cred")
	W=$(( $(date -u -d "$ende" +%s) - $(date -u +%s) ))
	ssh "${K[@]}" root@"$host" 'mkdir -p /tmp/otm-ref/bin /tmp/otm-ref/lib'
	scp -O -q "${K[@]}" "$CACHE/$ver/x/usr/bin/mosquitto_sub" root@"$host":/tmp/otm-ref/bin/
	scp -O -q "${K[@]}" "$CACHE/$ver"/x/usr/lib/libcjson* root@"$host":/tmp/otm-ref/lib/
	# Optionsdatei unter $XDG_CONFIG_HOME/mosquitto_sub (600): Passwort nicht in ps
	printf -- '-h cits1.opentrafficmap.org\n-p 8883\n--cafile /etc/ssl/certs/ca-certificates.crt\n-u %s\n-P %s\n' \
		"$local_user" "$local_pass" | ssh "${K[@]}" root@"$host" 'umask 077; cat > /tmp/otm-ref/mosquitto_sub'
	for t in packet stats; do
		printf '#!/bin/sh\nexport XDG_CONFIG_HOME=/tmp/otm-ref LD_LIBRARY_PATH=/tmp/otm-ref/lib\nexec /tmp/otm-ref/bin/mosquitto_sub -i otm-ref-%s-%s -t %s/%s -F "%%U %%x" -W %s > /tmp/otm-ref/%s.log 2> /tmp/otm-ref/%s.err\n' \
			"$t" "$(date +%s)" "$praefix" "$t" "$W" "$t" "$t" |
			ssh "${K[@]}" root@"$host" "cat > /tmp/otm-ref/run-$t.sh; chmod 700 /tmp/otm-ref/run-$t.sh; start-stop-daemon -S -b -x /tmp/otm-ref/run-$t.sh"
	done
	sleep 5
	ssh "${K[@]}" root@"$host" 'ps w | grep -c "[o]tm-ref/bin/mosquitto_sub"; cat /tmp/otm-ref/*.err'
	;;
*)
	sed -n '2,13p' "$0"; exit 1 ;;
esac
