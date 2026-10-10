#!/bin/sh
# Jede aufgebaute Verbindung protokollieren (Schluessel, Adresse, Interface),
# damit neue Geraete auffallen, auch wenn sie nicht freigeschaltet werden.
echo "$(date -u +%FT%TZ) $PEER_KEY $PEER_ADDRESS $INTERFACE" >> /var/log/otm-mgmt-peers.log
