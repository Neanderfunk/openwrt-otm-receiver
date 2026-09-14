#!/usr/bin/env python3
# Erzeugt die ITS-G5-Patches (ath9k-Kanaele, ath-regd bis 5925 MHz, Half-Rate,
# regdb DE mit NO-IR) passend zu einem vorbereiteten OpenWrt-Baum, also gegen
# den Stand, auf dem sie in der Build-Reihenfolge aufsetzen. Die Kopftexte
# (Autor, Beschreibung) kommen aus einem vorhandenen Patchsatz.
#
# Aufruf:
#   its_patches_erzeugen.py <backports-dir> <regdb-dir> <ziel> [--vorlage patches/openwrt-21.02]
#     [--ath9k-dir ath9k]   Unterordner fuer die ath9k-Patches (21.02: ath)
#
# Bricht ab, wenn eine Ersetzung nicht genau einmal passt (Baum anders als erwartet).

import argparse, difflib, os, re, sys

p = argparse.ArgumentParser()
p.add_argument('backports'); p.add_argument('regdb'); p.add_argument('ziel')
p.add_argument('--vorlage', default=os.path.join(os.path.dirname(__file__), '..', 'patches', 'openwrt-21.02'))
p.add_argument('--ath9k-dir', default='ath9k')
a = p.parse_args()

def header(pfad):
	"""Kopftext eines Vorlagen-Patches bis vor die erste '--- a/'-Zeile."""
	s = open(pfad).read()
	return s[:s.index('--- a/')]

def diff(base, rel, repl):
	src = open(os.path.join(base, rel)).read()
	dst = src
	for old, new in repl:
		if dst.count(old) != 1:
			sys.exit('%s: Stelle nicht genau einmal gefunden:\n%s' % (rel, old))
		dst = dst.replace(old, new)
	return ''.join(difflib.unified_diff(src.splitlines(True), dst.splitlines(True), 'a/' + rel, 'b/' + rel))

chans = ''.join('\tCHAN5G(%d, %d), /* Channel %d%s */\n' % (5850 + 5 * i, 38 + i, 170 + i,
	' - IEEE CCH' if i == 8 else (' - EU ITS-G5 CCH' if i == 10 else '')) for i in range(16))
half = ('\t/*\n\t * ITS-G5 / DSRC: 5850-5925 MHz channels are regulatorily defined\n'
	'\t * as 10 MHz wide. cfg80211 / iw sometimes loses the width on the\n'
	'\t * way down (especially for monitor-mode interfaces) and we end up\n'
	'\t * here with chandef->width = NL80211_CHAN_WIDTH_20_NOHT. Force\n'
	'\t * half-rate based on the frequency alone so the PLL/PHY in hw.c\n'
	'\t * and ar9002_phy.c reprogram correctly without needing the chanbw\n'
	'\t * debugfs workaround.\n\t */\n'
	'\tif (chan->band == NL80211_BAND_5GHZ &&\n'
	'\t    chan->center_freq >= 5850 && chan->center_freq <= 5925)\n'
	'\t\tflags = (flags & CHANNEL_5GHZ) | CHANNEL_HALF;\n\n')

v = a.vorlage
b = a.backports
ath9k = os.path.join(a.ziel, 'mac80211', a.ath9k_dir)
ath = os.path.join(a.ziel, 'mac80211', 'ath')
reg = os.path.join(a.ziel, 'wireless-regdb')
for d in (ath9k, ath, reg):
	os.makedirs(d, exist_ok=True)

vorl = {os.path.basename(f): os.path.join(r, f) for r, _, fs in os.walk(v) for f in fs if f.endswith('.patch')}

out = {
	os.path.join(ath9k, '995-ath9k-its-g5-channels.patch'):
		header(vorl['995-ath9k-its-g5-channels.patch']) +
		diff(b, 'drivers/net/wireless/ath/ath9k/common-init.c',
			[('\tCHAN5G(5825, 37), /* Channel 165 */\n',
			  '\tCHAN5G(5825, 37), /* Channel 165 */\n\t/* ITS-G5 / 802.11p, 5850-5925 MHz */\n' + chans)]) +
		diff(b, 'drivers/net/wireless/ath/ath9k/hw.h',
			[('#define ATH9K_NUM_CHANNELS\t38\n', '#define ATH9K_NUM_CHANNELS\t54 /* + 16 ITS-G5 channels */\n')]),
	os.path.join(ath, '996-ath-regd-its-g5-5925.patch'):
		header(vorl['996-ath-regd-its-g5-5925.patch']) +
		diff(b, 'drivers/net/wireless/ath/regd.c',
			[('#define ATH_5GHZ_5470_5850\tREG_RULE(5470-10, 5850+10,', '#define ATH_5GHZ_5470_5850\tREG_RULE(5470-10, 5925+10,'),
			 ('#define ATH_5GHZ_5725_5850\tREG_RULE(5725-10, 5850+10,', '#define ATH_5GHZ_5725_5850\tREG_RULE(5725-10, 5925+10,')]),
	os.path.join(ath9k, '997-ath9k-force-half-rate-its-g5.patch'):
		header(vorl['997-ath9k-force-half-rate-its-g5.patch']) +
		diff(b, 'drivers/net/wireless/ath/ath9k/common.c',
			[('\t\tWARN_ON(1);\n\t}\n\n\tichan->channelFlags = flags;\n',
			  '\t\tWARN_ON(1);\n\t}\n\n' + half + '\tichan->channelFlags = flags;\n')]),
}

# regdb separat: Einfuegen direkt nach der SRD-Zeile im DE-Block
db = open(os.path.join(a.regdb, 'db.txt')).read()
m = re.search(r'country DE: DFS-ETSI\n(?:\t.*\n)*?(\t\(5725 - 5875 @ 80\), \(25 mW\)\n)', db)
if not m:
	sys.exit('db.txt: DE-Block mit SRD-Zeile nicht gefunden')
srd_ende = m.end()
neu = db[:srd_ende] + ('\t# ITS-G5 / 802.11p (ETSI EN 302 571), receive only: NO-IR keeps\n'
	'\t# monitor tuning possible but blocks OCB join and monitor injection\n'
	'\t(5850 - 5925 @ 20), (33), NO-IR\n') + db[srd_ende:]
out[os.path.join(reg, '600-regdb-DE-ITS-G5-receive-only.patch')] = (
	header(vorl['600-regdb-DE-ITS-G5-receive-only.patch']) +
	''.join(difflib.unified_diff(db.splitlines(True), neu.splitlines(True), 'a/db.txt', 'b/db.txt')))

for pfad, text in out.items():
	open(pfad, 'w').write(text)
	print('geschrieben:', os.path.relpath(pfad, a.ziel))
