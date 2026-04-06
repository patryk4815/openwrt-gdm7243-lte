include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-gctd
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-gctd
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for GCT LTE modem
  DEPENDS:=+gctd +luci-base +luci-proto-gctd
  PKGARCH:=all
endef

define Build/Prepare
endef

define Build/Compile
endef

define Package/luci-app-gctd/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/gctd
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/gctd/status.js \
		$(1)/www/luci-static/resources/view/gctd/status.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/gctd/signal.js \
		$(1)/www/luci-static/resources/view/gctd/signal.js

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-gctd.json \
		$(1)/usr/share/luci/menu.d/luci-app-gctd.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-gctd.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-gctd.json
endef

$(eval $(call BuildPackage,luci-app-gctd))
