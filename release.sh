#!/bin/bash
# release.sh - baut einen vollstaendigen Release fuer firmware.ffnef.de/otm/:
# alle Geraete, ohne Key (otm/stable) und mit Key (otm/stable-key), Transport
# proxy mit Management-VPN und Autoupdater, alle mit derselben Versionsnummer.
#
# Aufruf:   ./release.sh                  Version = Startzeit (UTC, JJJJMMTThhmm)
#           OTM_VERSION=202610151119 ./release.sh
#
# Ergebnis: build/release-<version>/otm/{stable,stable-key}/{sysupgrade,factory}/
# mit sha256sums; otm/stable/sysupgrade/stable.manifest ist unsigniert. Die
# Key-Geraete aktualisieren ebenfalls aus otm/stable (ihre Keys stehen in der
# Konfiguration), deshalb hat stable-key kein Manifest.
#
# Laeuft lange (etwa eine Stunde). Abbruch bei einem gescheiterten Teillauf.
set -euo pipefail
cd "$(dirname "$0")"

export OTM_VERSION="${OTM_VERSION:-$(date -u +%Y%m%d%H%M)}"

# OpenWrt 25.12.4, ath79: alle ath9k-5-GHz-Geraete
ATH79="tplink_tl-wdr3600-v1 tplink_tl-wdr4300-v1 tplink_tl-wdr4310-v1 tplink_tl-wdr3500-v1
	tplink_cpe510-v1 tplink_cpe510-v2 tplink_cpe510-v3 tplink_cpe610-v1 tplink_cpe610-v2
	tplink_wbs510-v1 tplink_wbs510-v2
	ubnt_litebeam-m5-xw ubnt_nanostation-m-xw ubnt_nanostation-loco-m-xw
	ubnt_powerbeam-m5-xw ubnt_bullet-m-xw"
# OpenWrt 25.12.4, lantiq
LANTIQ="avm_fritz3390"
# OpenWrt 21.02.7 (NanoStation M XM: 32 MB RAM, ab 22.03 nicht mehr gebaut)
ALT="ubnt_nanostation-m"

echo "Release $OTM_VERSION"
mkdir -p build
rm -rf build/out/otm build/out/otm-key

lauf() {
	local log="build/release-$OTM_VERSION-$1.log"; shift
	echo "== $* (Log: $log)"
	env "$@" ./build.sh > "$log" 2>&1 || { tail -n 5 "$log"; echo "gescheitert: $*" >&2; exit 1; }
}
for v in nokey key; do
	if [ $v = nokey ]; then set -- OTM_SSH_KEYS=none; else set -- OTM_SSH_KEYS= OTM_VARIANT=key; fi
	lauf "$v-ath79"  "$@" OWRT_VER=25.12.4 PROFILES="$(echo $ATH79)"
	lauf "$v-lantiq" "$@" OWRT_VER=25.12.4 TARGET=lantiq SUBTARGET=xrx200 PROFILES="$LANTIQ"
	lauf "$v-2102"   "$@" OWRT_VER=21.02.7 PROFILES="$ALT"
done

A=build/release-$OTM_VERSION
rm -rf "$A"; mkdir -p "$A/otm"
cp -a build/out/otm/stable "$A/otm/stable"
cp -a build/out/otm-key/stable "$A/otm/stable-key"
rm -rf "$A/otm/stable/sysupgrade/.manifest.d" "$A/otm/stable-key/sysupgrade/.manifest.d" \
	"$A"/otm/stable-key/sysupgrade/*.manifest
for d in "$A"/otm/*/*/; do (cd "$d" && sha256sum *.bin > sha256sums); done

echo
for d in "$A"/otm/*/*/; do echo "${d#$A/}: $(ls "$d" | grep -c '\.bin$') Images"; done
echo "Manifest-Zeilen: $(grep -c " $OTM_VERSION " "$A/otm/stable/sysupgrade/stable.manifest")"
echo "Fertig: $A/otm/ hochladen, dann otm/stable/sysupgrade/stable.manifest signieren."
