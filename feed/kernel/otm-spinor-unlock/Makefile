include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=otm-spinor-unlock
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define KernelPackage/otm-spinor-unlock
  SUBMENU:=Other modules
  TITLE:=Unlock the whole SPI NOR flash at boot (Ubiquiti XW)
  FILES:=$(PKG_BUILD_DIR)/otm-spinor-unlock.ko
  AUTOLOAD:=$(call AutoLoad,30,otm-spinor-unlock)
endef

define KernelPackage/otm-spinor-unlock/description
 Clears the block protect bits of the whole SPI NOR chip. On Ubiquiti XW
 boards the bootloader protects the lower part of the flash and the kernel
 unlocks the wrong end, so sysupgrade silently writes nothing but the
 overlay. Needs mtd_get_master (kernel 5.9+).
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(KERNEL_MAKE) M="$(PKG_BUILD_DIR)" modules
endef

$(eval $(call KernelPackage,otm-spinor-unlock))
