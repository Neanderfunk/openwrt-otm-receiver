# /etc/profile.d/otm.sh - Hinweis beim Login
. /lib/otm-bridge/functions.sh
if otm_configmode; then
	cat <<EOF

 ===================================================================
  CONFIG-MODE: Dieser Empfaenger liefert gerade keine Daten,
  nur SSH laeuft (root ohne Passwort), Adresse 192.168.1.1.

  Einstellungen und Befehle:  otm-help
  Config-Mode verlassen:      otm-configmode exit   (Neustart)
  Auch ein Neustart oder Strom aus/an fuehrt in den Normalbetrieb;
  von selbst geschieht das 120 Minuten nach dem Start in den Config-Mode.
 ===================================================================

EOF
else
	echo " OTM-Empfaenger $(uci -q get system.@system[0].hostname), Build $(cat /lib/otm/version 2>/dev/null). Einstellungen und Befehle: otm-help"
	echo
fi
