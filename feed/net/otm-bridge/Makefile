include $(TOPDIR)/rules.mk

PKG_NAME:=otm-bridge
PKG_VERSION:=0.18.5
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/otm-bridge
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=opentrafficmap.org C-ITS MQTT bridge
  DEPENDS:=+libpcap +libmosquitto +iw-full
endef

define Package/otm-bridge/description
 Capture raw 802.11(p) frames from a Linux monitor interface and
 publish them to opentrafficmap.org's MQTT ingest (cits1.opentrafficmap.org),
 mimicking the wire format used by the ESP32-C5 reference receiver.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS) $(TARGET_CPPFLAGS)" \
		LDFLAGS="$(TARGET_LDFLAGS)"
endef

define Package/otm-bridge/conffiles
/etc/config/otm-bridge
endef

define Package/otm-bridge/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/otm-bridge $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/otm-bridge.config $(1)/etc/config/otm-bridge
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/otm-bridge.init $(1)/etc/init.d/otm-bridge
	$(INSTALL_DIR) $(1)/lib/otm-bridge
	$(INSTALL_DATA) ./files/otm-bridge.functions $(1)/lib/otm-bridge/functions.sh
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/otm-bridge.run $(1)/usr/libexec/otm-bridge-run
	$(INSTALL_BIN) ./files/otm-uplink.run $(1)/usr/libexec/otm-uplink
	$(INSTALL_BIN) ./files/otm-uplink.init $(1)/etc/init.d/otm-uplink
	$(INSTALL_DIR) $(1)/etc/hotplug.d/ntp
	$(INSTALL_DATA) ./files/otm-bridge.ntp-hotplug $(1)/etc/hotplug.d/ntp/25-otm-bridge
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/uci-defaults/99-otm-setup $(1)/etc/uci-defaults/99-otm-setup
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/otm-configmode $(1)/usr/sbin/otm-configmode
	$(INSTALL_BIN) ./files/otm-help $(1)/usr/sbin/otm-help
	$(INSTALL_BIN) ./files/otm-configmode-early.init $(1)/etc/init.d/otm-configmode-early
	$(INSTALL_BIN) ./files/otm-configmode.init $(1)/etc/init.d/otm-configmode
	$(INSTALL_DIR) $(1)/etc/hotplug.d/button
	$(INSTALL_DATA) ./files/otm-configmode.button $(1)/etc/hotplug.d/button/50-otm-configmode
	$(INSTALL_DIR) $(1)/etc/profile.d
	$(INSTALL_DATA) ./files/otm-login.sh $(1)/etc/profile.d/otm.sh
endef

$(eval $(call BuildPackage,otm-bridge))
