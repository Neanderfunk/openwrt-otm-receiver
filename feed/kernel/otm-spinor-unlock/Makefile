include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=otm-spinor-unlock
PKG_RELEASE:=3
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define KernelPackage/otm-spinor-unlock
  SUBMENU:=Other modules
  TITLE:=Unlock the whole SPI NOR flash at boot (Ubiquiti XW)
  FILES:=$(PKG_BUILD_DIR)/otm-spinor-unlock.ko
endef

define KernelPackage/otm-spinor-unlock/description
 Releases the SPI flash write-protect pin and clears the status register
 (block protect + SRWD) the way Linux 4.14 did for Macronix chips. On the
 Ubiquiti LiteBeam M5 XW the bootloader leaves the lower flash protected and
 sysupgrade silently writes nothing but the overlay. Needs kernel 5.9+.
endef

# Laden mit dem Schreibschutz-Pin des LiteBeam M5 XW (SoC-GPIO 0, global 512
# unter Kernel 6.12). Nur fuer Ubiquiti-XW-Boards ins Image nehmen (build.sh: XW).
# modules-boot.d, nicht modules.d: mount_root (preinit) muss das Overlay schon
# loeschen koennen, sonst Rueckfall auf RAM-Overlay und die gesicherte
# Konfiguration kommt nach sysupgrade nicht zurueck.
define KernelPackage/otm-spinor-unlock/install
	$(INSTALL_DIR) $(1)/etc/modules-boot.d
	echo "otm-spinor-unlock wp_gpio=512 wp_level=0" > $(1)/etc/modules-boot.d/30-otm-spinor-unlock
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(KERNEL_MAKE) M="$(PKG_BUILD_DIR)" modules
endef

$(eval $(call KernelPackage,otm-spinor-unlock))
