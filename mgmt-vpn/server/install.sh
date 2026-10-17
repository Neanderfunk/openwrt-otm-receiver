#!/bin/sh
# Auf der Gegenstelle als root aus diesem Verzeichnis ausfuehren. Idempotent;
# ein vorhandener fastd-Schluessel bleibt erhalten.
set -e
cd "$(dirname "$0")"
install -d /etc/fastd/otm /etc/otm-mgmt
install -m 644 fastd.conf /etc/fastd/otm/fastd.conf
install -m 755 peer-up.sh peer-log.sh /etc/fastd/otm/
install -m 755 fastd-verify.sh /etc/fastd/otm/verify.sh
touch /etc/fastd/otm/sperrliste /etc/fastd/otm/freigabeliste
install -m 755 otm-fastd /usr/local/sbin/otm-fastd
install -m 644 dnsmasq.conf nft.conf /etc/otm-mgmt/
install -m 644 otm-mgmt-net.service dnsmasq-otm.service /etc/systemd/system/
if [ ! -s /etc/fastd/otm/secret.conf ]; then
	umask 077
	fastd --generate-key --machine-readable | sed 's/.*/secret "&";/' > /etc/fastd/otm/secret.conf
fi
install -m 644 mosquitto-otm.conf /etc/mosquitto/conf.d/otm.conf
install -m 644 mosquitto-otm-tunnel.acl /etc/mosquitto/otm-tunnel.acl
install -d /etc/systemd/system/mosquitto.service.d
install -m 644 mosquitto-otm.override /etc/systemd/system/mosquitto.service.d/otm.conf
install -d /usr/local/lib/otm
install -m 755 otm-stats.py /usr/local/lib/otm/otm-stats.py
install -m 644 otm-stats.service /etc/systemd/system/
# VictoriaMetrics nur lokal (das Paket lauscht sonst auf allen Adressen), Admin-
# Endpunkte mit Schluessel (Grafana reicht GET-Anfragen per Proxy durch). Ein
# vorhandener Schluessel bleibt.
k=$(grep -o 'deleteAuthKey=[0-9a-f]*' /etc/default/victoria-metrics 2>/dev/null | cut -d= -f2)
[ -n "$k" ] || k=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
a=""
for f in deleteAuthKey snapshotAuthKey forceMergeAuthKey forceFlushAuthKey flagsAuthKey metricsAuthKey pprofAuthKey search.resetCacheAuthKey configAuthKey; do
	a="$a -$f=$k"
done
(umask 077; echo "ARGS=\"-storageDataPath=/var/lib/victoria-metrics -httpListenAddr=127.0.0.1:8428 -retentionPeriod=24$a\"" > /etc/default/victoria-metrics)
systemctl daemon-reload
systemctl enable --now otm-mgmt-net.service dnsmasq-otm.service fastd@otm.service
nft -f /etc/otm-mgmt/nft.conf
systemctl restart fastd@otm.service victoria-metrics.service mosquitto.service
systemctl enable --now otm-stats.service
systemctl restart otm-stats.service
fastd -c /etc/fastd/otm/fastd.conf --show-key --machine-readable
