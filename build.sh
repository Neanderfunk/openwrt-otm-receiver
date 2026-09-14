#!/usr/bin/env bash
#
# OTM-Empfaenger-Images: OpenWrt 21.02.7 (ath79/generic), plain, ohne LuCI.
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

OWRT_VER="${OWRT_VER:-21.02.7}"
TARGET="${TARGET:-ath79}"
SUBTARGET="${SUBTARGET:-generic}"
PROFILES="${PROFILES:-tplink_tl-wdr4300-v1 tplink_tl-wdr3600-v1}"
# Eigene Paket-Revision, damit opkg im ImageBuilder unsere Pakete den
# gleichnamigen aus dem Release-Repo vorzieht.
OTM_RELEASE="${OTM_RELEASE:-91}"
JOBS="${JOBS:-$(nproc)}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
DL_BASE="https://downloads.openwrt.org/releases/$OWRT_VER/targets/$TARGET/$SUBTARGET"
PATCHES="$HERE/patches/openwrt-${OWRT_VER%.*}"

# Pakete im Image: Standard des Profils plus/minus diese Liste.
# Kein DHCP/RA-Server, kein PPP, kein wpad (netifd fasst die Radios nicht an).
IMAGE_PACKAGES="otm-bridge -dnsmasq -odhcpd-ipv6only -ppp -ppp-mod-pppoe -wpad-basic-wolfssl"
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
[ -f "sha256sums-$OWRT_VER" ] || curl -fsS -o "sha256sums-$OWRT_VER" "$DL_BASE/sha256sums"
for t in "$SDK_TAR" "$IB_TAR"; do
	[ -f "$t" ] || { log "lade $t"; curl -fsS -o "$t" "$DL_BASE/$t"; }
	grep " \*\?$t\$" "sha256sums-$OWRT_VER" | sed 's/ \*/  /' | sha256sum -c --quiet - || die "Pruefsumme $t"
done
SDK="$BUILD/${SDK_TAR%.tar.*}"
IB="$BUILD/${IB_TAR%.tar.*}"
[ -d "$SDK" ] || { log "entpacke SDK"; tar xf "$SDK_TAR"; }
[ -d "$IB" ]  || { log "entpacke ImageBuilder"; tar xf "$IB_TAR"; }

# --- 1. SDK: Feeds, Patches, Pakete ------------------------------------------

cd "$SDK"
if [ ! -f feeds.conf ]; then
	grep -E '^src-git(-full)? (base|packages) ' feeds.conf.default > feeds.conf
	echo "src-link otm $HERE/feed" >> feeds.conf
fi
log "feeds update/install"
./scripts/feeds update -a >/dev/null
./scripts/feeds install -p base mac80211 wireless-regdb >/dev/null
./scripts/feeds install -p otm otm-bridge >/dev/null

# Gepatchte Paketverzeichnisse immer vom sauberen Stand aus: kein Rest aus
# frueheren Laeufen (auch keine unversionierten Dateien) im Image.
MAC=package/kernel/mac80211
REGDB=package/firmware/wireless-regdb
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
rm -rf packages/otm && mkdir -p packages/otm
find "$SDK/bin" -name '*.ipk' \( -name "kmod-*" -o -name "wireless-regdb_*" -o -name "otm-bridge_*" \) \
	-exec cp {} packages/otm/ \;
# Nur die Pakete mit unserer Revision (kmods: ...-<ver>-$OTM_RELEASE_<arch>.ipk)
ls packages/otm/*-"$OTM_RELEASE"_*.ipk >/dev/null 2>&1 || die "keine Pakete mit Revision $OTM_RELEASE"

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
	cp bin/targets/$TARGET/$SUBTARGET/*"$prof"*.manifest "$OUT/$prof/" 2>/dev/null || true
	cp "$FILES/etc/otm-build-info" "$OUT/$prof/build-info"
	(cd "$OUT/$prof" && sha256sum *.bin > sha256sums)
done

log "fertig:"
find "$OUT" -name '*sysupgrade.bin' -newer "$FILES/etc/otm-build-info" -exec ls -la {} \;
