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
import json, threading, time, urllib.request, collections
import paho.mqtt.client as mqtt

FENSTER = 5
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
				offen.setdefault(k, [now, set()])[1].add(node)
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
			nodes = offen.pop(k)[1]
			stationen.add(k[0])
			zaehler[('union_frames', '')] += 1
			zaehler[('receivers_n', str(len(nodes)))] += 1
			for n in nodes:
				zaehler[('frames', n)] += 1
				if len(nodes) == 1:
					zaehler[('exclusive', n)] += 1
		gauges[('union_stations', '')] = len(stationen)
		werte = list(zaehler.items()) + list(gauges.items())
	ts = int(now) * 10**9
	zeilen = []
	for (metrik, label), wert in werte:
		if metrik == 'receivers_n':
			tag = ',n=' + label
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
