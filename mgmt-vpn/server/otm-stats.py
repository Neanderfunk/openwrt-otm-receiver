#!/usr/bin/env python3
# Laufende Empfangsstatistik der OTM-Empfaenger: liest its/# am lokalen
# MQTT-Proxy mit und schreibt jede Minute Zaehler nach VictoriaMetrics
# (Influx-Line-Protokoll, /write). Gleicher Frame = gleiche Absender-MAC,
# Sequenznummer und Inhaltsanfang (wie werkzeug/vergleich.py), gesammelt
# in einem Fenster von FENSTER Sekunden ueber alle Empfaenger.
#
# Metriken (VictoriaMetrics: <messung>_<feld>):
#   otm_frames{node}        ITS-Frames, die dieser Empfaenger hatte
#   otm_exclusive{node}     davon solche, die kein anderer unserer Empfaenger hatte
#   otm_mqtt{node}          alle packet-Nachrichten (auch Nicht-ITS)
#   otm_union_frames        verschiedene ITS-Frames ueber alle Empfaenger
#   otm_union_stations      verschiedene Absender je Minute (Gauge)
#   otm_receivers_n{n}      Frames, die genau n Empfaenger hatten
#   otm_node_uptime{node}   Sekunden seit Boot (aus its/<node>/stats)
#   otm_node_online{node}   1 online, 0 offline (aus its/<node>/status)
#   otm_pos{node,lat,lon}   Frames je Rasterzelle der Absenderposition
#   otm_pos_union{lat,lon}  verschiedene Frames je Rasterzelle, alle Empfaenger
#
# Absenderposition: Long Position Vector aus dem GeoNetworking-Header (bei
# signierten Paketen im unsecuredData-Teil von IEEE 1609.2), gerundet auf
# RASTER Nachkommastellen (3 = ~110 m Nord-Sued, ~70 m Ost-West).
import json, struct, threading, time, urllib.request, collections
import paho.mqtt.client as mqtt

FENSTER = 5
RASTER = 3
VM = 'http://127.0.0.1:8428/write'
lock = threading.Lock()
offen = {}                       # key -> [erste_zeit, set(nodes)]
zaehler = collections.Counter()  # (metrik, label) -> Wert, kumulativ
gauges = {}                      # (metrik, label) -> Wert

def key(f):
	if len(f) < 40 or ((f[0] >> 2) & 3) != 2:
		return None
	hl = 24 + (2 if f[0] >> 4 & 8 else 0)
	if f[hl:hl + 8] != b'\xaa\xaa\x03\x00\x00\x00\x89\x47':
		return None
	return (f[10:16], f[22:24], f[hl:hl + 96])

def coer_len(b, i):
	n = b[i]
	if n < 0x80:
		return n, i + 1
	k = n & 0x7f
	return int.from_bytes(b[i + 1:i + 1 + k], 'big'), i + 1 + k

def position(f):
	"""Rasterzelle ('lat', 'lon') des Absenders oder None."""
	hl = 24 + (2 if f[0] >> 4 & 8 else 0)
	g = f[hl + 8:]
	if len(g) < 12:
		return None
	b = g[4:]
	if g[0] & 0x0f == 2:
		# Ieee1609Dot2Data{3, signedData{.. data{3, unsecuredData <laenge> ..}}}
		i = b.find(b'\x03\x80', 0, 12)
		if i < 0:
			return None
		_, j = coer_len(b, i + 2)
		b = b[j:]
	elif g[0] & 0x0f != 1:
		return None
	if len(b) < 8:
		return None
	ht, hst = b[1] >> 4, b[1] & 0x0f
	if ht == 1 or (ht == 5 and hst == 0):    # Beacon, SHB: SO PV direkt
		pv = b[8:]
	elif 2 <= ht <= 6:                        # GUC, GAC, GBC, TSB, LS: SN + reserviert
		pv = b[12:]
	else:
		return None
	if len(pv) < 20:
		return None
	lat, lon = struct.unpack('>ii', pv[12:20])
	lat, lon = lat / 1e7, lon / 1e7
	if not (-90 <= lat <= 90 and -180 <= lon <= 180) or (lat == 0 and lon == 0):
		return None
	return ('%.*f' % (RASTER, lat), '%.*f' % (RASTER, lon))

def on_message(c, u, m):
	t = m.topic.split('/')
	if len(t) != 3 or t[0] != 'its':
		return
	node, art = t[1], t[2]
	now = time.time()
	with lock:
		if art == 'packet':
			zaehler[('mqtt', node)] += 1
			k = key(m.payload)
			if k:
				if k not in offen:
					try:
						pos = position(m.payload)
					except Exception:
						pos = None
					offen[k] = [now, set(), pos]
				offen[k][1].add(node)
		elif art == 'stats':
			try:
				gauges[('node_uptime', node)] = json.loads(m.payload)['rbt']
			except Exception:
				pass
		elif art == 'status':
			gauges[('node_online', node)] = 1 if m.payload == b'online' else 0

def auswerten():
	now = time.time()
	stationen = set()
	with lock:
		fertig = [k for k, v in offen.items() if now - v[0] > FENSTER]
		for k in fertig:
			_, nodes, pos = offen.pop(k)
			stationen.add(k[0])
			zaehler[('union_frames', '')] += 1
			zaehler[('receivers_n', str(len(nodes)))] += 1
			if pos:
				zaehler[('pos_union', ('', pos))] += 1
			for n in nodes:
				zaehler[('frames', n)] += 1
				if len(nodes) == 1:
					zaehler[('exclusive', n)] += 1
				if pos:
					zaehler[('pos', (n, pos))] += 1
		gauges[('union_stations', '')] = len(stationen)
		werte = list(zaehler.items()) + list(gauges.items())
	ts = int(now) * 10**9
	zeilen = []
	for (metrik, label), wert in werte:
		if metrik == 'receivers_n':
			tag = ',n=' + label
		elif metrik in ('pos', 'pos_union'):
			n, (lat, lon) = label
			tag = (',node=' + n.replace(' ', '_').replace(',', '_') if n else '') + ',lat=%s,lon=%s' % (lat, lon)
		elif label:
			tag = ',node=' + label.replace(' ', '_').replace(',', '_')
		else:
			tag = ''
		zeilen.append('otm%s %s=%s %d' % (tag, metrik, wert, ts))
	if zeilen:
		try:
			urllib.request.urlopen(VM, '\n'.join(zeilen).encode(), timeout=10)
		except Exception as e:
			print('VictoriaMetrics:', e, flush=True)

def main():
	c = mqtt.Client(client_id='otm-stats')
	c.on_message = on_message
	c.on_connect = lambda c, u, f, rc: c.subscribe('its/#')
	c.connect_async('127.0.0.1', 1883, 60)
	c.loop_start()
	while True:
		time.sleep(60 - time.time() % 60)
		auswerten()

if __name__ == '__main__':
	main()
