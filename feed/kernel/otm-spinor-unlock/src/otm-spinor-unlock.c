// SPDX-License-Identifier: GPL-2.0
/*
 * otm-spinor-unlock: hebt beim Laden den Schreibschutz des SPI-NOR auf.
 *
 * Ubiquiti-XW-Geraete (LiteBeam M5 XW) mit neuerem Ubiquiti-U-Boot kommen mit
 * gesetzten Block-Protect-Bits, die beim MX25L6405D (c22017) die UNTERE
 * Flash-Haelfte schuetzen (BP3 wirkt dort wie TB). Der Kernel rechnet mit
 * Schutz von oben: "mtd unlock" aendert nichts, das Entsperren des ganzen
 * Chips scheitert mit -EIO, sysupgrade schreibt nur die Konfigurationspartition.
 *
 * Das Statusregister steht nach dem Boot auf 0x9c (SRWD + BP0-2). Ein WRSR
 * greift erst, wenn der Schreibschutz-Pin des Flash (LiteBeam M5 XW: SoC-GPIO
 * 0, unter 19.07 "SPI nWP", im ath79-DTS faelschlich als PHY-Reset gefuehrt)
 * ausdruecklich physisch auf low gesetzt wird. Das Modul macht wie Linux 4.14
 * bei Macronix: WP-Pin setzen, WREN, WRSR 0x00 (1 Byte), warten, zuruecklesen,
 * WP-Pin zurueck. Am LiteBeam am 14.10.2026 erprobt: 0x9c -> 0x00, danach
 * schreibt sysupgrade Kernel und System.
 */
#include <linux/module.h>
#include <linux/mtd/mtd.h>
#include <linux/mtd/spi-nor.h>
#include <linux/spi/spi-mem.h>
#include <linux/slab.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/gpio/consumer.h>
#include <linux/gpio.h>

static char *part = "firmware";
module_param(part, charp, 0444);
MODULE_PARM_DESC(part, "MTD partition on the flash chip to unlock (default firmware)");

/* Schreibschutz-Pin (WP#) des Flash, globale GPIO-Nummer; -1 = nicht anfassen.
 * Am LiteBeam M5 XW SoC-GPIO 0 (OpenWrt 19.07: "SPI nWP"). Der Pin wird nur
 * fuer das Schreiben des Statusregisters auf wp_level gesetzt und danach auf
 * den alten Pegel zurueckgestellt. */
static int wp_gpio = -1;
module_param(wp_gpio, int, 0444);
static int wp_level;
module_param(wp_level, int, 0444);

static int nor_rdsr(struct spi_mem *mem, u8 *buf)
{
	struct spi_mem_op op = SPI_MEM_OP(SPI_MEM_OP_CMD(0x05, 1), SPI_MEM_OP_NO_ADDR,
					  SPI_MEM_OP_NO_DUMMY, SPI_MEM_OP_DATA_IN(1, buf, 1));
	return spi_mem_exec_op(mem, &op);
}

static int nor_cmd(struct spi_mem *mem, u8 opcode)
{
	struct spi_mem_op op = SPI_MEM_OP(SPI_MEM_OP_CMD(opcode, 1), SPI_MEM_OP_NO_ADDR,
					  SPI_MEM_OP_NO_DUMMY, SPI_MEM_OP_NO_DATA);
	return spi_mem_exec_op(mem, &op);
}

static int nor_wrsr(struct spi_mem *mem, u8 *buf)
{
	struct spi_mem_op op = SPI_MEM_OP(SPI_MEM_OP_CMD(0x01, 1), SPI_MEM_OP_NO_ADDR,
					  SPI_MEM_OP_NO_DUMMY, SPI_MEM_OP_DATA_OUT(1, buf, 1));
	return spi_mem_exec_op(mem, &op);
}

static int __init otm_spinor_unlock_init(void)
{
	struct mtd_info *mtd, *master;
	struct spi_nor *nor;
	u8 *buf;
	u8 before = 0xff;
	struct gpio_desc *wp = NULL;
	int wp_old = -1;
	int ret, i;

	mtd = get_mtd_device_nm(part);
	if (IS_ERR(mtd)) {
		pr_err("otm-spinor-unlock: no mtd partition '%s'\n", part);
		return PTR_ERR(mtd);
	}
	master = mtd_get_master(mtd);
	/* Die MTD-Struktur des Chips ist in struct spi_nor eingebettet */
	nor = container_of(master, struct spi_nor, mtd);
	if (!nor->spimem) {
		pr_info("otm-spinor-unlock: %s has no spi-mem access\n", master->name);
		goto out;
	}
	buf = kmalloc(1, GFP_KERNEL);
	if (!buf)
		goto out;

	mutex_lock(&nor->lock);
	if (wp_gpio >= 0) {
		wp = gpio_to_desc(wp_gpio);
		if (wp) {
			wp_old = gpiod_get_raw_value(wp);
			gpiod_set_raw_value(wp, wp_level);
			msleep(5);
			pr_info("otm-spinor-unlock: WP gpio %d: %d -> %d\n", wp_gpio, wp_old, wp_level);
		}
	}
	ret = nor_rdsr(nor->spimem, buf);
	before = *buf;
	pr_info("otm-spinor-unlock: %s SR before: 0x%02x (rdsr %d)\n", master->name, before, ret);
	if (!ret && (before & 0xbc)) {	/* SRWD (0x80) oder BP0-3 (0x3c) gesetzt */
		ret = nor_cmd(nor->spimem, 0x06);	/* WREN */
		*buf = 0x00;
		if (!ret)
			ret = nor_wrsr(nor->spimem, buf);	/* WRSR, 1 Byte */
		for (i = 0; i < 200 && !ret; i++) {	/* WIP abwarten, max. ~2 s */
			ret = nor_rdsr(nor->spimem, buf);
			if (ret || !(*buf & 0x01))
				break;
			msleep(10);
		}
		pr_info("otm-spinor-unlock: %s SR after WRSR 0: 0x%02x (ret %d)\n",
			master->name, *buf, ret);
	}
	if (wp && wp_old >= 0)
		gpiod_set_raw_value(wp, wp_old);
	mutex_unlock(&nor->lock);
	kfree(buf);
out:
	put_mtd_device(mtd);
	return 0;
}

static void __exit otm_spinor_unlock_exit(void)
{
}

module_init(otm_spinor_unlock_init);
module_exit(otm_spinor_unlock_exit);
MODULE_DESCRIPTION("Clear SPI NOR status register like Linux 4.14 did (Ubiquiti XW)");
MODULE_LICENSE("GPL");
