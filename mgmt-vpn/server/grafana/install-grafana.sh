#!/bin/sh
# Grafana-Teil der Gegenstelle (Grafana selbst aus apt.grafana.com, siehe
# README). Auf dem Server als root aus diesem Verzeichnis ausfuehren.
set -e
cd "$(dirname "$0")"
f=/etc/default/grafana-server
grep -q '^GF_SERVER_HTTP_ADDR=' "$f" || cat grafana-server.env >> "$f"
install -m 644 -o root -g grafana datasource.yaml /etc/grafana/provisioning/datasources/otm.yaml
install -m 644 -o root -g grafana dashboards.yaml /etc/grafana/provisioning/dashboards/otm.yaml
install -d -o grafana -g grafana /var/lib/grafana/dashboards/otm
install -m 644 -o grafana -g grafana otm-empfang.json /var/lib/grafana/dashboards/otm/
systemctl daemon-reload
systemctl enable grafana-server
systemctl restart grafana-server
