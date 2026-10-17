# Ersetzt OpenWrts Warnung "There is no root password defined" (base-files):
# root ohne Passwort ist bei OTM gewollt. Im Normalbetrieb ist SSH nur per Key
# offen (oder ganz zu), im Config-Mode laesst dropbear -B root ohne Passwort
# herein; ein gesetztes Passwort wuerde dort dann verlangt.
