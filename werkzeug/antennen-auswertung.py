#!/usr/bin/env python3
# Wertet Beacon-Mitschnitte zweier Empfaenger aus: je Access Point der mittlere
# RSSI und die Differenz zwischen den Geraeten, dazu der RSSI je Empfangskette
# (Antennenbuchse), den ath9k in weiteren Radiotap-Namensraeumen mitliefert.
#
# Aufruf: antennen-auswertung.py name=a.pcap name=b.pcap

import collections, statistics, struct, sys

F = {0: (8, 8), 1: (1, 1), 2: (1, 1), 3: (4, 2), 4: (2, 1), 5: (1, 1), 6: (1, 1), 7: (2, 2),
     8: (2, 2), 9: (2, 2), 10: (1, 1), 11: (1, 1), 12: (1, 1), 13: (1, 1), 14: (2, 2),
     15: (2, 2), 16: (2, 2), 17: (1, 1), 18: (1, 1), 19: (3, 1), 20: (8, 4), 21: (12, 2), 22: (12, 8)}

def beacons(path):
	d = open(path, 'rb').read()
	if len(d) < 24:
		return
	e = '<' if struct.unpack('<I', d[:4])[0] == 0xa1b2c3d4 else '>'
	i = 24
	while i + 16 <= len(d):
		ts, tu, cl, _ = struct.unpack(e + 'IIII', d[i:i + 16])
		pk = d[i + 16:i + 16 + cl]
		i += 16 + cl
		if len(pk) < cl or cl < 8:
			break
		ln = struct.unpack('<H', pk[2:4])[0]
		o, words = 4, []
		while True:
			w = struct.unpack('<I', pk[o:o + 4])[0]
			words.append(w)
			o += 4
			if not w & 0x80000000:
				break
		sig = None
		chains = {}          # Kette -> dBm
		ant = None
		for wi, w in enumerate(words):
			for b in range(23):
				if not w & (1 << b):
					continue
				sz, al = F.get(b, (0, 1))
				if not sz:
					continue
				o = (o + al - 1) // al * al
				v = pk[o:o + sz]
				o += sz
				if b == 5:
					s = struct.unpack('b', v)[0]
					if wi == 0:
						sig = s          # kombinierter Wert im Standard-Namensraum
					else:
						chains[ant if ant is not None else len(chains)] = s
				elif b == 11:
					ant = v[0]
		f = pk[ln:]
		if len(f) < 22 or f[0] != 0x80:   # nur Beacons
			continue
		yield f[16:22].hex(':'), sig, chains

rx = {}
for q in sys.argv[1:]:
	name, _, path = q.partition('=')
	per = collections.defaultdict(list)
	chains = collections.defaultdict(lambda: collections.defaultdict(list))
	for bssid, sig, ch in beacons(path):
		if sig is not None:
			per[bssid].append(sig)
		for k, v in ch.items():
			chains[bssid][k].append(v)
	rx[name] = (per, chains)

names = list(rx)
print('Beacons je Geraet: ' + ', '.join('%s %d' % (n, sum(len(v) for v in rx[n][0].values())) for n in names))
gemeinsam = set(rx[names[0]][0]) & set(rx[names[1]][0]) if len(names) > 1 else set(rx[names[0]][0])
print('%-18s %10s %10s %8s   Ketten' % ('BSSID', names[0], names[1] if len(names) > 1 else '', 'Diff'))
diffs = []
for b in sorted(gemeinsam, key=lambda x: -statistics.median(rx[names[0]][0][x])):
	a = statistics.median(rx[names[0]][0][b])
	z = statistics.median(rx[names[1]][0][b]) if len(names) > 1 else float('nan')
	diffs.append(a - z)
	ket = ' | '.join('%s: %s' % (n, ', '.join('K%d %d' % (k, statistics.median(v))
		for k, v in sorted(rx[n][1][b].items()))) for n in names if rx[n][1][b])
	print('%-18s %7.0f dBm %7.0f dBm %+6.1f   %s' % (b, a, z, a - z, ket))
if diffs:
	print('\nMedian ueber alle Access Points: %+.1f dB (%s gegen %s)' % (
		statistics.median(diffs), names[0], names[1]))
