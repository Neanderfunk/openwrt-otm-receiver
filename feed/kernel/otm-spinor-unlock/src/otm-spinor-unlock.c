// SPDX-License-Identifier: GPL-2.0
/*
 * otm-spinor-unlock: hebt beim Laden den Schreibschutz des ganzen SPI-NOR auf.
 *
 * Ubiquiti-XW-Geraete (LiteBeam M5 XW) kommen mit gesetzten Block-Protect-Bits
 * vom Bootloader, die den unteren Teil des Flash schuetzen. Der Kernel kennt
 * den Macronix-Chip (c22017) nur mit Schutz von oben; "mtd unlock firmware"
 * rechnet dann am falschen Ende, meldet Erfolg und aendert nichts. sysupgrade
 * schreibt so nur die Konfigurationspartition, Kernel und System bleiben alt.
 * Das Entsperren des GANZEN Chips setzt alle BP-Bits auf 0, egal von welcher
 * Seite geschuetzt war.
 */
#include <linux/module.h>
#include <linux/mtd/mtd.h>
#include <linux/err.h>

static char *part = "firmware";
module_param(part, charp, 0444);
MODULE_PARM_DESC(part, "MTD partition on the flash chip to unlock (default firmware)");

static int __init otm_spinor_unlock_init(void)
{
	struct mtd_info *mtd, *master;
	int ret;

	mtd = get_mtd_device_nm(part);
	if (IS_ERR(mtd)) {
		pr_err("otm-spinor-unlock: no mtd partition '%s'\n", part);
		return PTR_ERR(mtd);
	}
	master = mtd_get_master(mtd);
	if (!master->_unlock) {
		pr_info("otm-spinor-unlock: %s has no unlock operation\n", master->name);
		put_mtd_device(mtd);
		return 0;
	}
	ret = master->_unlock(master, 0, master->size);
	pr_info("otm-spinor-unlock: unlock %s (%llu bytes, via '%s'): %d\n",
		master->name, (unsigned long long)master->size, part, ret);
	put_mtd_device(mtd);
	return 0;
}

static void __exit otm_spinor_unlock_exit(void)
{
}

module_init(otm_spinor_unlock_init);
module_exit(otm_spinor_unlock_exit);
MODULE_DESCRIPTION("Unlock the whole SPI NOR flash (Ubiquiti XW bottom protection)");
MODULE_LICENSE("GPL");
