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
ATH79="tplink_tl-wdr3600-v1 tplink_tl-wdr4300-v1 tplink_tl-wdr4310-v1 tplink_tl-wdr3500-v1 tplink_tl-wdr4900-v2
	buffalo_wzr-hp-ag300h buffalo_wzr-600dhp aruba_ap-105 aruba_ap-175
	tplink_cpe510-v1 tplink_cpe510-v2 tplink_cpe510-v3 tplink_cpe610-v1 tplink_cpe610-v2
	tplink_wbs510-v1 tplink_wbs510-v2 tplink_tl-wr2543-v1
	ubnt_litebeam-m5-xw ubnt_nanostation-m-xw ubnt_nanostation-loco-m-xw
	ubnt_powerbeam-m5-xw ubnt_bullet-m-xw
	ubnt_rocket-m ubnt_powerbridge-m ubnt_unifi-ap-pro
	netgear_wndr3700 netgear_wndr3700-v2 netgear_wndr3800 netgear_wndr3800ch netgear_wndrmac-v2
	avm_fritz300e dlink_dir-825-b1 dlink_dir-825-c1 enterasys_ws-ap3705i
	openmesh_mr900-v1 openmesh_mr900-v2 meraki_mr16
	fortinet_fap-220-b fortinet_fap-221-b huawei_ap6010dn
	ruckus_zf7351 ruckus_zf7363 ruckus_zf7372
	engenius_esr900 mercury_mw4530r-v1"
# OpenWrt 25.12.4, ath79/nand (kuerzere Namen vor laengeren: build.sh loescht per Muster)
ATH79NAND="aerohive_hiveap-121 linksys_ea4500-v3 netgear_wndr3700-v4
	netgear_wndr4300 netgear_wndr4300-v2 netgear_wndr4500-v3"
# OpenWrt 25.12.4, ath79/mikrotik
ATH79MIKROTIK="mikrotik_routerboard-lhg-5nd mikrotik_routerboard-sxt-5nd-r2"
# OpenWrt 25.12.4, lantiq
LANTIQ="avm_fritz3390 avm_fritz3370-rev2-hynix avm_fritz3370-rev2-micron"
# OpenWrt 25.12.4, mpc85xx (PowerPC): TL-WDR4900 v1, 5 GHz ueber AR9580 (ath9k)
MPC85XX="tplink_tl-wdr4900-v1 enterasys_ws-ap3715i"
# OpenWrt 25.12.4, mpc85xx/p1020 (PowerPC). WS-AP3825i: ath9k und ath10k im Geraet
MPC85XXP1020="enterasys_ws-ap3710i aerohive_hiveap-330 hpe_msm460 extreme-networks_ws-ap3825i"
# OpenWrt 21.02.7: Ubiquiti-M-Serie mit XM-Board und 32 MB RAM (ab 22.03 nicht mehr
# gebaut; Rocket M und PowerBridge M haben 64 MB und laufen oben mit 25.12.4)
ALT="ubnt_nanostation-m ubnt_nanostation-loco-m ubnt_bullet-m-ar7240 ubnt_bullet-m-ar7241"

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
	lauf "$v-ath79-nand" "$@" OWRT_VER=25.12.4 SUBTARGET=nand PROFILES="$(echo $ATH79NAND)"
	lauf "$v-ath79-mikrotik" "$@" OWRT_VER=25.12.4 SUBTARGET=mikrotik PROFILES="$ATH79MIKROTIK"
	lauf "$v-lantiq" "$@" OWRT_VER=25.12.4 TARGET=lantiq SUBTARGET=xrx200 PROFILES="$LANTIQ"
	lauf "$v-mpc85xx" "$@" OWRT_VER=25.12.4 TARGET=mpc85xx SUBTARGET=p1010 PROFILES="$MPC85XX"
	lauf "$v-mpc85xx-p1020" "$@" OWRT_VER=25.12.4 TARGET=mpc85xx SUBTARGET=p1020 PROFILES="$MPC85XXP1020"
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
