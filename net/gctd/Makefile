include $(TOPDIR)/rules.mk

PKG_NAME:=gctd
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Patryk Sondej <patryk.sondej@gmail.com>

PKG_BUILD_DEPENDS:=zig/host

include $(INCLUDE_DIR)/package.mk

define Package/gctd
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=GCT GDM7243 LTE modem daemon
  DEPENDS:=+kmod-8021q
  URL:=https://github.com/patryk4815/openwrt-gdm7243-lte
endef

define Package/gctd/description
  Lightweight daemon for GCT GDM7243 LTE modem connected via Ethernet.
  Handles AT commands over TCP, UDP keepalive, LTE connection management,
  signal monitoring, cell locking, SMS, and netifd integration (proto gctd).
  Written in Zig, cross-compiles to a single static binary (~130KB).
endef

define Package/gctd/conffiles
/etc/config/gctd
endef

# Map OpenWrt target to Zig target triple
ZIG_TARGET:=mipsel-linux-musl
ifeq ($(ARCH),aarch64)
  ZIG_TARGET:=aarch64-linux-musl
endif
ifeq ($(ARCH),arm)
  ZIG_TARGET:=arm-linux-musleabihf
endif
ifeq ($(ARCH),x86_64)
  ZIG_TARGET:=x86_64-linux-musl
endif

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(CURDIR)/../../src $(PKG_BUILD_DIR)/src
	$(CP) $(CURDIR)/../../build.zig $(PKG_BUILD_DIR)/build.zig
endef

define Build/Compile
	cd $(PKG_BUILD_DIR) && \
	$(STAGING_DIR_HOSTPKG)/bin/zig build \
		-Dtarget=$(ZIG_TARGET) \
		--release=small \
		--zig-lib-dir $(STAGING_DIR_HOSTPKG)/lib/zig
endef

define Package/gctd/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/zig-out/bin/gctd $(1)/usr/sbin/gctd

	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) ./files/gctd.sh $(1)/lib/netifd/proto/gctd.sh

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/gctd.config $(1)/etc/config/gctd

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/gctd.rpcd $(1)/usr/libexec/rpcd/gctd
endef

$(eval $(call BuildPackage,gctd))
