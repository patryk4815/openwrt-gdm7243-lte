include $(TOPDIR)/rules.mk

PKG_NAME:=luci-proto-gctd
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/luci-proto-gctd
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=5. Protocols
  TITLE:=Support for GCT LTE (gctd)
  DEPENDS:=+gctd
  PKGARCH:=all
endef

define Build/Prepare
endef

define Build/Compile
endef

define Package/luci-proto-gctd/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/protocol
	$(INSTALL_DATA) ./htdocs/luci-static/resources/protocol/gctd.js \
		$(1)/www/luci-static/resources/protocol/gctd.js
endef

$(eval $(call BuildPackage,luci-proto-gctd))
