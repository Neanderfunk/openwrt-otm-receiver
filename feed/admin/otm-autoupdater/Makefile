include $(TOPDIR)/rules.mk

PKG_NAME:=otm-autoupdater
PKG_VERSION:=1.0
PKG_RELEASE:=2

include $(INCLUDE_DIR)/package.mk

define Package/otm-autoupdater
  SECTION:=admin
  CATEGORY:=Administration
  TITLE:=Autoupdater for OTM receivers (Gluon manifest format)
  # nur Laufzeit-Abhaengigkeit, ecdsautils kommt fertig aus dem Release-Repo
  EXTRA_DEPENDS:=ecdsautils (>=0.3)
  PKGARCH:=all
endef

define Package/otm-autoupdater/description
 Checks a signed manifest in the Gluon autoupdater format once a day and
 runs sysupgrade (keeping the configuration) when a newer image for this
 board is listed. Signatures are verified with ecdsaverify against the
 configured public keys.
endef

define Package/otm-autoupdater/conffiles
/etc/config/autoupdater
endef

define Build/Compile
endef

define Package/otm-autoupdater/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/config $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/otm-autoupdater $(1)/usr/sbin/otm-autoupdater
	$(INSTALL_CONF) ./files/autoupdater.config $(1)/etc/config/autoupdater
	$(INSTALL_BIN) ./files/96-otm-autoupdater $(1)/etc/uci-defaults/96-otm-autoupdater
endef

$(eval $(call BuildPackage,otm-autoupdater))
