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
#   otm_node_problem{node,problem}  1 (Geraet kann nicht empfangen, z. B.
#                           "no_its_radio phy0:2.4GHz"; aus otm/<node>/problem
#                           retained, ab 0.18.3; nur solange in PROBLEM_MAX gemeldet)
#   otm_rx_{cap,pkts,crc,phy,active,busy,rxt}{node}  Zaehler aus
#                           otm/<node>/health (ab 0.16.0), otm_rx_noise{node} dBm
#   otm_speed_sum{lat,lon}  Summe der Geschwindigkeiten (km/h) je Rasterzelle,
#   otm_speed_n{lat,lon}    und Zahl der Meldungen; nur fahrende Fahrzeuge (Stationstyp
#                           1-11, keine RSU, ab VSTEHT km/h), jeder Frame einmal;
#                           Mittel = sum/n
#   otm_speed_max{lat,lon}  hoechste Geschwindigkeit der Minute je Zelle (Gauge,
#                           nur geschrieben, wenn es Meldungen gab)
#   otm_hour_{fz,vsum,vn,vmax}{wd,h}  je abgeschlossener Stunde (Europe/Berlin), in
#                           der mindestens ein Empfaenger online war, ein Wert mit dem
#                           Zeitstempel des Stundenendes: verschiedene Fahrzeuge,
#                           Summe und Zahl der Geschwindigkeiten fahrender Fahrzeuge
#                           (ab VSTEHT), hoechste km/h (nur wenn es Fahrzeuge gab).
#                           Grafana: avg_over_time(fz), sum(vsum)/sum(vn),
#                           max_over_time(vmax). Seit 20.10.2026; davor kumulative
#                           otm_traffic_*-Zaehler, die increase() bei einem Sprung je
#                           Woche falsch auswertete. Die Stunde, in der otm-stats
#                           startet, zaehlt unvollstaendig
#   otm_speed_node_{sum,n,max}{node,lat,lon}, otm_hour_node_{fz,vsum,vn,vmax}{node,wd,h}
#                           dasselbe je Empfaenger (was er gehoert hat; Stunden, in
#                           denen er online war).
#                           Eigene Namen, damit Summen ueber die Gesamtwerte
#                           nicht doppelt zaehlen
#
# Umbenennen: Feste Kennung eines Empfaengers ist die MAC seines ITS-Radios
# (emac aus its/<node>/info, ab 0.18.4 auch mac in otm/<node>/build). Meldet
# sich eine bekannte MAC unter neuem Namen, schreibt otm-stats alle Reihen des
# alten Namens in VictoriaMetrics auf den neuen um (Export, Import, Loeschen;
# Werte ab dem ersten des neuen Namens fallen weg). Grafana fragt weiter nach
# node und sieht einen durchgehenden Verlauf unter dem aktuellen Namen.
# Zuordnung in $STATE_DIRECTORY/namen.json; von Hand:
#   otm-stats.py --umbenennen <alt> <neu>
#
# Absenderposition: Long Position Vector aus dem GeoNetworking-Header (bei
# signierten Paketen im unsecuredData-Teil von IEEE 1609.2), gerundet auf
# Raster RASTER_LAT x RASTER_LON Grad (seit 19.10.2026 ~50 x 50 m um 50 Grad Nord;
# vorher 3 Nachkommastellen, ~110 x 70 m). Aus
# demselben Vektor: Stationstyp (aus der GN-Adresse) und Geschwindigkeit.
import json, os, re, struct, sys, threading, time, urllib.parse, urllib.request, collections, datetime
from zoneinfo import ZoneInfo
import paho.mqtt.client as mqtt

FENSTER = 5
RASTER_LAT = 0.00045                 # ~50 m Nord-Sued
RASTER_LON = 0.0007                  # ~50 m Ost-West bei 50 Grad Nord
VMBASE = 'http://127.0.0.1:8428'
VM = VMBASE + '/write'
STATE = os.path.join(os.environ.get('STATE_DIRECTORY', '/var/lib/otm-stats'), 'namen.json')
namen = {}                       # mac -> aktueller Name
umbenannt = {}                   # alter Name -> neuer (retained Reste des alten ignorieren)
mqtt_client = None               # zum Loeschen retained Reste unter otm/<alter Name>/
# Zaehler/Gauges, deren Label der Knoten ist bzw. mit ihm beginnt
KNOTEN_LABEL = ('frames', 'exclusive', 'mqtt', 'node_online', 'node_uptime')
KNOTEN_TUPEL = ('pos', 'speed_node_sum', 'speed_node_n')
lock = threading.Lock()
offen = {}                       # key -> [erste_zeit, set(nodes)]
zaehler = collections.Counter()  # (metrik, label) -> Wert, kumulativ
gauges = {}                      # (metrik, label) -> Wert
firmware = {}                    # node -> {version, commit, bridge, model}
standorte = {}                   # node -> (lat, lon)
gesundheit = {}                  # node -> (zeit, {feld: wert}) aus otm/<node>/health
probleme = {}                    # node -> (zeit, text) aus otm/<node>/problem
PROBLEM_MAX = 3 * 3600           # Knoten meldet stuendlich; laenger still: nicht mehr zeigen
GESUND_MAX = 300                 # aeltere Health-Werte nicht weiterschreiben (offline != taub)
offline_seit = {}                # node -> Zeitpunkt der Offline-Meldung (seit Start von otm-stats)
OFFLINE_MAX = 86400              # laenger offline: nicht mehr fortschreiben (faellt aus den Tabellen)
stunde = {'id': None}             # laufende Stunde: Fahrzeuge gesamt und je Empfaenger
FAHRZEUG = range(1, 12)          # ETSI StationType: 1 Fussgaenger .. 11 Tram; 15 = RSU
VMAX = 250                       # km/h, darueber unplausibel
VSTEHT = 1                       # km/h, darunter steht es: zaehlt nicht in Mittelwerte
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
	return ('%.5f' % (round(lat / RASTER_LAT) * RASTER_LAT), '%.5f' % (round(lon / RASTER_LON) * RASTER_LON)), fz

def on_message(c, u, m):
	t = m.topic.split('/')
	if len(t) == 3 and t[1] in umbenannt and t[2] not in ('info', 'build'):
		return
	if len(t) == 3 and t[0] == 'otm' and t[2] == 'location':
		with lock:
			try:
				l = json.loads(m.payload)
				standorte[t[1]] = ('%.6f' % float(l['lat']), '%.6f' % float(l['lon']))
			except Exception:
				standorte.pop(t[1], None)   # leer = nicht (mehr) geteilt
		return
	if len(t) == 3 and t[0] == 'otm' and t[2] == 'problem':
		with lock:
			try:
				probleme[t[1]] = (time.time(), str(json.loads(m.payload)['problem'])[:120])
			except Exception:
				probleme.pop(t[1], None)    # leer = Geraet empfaengt wieder
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
			kennen(t[1], str(b.get('mac', '')))
			# retained build eines umbenannten Namens: nicht wieder als Empfaenger fuehren
			if t[1] not in umbenannt:
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
			kennen(node, str(i.get('emac', '')))
			if node not in umbenannt:
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

def namen_laden():
	try:
		z = json.load(open(STATE))
		namen.update(z.get('namen', {}))
		umbenannt.update(z.get('umbenannt', {}))
	except Exception:
		pass

def namen_speichern():
	try:
		os.makedirs(os.path.dirname(STATE), exist_ok=True)
		with open(STATE + '.neu', 'w') as f:
			json.dump({'namen': namen, 'umbenannt': umbenannt}, f, indent=1, sort_keys=True)
		os.replace(STATE + '.neu', STATE)
	except Exception as e:
		print('Zustand:', e, flush=True)

def kennen(name, mac):
	"""name meldet sich mit mac (unter lock). Neuer Name fuer bekannte MAC:
	alten Namen vergessen und in der Datenbank umschreiben."""
	mac = mac.lower()
	if not re.fullmatch(r'([0-9a-f]{2}:){5}[0-9a-f]{2}', mac) or mac == '00:00:00:00:00:00':
		return
	if umbenannt.pop(name, None) is not None:
		namen_speichern()                 # alter Name wieder in Gebrauch
	alt = namen.get(mac)
	if alt == name:
		return
	namen[mac] = name
	# alter Name gehoert inzwischen einem anderen Geraet: nichts umschreiben
	if alt and alt not in namen.values():
		umbenannt[alt] = name
		vergessen(alt, name)
		# unsere eigenen retained Nachrichten des alten Namens am Proxy loeschen
		# (otm/# geht nicht an OpenTrafficMap; its/<alt>/status bleibt dort stehen)
		if mqtt_client:
			for x in ('build', 'location', 'problem'):
				mqtt_client.publish('otm/%s/%s' % (alt, x), b'', retain=True)
		threading.Thread(target=db_umbenennen, args=(alt, name, 90), daemon=True).start()
	namen_speichern()

def vergessen(alt, neu):
	"""Laufende Werte des alten Namens nicht weiter schreiben (unter lock).
	Zaehler beginnen unter dem neuen Namen bei 0, das wertet increase() als
	Zaehler-Neustart."""
	for d in (zaehler, gauges):
		for k in [k for k in d if k[1] == alt or (isinstance(k[1], tuple) and k[1][:1] == (alt,)
		                                          and (k[0] in KNOTEN_TUPEL or k[0].startswith('traffic_node_')))]:
			del d[k]
	for d in (firmware, standorte, gesundheit, offline_seit, probleme):
		d.pop(alt, None)
	for v in offen.values():
		if alt in v[1]:
			v[1].discard(alt)
			v[1].add(neu)
	if stunde.get('knoten') and alt in stunde['knoten']:
		stunde['knoten'].discard(alt)
		stunde['knoten'].add(neu)
	if stunde.get('nfz') and alt in stunde['nfz']:
		stunde['nfz'][neu] |= stunde['nfz'].pop(alt)
	if stunde.get('nv') and alt in stunde['nv']:
		a, b = stunde['nv'].pop(alt), stunde['nv'][neu]
		b[0] += a[0]
		b[1] += a[1]
		if a[2] is not None:
			b[2] = a[2] if b[2] is None else max(b[2], a[2])

def vm_schluessel():
	for f in (os.path.join(os.environ.get('CREDENTIALS_DIRECTORY', '/nonexistent'), 'vm'),
	          '/etc/default/victoria-metrics'):
		try:
			k = re.search(r'deleteAuthKey=([0-9a-f]+)', open(f).read())
			if k:
				return k.group(1)
		except OSError:
			pass
	return None

def db_umbenennen(alt, neu, warten=0):
	"""Alle Reihen node=alt in VictoriaMetrics nach node=neu umschreiben."""
	time.sleep(warten)          # letzte Minute unter altem Namen ist geschrieben
	sel = '{node="%s"}' % alt.replace('\\', '\\\\').replace('"', '\\"')
	try:
		key = vm_schluessel()
		if not key:
			raise RuntimeError('kein deleteAuthKey')
		q = 'min(tfirst_over_time({node="%s"}[800d]))' % neu.replace('\\', '\\\\').replace('"', '\\"')
		r = json.load(urllib.request.urlopen(VMBASE + '/api/v1/query?query=' + urllib.parse.quote(q), timeout=120))
		res = r['data']['result']
		t0 = float(res[0]['value'][1]) * 1000 if res else None
		roh = urllib.request.urlopen(VMBASE + '/api/v1/export?match[]=' + urllib.parse.quote(sel), timeout=600).read()
		zeilen, n = [], 0
		for l in roh.splitlines():
			o = json.loads(l)
			o['metric']['node'] = neu
			if t0 is not None:
				paare = [(v, t) for v, t in zip(o['values'], o['timestamps']) if t < t0]
				o['values'], o['timestamps'] = [v for v, _ in paare], [t for _, t in paare]
			if o['timestamps']:
				zeilen.append(json.dumps(o))
				n += len(o['timestamps'])
		if zeilen:
			urllib.request.urlopen(VMBASE + '/api/v1/import', '\n'.join(zeilen).encode(), timeout=600).read()
		urllib.request.urlopen(VMBASE + '/api/v1/admin/tsdb/delete_series?authKey=%s&match[]=%s'
		                       % (key, urllib.parse.quote(sel)), timeout=120).read()
		urllib.request.urlopen(VMBASE + '/internal/resetRollupResultCache?authKey=' + key, timeout=60).read()
		print('umbenannt: %s -> %s, %d Reihen, %d Werte' % (alt, neu, len(zeilen), n), flush=True)
	except Exception as e:
		print('umbenennen %s -> %s gescheitert: %s' % (alt, neu, e), flush=True)

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
	nv = collections.defaultdict(lambda: [0.0, 0, None])   # node -> [Summe, Zahl, hoechste km/h]
	vhoch = None                     # hoechste km/h dieser Minute, alle Fahrzeuge
	stundenzeilen = []
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
				vhoch = fz if vhoch is None else max(vhoch, fz)
				if fz >= VSTEHT:
					vsum += fz
					vn += 1
				if pos:
					if fz >= VSTEHT:
						zaehler[('speed_sum', ('', pos))] += fz
						zaehler[('speed_n', ('', pos))] += 1
					vmax[('', pos)] = max(vmax.get(('', pos), 0), fz)
			for n in nodes:
				zaehler[('frames', n)] += 1
				if fz is not None:
					nfz[n].add(k[0])
					nv[n][2] = fz if nv[n][2] is None else max(nv[n][2], fz)
					if fz >= VSTEHT:
						nv[n][0] += fz
						nv[n][1] += 1
					if pos:
						if fz >= VSTEHT:
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
			if stunde['id'] is not None:     # vorige Stunde abschliessen: ein Wert je Stunde
				tag = ',wd=%s,h=%s' % stunde['slot']
				if stunde['online']:
					f = 'hour_fz=%d,hour_vsum=%.1f,hour_vn=%d' % (len(stunde['fz']), stunde['vsum'], stunde['vn'])
					if stunde['vmax'] is not None:
						f += ',hour_vmax=%.1f' % stunde['vmax']
					stundenzeilen.append('otm%s %s' % (tag, f))
				for n in stunde['knoten']:
					w = stunde['nv'].get(n, [0.0, 0, None])
					f = 'hour_node_fz=%d,hour_node_vsum=%.1f,hour_node_vn=%d' % (len(stunde['nfz'].get(n, ())), w[0], w[1])
					if w[2] is not None:
						f += ',hour_node_vmax=%.1f' % w[2]
					stundenzeilen.append('otm,node=%s%s %s' % (esc(n), tag, f))
			stunde.update(id=sid, slot=slot, fz=set(), nfz=collections.defaultdict(set), knoten=set(),
			              online=False, vsum=0.0, vn=0, vmax=None,
			              nv=collections.defaultdict(lambda: [0.0, 0, None]))
		stunde['fz'] |= fahrzeuge
		stunde['vsum'] += vsum
		stunde['vn'] += vn
		if vhoch is not None:
			stunde['vmax'] = vhoch if stunde['vmax'] is None else max(stunde['vmax'], vhoch)
		for n, f in nfz.items():
			stunde['nfz'][n] |= f
		for n, (a_, b_, c_) in nv.items():
			w = stunde['nv'][n]
			w[0] += a_
			w[1] += b_
			if c_ is not None:
				w[2] = c_ if w[2] is None else max(w[2], c_)
		for (m, n), v in list(gauges.items()):
			if m == 'node_online' and v == 1:
				stunde['knoten'].add(n)
				stunde['online'] = True
		weg = {n for n, t in offline_seit.items() if now - t > OFFLINE_MAX}
		werte = list(zaehler.items()) + [(k, v) for k, v in gauges.items()
		                                 if not (k[0] in ('node_online', 'node_uptime') and k[1] in weg)]
		fw = {n: dict(f) for n, f in firmware.items() if n not in weg}
		orte = {n: o for n, o in standorte.items() if n not in weg}
		gesund = {n: dict(w) for n, (z, w) in gesundheit.items() if now - z < GESUND_MAX}
		probl = {n: p for n, (z, p) in probleme.items() if now - z < PROBLEM_MAX}
	ts = int(now) * 10**9
	zeilen = []
	for (metrik, label), wert in werte:
		if metrik == 'receivers_n':
			tag = ',n=' + label
		elif metrik in ('pos', 'pos_union', 'speed_sum', 'speed_n', 'speed_node_sum', 'speed_node_n'):
			n, (lat, lon) = label
			tag = (',node=' + n.replace(' ', '_').replace(',', '_') if n else '') + ',lat=%s,lon=%s' % (lat, lon)
		elif label:
			tag = ',node=' + label.replace(' ', '_').replace(',', '_')
		else:
			tag = ''
		zeilen.append('otm%s %s=%s %d' % (tag, metrik, round(wert, 1) if isinstance(wert, float) else wert, ts))
	zeilen += ['%s %d' % (z, ts) for z in stundenzeilen]
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
	for n, p in probl.items():
		zeilen.append('otm,node=%s,problem=%s node_problem=1 %d' % (esc(n), esc(p) or '-', ts))
	if zeilen:
		try:
			urllib.request.urlopen(VM, '\n'.join(zeilen).encode(), timeout=10)
		except Exception as e:
			print('VictoriaMetrics:', e, flush=True)

def main():
	if len(sys.argv) == 4 and sys.argv[1] == '--umbenennen':
		# von Hand, bei angehaltenem Dienst: Datenbank umschreiben und den
		# alten Namen merken (retained Reste nicht wieder als Empfaenger zaehlen)
		db_umbenennen(sys.argv[2], sys.argv[3])
		namen_laden()
		umbenannt[sys.argv[2]] = sys.argv[3]
		namen_speichern()
		d = os.stat(os.path.dirname(STATE))
		for f in (STATE,):
			os.chown(f, d.st_uid, d.st_gid)
		return
	namen_laden()
	global mqtt_client
	c = mqtt_client = mqtt.Client(client_id='otm-stats')
	c.on_message = on_message
	c.on_connect = lambda c, u, f, rc: c.subscribe([('its/#', 0), ('otm/+/build', 0), ('otm/+/location', 0), ('otm/+/health', 0), ('otm/+/problem', 0)])
	c.connect_async('127.0.0.1', 1883, 60)
	c.loop_start()
	while True:
		time.sleep(60 - time.time() % 60)
		auswerten()

if __name__ == '__main__':
	main()
