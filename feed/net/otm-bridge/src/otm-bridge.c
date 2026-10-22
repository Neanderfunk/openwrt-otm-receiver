/*
 * otm-bridge: capture raw 802.11(p) frames from a Linux monitor interface
 * and publish them via MQTT to opentrafficmap.org's C-ITS ingest, mimicking
 * the wire format of opentrafficmap/its-g5-receiver-firmware (ESP32-C5).
 *
 * Topic layout (default broker mqtt://10.66.0.1, the MQTT proxy behind the
 * management VPN that forwards to mqtts://cits1.opentrafficmap.org):
 *   its/<node>/status   "online"/"offline" (LWT, retained)
 *   its/<node>/info     {"emac":"aa:bb:..","ver":"...","hwv":"..."}  (on connect)
 *   its/<node>/packet   raw 802.11 frame (radiotap stripped), QoS 0
 *   its/<node>/stats    {"rbt":<seconds since boot>}  (on connect, every 60 s)
 *   otm/<node>/build    {"version":"..","commit":"..","bridge":"..","model":"..",
 *                        "mac":".."}  (mac = emac, stable id across renames)
 *                       (on connect, retained; only with -V, i.e. via our proxy:
 *                       outside its/# so it is not forwarded to opentrafficmap)
 *   otm/<node>/location {"lat":..,"lon":..[,"alt":..]}  (on connect, retained;
 *                       only with -L; -L "" clears a previously shared one)
 *   otm/<node>/problem  {"problem":"..","bridge":".."} (retained; only with -E,
 *                       i.e. the device cannot receive at all, e.g. no radio
 *                       for 5.9 GHz; with -H an empty retained message clears
 *                       an earlier one)
 *   otm/<node>/health   receiver health every 60 s, only with -H:
 *                       {"cap":..,"pkts":..,"crc":..,"phy":..,"noise":..,
 *                        "active":..,"busy":..,"rxt":..}
 *                       cap = frames seen by pcap since start; pkts/crc/phy =
 *                       ath9k debugfs recv counters (all frames, CRC errors =
 *                       preamble seen but payload broken, PHY errors = energy
 *                       seen, nothing decodable); noise and channel times (ms)
 *                       from the nl80211 survey of the channel in use; -1
 *                       (noise: 0) if a source is missing. Cumulative; a deaf radio keeps
 *                       all of them at 0 for hours.
 *
 * <node> defaults to the capture interface MAC as 12 lowercase hex chars.
 */

#include <errno.h>
#include <fcntl.h>
#include <pcap.h>
#include <pthread.h>
#include <mosquitto.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define OTM_BRIDGE_VERSION "0.18.11"

static struct mosquitto *mosq;
static pcap_t *pc;
static volatile sig_atomic_t running = 1;
/* 0, solange keine Broker-Verbindung steht; siehe stats_thread */
static volatile sig_atomic_t mqtt_up;
static volatile sig_atomic_t mqtt_stop;
/* -x: Sekunden ohne Broker-Verbindung, nach denen der Prozess endet (0 = nie);
 * procd startet den Wrapper neu, der den Weg zum Broker neu waehlt */
static int giveup;

static char topic_packet[160];
static char topic_status[160];
static char topic_info[160];
static char topic_stats[160];
static char topic_build[160];
static char topic_location[160];
static char topic_health[160];
static char topic_problem[160];
static int health;                    /* -H */
static unsigned long pkt_captured;

/* -V/-G: Build-Nummer und Commit des Images (aus /etc/otm-build-info) */
static const char *build_version;
static const char *build_commit;
/* -L "lat,lon[,alt]" oder "" (Position nicht teilen, alte loeschen) */
static const char *location;
/* -E: Grund, warum das Geraet nicht empfangen kann; nur melden, kein pcap */
static const char *problem;
static volatile sig_atomic_t problem_sent;

static const char *cap_iface = "mon0";
static int verbose;
static unsigned long pkt_published;
static unsigned long pkt_pcap_err;

static void on_signal(int s)
{
	(void)s;
	running = 0;
	if (pc)
		pcap_breakloop(pc);
}

static int read_mac_hex12_from(const char *path, char *out13)
{
	char line[32];
	FILE *f = fopen(path, "r");
	if (!f)
		return -1;
	if (!fgets(line, sizeof(line), f)) { fclose(f); return -1; }
	fclose(f);

	int j = 0;
	for (int i = 0; line[i] && j < 12; i++) {
		char c = line[i];
		if (c == ':' || c == '-' || c == '\n' || c == '\r')
			continue;
		if (c >= 'A' && c <= 'F') c += 32;
		if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
			return -1;
		out13[j++] = c;
	}
	out13[12] = 0;
	return j == 12 ? 0 : -1;
}

/* Try a list of stable MAC sources. The capture interface comes first: a
 * monitor vif carries the permanent address of the radio that actually
 * receives (on dual-radio boards like the WDR4300 that is not phy0). eth0 is
 * intentionally last because on lantiq/DSA setups it often gets a
 * randomly-generated locally-administered address that changes per boot,
 * breaking the node identity across reboots. */
static int read_mac_hex12(const char *iface, char *out13)
{
	char path[96];
	snprintf(path, sizeof(path), "/sys/class/net/%s/address", iface);
	if (read_mac_hex12_from(path, out13) == 0)
		return 0;

	static const char *sources[] = {
		"/sys/class/ieee80211/phy0/macaddress",
		"/sys/class/net/lan1/address",
		"/sys/class/net/br-lan/address",
		"/sys/class/net/eth0/address",
		NULL,
	};
	for (int i = 0; sources[i]; i++) {
		if (read_mac_hex12_from(sources[i], out13) == 0)
			return 0;
	}
	return -1;
}

/* Board name as OpenWrt knows it, made safe for a JSON string. */
static void read_model(char *out, size_t len)
{
	FILE *f = fopen("/tmp/sysinfo/model", "r");
	out[0] = 0;
	if (f) {
		if (!fgets(out, (int)len, f))
			out[0] = 0;
		fclose(f);
	}
	for (char *p = out; *p; p++) {
		if (*p == '\n' || *p == '\r') { *p = 0; break; }
		if (*p == '"' || *p == '\\' || (unsigned char)*p < 0x20)
			*p = ' ';
	}
	if (!out[0])
		snprintf(out, len, "OpenWrt");
}

static void format_mac_colon(const char *hex12, char out[18])
{
	snprintf(out, 18, "%c%c:%c%c:%c%c:%c%c:%c%c:%c%c",
		 hex12[0], hex12[1], hex12[2], hex12[3], hex12[4], hex12[5],
		 hex12[6], hex12[7], hex12[8], hex12[9], hex12[10], hex12[11]);
}

static int parse_broker_uri(const char *uri, char host[128], int *port, int *tls)
{
	const char *p;
	if (!strncmp(uri, "mqtts://", 8)) { *tls = 1; *port = 8883; p = uri + 8; }
	else if (!strncmp(uri, "mqtt://", 7)) { *tls = 0; *port = 1883; p = uri + 7; }
	else return -1;

	const char *colon = strchr(p, ':');
	const char *slash = strchr(p, '/');
	const char *end   = colon ? colon : (slash ? slash : p + strlen(p));
	size_t hl = end - p;
	if (hl == 0 || hl >= 128) return -1;

	memcpy(host, p, hl);
	host[hl] = 0;
	if (colon) *port = atoi(colon + 1);
	return 0;
}

/* its/<node>/stats like the ESP32 firmware: {"rbt":<seconds since boot>}
 * on connect and every STATS_INTERVAL seconds. No temperature: ath79 and
 * ath9k expose none. */
#define STATS_INTERVAL 60

static void publish_stats(struct mosquitto *m)
{
	struct timespec ts;
	char stats[64];
	clock_gettime(CLOCK_BOOTTIME, &ts);
	int n = snprintf(stats, sizeof(stats), "{\"rbt\":%lld}", (long long)ts.tv_sec);
	mosquitto_publish(m, NULL, topic_stats, n, stats, 0, false);
}

/* ath9k debugfs: "  CRC ERR :   3" - Name exakt vergleichen, sonst trifft
 * "CRC ERR" auch "PRE-DELIM CRC ERR" */
static void read_recv(const char *phy, long *pkts, long *crc, long *phyerr)
{
	char path[160], line[128];
	*pkts = *crc = *phyerr = -1;
	snprintf(path, sizeof(path), "/sys/kernel/debug/ieee80211/%s/ath9k/recv", phy);
	FILE *f = fopen(path, "r");
	if (!f)
		return;
	while (fgets(line, sizeof(line), f)) {
		char *c = strchr(line, ':');
		if (!c)
			continue;
		*c = 0;
		char *name = line;
		while (*name == ' ')
			name++;
		char *e = c;
		while (e > name && e[-1] == ' ')
			*--e = 0;
		long v = strtol(c + 1, NULL, 10);
		if (!strcmp(name, "PKTS-ALL"))
			*pkts = v;
		else if (!strcmp(name, "CRC ERR"))
			*crc = v;
		else if (!strcmp(name, "PHY ERR"))
			*phyerr = v;
	}
	fclose(f);
}

/* Survey des benutzten Kanals ("[in use]") aus iw */
static void read_survey(int *noise, long long *active, long long *busy, long long *rxt)
{
	char cmd[96], line[160];
	int inuse = 0;
	*noise = 0;
	*active = *busy = *rxt = -1;
	snprintf(cmd, sizeof(cmd), "iw dev %s survey dump 2>/dev/null", cap_iface);
	FILE *f = popen(cmd, "r");
	if (!f)
		return;
	while (fgets(line, sizeof(line), f)) {
		if (strstr(line, "frequency:"))
			inuse = strstr(line, "[in use]") != NULL;
		else if (inuse) {
			char *c = strchr(line, ':');
			if (!c)
				continue;
			if (strstr(line, "noise:"))
				*noise = atoi(c + 1);
			else if (strstr(line, "channel active time:"))
				*active = atoll(c + 1);
			else if (strstr(line, "channel busy time:"))
				*busy = atoll(c + 1);
			else if (strstr(line, "channel receive time:"))
				*rxt = atoll(c + 1);
		}
	}
	pclose(f);
}

static void publish_health(struct mosquitto *m)
{
	char path[128], phy[32] = "", buf[256];
	long pkts, crc, phyerr;
	int noise;
	long long active, busy, rxt;
	snprintf(path, sizeof(path), "/sys/class/net/%s/phy80211/name", cap_iface);
	FILE *f = fopen(path, "r");
	if (f) {
		if (fgets(phy, sizeof(phy), f))
			phy[strcspn(phy, "\n")] = 0;
		fclose(f);
	}
	read_recv(phy, &pkts, &crc, &phyerr);
	read_survey(&noise, &active, &busy, &rxt);
	int n = snprintf(buf, sizeof(buf),
		"{\"cap\":%lu,\"pkts\":%ld,\"crc\":%ld,\"phy\":%ld,\"noise\":%d,"
		"\"active\":%lld,\"busy\":%lld,\"rxt\":%lld}",
		pkt_captured, pkts, crc, phyerr, noise, active, busy, rxt);
	if (n > 0 && n < (int)sizeof(buf))
		mosquitto_publish(m, NULL, topic_health, n, buf, 0, false);
}

/* Own thread: pcap_loop may block indefinitely on a quiet channel
 * (TPACKET_V3 polls without timeout), so it cannot drive the timer. */
static void *stats_thread(void *arg)
{
	(void)arg;
	struct timespec ok, now;
	clock_gettime(CLOCK_MONOTONIC, &ok);
	while (running) {
		for (int i = 0; i < STATS_INTERVAL && running; i++)
			sleep(1);
		if (running && mqtt_up) {
			publish_stats(mosq);
			if (health)
				publish_health(mosq);
		}
		clock_gettime(CLOCK_MONOTONIC, &now);
		if (mqtt_up)
			ok = now;
		else if (giveup > 0 && now.tv_sec - ok.tv_sec > giveup) {
			syslog(LOG_WARNING, "no broker connection for %d s, exiting", giveup);
			_exit(3);
		}
	}
	return NULL;
}

/* Eigene Netzwerkschleife statt mosquitto_loop_start(): deren Thread
 * (mosquitto_loop_forever) beendet sich still bei TLS-, DNS- und
 * Protokollfehlern. Scheitert so der erste Handshake nach dem Boot,
 * oeffnet ein Reconnect zwar noch Sockets, aber niemand fuehrt den
 * TLS-Handshake mehr weiter (LiteBeam 01.10.: CLOSE_WAIT, Knoten stumm).
 * Hier wird nach jedem Fehler mit wachsender Pause (bis 60 s) neu
 * verbunden, egal welcher. */
static void *mqtt_thread(void *arg)
{
	(void)arg;
	unsigned int delay = 1, fails = 0;
	while (!mqtt_stop) {
		int rc = mosquitto_loop(mosq, 1000, 1);
		if (rc == MOSQ_ERR_SUCCESS) {
			if (mqtt_up) {
				delay = 1;
				fails = 0;
			}
			continue;
		}
		for (unsigned int i = 0; i < delay && !mqtt_stop; i++)
			sleep(1);
		if (mqtt_stop)
			break;
		if (delay < 60)
			delay = delay * 2 > 60 ? 60 : delay * 2;
		rc = mosquitto_reconnect(mosq);
		/* bei langem Ausfall nicht jede Minute eine Zeile ins Log */
		if (rc != MOSQ_ERR_SUCCESS && (fails++ < 5 || fails % 60 == 0))
			syslog(LOG_WARNING, "mqtt reconnect: %s",
			       mosquitto_strerror(rc));
	}
	return NULL;
}

static void publish_build(struct mosquitto *m, const char *model, const char *mac)
{
	if (!build_version)
		return;
	char build[352];
	int n = snprintf(build, sizeof(build),
		 "{\"version\":\"%s\",\"commit\":\"%s\",\"bridge\":\"%s\",\"model\":\"%s\",\"mac\":\"%s\"}",
		 build_version, build_commit ? build_commit : "", OTM_BRIDGE_VERSION, model, mac);
	if (n > 0 && n < (int)sizeof(build))
		mosquitto_publish(m, NULL, topic_build, n, build, 0, true);
}

static void on_connect(struct mosquitto *m, void *ud, int rc)
{
	(void)ud;
	if (rc) {
		syslog(LOG_ERR, "mqtt connect rc=%d (%s)", rc, mosquitto_connack_string(rc));
		return;
	}
	mqtt_up = 1;
	if (problem) {
		/* nur otm/<node>/build und /problem, nichts unter its/: das
		 * Geraet soll bei OpenTrafficMap nicht als Empfaenger auftauchen */
		char model[96], buf[256];
		read_model(model, sizeof(model));
		publish_build(m, model, "");
		int n = snprintf(buf, sizeof(buf), "{\"problem\":\"%s\",\"bridge\":\"%s\"}",
				 problem, OTM_BRIDGE_VERSION);
		if (n > 0 && n < (int)sizeof(buf)
		    && mosquitto_publish(m, NULL, topic_problem, n, buf, 1, true) == MOSQ_ERR_SUCCESS)
			syslog(LOG_INFO, "reported problem: %s", problem);
		return;
	}
	syslog(LOG_INFO, "mqtt connected, topic=its/<node>/packet");

	mosquitto_publish(m, NULL, topic_status,
			  (int)strlen("online"), "online", 1, true);

	char info[256], hex12[13] = "000000000000", mac_colon[18], model[96];
	read_mac_hex12(cap_iface, hex12);
	format_mac_colon(hex12, mac_colon);
	read_model(model, sizeof(model));
	int n = snprintf(info, sizeof(info),
		 "{\"emac\":\"%s\",\"ver\":\"otm-bridge-%s\",\"hwv\":\"%s\"}",
		 mac_colon, OTM_BRIDGE_VERSION, model);
	mosquitto_publish(m, NULL, topic_info, n, info, 0, false);
	publish_build(m, model, mac_colon);
	/* Geraet empfaengt wieder: eine fruehere Problem-Meldung loeschen */
	if (health)
		mosquitto_publish(m, NULL, topic_problem, 0, "", 0, true);
	if (location) {
		char loc[128] = "";
		double lat, lon, alt;
		int k = sscanf(location, "%lf,%lf,%lf", &lat, &lon, &alt);
		n = 0;
		if (k >= 2 && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180)
			n = k == 3 ? snprintf(loc, sizeof(loc), "{\"lat\":%.6f,\"lon\":%.6f,\"alt\":%.1f}", lat, lon, alt)
			           : snprintf(loc, sizeof(loc), "{\"lat\":%.6f,\"lon\":%.6f}", lat, lon);
		/* leere retained Nachricht loescht eine frueher geteilte Position */
		mosquitto_publish(m, NULL, topic_location, n > 0 ? n : 0, loc, 0, true);
	}
	publish_stats(m);
}

static void on_publish(struct mosquitto *m, void *ud, int mid)
{
	(void)m; (void)ud; (void)mid;
	if (problem)
		problem_sent = 1;
}

static void on_disconnect(struct mosquitto *m, void *ud, int rc)
{
	(void)m; (void)ud;
	mqtt_up = 0;
	syslog(LOG_WARNING, "mqtt disconnected rc=%d", rc);
}

static void on_log(struct mosquitto *m, void *ud, int level, const char *str)
{
	(void)m; (void)ud;
	if (level <= MOSQ_LOG_WARNING || verbose >= 2)
		syslog(LOG_DEBUG, "mosq: %s", str);
}

/* -E: einmal melden und beenden. Ohne Verbindung nach 30 s aufgeben; der
 * Aufrufer versucht es spaeter wieder. */
static int report_problem(const char *host, int port, const char *node_id)
{
	mosquitto_lib_init();
	/* Client-ID = Knotenname: die ACL am Proxy erlaubt nur otm/<Client-ID>/# */
	mosq = mosquitto_new(node_id, true, NULL);
	if (!mosq) { syslog(LOG_ERR, "mosquitto_new failed"); return 1; }
	mosquitto_connect_callback_set(mosq, on_connect);
	mosquitto_publish_callback_set(mosq, on_publish);
	mosquitto_log_callback_set(mosq, on_log);
	int rc = mosquitto_connect(mosq, host, port, 60);
	for (int i = 0; rc == MOSQ_ERR_SUCCESS && !problem_sent && i < 300; i++)
		rc = mosquitto_loop(mosq, 100, 1);
	if (!problem_sent)
		syslog(LOG_WARNING, "problem not reported (%s)", mosquitto_strerror(rc));
	mosquitto_disconnect(mosq);
	mosquitto_destroy(mosq);
	mosquitto_lib_cleanup();
	return problem_sent ? 0 : 1;
}

/* opentrafficmap.org's ingest (cits-wireshark-bridge) decodes the MQTT
 * payload with PCAP_LINKTYPE=105 (DLT_IEEE802_11) — raw 802.11 frames,
 * NO radiotap header. mac80211 monitor-mode hands us DLT_IEEE802_11_RADIO
 * (DLT 127), so we strip the radiotap prefix before publishing. The
 * radiotap header is little-endian and self-describes its length via
 * `it_len` at offset 2. */
static unsigned int radiotap_len(const u_char *p, unsigned int caplen)
{
	if (caplen < 8 || p[0] != 0 /* it_version */)
		return 0;
	unsigned int it_len = (unsigned int)p[2] | ((unsigned int)p[3] << 8);
	if (it_len < 8 || it_len > caplen)
		return 0;
	return it_len;
}

static void pkt_handler(u_char *ud, const struct pcap_pkthdr *h, const u_char *bytes)
{
	(void)ud;
	pkt_captured++;
	if (!mosq) return;
	unsigned int rt = radiotap_len(bytes, h->caplen);
	const u_char *frame = bytes + rt;
	int frame_len = (int)(h->caplen - rt);
	int r = mosquitto_publish(mosq, NULL, topic_packet,
				   frame_len, frame, 0, false);
	if (r == MOSQ_ERR_SUCCESS) {
		pkt_published++;
		if (verbose && (pkt_published % 100 == 0))
			syslog(LOG_INFO, "published %lu packets", pkt_published);
	} else if (r == MOSQ_ERR_NO_CONN) {
		/* dropped while disconnected; mqtt_thread reconnects */
	} else {
		pkt_pcap_err++;
		if (pkt_pcap_err < 5 || pkt_pcap_err % 1000 == 0)
			syslog(LOG_WARNING, "publish err %d (%s) total=%lu",
			       r, mosquitto_strerror(r), pkt_pcap_err);
	}
}

static void usage(void)
{
	fprintf(stderr,
	    "usage: otm-bridge [options]\n"
	    "  -i IFACE   capture interface (default mon0)\n"
	    "  -b URI     broker URI (default mqtt://10.66.0.1)\n"
	    "  -n NODE    node id (default: MAC of the capture interface, 12 hex chars)\n"
	    "  -c CAFILE  TLS CA file (default /etc/ssl/certs/ca-certificates.crt)\n"
	    "  -s SNAP    pcap snap length (default 2300)\n"
	    "  -v         verbose (repeat for more)\n"
	    "  -x SECS    exit after SECS without broker connection (default: never)\n"
	    "  -V VER     image build number, published retained to otm/<node>/build\n"
	    "  -G COMMIT  image commit for otm/<node>/build\n"
	    "  -L LOC     \"lat,lon[,alt]\" retained to otm/<node>/location, \"\" clears it\n"
	    "  -H         receiver health to otm/<node>/health every 60 s\n"
	    "  -E REASON  no capture: report REASON retained to otm/<node>/problem\n"
	    "             (plain mqtt:// only, needs -n) and exit\n"
	    "  -f         stay in foreground\n");
}

int main(int argc, char **argv)
{
	const char *broker_uri  = "mqtt://10.66.0.1";
	const char *cafile      = "/etc/ssl/certs/ca-certificates.crt";
	char node_id[64]        = { 0 };
	int snaplen             = 2300;
	int foreground          = 0;

	int opt;
	while ((opt = getopt(argc, argv, "i:b:n:c:s:x:V:G:L:E:Hvfh")) != -1) {
		switch (opt) {
		case 'i': cap_iface   = optarg; break;
		case 'b': broker_uri  = optarg; break;
		case 'n': strncpy(node_id, optarg, sizeof(node_id) - 1); break;
		case 'c': cafile      = optarg; break;
		case 's': snaplen     = atoi(optarg); break;
		case 'v': verbose++;            break;
		case 'x': giveup      = atoi(optarg); break;
		case 'V': build_version = optarg; break;
		case 'G': build_commit  = optarg; break;
		case 'L': location      = optarg; break;
		case 'H': health        = 1;      break;
		case 'E': problem       = optarg; break;
		case 'f': foreground  = 1;      break;
		case 'h':
		default:  usage(); return opt == 'h' ? 0 : 1;
		}
	}

	if (!node_id[0] && read_mac_hex12(cap_iface, node_id) != 0) {
		fprintf(stderr, "failed to derive node id from a MAC address; pass -n\n");
		return 1;
	}

	char host[128];
	int port = 8883, tls = 1;
	if (parse_broker_uri(broker_uri, host, &port, &tls) != 0) {
		fprintf(stderr, "bad broker URI: %s\n", broker_uri);
		return 1;
	}

	snprintf(topic_packet, sizeof(topic_packet), "its/%s/packet", node_id);
	snprintf(topic_status, sizeof(topic_status), "its/%s/status", node_id);
	snprintf(topic_info,   sizeof(topic_info),   "its/%s/info",   node_id);
	snprintf(topic_stats,  sizeof(topic_stats),  "its/%s/stats",  node_id);
	snprintf(topic_build,  sizeof(topic_build),  "otm/%s/build",  node_id);
	snprintf(topic_location, sizeof(topic_location), "otm/%s/location", node_id);
	snprintf(topic_health, sizeof(topic_health), "otm/%s/health", node_id);
	snprintf(topic_problem, sizeof(topic_problem), "otm/%s/problem", node_id);

	/* Under procd stderr already ends up in syslog; LOG_PERROR would log
	 * every line twice. Only mirror to stderr on an interactive terminal. */
	openlog("otm-bridge", LOG_PID | (foreground && isatty(2) ? LOG_PERROR : 0), LOG_DAEMON);
	syslog(LOG_INFO, "starting v%s iface=%s broker=%s://%s:%d node=%s",
	       OTM_BRIDGE_VERSION, cap_iface, tls ? "mqtts" : "mqtt",
	       host, port, node_id);

	if (problem) {
		/* otm/ gehoert nur an unseren Proxy, nie direkt an OpenTrafficMap */
		if (tls) {
			syslog(LOG_ERR, "-E only with mqtt:// (our proxy)");
			return 1;
		}
		return report_problem(host, port, node_id);
	}

	char errbuf[PCAP_ERRBUF_SIZE];
	pc = pcap_open_live(cap_iface, snaplen, 1, 100, errbuf);
	if (!pc) {
		syslog(LOG_ERR, "pcap_open_live(%s): %s", cap_iface, errbuf);
		return 1;
	}
	int dlt = pcap_datalink(pc);
	if (dlt != DLT_IEEE802_11_RADIO)
		syslog(LOG_WARNING, "iface %s datalink is %s, not radiotap; "
		       "server may reject payloads", cap_iface,
		       pcap_datalink_val_to_name(dlt));

	mosquitto_lib_init();
	mosq = mosquitto_new(node_id, true, NULL);
	if (!mosq) { syslog(LOG_ERR, "mosquitto_new failed"); return 1; }

	mosquitto_will_set(mosq, topic_status,
			   (int)strlen("offline"), "offline", 1, true);
	mosquitto_connect_callback_set(mosq, on_connect);
	mosquitto_disconnect_callback_set(mosq, on_disconnect);
	mosquitto_log_callback_set(mosq, on_log);

	if (tls && mosquitto_tls_set(mosq, cafile, NULL, NULL, NULL, NULL)
		   != MOSQ_ERR_SUCCESS) {
		syslog(LOG_ERR, "mosquitto_tls_set(%s) failed", cafile);
		return 1;
	}

	struct sigaction sa = { 0 };
	sa.sa_handler = on_signal;
	sigaction(SIGINT,  &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	if (!foreground && daemon(0, 0) < 0) {
		syslog(LOG_ERR, "daemon: %s", strerror(errno));
		return 1;
	}

	/* Publish aus pcap- und stats-Thread, Netzwerk im mqtt_thread */
	mosquitto_threaded_set(mosq, true);
	/* Scheitert schon das (z. B. DNS direkt nach dem Boot), merkt sich
	 * libmosquitto Host und Port trotzdem; mqtt_thread versucht es weiter.
	 * Frueher endete der Prozess hier, und procd gibt nach wenigen
	 * schnellen Abstuerzen auf. */
	int r = mosquitto_connect_async(mosq, host, port, 60);
	if (r != MOSQ_ERR_SUCCESS)
		syslog(LOG_WARNING, "mqtt connect: %s", mosquitto_strerror(r));

	pthread_t mqtt_tid;
	if (pthread_create(&mqtt_tid, NULL, mqtt_thread, NULL) != 0) {
		syslog(LOG_ERR, "mqtt thread not started");
		return 1;
	}

	pthread_t stats_tid;
	int have_stats = pthread_create(&stats_tid, NULL, stats_thread, NULL) == 0;
	if (!have_stats)
		syslog(LOG_WARNING, "stats thread not started");

	pcap_loop(pc, -1, pkt_handler, NULL);
	running = 0;
	if (have_stats)
		pthread_join(stats_tid, NULL);

	syslog(LOG_INFO, "shutting down, published=%lu errs=%lu",
	       pkt_published, pkt_pcap_err);
	mosquitto_publish(mosq, NULL, topic_status,
			  (int)strlen("offline"), "offline", 1, true);
	struct timespec ts = { 1, 0 };
	nanosleep(&ts, NULL);
	mosquitto_disconnect(mosq);
	mqtt_stop = 1;
	pthread_join(mqtt_tid, NULL);
	mosquitto_destroy(mosq);
	mosquitto_lib_cleanup();
	pcap_close(pc);
	closelog();
	return 0;
}
