#!/bin/sh
# fastd "on verify" fuer die Instanz otm: entscheidet, ob ein Empfaenger mit
# dem Schluessel $PEER_KEY einen Tunnel aufbauen darf (0 = ja).
#
#   /etc/fastd/otm/sperrliste      diese Schluessel nie (z. B. Station flutet mit Unsinn)
#   /etc/fastd/otm/freigabeliste   nur diese, wenn /etc/fastd/otm/nur-freigegebene existiert
#
# Eine Zeile je Schluessel (64 Hex-Zeichen), dahinter # Kommentar erlaubt.
# Ohne nur-freigegebene darf jeder ausser der Sperrliste (Vorgabe).
# Pflege mit otm-fastd (sperren, entsperren, freigeben, modus).

D=/etc/fastd/otm
key=$(printf '%s' "$PEER_KEY" | tr 'A-F' 'a-f')

steht_in() {
	[ -f "$1" ] && sed 's/#.*//' "$1" | tr -d ' \t' | tr 'A-F' 'a-f' | grep -qxF "$key"
}

# Abweisungen hoechstens einmal je Stunde und Schluessel protokollieren
# (fastd fragt bei jedem Handshake, also etwa alle 20 s)
abweisen() {
	s=/run/fastd-otm-abgewiesen
	mkdir -p "$s"
	if [ -z "$(find "$s/$key" -mmin -60 2>/dev/null)" ]; then
		logger -t fastd-otm-verify "abgewiesen ($1): $key von $PEER_ADDRESS"
		touch "$s/$key"
	fi
	exit 1
}

steht_in "$D/sperrliste" && abweisen Sperrliste
if [ -e "$D/nur-freigegebene" ]; then
	steht_in "$D/freigabeliste" || abweisen "nicht freigegeben"
fi
exit 0
