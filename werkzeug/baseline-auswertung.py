#!/usr/bin/env python3
# Wertet eine 24-h-Messung von baseline-24h.sh aus: its-24h.pcap (Radiotap)
# und counters.log. Ausgabe: Frames gesamt, GeoNetworking-Anteil, Frames je
# Stunde (Ortszeit), eindeutige Absender, RSSI-Verteilung, Zaehler-Deltas.
#
# Hinweis zur CRC-Quote aus den ath9k-Zaehlern: Sie enthaelt vor allem
# Fehlausloesungen am Rauschrand (siehe radiotap-auswertung.py), sie ist kein
# Mass fuer verlorene ITS-Frames.
#
# Aufruf: baseline-auswertung.py <verzeichnis> [--tz-offset 2]

import argparse, collections, datetime as dt, os, statistics, struct, sys

p = argparse.ArgumentParser()
p.add_argument('dir')
p.add_argument('--tz-offset', type=int, default=2, help='Ortszeit = UTC + N Stunden (CEST = 2)')
a = p.parse_args()

# Radiotap-Standardfelder Bit 0..14: (Groesse, Ausrichtung)
F = {0: (8, 8), 1: (1, 1), 2: (1, 1), 3: (4, 2), 4: (2, 1), 5: (1, 1), 6: (1, 1), 7: (2, 2),
     8: (2, 2), 9: (2, 2), 10: (1, 1), 11: (1, 1), 12: (1, 1), 13: (1, 1), 14: (2, 2)}

def frames(path):
	d = open(path, 'rb').read()
	e = '<' if struct.unpack('<I', d[:4])[0] == 0xa1b2c3d4 else '>'
	i = 24
	while i + 16 <= len(d):
		ts, tu, cl, _ = struct.unpack(e + 'IIII', d[i:i + 16])
		pk = d[i + 16:i + 16 + cl]
		i += 16 + cl
		ln = struct.unpack('<H', pk[2:4])[0]
		o, words = 4, []
		while True:
			w = struct.unpack('<I', pk[o:o + 4])[0]
			words.append(w)
			o += 4
			if not w & 0x80000000:
				break
		r = {'ts': ts + tu / 1e6, 'flags': 0}
		for b in range(15):
			if not words[0] & (1 << b):
				continue
			sz, al = F[b]
			o = (o + al - 1) // al * al
			v = pk[o:o + sz]
			o += sz
			if b == 1: r['flags'] = v[0]
			elif b == 2: r['rate'] = v[0] / 2
			elif b == 3: r['freq'], r['chflags'] = struct.unpack('<HH', v)
			elif b == 5: r['sig'] = struct.unpack('b', v)[0]
		f = pk[ln:]
		if r['flags'] & 0x10 and len(f) >= 4:   # FCS am Ende
			f = f[:-4]
		r['len'] = len(f)
		fc = f[0] if f else 0
		typ, sub = (fc >> 2) & 3, fc >> 4
		r['type'] = {0: 'mgmt', 1: 'ctrl', 2: 'data'}.get(typ, '?')
		r['sa'] = f[10:16].hex(':') if len(f) >= 16 else ''
		r['bcast'] = f[4:10] == b'\xff' * 6
		hl = 24 + (2 if typ == 2 and sub & 8 else 0)
		snap = f[hl:hl + 8]
		r['ethertype'] = snap[6:8].hex() if len(snap) == 8 and snap[:6] == b'\xaa\xaa\x03\x00\x00\x00' else None
		r['its'] = r['ethertype'] == '8947'
		# GeoNetworking Basic Header: Version/NH, Common Header: NH (BTP/secured)
		gn = f[hl + 8:hl + 12] if r['its'] else b''
		r['gn_nh'] = {1: 'common', 2: 'secured'}.get(gn[0] & 0x0f, gn[0] & 0x0f) if gn else None
		r['bad'] = bool(r['flags'] & 0x40)
		yield r

fr = list(frames(os.path.join(a.dir, 'its-24h.pcap')))
its = [x for x in fr if x['its'] and not x['bad']]
tz = dt.timezone(dt.timedelta(hours=a.tz_offset))
print('== %s' % a.dir)
if fr:
	t0, t1 = fr[0]['ts'], fr[-1]['ts']
	print('Zeitraum: %s bis %s (%.1f h)' % (dt.datetime.fromtimestamp(t0, tz).strftime('%d.%m. %H:%M'),
		dt.datetime.fromtimestamp(t1, tz).strftime('%d.%m. %H:%M'), (t1 - t0) / 3600))
print('Frames im pcap: %d, davon CRC-markiert %d' % (len(fr), sum(x['bad'] for x in fr)))
print('Typen: %s' % dict(collections.Counter(x['type'] for x in fr)))
print('Ethertypes: %s' % dict(collections.Counter(x['ethertype'] for x in fr).most_common(6)))
print('ITS (GeoNetworking 0x8947): %d = %.1f %%, Broadcast %d, GN-Next-Header %s' % (
	len(its), 100 * len(its) / max(1, len(fr)), sum(x['bcast'] for x in its),
	dict(collections.Counter(x['gn_nh'] for x in its))))
s = sorted(x['sig'] for x in its if 'sig' in x)
if s:
	q = lambda p: s[min(len(s) - 1, int(p * len(s)))]
	print('RSSI ITS (dBm): min %d | 10 %% %d | Median %d | 90 %% %d | max %d' % (s[0], q(.1), q(.5), q(.9), s[-1]))
	hist = collections.Counter((v // 5) * 5 for v in s)
	print('RSSI-Klassen: ' + ' '.join('%d:%d' % (k, hist[k]) for k in sorted(hist)))
sa = collections.Counter(x['sa'] for x in its)
print('Eindeutige Absender (MAC, Pseudonyme wechseln): %d; Frames je Absender Median %d, max %d' % (
	len(sa), statistics.median(sa.values()) if sa else 0, max(sa.values()) if sa else 0))
print('Laenge ITS-Frames: Median %d Byte, Raten %s' % (statistics.median(x['len'] for x in its) if its else 0,
	dict(collections.Counter(x.get('rate') for x in its).most_common(3))))
ph = collections.Counter(dt.datetime.fromtimestamp(x['ts'], tz).hour for x in its)
print('ITS je Stunde (Ortszeit): ' + ' '.join('%02d:%d' % (h, ph.get(h, 0)) for h in range(24)))
# Absender je Stunde (grob: Anzahl verschiedener MACs)
psa = collections.defaultdict(set)
for x in its:
	psa[dt.datetime.fromtimestamp(x['ts'], tz).hour].add(x['sa'])
print('Absender je Stunde:        ' + ' '.join('%02d:%d' % (h, len(psa.get(h, ()))) for h in range(24)))

# Zaehler-Deltas aus counters.log
rows = [l.split() for l in open(os.path.join(a.dir, 'counters.log')) if l[0] != '#']
if len(rows) >= 2:
	f0, f1 = rows[0], rows[-1]
	dl = lambda k: int(f1[k]) - int(f0[k])
	print('Zaehler-Delta: rx_packets %d, pkts_all %d, crc_err %d (%.1f %% der Erkennungen), phy_err %d' % (
		dl(2), dl(4), dl(5), 100 * dl(5) / max(1, dl(4)), dl(6)))
	busy = [(int(r[8]), int(r[7])) for r in rows]
	print('Survey busy/active letzter Stand: %.2f %%, Rauschen %s dBm' % (
		100 * busy[-1][0] / max(1, busy[-1][1]), f1[10]))
