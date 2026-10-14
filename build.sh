#!/usr/bin/env bash
#
# OTM-Empfaenger-Images: OpenWrt 21.02/22.03/25.12 (Standard 21.02.7 ath79/generic),
# plain, ohne LuCI.
#
#   1. SDK baut die gepatchten Pakete: mac80211 (ath9k ITS-Kanaele, regd,
#      Half-Rate), wireless-regdb (DE ITS, NO-IR), otm-bridge und
#      otm-mgmt-vpn (fastd zur Management-Gegenstelle).
#   2. ImageBuilder baut daraus je Profil ein sysupgrade-Image, mit
#      files/common, files/local (eigene authorized_keys, nicht im Repo)
#      und /etc/otm-build-info.
#
# Kein Komplettbau: Kernel und alle anderen Pakete kommen aus dem Release.
# Die kmods aus dem SDK passen zum Release-Kernel (gleiche vermagic).
#
# Aufruf:   ./build.sh                    alle Profile aus PROFILES
#           PROFILES="tplink_tl-wdr3600-v1" ./build.sh
# Ergebnis: build/out/<release>/<profil>/*sysupgrade.bin + build-info

set -euo pipefail

# Von einer Kopie laufen: bash liest Skripte waehrend der Ausfuehrung nach,
# eine Aenderung an build.sh mitten im Lauf fuehrte sonst zu Syntaxfehlern.
if [ -z "${OTM_BUILD_RUNCOPY:-}" ]; then
	OTM_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	mkdir -p "$OTM_HERE/build"
	cp "${BASH_SOURCE[0]}" "$OTM_HERE/build/.build.sh.run"
	OTM_BUILD_RUNCOPY=1 OTM_HERE="$OTM_HERE" exec bash "$OTM_HERE/build/.build.sh.run" "$@"
fi

OWRT_VER="${OWRT_VER:-21.02.7}"
TARGET="${TARGET:-ath79}"
SUBTARGET="${SUBTARGET:-generic}"
PROFILES="${PROFILES:-tplink_tl-wdr4300-v1 tplink_tl-wdr3600-v1}"
# Eigene Paket-Revision, damit opkg im ImageBuilder unsere Pakete den
# gleichnamigen aus dem Release-Repo vorzieht.
OTM_RELEASE="${OTM_RELEASE:-91}"
# Fuer A/B-Tests: Patches weglassen (Dateinamen-Muster, durch Leerzeichen
# getrennt, z. B. SKIP_PATCHES="997-*") und die Variante benennen, damit
# Image-Name, Ausgabeverzeichnis und build-info sie auseinanderhalten.
SKIP_PATCHES="${SKIP_PATCHES:-}"
OTM_VARIANT="${OTM_VARIANT:-}"
JOBS="${JOBS:-$(nproc)}"
# Weg zum MQTT-Broker:
#   proxy  (Vorgabe) MQTT ohne TLS durch das Management-VPN an den Proxy auf
#          wgiot6.ffdus.de, der per TLS an cits1.opentrafficmap.org weiterreicht.
#          Kein TLS und kein CA-Bundle im Image, keine Abhaengigkeit von der Uhr.
#   direct mqtts direkt an cits1.opentrafficmap.org (TLS + CA-Bundle im Image)
#   auto   beides im Image: Tunnel, wenn er binnen 2 min steht, sonst direkt
OTM_MQTT="${OTM_MQTT:-proxy}"
# Management-VPN (fastd zu wgiot6.ffdus.de, SSH als <knoten>.otm): 1 oder 0.
# proxy und auto brauchen es.
OTM_VPN="${OTM_VPN:-1}"
# SSH-Keys fuers Image: Pfad zu einer authorized_keys-Datei, oder "none" fuer
# ein Image ohne Fernzugang. Vorgabe: files/local/etc/dropbear/authorized_keys,
# sonst ohne.
OTM_SSH_KEYS="${OTM_SSH_KEYS:-}"
# Autoupdater (Manifest und Signaturen wie bei Gluon): 1 (Vorgabe) oder 0.
# OTM_VERSION ist die Versionsnummer im Image und im Manifest; gleich lange
# Ziffernfolge, damit der Autoupdater per Textvergleich "neuer" erkennt.
OTM_AUTOUPDATER="${OTM_AUTOUPDATER:-1}"
OTM_BRANCH="${OTM_BRANCH:-stable}"
OTM_VERSION="${OTM_VERSION:-$(date -u +%Y%m%d%H%M)}"
case "$OTM_MQTT" in proxy|direct|auto) ;; *)
	echo "OTM_MQTT=$OTM_MQTT: erlaubt sind proxy, direct, auto" >&2; exit 1 ;;
esac
case "$OTM_VPN" in 0|1) ;; *) echo "OTM_VPN=$OTM_VPN: erlaubt sind 0 und 1" >&2; exit 1 ;; esac
if [ "$OTM_VPN" = 0 ] && [ "$OTM_MQTT" != direct ]; then
	echo "OTM_MQTT=$OTM_MQTT braucht das Management-VPN (OTM_VPN=1)" >&2; exit 1
fi

HERE="${OTM_HERE:?}"
BUILD="$HERE/build"
DL_BASE="https://downloads.openwrt.org/releases/$OWRT_VER/targets/$TARGET/$SUBTARGET"
PATCHES="$HERE/patches/openwrt-${OWRT_VER%.*}"

# Pakete im Image: Standard des Profils plus/minus diese Liste.
# Kein RA/DHCPv6-Server, kein PPP, kein wpad (netifd fasst die Radios nicht an).
# dnsmasq bleibt als reiner DNS-Forwarder: ab 22.03 laeuft ntpd in einer ujail
# ohne resolv.conf und fragt 127.0.0.1 - ohne dnsmasq keine Zeit, kein TLS.
# DHCP verteilt er nicht (99-otm-setup loescht dhcp.lan), die wan-Zone blockt 53.
IMAGE_PACKAGES="otm-bridge -odhcpd-ipv6only -ppp -ppp-mod-pppoe -wpad-basic-wolfssl"
# ab 25.12 heisst das Standard-wpad anders
case "$OWRT_VER" in 2[3-9].*) IMAGE_PACKAGES="$IMAGE_PACKAGES -wpad-basic-mbedtls" ;; esac
[ "$OTM_VPN" = 1 ] && IMAGE_PACKAGES="$IMAGE_PACKAGES otm-mgmt-vpn fastd kmod-tun"
[ "$OTM_AUTOUPDATER" = 1 ] && IMAGE_PACKAGES="$IMAGE_PACKAGES otm-autoupdater ecdsautils"
if [ "$OTM_MQTT" = proxy ]; then
	# Kein TLS auf dem Geraet: CA-Bundle und TLS-Bibliothek fuer uclient-fetch
	# fliegen raus (das Bundle veraltete ohnehin im Flash); apk/opkg holen die
	# signierten Pakete dann per http (99-otm-setup).
	# vor otm-bridge: opkg (bis 22.03) nimmt sonst fuer die virtuelle
	# Abhaengigkeit "libmosquitto" die TLS-Variante, die dann kollidiert
	IMAGE_PACKAGES="libmosquitto-nossl $IMAGE_PACKAGES -ca-bundle"
	case "$OWRT_VER" in
	2[3-9].*) IMAGE_PACKAGES="$IMAGE_PACKAGES -libustream-mbedtls" ;;
	*) IMAGE_PACKAGES="$IMAGE_PACKAGES -libustream-wolfssl" ;;
	esac
else
	IMAGE_PACKAGES="libmosquitto-ssl ca-bundle $IMAGE_PACKAGES"
fi
# lantiq (FRITZ!Box 3390 u. a.): DSL-Stack wird fuer den Empfaenger nicht gebraucht
case "$TARGET" in
lantiq) IMAGE_PACKAGES="$IMAGE_PACKAGES -ppp-mod-pppoa -ltq-vdsl-app -ltq-vdsl-vr9-vectoring-fw-installer \
	-kmod-ltq-vdsl-vr9 -kmod-ltq-vdsl-vr9-mei -kmod-ltq-atm-vr9 -kmod-ltq-ptm-vr9 \
	-dsl-vrx200-firmware-xdsl-a -dsl-vrx200-firmware-xdsl-b-patch" ;;
esac

log()  { printf '\033[1;34m[otm]\033[0m %s\n' "$*"; }
uebersprungen() { # Patchpfad -> 0, wenn er laut SKIP_PATCHES entfallen soll
	local m n=${1##*/}
	for m in $SKIP_PATCHES; do
		case "$n" in $m) return 0 ;; esac
	done
	return 1
}
die()  { printf '\033[1;31m[otm]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$BUILD"
cd "$BUILD"

# --- 0. SDK und ImageBuilder holen (mit Pruefsumme) -------------------------

SDK_TAR=$(curl -fsS "$DL_BASE/" | grep -oE "openwrt-sdk-$OWRT_VER-$TARGET-${SUBTARGET}_[^\"]*\.tar\.(xz|zst)" | head -n 1)
IB_TAR=$(curl -fsS "$DL_BASE/" | grep -oE "openwrt-imagebuilder-$OWRT_VER-$TARGET-$SUBTARGET\.[^\"]*\.tar\.(xz|zst)" | head -n 1)
[ -n "$SDK_TAR" ] && [ -n "$IB_TAR" ] || die "SDK/ImageBuilder fuer $OWRT_VER $TARGET/$SUBTARGET nicht gefunden"
[ -f "sha256sums-$OWRT_VER-$TARGET-$SUBTARGET" ] || curl -fsS -o "sha256sums-$OWRT_VER-$TARGET-$SUBTARGET" "$DL_BASE/sha256sums"
for t in "$SDK_TAR" "$IB_TAR"; do
	[ -f "$t" ] || { log "lade $t"; curl -fsS -o "$t" "$DL_BASE/$t"; }
	grep " \*\?$t\$" "sha256sums-$OWRT_VER-$TARGET-$SUBTARGET" | sed 's/ \*/  /' | sha256sum -c --quiet - || die "Pruefsumme $t"
done
SDK="$BUILD/${SDK_TAR%.tar.*}"
IB="$BUILD/${IB_TAR%.tar.*}"
[ -d "$SDK" ] || { log "entpacke SDK"; tar xf "$SDK_TAR"; }
[ -d "$IB" ]  || { log "entpacke ImageBuilder"; tar xf "$IB_TAR"; }

# --- 1. SDK: Feeds, Patches, Pakete ------------------------------------------

cd "$SDK"
if [ ! -f feeds.conf ]; then
	# ab 25.12 steht der base-Feed als "src-git --root=package base ..." drin
	grep -E '^src-git(-full)? (--root=\S+ )?(base|packages) ' feeds.conf.default > feeds.conf
	echo "src-link otm $HERE/feed" >> feeds.conf
fi
log "feeds update/install"
./scripts/feeds update -a >/dev/null
# libpcap explizit: ab 25.12 zieht feeds install es nicht mehr als Abhaengigkeit
# von otm-bridge nach, der Bau bricht dann an fehlendem pcap.h ab
./scripts/feeds install -p base mac80211 wireless-regdb libpcap >/dev/null
./scripts/feeds install -p otm otm-bridge otm-mgmt-vpn otm-autoupdater >/dev/null
# Flash-Entsperren fuer den LiteBeam M5 XW, braucht Kernel 5.9+ (nicht 21.02)
KMODS_OTM=""
case "$OWRT_VER" in 2[3-9].*) KMODS_OTM="otm-spinor-unlock"
	./scripts/feeds install -p otm otm-spinor-unlock >/dev/null ;;
esac

# Gepatchte Paketverzeichnisse immer vom sauberen Stand aus: kein Rest aus
# frueheren Laeufen (auch keine unversionierten Dateien) im Image.
# bis 24.10 ist der base-Feed der ganze OpenWrt-Baum, ab 25.12 ist er auf
# package/ gewurzelt (--root=package), die Pfade darin sind entsprechend kuerzer
if [ -d feeds/base/package/kernel/mac80211 ]; then
	MAC=package/kernel/mac80211
	REGDB=package/firmware/wireless-regdb
else
	MAC=kernel/mac80211
	REGDB=firmware/wireless-regdb
fi
git -C feeds/base checkout -q -- "$MAC" "$REGDB"
git -C feeds/base clean -q -fdx -- "$MAC" "$REGDB"
[ -d "$PATCHES" ] || die "keine Patches fuer ${OWRT_VER%.*}: $PATCHES fehlt"
# je Unterordner (ath, ath9k, ...) in den gleichnamigen des Pakets: die
# Ordner-Reihenfolge von mac80211 bestimmt, auf welchem Stand ein Patch aufsetzt
GENOMMEN=""
for d in "$PATCHES"/mac80211/*/ "$PATCHES"/wireless-regdb/; do
	d=${d%/}
	case "$d" in
	*/wireless-regdb) ziel="feeds/base/$REGDB/patches" ;;
	*) ziel="feeds/base/$MAC/patches/${d##*/}"; mkdir -p "$ziel" ;;
	esac
	for f in "$d"/*.patch; do
		if uebersprungen "$f"; then
			log "Patch ausgelassen: ${f##*/}"
			continue
		fi
		cp "$f" "$ziel/"
		GENOMMEN="$GENOMMEN ${f##*/}"
	done
done
[ -n "$GENOMMEN" ] || die "kein einziger Patch uebrig (SKIP_PATCHES=$SKIP_PATCHES)"
sed -i "s/^PKG_RELEASE:=.*/PKG_RELEASE:=$OTM_RELEASE/" "feeds/base/$MAC/Makefile" "feeds/base/$REGDB/Makefile"

# Nur bauen, was wir brauchen (SDK-Vorgabe waere "alles").
cat > .config <<EOF
# CONFIG_ALL is not set
# CONFIG_ALL_KMODS is not set
# CONFIG_ALL_NONSHARED is not set
# CONFIG_SIGNED_PACKAGES is not set
CONFIG_PACKAGE_kmod-ath9k=m
CONFIG_PACKAGE_wireless-regdb=m
CONFIG_PACKAGE_otm-bridge=m
CONFIG_PACKAGE_otm-mgmt-vpn=m
CONFIG_PACKAGE_otm-autoupdater=m
EOF
for k in $KMODS_OTM; do echo "CONFIG_PACKAGE_kmod-$k=m" >> .config; done
make defconfig >/dev/null

log "baue mac80211, wireless-regdb, otm-bridge, otm-mgmt-vpn (-j$JOBS)"
for p in mac80211 wireless-regdb otm-bridge otm-mgmt-vpn otm-autoupdater $KMODS_OTM; do
	make "package/$p/clean" >/dev/null 2>&1 || true
done
make -j"$JOBS" package/mac80211/compile package/wireless-regdb/compile \
	package/otm-bridge/compile package/otm-mgmt-vpn/compile \
	package/otm-autoupdater/compile $(for k in $KMODS_OTM; do echo package/$k/compile; done) \
	> "$BUILD/sdk-build.log" 2>&1 ||
	die "SDK-Build fehlgeschlagen, siehe $BUILD/sdk-build.log"

# --- 2. ImageBuilder ---------------------------------------------------------

cd "$IB"
# Fehler im ImageBuilder 25.12: FormatPackages setzt pkg_ver zwischen zwei
# Paketen nicht zurueck, dadurch erbt jedes Paket nach einem gepinnten dessen
# Version ("breaks: world[libgcc1=<ath9k-Version>]"). Vor dem Bau reparieren.
grep -q 'eval pkg_ver:=)' Makefile ||
	sed -i 's/^\(  \$(eval pkg_name:=.*\)$/\1\n  $(eval pkg_ver:=)/' Makefile

# bis 24.10 (opkg) liest der Index rekursiv, ab 25.12 (apk) nur "packages/*.apk"
# - deshalb dort flach ablegen. Revision: ...-91_<arch>.ipk bzw. ...-r91.apk
case "$OWRT_VER" in
2[5-9].*) PKGDIR=packages ;;
*) PKGDIR=packages/otm; rm -rf "$PKGDIR" ;;
esac
mkdir -p "$PKGDIR"
find "$SDK/bin" \( -name '*.ipk' -o -name '*.apk' \) \
	\( -name "kmod-*" -o -name "wireless-regdb*" -o -name "otm-bridge*" -o -name "otm-mgmt-vpn*" -o -name "otm-autoupdater*" \) -exec cp {} "$PKGDIR/" \;
ls "$PKGDIR" | grep -qE -e "-${OTM_RELEASE}_|-r${OTM_RELEASE}\.apk\$" || die "keine Pakete mit Revision $OTM_RELEASE"

# Unsere Pakete auf ihre Version festnageln. Sonst gewinnt eine hoehere Version
# aus dem Release-Repo: 25.12.4 liefert wireless-regdb 2026.05.30, unser SDK
# baut die 2026.03.18 des base-Feeds - ohne Pin landet die ungepatchte im Image
# (und damit kein DE-Eintrag fuer 5850-5925 MHz).
# Bis 24.10 stimmten die Versionen zwischen SDK und Release-Repo ueberein, dort
# reicht die hoehere Revision 91; gepinnt wird deshalb nur fuer apk.
case "$OWRT_VER" in 2[5-9].*)
	for p in wireless-regdb kmod-ath9k; do
		f=$(ls "$PKGDIR/$p"-[0-9]*.apk 2>/dev/null | head -n 1) || die "$p nicht in $PKGDIR"
		f=${f##*/}; f=${f%.apk}
		IMAGE_PACKAGES="$IMAGE_PACKAGES $p=${f#$p-}"
	done ;;
esac

# Herkunft ins Image (was laeuft da drei Wochen spaeter?)
OTM_COMMIT=$(git -C "$HERE" rev-parse --short HEAD)${OTM_VARIANT:+-$OTM_VARIANT}
git -C "$HERE" diff --quiet HEAD -- feed patches files build.sh || OTM_COMMIT="$OTM_COMMIT-dirty"
# files/common (im Repo) und files/local (gitignored, eigene SSH-Keys u. a.)
FILES="$BUILD/files"
rm -rf "$FILES" && mkdir -p "$FILES/etc"
for d in "$HERE/files/common" "$HERE/files/local"; do
	[ -d "$d" ] && cp -a "$d/." "$FILES/"
done
case "$OTM_SSH_KEYS" in
"") ;;
none) rm -f "$FILES/etc/dropbear/authorized_keys" ;;
*)	[ -f "$OTM_SSH_KEYS" ] || die "OTM_SSH_KEYS: $OTM_SSH_KEYS gibt es nicht"
	mkdir -p "$FILES/etc/dropbear"
	install -m 600 "$OTM_SSH_KEYS" "$FILES/etc/dropbear/authorized_keys" ;;
esac
SSH_KEYS=$(grep -cE '^(ssh-|ecdsa-)' "$FILES/etc/dropbear/authorized_keys" 2>/dev/null || true)
[ "${SSH_KEYS:-0}" -gt 0 ] ||
	printf '\033[1;33m[otm]\033[0m %s\n' "kein SSH-Key im Image: ohne Fernzugang (SSH bleibt zu)" >&2
mkdir -p "$FILES/lib/otm"
echo "$OTM_VERSION" > "$FILES/lib/otm/version"
# Vorgabe fuer den Weg zum Broker; eine spaeter von Hand gesetzte bleibt
mkdir -p "$FILES/etc/uci-defaults"
cat > "$FILES/etc/uci-defaults/97-otm-transport" <<UCIEOF
#!/bin/sh
[ -n "\$(uci -q get otm-bridge.main.transport)" ] && exit 0
uci set otm-bridge.main.transport='$OTM_MQTT'
uci commit otm-bridge
UCIEOF
cat > "$FILES/etc/otm-build-info" <<EOF
otm_commit=$OTM_COMMIT
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
openwrt=$OWRT_VER $TARGET/$SUBTARGET (SDK + ImageBuilder)
otm_pkg_release=$OTM_RELEASE
mqtt=$OTM_MQTT vpn=$OTM_VPN ssh_keys=${SSH_KEYS:-0} autoupdater=$OTM_AUTOUPDATER
version=$OTM_VERSION
patches=$(echo $GENOMMEN | tr ' ' '\n' | sort | tr '\n' ' ')
patches_ausgelassen=${SKIP_PATCHES:-keine}
EOF

OUT="$BUILD/out/$OWRT_VER${OTM_VARIANT:+-$OTM_VARIANT}"
# Geraete, bei denen TLS (direct/auto) das Overlay fast aufbraucht: 8 MB Flash
# und ein grosses Kernel-/Loader-Layout. Mit TLS bleiben dort grob 300 KB,
# der erste Boot schreibt fast so viel.
KNAPP="ubnt_litebeam-m5-xw ubnt_nanostation-m-xw ubnt_nanostation-loco-m-xw
	ubnt_powerbeam-m5-xw ubnt_bullet-m-xw
	tplink_cpe510-v1 tplink_cpe510-v2 tplink_cpe510-v3 tplink_cpe610-v1 tplink_cpe610-v2
	tplink_wbs510-v1 tplink_wbs510-v2"
# Ubiquiti XW: der Bootloader laesst den Flash schreibgeschuetzt, sysupgrade (und
# damit der Autoupdater) schreibt sonst Kernel und System nicht. Am LiteBeam
# belegt; die XW-Boards sind elektrisch gleich (Gluon-Images liefen
# geraeteuebergreifend), Schreibschutz-Pin ueberall SoC-GPIO 0.
XW="ubnt_litebeam-m5-xw ubnt_nanostation-m-xw ubnt_nanostation-loco-m-xw
	ubnt_powerbeam-m5-xw ubnt_bullet-m-xw"
for prof in $PROFILES; do
	log "Image $prof"
	case " $(echo $KNAPP) " in *" $prof "*)
		[ "$OTM_MQTT" = proxy ] ||
			printf '\033[1;33m[otm]\033[0m %s\n' "$prof: OTM_MQTT=$OTM_MQTT braucht TLS im Image, dafuer ist der Flash knapp (Overlay ~300 KB); proxy empfohlen" >&2 ;;
	esac
	# alte Images dieses Profils weg, sonst landen sie mit in out/
	rm -f bin/targets/$TARGET/$SUBTARGET/*"$prof"*
	rm -rf "${OUT:?}/$prof"
	# Je Board: Ubiquiti XW braucht das Entsperren des Flash (siehe XW oben)
	PKGS="$IMAGE_PACKAGES"
	case " $(echo $XW) :$KMODS_OTM" in *" $prof "*:*otm-spinor-unlock*)
		PKGS="$PKGS kmod-otm-spinor-unlock" ;;
	esac
	make image PROFILE="$prof" PACKAGES="$PKGS" FILES="$FILES" \
		EXTRA_IMAGE_NAME="otm-$OTM_COMMIT" > "$BUILD/ib-$prof.log" 2>&1 ||
		die "ImageBuilder $prof fehlgeschlagen, siehe $BUILD/ib-$prof.log"
	mkdir -p "$OUT/$prof"
	cp bin/targets/$TARGET/$SUBTARGET/*"$prof"*sysupgrade.bin "$OUT/$prof/"
	# factory-Image, wo es eins gibt: Umstieg von der Herstellerfirmware
	cp bin/targets/$TARGET/$SUBTARGET/*"$prof"*factory.bin "$OUT/$prof/" 2>/dev/null || true
	cp bin/targets/$TARGET/$SUBTARGET/*"$prof"*.manifest "$OUT/$prof/" 2>/dev/null || true
	# Kontrolle: im Image muessen unsere gepatchten Pakete stecken, nicht die
	# gleichnamigen aus dem Release-Repo
	for m in "$OUT/$prof"/*.manifest; do
		[ -f "$m" ] || continue
		for p in wireless-regdb kmod-ath9k; do
			grep -qE "^$p - .*-r?$OTM_RELEASE\$" "$m" ||
				die "$prof: $p im Image ist nicht unseres (siehe $m)"
		done
	done
	cp "$FILES/etc/otm-build-info" "$OUT/$prof/build-info"
	(cd "$OUT/$prof" && sha256sum *.bin > sha256sums)
done

# --- Autoupdater: Verzeichnis zum Hochladen ---------------------------------
# build/out/otm/<branch>/ entspricht firmware.ffnef.de/otm/<branch>/:
# sysupgrade/ mit Images und <branch>.manifest (unsigniert, zum Signieren mit
# sign.sh bzw. ecdsasign), factory/ mit den Images fuer den Erstumstieg. Jeder
# Lauf ersetzt nur die Eintraege seiner Profile, Laeufe fuer andere Targets
# bleiben stehen.
if [ "$OTM_AUTOUPDATER" = 1 ]; then
	PUB="$BUILD/out/otm${OTM_VARIANT:+-$OTM_VARIANT}/$OTM_BRANCH"
	mkdir -p "$PUB/sysupgrade/.manifest.d" "$PUB/factory"
	PJ=$(ls bin/targets/$TARGET/$SUBTARGET/profiles.json)
	for prof in $PROFILES; do
		frag="$PUB/sysupgrade/.manifest.d/$OWRT_VER-$TARGET-$SUBTARGET-$prof"
		if [ -f "$frag.files" ]; then
			while read -r f; do rm -f "$PUB/$f"; done < "$frag.files"
		fi
		: > "$frag.files"
		img=$(ls "$OUT/$prof/"*sysupgrade.bin)
		cp "$img" "$PUB/sysupgrade/"
		echo "sysupgrade/${img##*/}" >> "$frag.files"
		for f in "$OUT/$prof/"*factory.bin; do
			[ -f "$f" ] || continue
			cp "$f" "$PUB/factory/"
			echo "factory/${f##*/}" >> "$frag.files"
		done
		sha=$(sha256sum "$img" | cut -d' ' -f1)
		size=$(stat -c %s "$img")
		# Board-Namen (DT-compatible, wie /tmp/sysinfo/board_name); Altnamen
		# ohne Komma gehoeren zu ar71xx und waeren nicht eindeutig
		python3 -c 'import json,sys; [print(d) for d in json.load(open(sys.argv[1]))["profiles"][sys.argv[2]]["supported_devices"] if "," in d]' \
			"$PJ" "$prof" | while read -r board; do
			echo "$board $OTM_VERSION $sha $size ${img##*/}"
		done > "$frag.lines"
		[ -s "$frag.lines" ] || die "$prof: kein Board-Name in $PJ"
	done
	{
		echo "BRANCH=$OTM_BRANCH"
		echo "DATE=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
		echo "PRIORITY=0"
		echo
		cat "$PUB/sysupgrade/.manifest.d/"*.lines | sort
		echo "---"
	} > "$PUB/sysupgrade/$OTM_BRANCH.manifest"
	log "Autoupdater: $PUB (Manifest unsigniert)"
fi

log "fertig:"
find "$OUT" -name '*sysupgrade.bin' -newer "$FILES/etc/otm-build-info" -exec ls -la {} \;
