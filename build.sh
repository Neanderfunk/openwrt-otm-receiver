#!/usr/bin/env bash
#
# OTM-Empfaenger-Images: OpenWrt 21.02/22.03/25.12 (Standard 21.02.7 ath79/generic),
# plain, ohne LuCI.
#
#   1. SDK baut die gepatchten Pakete: mac80211 (ath9k ITS-Kanaele, regd,
#      Half-Rate), wireless-regdb (DE ITS, NO-IR) und otm-bridge.
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
JOBS="${JOBS:-$(nproc)}"

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
# lantiq (FRITZ!Box 3390 u. a.): DSL-Stack wird fuer den Empfaenger nicht gebraucht
case "$TARGET" in
lantiq) IMAGE_PACKAGES="$IMAGE_PACKAGES -ppp-mod-pppoa -ltq-vdsl-app -ltq-vdsl-vr9-vectoring-fw-installer \
	-kmod-ltq-vdsl-vr9 -kmod-ltq-vdsl-vr9-mei -kmod-ltq-atm-vr9 -kmod-ltq-ptm-vr9 \
	-dsl-vrx200-firmware-xdsl-a -dsl-vrx200-firmware-xdsl-b-patch" ;;
esac

log()  { printf '\033[1;34m[otm]\033[0m %s\n' "$*"; }
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
./scripts/feeds install -p otm otm-bridge >/dev/null

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
for d in "$PATCHES"/mac80211/*/; do
	d=${d%/}
	mkdir -p "feeds/base/$MAC/patches/${d##*/}"
	cp "$d"/*.patch "feeds/base/$MAC/patches/${d##*/}/"
done
cp "$PATCHES"/wireless-regdb/*.patch "feeds/base/$REGDB/patches/"
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
EOF
make defconfig >/dev/null

log "baue mac80211, wireless-regdb, otm-bridge (-j$JOBS)"
for p in mac80211 wireless-regdb otm-bridge; do
	make "package/$p/clean" >/dev/null 2>&1 || true
done
make -j"$JOBS" package/mac80211/compile package/wireless-regdb/compile \
	package/otm-bridge/compile > "$BUILD/sdk-build.log" 2>&1 ||
	die "SDK-Build fehlgeschlagen, siehe $BUILD/sdk-build.log"

# --- 2. ImageBuilder ---------------------------------------------------------

cd "$IB"
# bis 24.10 (opkg) liest der Index rekursiv, ab 25.12 (apk) nur "packages/*.apk"
# - deshalb dort flach ablegen. Revision: ...-91_<arch>.ipk bzw. ...-r91.apk
case "$OWRT_VER" in
2[5-9].*) PKGDIR=packages ;;
*) PKGDIR=packages/otm; rm -rf "$PKGDIR" ;;
esac
mkdir -p "$PKGDIR"
find "$SDK/bin" \( -name '*.ipk' -o -name '*.apk' \) \
	\( -name "kmod-*" -o -name "wireless-regdb*" -o -name "otm-bridge*" \) -exec cp {} "$PKGDIR/" \;
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
OTM_COMMIT=$(git -C "$HERE" rev-parse --short HEAD)
git -C "$HERE" diff --quiet HEAD -- feed patches files build.sh || OTM_COMMIT="$OTM_COMMIT-dirty"
# files/common (im Repo) und files/local (gitignored, eigene SSH-Keys u. a.)
FILES="$BUILD/files"
rm -rf "$FILES" && mkdir -p "$FILES/etc"
for d in "$HERE/files/common" "$HERE/files/local"; do
	[ -d "$d" ] && cp -a "$d/." "$FILES/"
done
grep -qE '^(ssh-|ecdsa-)' "$FILES/etc/dropbear/authorized_keys" 2>/dev/null ||
	printf '\033[1;33m[otm]\033[0m %s\n' "kein SSH-Key in files/local/etc/dropbear/authorized_keys: Image ohne Fernzugang (SSH bleibt zu)" >&2
cat > "$FILES/etc/otm-build-info" <<EOF
otm_commit=$OTM_COMMIT
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
openwrt=$OWRT_VER $TARGET/$SUBTARGET (SDK + ImageBuilder)
otm_pkg_release=$OTM_RELEASE
patches=$(cd "$PATCHES" && find . -name '*.patch' | sort | tr '\n' ' ')
EOF

OUT="$BUILD/out/$OWRT_VER"
for prof in $PROFILES; do
	log "Image $prof"
	# alte Images dieses Profils weg, sonst landen sie mit in out/
	rm -f bin/targets/$TARGET/$SUBTARGET/*"$prof"*
	rm -rf "${OUT:?}/$prof"
	make image PROFILE="$prof" PACKAGES="$IMAGE_PACKAGES" FILES="$FILES" \
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

log "fertig:"
find "$OUT" -name '*sysupgrade.bin' -newer "$FILES/etc/otm-build-info" -exec ls -la {} \;
