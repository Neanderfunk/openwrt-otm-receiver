# LiteBeam M5 XW: sysupgrade schreibt nicht (Flash-Schreibschutz)

Stand 14.10.2026, ein Gerät (LBE-M5-23, `LBEM5-2028`, AR9342, 8 MB SPI-NOR
Macronix `c22017` = Linux `mx25l6405d`), OpenWrt 25.12.4 ath79 mit OTM-Image.
Allgemeine Fassung für alle Geräte: Router-Werkstatt `docs/flash-schreibschutz.md`.

## Kurzfassung

- `sysupgrade` meldet Erfolg und startet neu, Kernel und System bleiben aber
  alt. Je nach Lauf ist danach die Konfiguration weg (Overlay leer) oder
  unverändert.
- Ursache, belegt: Der untere Teil des Flash ist schreibgeschützt.
  Statusregister nach dem Booten `0x9c` (SRWD + BP0-2). `mtd` meldet bei
  Schreibzugriffen dort trotzdem Erfolg (rc=0), der Chip ignoriert Löschen
  und Schreiben.
- Das Statusregister lässt sich nur ändern, wenn SoC-GPIO 0 ausdrücklich
  physisch auf low gesetzt wird. Das ist der Schreibschutz-Pin des Flash:
  OpenWrt 19.07 (ar71xx) nennt ihn `SPI nWP`, das ath79-Device-Tree von 25.12
  führt ihn als `reset-gpios` des Ethernet-PHY. Das Ethernet läuft
  unabhängig davon weiter.
- `kmod-otm-spinor-unlock` (OTM-Feed, nur im LiteBeam-Image ab 25.12) setzt
  beim Booten den Pin und löscht das Statusregister. Danach ist der Flash
  nachweislich beschreibbar (Schreibtests, Register bleibt `0x00`).
- Das Modul muss aus `/etc/modules-boot.d` laden (seit f1baf30), nicht aus
  `/etc/modules.d`: `mount_root` braucht den entsperrten Flash schon in
  preinit, sonst RAM-Overlay und die gesicherte Konfiguration kommt nicht
  zurück. So lief sysupgrade am 14.10. vollständig durch (Lauf 6).
- **Noch offen:** das Fehlerbild „schreibt gar nichts“ (Läufe 2 und 3, von
  Hand entsperrt) ist nicht erklärt. Weitere Upgrades beobachten.

## Befunde der Reihe nach

1. **Fünf sysupgrade-Versuche ohne Gegenmaßnahme** (01.-14.10.): Kernel und
   rootfs im Flash unverändert. Mit `-n` war das Overlay danach neu
   formatiert, ohne `-n` war die Konfiguration verloren.
2. **Flash blockweise verglichen** (`dd` aus `/dev/mtd2` gegen das Image, je
   64 KB): Kernel-Blöcke gleich (in beiden Images identisch), rootfs-Blöcke
   alle alt.
3. **`/rom` geprüft:** `/rom/etc/otm-build-info` und das Vorhandensein von
   `/rom/etc/dropbear/authorized_keys` zeigen eindeutig, welches Image
   geschrieben ist. `/etc/otm-build-info` allein taugt nicht, weil das
   Overlay sie überdecken könnte.
4. **Markertest** (Idee adorfer): Datei in `/root` (Overlay, wird nicht
   gesichert) und Datei in `/etc`, die in `/etc/sysupgrade.conf` steht (wird
   gesichert). Ergebnis: beide weg, `/rom` alt. Kernel-Log beim nächsten
   Start: `jffs2: End of filesystem marker found at 0x0`. Die Markierung
   `0xdeadc0de` schreibt `mtd` erst nach dem Ende des Images. `mtd` lief also
   bis zum Ende, nur ganz oben (Konfigurationspartition) kam Geschriebenes an.
5. **Schreibtest** auf Block 91 der Partition `firmware` (Offset `0x5b0000`,
   hinter dem squashfs-Ende nur `0xFF`-Auffüllung): Block lesen, Testmuster in
   die Auffüllung, `mtd -p 0x5b0000 write … firmware`. `mtd` meldet „Unlocking
   firmware“ und rc=0, der Block ist danach byte-gleich mit vorher.
6. **`mtd unlock firmware`** ändert nichts.
7. **Modul, erste Fassung:** `_unlock` des ganzen Chips über den MTD-Master
   liefert `-EIO`: Das Statusregister wird geschrieben, beim Zurücklesen ist
   es unverändert.
8. **Statusregister direkt gelesen** (Modul, `spi_mem_exec_op` RDSR): `0x9c`.
   WREN + WRSR `0x00` (1 Byte, wie Linux 4.14 bei Macronix): bleibt `0x9c`,
   zweimal hintereinander reproduziert.
9. **19.07-Board-Code** (`mach-ubnt-xm.c`, `ubnt_lbe_m5_setup`):
   `gpio_request_one(0, GPIOF_OUT_INIT_LOW | GPIOF_ACTIVE_LOW | …, "SPI nWP")`.
10. **Mit GPIO 0** (global 512 unter 6.12) per `gpiod_set_raw_value(…, 0)`
    vor dem WRSR: `0x9c → 0x00`, reproduzierbar. Schreibtest auf Block 91 klappt,
    dreimal hintereinander und nach 60 s noch. `mtd unlock firmware` danach
    setzt nichts zurück. Auffällig: `gpiod_get_raw_value` meldet vorher schon 0,
    erst das ausdrückliche Setzen gibt das Register frei.
11. **Modul beim Booten** (Image `8ccf43b`, `/etc/modules.d`): meldet
    `SR before: 0x9c`, `SR after WRSR 0: 0x00`, aber erst bei ~20 s.
12. **Boot-Log nach Lauf 5:** `jffs2: Newly-erased block contained word
    0xdeadc0de at offset 0x00010000`, `mount_root: switching to jffs2 failed -
    fallback to ramoverlay`. `mount_root` lief bei ~14 s, also im noch
    gesperrten Flash. `/overlay/sysupgrade.tgz` lag da, wurde aber nie
    zurückgespielt; jffs2 zeigte 100 % belegt. Das ist das Fehlerbild
    „Konfiguration verloren“.
13. **Modul aus `/etc/modules-boot.d`** (f1baf30): `/sbin/init` lädt es bei
    3.8 s, danach `jffs2_build_filesystem(): erasing all blocks after the end
    marker...` und `mount_root: switching to jffs2 overlay` ohne Fehler.

## sysupgrade-Läufe nach dem Entsperren (14.10.)

| # | Entsperrt | Image | Ergebnis |
|---|---|---|---|
| 1 | von Hand, Minuten vorher | 8e6ab30 ohne Key | **voll erfolgreich**: `/rom` neu, `/root`-Marker weg, `/etc`-Marker da, fastd-Schlüssel gleich |
| 2 | von Hand, ~20 min vorher | 8ccf43b mit Key | nichts geschrieben, Konfiguration unverändert |
| 3 | von Hand, Schreibtests direkt vorher ok | 8ccf43b mit Key (`-v`) | nichts geschrieben, Konfiguration unverändert, jffs2 gültig |
| 4 | von Hand | 8e6ab30 ohne Key | Konfiguration verloren, ohne Key kein SSH (dropbear aus), TFTP-Rescue nötig |
| 5 | Modul beim Booten (modules.d) | 8ccf43b mit Key (gleiches Image) | Konfiguration verloren (beide Marker weg, neuer fastd-Schlüssel); Ursache RAM-Overlay, siehe 12. |
| 6 | Modul beim Booten (modules.d, Gerät lief auf RAM-Overlay), neues Image lädt es aus modules-boot.d | f1baf30 mit Key, Version 202610141907 | **voll erfolgreich**: `/rom` neu, `/root`-Marker weg, `/etc`-Marker da, fastd-Schlüssel gleich, Overlay auf jffs2 |

Es gab zwei Fehlerbilder: „Upgrade-Phase schreibt gar nichts“ (2, 3) und
„Upgrade-Phase läuft durch, die Konfiguration kommt nicht zurück“ (4, 5). Das
zweite ist erklärt (12.) und behoben (13., Lauf 6). Ob in Lauf 5 die Firmware
geschrieben wurde, ist nicht feststellbar (gleiches Image).

## Was das Modul tut

`feed/kernel/otm-spinor-unlock`, Paket `kmod-otm-spinor-unlock`, geladen aus
`/etc/modules-boot.d` mit `wp_gpio=512 wp_level=0`:

1. MTD-Partition `firmware` suchen, über `mtd_get_master` den Chip, über
   `container_of` die `struct spi_nor`.
2. GPIO `wp_gpio` physisch auf `wp_level` setzen.
3. RDSR; wenn SRWD oder BP gesetzt: WREN, WRSR `0x00`, auf WIP warten,
   zurücklesen, beides protokollieren.
4. GPIO auf den alten Wert zurück.

## Quellen

- OpenWrt-Geräteseite LiteBeam M5: „To run openwrt 23.05 or later on this device
  a downgrade of the bootloader is needed“ (U-Boot 1.1.4-s776),
  https://openwrt.org/toh/ubiquiti/litebeam_m5 , Anleitung/Image
  https://github.com/a-gave/ubnt_litebeam-m5-xw
- MX25L6405D: BP3 schützt die untere Hälfte, Linux bildet das nicht ab,
  https://lkml.iu.edu/hypermail/linux/kernel/2101.2/08418.html
- OpenWrt PR #14237 (`CONFIG_MTD_SPI_NOR_SWP_DISABLE` für ath79),
  Issues #12882, #17914; AREDN #2640, #2786.
- 19.07 Board-Code:
  https://github.com/openwrt/openwrt/blob/openwrt-19.07/target/linux/ar71xx/files/arch/mips/ath79/mach-ubnt-xm.c

## Nächste Schritte, falls es weitergehen soll

- Weitere Upgrades (auch über den Autoupdater) mit Markertest prüfen. Tritt
  „schreibt gar nichts“ wieder auf: Ausgabe der Upgrade-Phase (stage2) übers
  Netz mitschneiden.
- Der Bootloader-Rückschritt auf s776 ist mit dem Modul nicht mehr nötig.
- **Testregel:** für Upgrade-Versuche nur Images mit Key nehmen. Geht die
  Konfiguration verloren, schaltet ein Image ohne Key SSH ab.
