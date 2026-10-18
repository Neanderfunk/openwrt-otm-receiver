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
#   otm_speed_sum{lat,lon}  Summe der Geschwindigkeiten (km/h) je Rasterzelle,
#   otm_speed_n{lat,lon}    und Zahl der Meldungen; nur Fahrzeuge (Stationstyp
#                           1-11, keine RSU), jeder Frame einmal; Mittel = sum/n
#   otm_speed_max{lat,lon}  hoechste Geschwindigkeit der Minute je Zelle (Gauge,
#                           nur geschrieben, wenn es Meldungen gab)
#   otm_traffic_fz{wd,h}    verschiedene Fahrzeuge je Minute, aufsummiert je
#   otm_traffic_min{wd,h}   Wochentag/Stunde (Europe/Berlin), dazu die Zahl der
#                           Minuten mit mindestens einem Empfaenger online;
#                           Mittel = fz/min
#   otm_traffic_speed_sum{wd,h}, otm_traffic_speed_n{wd,h}  Geschwindigkeit je
#                           Wochentag/Stunde wie oben
#   otm_traffic_fzh{wd,h}   verschiedene Fahrzeuge je ganzer Stunde, aufsummiert je
#   otm_traffic_hours{wd,h} Wochentag/Stunde, dazu die Zahl dieser Stunden (mit
#                           mindestens einem Empfaenger online); Mittel = fzh/hours.
#                           Gezaehlt beim Stundenwechsel; die Stunde, in der
#                           otm-stats startet, zaehlt unvollstaendig
#   otm_speed_node_{sum,n,max}{node,lat,lon}, otm_traffic_node_{fz,min,fzh,hours,
#                           speed_sum,speed_n}{node,wd,h}  dasselbe je Empfaenger (was er
#                           gehoert hat; min = Minuten, in denen er online war).
#                           Eigene Namen, damit Summen ueber die Gesamtwerte
#                           nicht doppelt zaehlen
#
# Absenderposition: Long Position Vector aus dem GeoNetworking-Header (bei
# signierten Paketen im unsecuredData-Teil von IEEE 1609.2), gerundet auf
# RASTER Nachkommastellen (3 = ~110 m Nord-Sued, ~70 m Ost-West). Aus
# demselben Vektor: Stationstyp (aus der GN-Adresse) und Geschwindigkeit.
import json, struct, threading, time, urllib.request, collections, datetime
from zoneinfo import ZoneInfo
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
offline_seit = {}                # node -> Zeitpunkt der Offline-Meldung (seit Start von otm-stats)
OFFLINE_MAX = 86400              # laenger offline: nicht mehr fortschreiben (faellt aus den Tabellen)
stunde = {'id': None}             # laufende Stunde: Fahrzeuge gesamt und je Empfaenger
FAHRZEUG = range(1, 12)          # ETSI StationType: 1 Fussgaenger .. 11 Tram; 15 = RSU
VMAX = 250                       # km/h, darueber unplausibel
TZ = ZoneInfo('Europe/Berlin')
TAGE = ('1-Mo', '2-Di', '3-Mi', '4-Do', '5-Fr', '6-Sa', '7-So')

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

def lpv(f):
	"""(Rasterzelle ('lat', 'lon'), Fahrzeug-km/h oder None) des Absenders, oder None."""
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
	if len(pv) < 24:
		return None
	lat, lon = struct.unpack('>ii', pv[12:20])
	lat, lon = lat / 1e7, lon / 1e7
	if not (-90 <= lat <= 90 and -180 <= lon <= 180) or (lat == 0 and lon == 0):
		return None
    # GN_ADDR: M(1) ST(5) ..; danach PAI(1) Speed(15, Zweierkomplement, 0.01 m/s)
	v = (pv[20] & 0x7f) << 8 | pv[21]
	kmh = abs(v - 0x8000 if v & 0x4000 else v) * 0.036
	fz = round(kmh, 1) if (pv[0] >> 2) & 0x1f in FAHRZEUG and kmh <= VMAX else None
	return ('%.*f' % (RASTER, lat), '%.*f' % (RASTER, lon)), fz

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
						pos, fz = lpv(m.payload) or (None, None)
					except Exception:
						pos, fz = None, None
					offen[k] = [now, set(), pos, fz]
				offen[k][1].add(node)
		elif art == 'stats':
			try:
				gauges[('node_uptime', node)] = json.loads(m.payload)['rbt']
			except Exception:
				pass
		elif art == 'status':
			if m.payload:
				online = m.payload == b'online'
				gauges[('node_online', node)] = 1 if online else 0
				if online:
					offline_seit.pop(node, None)
				else:
					offline_seit.setdefault(node, now)
			else:
				# leere retained Meldung: Station abgebaut, aus der Statistik nehmen
				gauges.pop(('node_online', node), None)
				gauges.pop(('node_uptime', node), None)
				firmware.pop(node, None)
				standorte.pop(node, None)
				gesundheit.pop(node, None)
				offline_seit.pop(node, None)

def esc(v):
	"""Tag-Wert fuer das Influx-Line-Protokoll."""
	return v.replace('\\', '').replace(' ', '\\ ').replace(',', '\\,').replace('=', '\\=')

def auswerten():
	now = time.time()
	stationen = set()
	fahrzeuge = set()
	vmax = {}                        # Zelle -> hoechste km/h dieser Minute
	vsum, vn = 0.0, 0
	nfz = collections.defaultdict(set)    # node -> Fahrzeuge dieser Minute
	nv = collections.defaultdict(lambda: [0.0, 0])
	with lock:
		fertig = [k for k, v in offen.items() if now - v[0] > FENSTER]
		for k in fertig:
			_, nodes, pos, fz = offen.pop(k)
			stationen.add(k[0])
			zaehler[('union_frames', '')] += 1
			zaehler[('receivers_n', str(len(nodes)))] += 1
			if pos:
				zaehler[('pos_union', ('', pos))] += 1
			if fz is not None:
				fahrzeuge.add(k[0])
				vsum += fz
				vn += 1
				if pos:
					zaehler[('speed_sum', ('', pos))] += fz
					zaehler[('speed_n', ('', pos))] += 1
					vmax[('', pos)] = max(vmax.get(('', pos), 0), fz)
			for n in nodes:
				zaehler[('frames', n)] += 1
				if fz is not None:
					nfz[n].add(k[0])
					nv[n][0] += fz
					nv[n][1] += 1
					if pos:
						zaehler[('speed_node_sum', (n, pos))] += fz
						zaehler[('speed_node_n', (n, pos))] += 1
						vmax[(n, pos)] = max(vmax.get((n, pos), 0), fz)
				if len(nodes) == 1:
					zaehler[('exclusive', n)] += 1
				if pos:
					zaehler[('pos', (n, pos))] += 1
		gauges[('union_stations', '')] = len(stationen)
		lt = datetime.datetime.fromtimestamp(now - 30, TZ)
		slot = (TAGE[lt.weekday()], '%02d' % lt.hour)
		sid = lt.strftime('%Y%m%d%H')
		if stunde['id'] != sid:
			if stunde['id'] is not None:     # vorige Stunde abschliessen
				if stunde['online']:
					zaehler[('traffic_fzh', stunde['slot'])] += len(stunde['fz'])
					zaehler[('traffic_hours', stunde['slot'])] += 1
				for n in stunde['knoten']:
					zaehler[('traffic_node_fzh', (n,) + stunde['slot'])] += len(stunde['nfz'].get(n, ()))
					zaehler[('traffic_node_hours', (n,) + stunde['slot'])] += 1
			stunde.update(id=sid, slot=slot, fz=set(), nfz=collections.defaultdict(set), knoten=set(), online=False)
		stunde['fz'] |= fahrzeuge
		for n, f in nfz.items():
			stunde['nfz'][n] |= f
		for (m, n), v in list(gauges.items()):
			if m == 'node_online' and v == 1:
				stunde['knoten'].add(n)
				stunde['online'] = True
				zaehler[('traffic_node_min', (n,) + slot)] += 1
				zaehler[('traffic_node_fz', (n,) + slot)] += len(nfz.get(n, ()))
				zaehler[('traffic_node_speed_sum', (n,) + slot)] += nv[n][0] if n in nv else 0.0
				zaehler[('traffic_node_speed_n', (n,) + slot)] += nv[n][1] if n in nv else 0
		if any(v == 1 for (m, _), v in gauges.items() if m == 'node_online'):
			zaehler[('traffic_min', slot)] += 1
			zaehler[('traffic_fz', slot)] += len(fahrzeuge)
			zaehler[('traffic_speed_sum', slot)] += vsum
			zaehler[('traffic_speed_n', slot)] += vn
		weg = {n for n, t in offline_seit.items() if now - t > OFFLINE_MAX}
		werte = list(zaehler.items()) + [(k, v) for k, v in gauges.items()
		                                 if not (k[0] in ('node_online', 'node_uptime') and k[1] in weg)]
		fw = {n: dict(f) for n, f in firmware.items() if n not in weg}
		orte = {n: o for n, o in standorte.items() if n not in weg}
		gesund = {n: dict(w) for n, (z, w) in gesundheit.items() if now - z < GESUND_MAX}
	ts = int(now) * 10**9
	zeilen = []
	for (metrik, label), wert in werte:
		if metrik == 'receivers_n':
			tag = ',n=' + label
		elif metrik.startswith('traffic_node_'):
			tag = ',node=%s,wd=%s,h=%s' % ((esc(label[0]),) + label[1:])
		elif metrik.startswith('traffic_'):
			tag = ',wd=%s,h=%s' % label
		elif metrik in ('pos', 'pos_union', 'speed_sum', 'speed_n', 'speed_node_sum', 'speed_node_n'):
			n, (lat, lon) = label
			tag = (',node=' + n.replace(' ', '_').replace(',', '_') if n else '') + ',lat=%s,lon=%s' % (lat, lon)
		elif label:
			tag = ',node=' + label.replace(' ', '_').replace(',', '_')
		else:
			tag = ''
		zeilen.append('otm%s %s=%s %d' % (tag, metrik, round(wert, 1) if isinstance(wert, float) else wert, ts))
	for (n, (lat, lon)), v in vmax.items():
		if n:
			zeilen.append('otm,node=%s,lat=%s,lon=%s speed_node_max=%s %d' % (esc(n), lat, lon, v, ts))
		else:
			zeilen.append('otm,lat=%s,lon=%s speed_max=%s %d' % (lat, lon, v, ts))
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
