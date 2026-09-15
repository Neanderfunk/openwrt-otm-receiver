#!/usr/bin/env python3
# Frame-fuer-Frame-Vergleich mehrerer ITS-Empfaenger am selben Ort.
#
# Eingaben: pcap-Mitschnitte (Radiotap, von mon0) und/oder MQTT-Mitschnitte
# (Zeile "<unixzeit> <hex>" wie von mosquitto_sub -F '%U %x', Payload = rohes
# 802.11-Frame ohne Radiotap). Gleicher Frame = gleiche Absender-MAC,
# gleiche Sequenznummer und gleicher Anfang des Inhalts (unabhaengig davon,
# ob ein Empfaenger die FCS mitschickt).
#
# Aufruf: vergleich.py name=datei.pcap name=datei.log [...] [--von UNIX] [--bis UNIX]

import argparse, collections, datetime as dt, statistics, struct, sys

p = argparse.ArgumentParser()
p.add_argument('quellen', nargs='+', help='name=pfad (.pcap oder MQTT-Log)')
p.add_argument('--von', type=float, default=0)
p.add_argument('--bis', type=float, default=1e12)
p.add_argument('--tz-offset', type=int, default=2)
a = p.parse_args()

F = {0: (8, 8), 1: (1, 1), 2: (1, 1), 3: (4, 2), 4: (2, 1), 5: (1, 1)}

def key(f):
	"""(SA, Sequenz, Inhaltsanfang) fuer ITS-Datenframes, sonst None."""
	if len(f) < 40 or ((f[0] >> 2) & 3) != 2:
		return None
	hl = 24 + (2 if f[0] >> 4 & 8 else 0)
	if f[hl:hl + 8] != b'\xaa\xaa\x03\x00\x00\x00\x89\x47':
		return None
	return (f[10:16], f[22:24], f[hl:hl + 96])

def pcap(path):
	d = open(path, 'rb').read()
	e = '<' if struct.unpack('<I', d[:4])[0] == 0xa1b2c3d4 else '>'
	i = 24
	while i + 16 <= len(d):
		ts, tu, cl, _ = struct.unpack(e + 'IIII', d[i:i + 16])
		pk = d[i + 16:i + 16 + cl]
		i += 16 + cl
		if len(pk) < cl:        # letzter Datensatz noch nicht fertig geschrieben
			break
		ln = struct.unpack('<H', pk[2:4])[0]
		o, w = 4, []
		while True:
			x = struct.unpack('<I', pk[o:o + 4])[0]; w.append(x); o += 4
			if not x & 0x80000000: break
		flags, sig = 0, None
		for b in range(6):
			if not w[0] & (1 << b): continue
			sz, al = F[b]; o = (o + al - 1) // al * al; v = pk[o:o + sz]; o += sz
			if b == 1: flags = v[0]
			elif b == 5: sig = struct.unpack('b', v)[0]
		if flags & 0x40:
			continue            # CRC-fehlerhaft
		k = key(pk[ln:])
		if k:
			yield ts + tu / 1e6, k, sig

def mqttlog(path):
	for l in open(path):
		t, _, h = l.strip().partition(' ')
		try:
			k = key(bytes.fromhex(h))
		except ValueError:
			continue
		if k:
			yield float(t), k, None

rx = {}
for q in a.quellen:
	name, _, path = q.partition('=')
	gen = pcap(path) if path.endswith('.pcap') else mqttlog(path)
	m = {}
	for t, k, s in gen:
		if a.von <= t <= a.bis and k not in m:
			m[k] = (t, s)
	rx[name] = m

names = list(rx)
alle = set().union(*[set(m) for m in rx.values()])
tz = dt.timezone(dt.timedelta(hours=a.tz_offset))
ts_all = [v[0] for m in rx.values() for v in m.values()]
if ts_all:
	print('Zeitraum: %s bis %s' % (dt.datetime.fromtimestamp(min(ts_all), tz).strftime('%d.%m. %H:%M'),
		dt.datetime.fromtimestamp(max(ts_all), tz).strftime('%d.%m. %H:%M')))
print('Verschiedene ITS-Frames insgesamt (Vereinigung): %d' % len(alle))
for n in names:
	print('  %-10s %5d Frames = %5.1f %% der Vereinigung' % (n, len(rx[n]), 100 * len(rx[n]) / max(1, len(alle))))
print('Aufteilung (wer hat den Frame):')
kombi = collections.Counter(tuple(n for n in names if k in rx[n]) for k in alle)
for c, v in kombi.most_common():
	print('  %-32s %5d' % ('+'.join(c), v))
for i, x in enumerate(names):
	for y in names[i + 1:]:
		ge = [k for k in rx[x] if k in rx[y]]
		d = [rx[x][k][1] - rx[y][k][1] for k in ge if rx[x][k][1] is not None and rx[y][k][1] is not None]
		dts = [rx[x][k][0] - rx[y][k][0] for k in ge]
		extra = ''
		if d:
			extra += ', RSSI %s-%s: Median %+.0f dB' % (x, y, statistics.median(d))
		if dts:
			extra += ', Zeitversatz Median %+.2f s' % statistics.median(dts)
		print('Paar %s/%s: gemeinsam %d, nur %s %d, nur %s %d%s' % (
			x, y, len(ge), x, len(rx[x]) - len(ge), y, len(rx[y]) - len(ge), extra))
print('Je Stunde (Ortszeit):')
for n in names:
	c = collections.Counter(dt.datetime.fromtimestamp(v[0], tz).hour for v in rx[n].values())
	print('  %-10s ' % n + ' '.join('%02d:%d' % (h, c[h]) for h in range(24) if c[h]))
for n in names:
	s = sorted(v[1] for v in rx[n].values() if v[1] is not None)
	if s:
		print('RSSI %-10s Median %d, 10 %% %d, 90 %% %d dBm' % (n, s[len(s) // 2], s[len(s) // 10], s[len(s) * 9 // 10]))
