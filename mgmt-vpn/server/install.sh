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
systemctl daemon-reload
systemctl enable --now otm-mgmt-net.service dnsmasq-otm.service fastd@otm.service
systemctl restart fastd@otm.service
fastd -c /etc/fastd/otm/fastd.conf --show-key --machine-readable
