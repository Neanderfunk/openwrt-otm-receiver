#!/bin/sh
# Auf der Gegenstelle als root aus diesem Verzeichnis ausfuehren. Idempotent;
# ein vorhandener fastd-Schluessel bleibt erhalten.
set -e
cd "$(dirname "$0")"
install -d /etc/fastd/otm /etc/otm-mgmt
install -m 644 fastd.conf /etc/fastd/otm/fastd.conf
install -m 755 peer-up.sh peer-log.sh /etc/fastd/otm/
install -m 644 dnsmasq.conf nft.conf /etc/otm-mgmt/
install -m 644 otm-mgmt-net.service dnsmasq-otm.service /etc/systemd/system/
if [ ! -s /etc/fastd/otm/secret.conf ]; then
	umask 077
	fastd --generate-key --machine-readable | sed 's/.*/secret "&";/' > /etc/fastd/otm/secret.conf
fi
install -m 644 mosquitto-otm.conf /etc/mosquitto/conf.d/otm.conf
install -d /etc/systemd/system/mosquitto.service.d
install -m 644 mosquitto-otm.override /etc/systemd/system/mosquitto.service.d/otm.conf
install -d /usr/local/lib/otm
install -m 755 otm-stats.py /usr/local/lib/otm/otm-stats.py
install -m 644 otm-stats.service /etc/systemd/system/
# VictoriaMetrics nur lokal (das Paket lauscht sonst auf allen Adressen)
echo 'ARGS="-storageDataPath=/var/lib/victoria-metrics -httpListenAddr=127.0.0.1:8428 -retentionPeriod=24"' > /etc/default/victoria-metrics
systemctl daemon-reload
systemctl enable --now otm-mgmt-net.service dnsmasq-otm.service fastd@otm.service
nft -f /etc/otm-mgmt/nft.conf
systemctl restart fastd@otm.service victoria-metrics.service mosquitto.service
systemctl enable --now otm-stats.service
systemctl restart otm-stats.service
fastd -c /etc/fastd/otm/fastd.conf --show-key --machine-readable
