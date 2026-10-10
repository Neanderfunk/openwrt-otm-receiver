include $(TOPDIR)/rules.mk

PKG_NAME:=otm-mgmt-vpn
PKG_VERSION:=1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/otm-mgmt-vpn
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OTM management VPN (fastd to wgiot6.ffdus.de)
  # nur Laufzeit-Abhaengigkeit: fastd/kmod-tun kommen fertig aus dem
  # Release-Repo; als DEPENDS wuerde das SDK fastd selbst bauen (21.02:
  # scheitert am Host-ninja). Versionsangaben verlangt das SDK ab 25.12.
  EXTRA_DEPENDS:=fastd (>=21), kmod-tun (>=5)
  PKGARCH:=all
endef

define Package/otm-mgmt-vpn/description
 Joins the receiver to the OTM management network: fastd in tap mode with
 a per-device key (no enrolment on the server), DHCP on interface mgmt
 without default route or DNS, SSH reachable as <node>.otm.
endef

define Build/Compile
endef

define Package/otm-mgmt-vpn/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/98-otm-mgmt-vpn $(1)/etc/uci-defaults/98-otm-mgmt-vpn
endef

$(eval $(call BuildPackage,otm-mgmt-vpn))
