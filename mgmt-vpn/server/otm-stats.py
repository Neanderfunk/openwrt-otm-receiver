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
#   otm_node_build{node,version,commit,bridge,model}  1 (Firmware-Stand, aus
#                           otm/<node>/build retained; aeltere Bridges nur
#                           bridge/model aus its/<node>/info beim Verbinden)
#   otm_node_location{node,lat,lon}  1 (Empfaengerposition, nur wenn der Knoten
#                           sie teilt: otm/<node>/location retained, ab 0.15.0)
#   otm_rx_{cap,pkts,crc,phy,active,busy,rxt}{node}  Zaehler aus
#                           otm/<node>/health (ab 0.16.0), otm_rx_noise{node} dBm
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
firmware = {}                    # node -> {version, commit, bridge, model}
standorte = {}                   # node -> (lat, lon)
gesundheit = {}                  # node -> (zeit, {feld: wert}) aus otm/<node>/health
GESUND_MAX = 300                 # aeltere Health-Werte nicht weiterschreiben (offline != taub)

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
	if len(t) == 3 and t[0] == 'otm' and t[2] == 'location':
		with lock:
			try:
				l = json.loads(m.payload)
				standorte[t[1]] = ('%.6f' % float(l['lat']), '%.6f' % float(l['lon']))
			except Exception:
				standorte.pop(t[1], None)   # leer = nicht (mehr) geteilt
		return
	if len(t) == 3 and t[0] == 'otm' and t[2] == 'health':
		try:
			h = json.loads(m.payload)
			werte = {k: int(h[k]) for k in ('cap', 'pkts', 'crc', 'phy', 'active', 'busy', 'rxt')
			         if k in h and int(h[k]) >= 0}
			if int(h.get('noise', 0)) < 0:
				werte['noise'] = int(h['noise'])
		except Exception:
			return
		with lock:
			gesundheit[t[1]] = (time.time(), werte)
		return
	if len(t) == 3 and t[0] == 'otm' and t[2] == 'build':
		try:
			b = json.loads(m.payload)
		except Exception:
			return
		with lock:
			firmware[t[1]] = {k: str(b.get(k, '')) for k in ('version', 'commit', 'bridge', 'model')}
		return
	if len(t) != 3 or t[0] != 'its':
		return
	node, art = t[1], t[2]
	if art == 'info':
		try:
			i = json.loads(m.payload)
		except Exception:
			return
		with lock:
			f = firmware.setdefault(node, {'version': '', 'commit': ''})
			f['bridge'] = str(i.get('ver', '')).replace('otm-bridge-', '')
			f['model'] = str(i.get('hwv', ''))
		return
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
			if m.payload:
				gauges[('node_online', node)] = 1 if m.payload == b'online' else 0
			else:
				# leere retained Meldung: Station abgebaut, aus der Statistik nehmen
				gauges.pop(('node_online', node), None)
				gauges.pop(('node_uptime', node), None)
				firmware.pop(node, None)
				standorte.pop(node, None)
				gesundheit.pop(node, None)

def esc(v):
	"""Tag-Wert fuer das Influx-Line-Protokoll."""
	return v.replace('\\', '').replace(' ', '\\ ').replace(',', '\\,').replace('=', '\\=')

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
		fw = {n: dict(f) for n, f in firmware.items()}
		orte = dict(standorte)
		gesund = {n: dict(w) for n, (z, w) in gesundheit.items() if now - z < GESUND_MAX}
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
	for n, f in fw.items():
		tags = ''.join(',%s=%s' % (k, esc(f.get(k) or '-')) for k in ('version', 'commit', 'bridge', 'model'))
		zeilen.append('otm,node=%s%s node_build=1 %d' % (esc(n), tags, ts))
	for n, w in gesund.items():
		if w:
			felder = ','.join('rx_%s=%d' % (k, v) for k, v in sorted(w.items()))
			zeilen.append('otm,node=%s %s %d' % (esc(n), felder, ts))
	for n, (lat, lon) in orte.items():
		zeilen.append('otm,node=%s,lat=%s,lon=%s node_location=1 %d' % (esc(n), lat, lon, ts))
	if zeilen:
		try:
			urllib.request.urlopen(VM, '\n'.join(zeilen).encode(), timeout=10)
		except Exception as e:
			print('VictoriaMetrics:', e, flush=True)

def main():
	c = mqtt.Client(client_id='otm-stats')
	c.on_message = on_message
	c.on_connect = lambda c, u, f, rc: c.subscribe([('its/#', 0), ('otm/+/build', 0), ('otm/+/location', 0), ('otm/+/health', 0)])
	c.connect_async('127.0.0.1', 1883, 60)
	c.loop_start()
	while True:
		time.sleep(60 - time.time() % 60)
		auswerten()

if __name__ == '__main__':
	main()
