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
#   runde-starten.sh referenz-lokal <ziel-verzeichnis> <topic-praefix> <credfile> <ende-UTC>
#       dasselbe, aber auf diesem Rechner - noetig ab OpenWrt 25.12: der
#       mosquitto_sub der alten Feeds braucht libssl.so.1.1, auf dem Geraet
#       liegt OpenSSL 3. Binary aus $MOSQ (Standard: mosquitto_sub aus dem PATH;
#       ohne Paket: apt-get download mosquitto-clients libmosquitto1 + dpkg -x
#       nach build/messwerkzeug/host/root, LD_LIBRARY_PATH mitgeben).
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
	ssh "${K[@]}" root@"$host" 'mkdir -p /tmp/otm-baseline/x/usr/bin /tmp/otm-baseline/x/usr/lib'
	if vorhanden=$(ssh "${K[@]}" root@"$host" 'command -v tcpdump'); then
		# im Image vorhanden (z. B. Muensters Build): nehmen statt holen
		ssh "${K[@]}" root@"$host" "ln -sf $vorhanden /tmp/otm-baseline/x/usr/bin/tcpdump"
	else
		# Ab 25.12 liefern die Feeds .apk statt .ipk; statt die zu entpacken
		# nehmen wir das tcpdump des 22.03-Feeds mit. Es laeuft dort
		# unveraendert (musl 1.2, eigene libpcap per LD_LIBRARY_PATH).
		case "$ver" in 2[5-9].*) ver=${TOOLS_VER:-22.03.7} ;; esac
		hole "$ver" "$arch" base tcpdump-mini
		hole "$ver" "$arch" base libpcap1
		scp -O -q "${K[@]}" "$CACHE/$ver/x/usr/sbin/tcpdump" root@"$host":/tmp/otm-baseline/x/usr/bin/tcpdump 2>/dev/null ||
			scp -O -q "${K[@]}" "$CACHE/$ver/x/usr/bin/tcpdump" root@"$host":/tmp/otm-baseline/x/usr/bin/tcpdump
		scp -O -q "${K[@]}" "$CACHE/$ver"/x/usr/lib/libpcap* root@"$host":/tmp/otm-baseline/x/usr/lib/
	fi
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
referenz-lokal)
	ziel=$2 praefix=$3 cred=$4 ende=$5
	mkdir -p "$ziel"
	# shellcheck disable=SC1090
	. <(sed 's/^/local_/' "$cred")
	# Optionsdatei (600): Passwort steht damit nicht in der Prozessliste
	umask 077
	printf -- '-h cits1.opentrafficmap.org\n-p 8883\n--capath /etc/ssl/certs\n-u %s\n-P %s\n' \
		"$local_user" "$local_pass" > "$ziel/mosquitto_sub"
	# mosquitto_sub verbindet sich nach einem Abbruch nicht von selbst neu (in R5
	# riss die Referenz 3 h vor Schluss ab). Deshalb in einer Schleife bis zum
	# Endzeitpunkt, Ausgabe angehaengt.
	ende_ts=$(date -u -d "$ende" +%s)
	for t in packet stats; do
		(
			export XDG_CONFIG_HOME="$ziel"
			while [ "$(date -u +%s)" -lt "$ende_ts" ]; do
				"${MOSQ:-mosquitto_sub}" -i "otm-ref-$t-$(date +%s)" \
					-t "$praefix/$t" -F '%U %x' \
					-W $(( ende_ts - $(date -u +%s) )) \
					>> "$ziel/$t.log" 2>> "$ziel/$t.err"
				sleep 5
			done
		) >/dev/null 2>&1 &
	done
	sleep 5
	pgrep -fc "otm-ref-.*-" || true
	cat "$ziel"/*.err
	;;
*)
	sed -n '2,17p' "$0"; exit 1 ;;
esac
