#!/bin/sh
# Grafana-Teil der Gegenstelle (Grafana selbst aus apt.grafana.com, siehe
# README). Auf dem Server als root aus diesem Verzeichnis ausfuehren.
set -e
cd "$(dirname "$0")"
f=/etc/default/grafana-server
sed -i '/^# an \/etc\/default\/grafana-server angehaengt/,$d' "$f"
cat grafana-server.env >> "$f"
install -m 644 -o root -g grafana datasource.yaml /etc/grafana/provisioning/datasources/otm.yaml
install -m 644 -o root -g grafana dashboards.yaml /etc/grafana/provisioning/dashboards/otm.yaml
install -d -o grafana -g grafana /var/lib/grafana/dashboards/otm
# Kartensymbol fuer Empfaenger (eigene Zeichnung), liegt bei Grafanas Markern
# Grafana 13 liest die Symbole aus public/build/img/..., aeltere aus public/img/...
for d in /usr/share/grafana/public/img/icons/marker /usr/share/grafana/public/build/img/icons/marker; do
	[ -d "$d" ] && install -m 644 otm-funkmast.svg "$d/otm-funkmast.svg"
done
install -m 644 -o grafana -g grafana otm-empfang.json otm-heatmap.json otm-heatmap-knoten.json otm-knoten.json /var/lib/grafana/dashboards/otm/
systemctl daemon-reload
systemctl enable grafana-server
systemctl restart grafana-server
