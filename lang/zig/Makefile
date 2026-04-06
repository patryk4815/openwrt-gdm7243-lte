include $(TOPDIR)/rules.mk

PKG_NAME:=zig
PKG_VERSION:=0.15.2
PKG_RELEASE:=1
PKG_LICENSE:=MIT

HOST_BUILD_DIR:=$(BUILD_DIR_HOST)/zig-$(PKG_VERSION)

include $(INCLUDE_DIR)/host-build.mk
include $(INCLUDE_DIR)/package.mk

# Detect host architecture
ZIG_HOST_OS:=linux
ZIG_HOST_ARCH:=$(shell uname -m)

ifeq ($(shell uname -s),Darwin)
  ZIG_HOST_OS:=macos
endif

ifeq ($(ZIG_HOST_ARCH),arm64)
  ZIG_HOST_ARCH:=aarch64
endif

ZIG_TAR:=zig-$(ZIG_HOST_ARCH)-$(ZIG_HOST_OS)-$(PKG_VERSION).tar.xz
ZIG_URL:=https://ziglang.org/download/$(PKG_VERSION)/$(ZIG_TAR)

define Package/zig
  SECTION:=lang
  CATEGORY:=Languages
  TITLE:=Zig programming language compiler (host tool)
  URL:=https://ziglang.org
endef

define Package/zig/description
  Zig compiler as a host tool for cross-compiling Zig programs for OpenWrt targets.
endef

define Host/Prepare
	mkdir -p $(HOST_BUILD_DIR)
	[ -f $(DL_DIR)/$(ZIG_TAR) ] || wget -O $(DL_DIR)/$(ZIG_TAR) $(ZIG_URL)
	tar -xf $(DL_DIR)/$(ZIG_TAR) -C $(HOST_BUILD_DIR) --strip-components=1
endef

define Host/Configure
endef

define Host/Compile
endef

define Host/Install
	$(INSTALL_DIR) $(STAGING_DIR_HOSTPKG)/bin
	$(INSTALL_BIN) $(HOST_BUILD_DIR)/zig $(STAGING_DIR_HOSTPKG)/bin/zig
	$(CP) $(HOST_BUILD_DIR)/lib $(STAGING_DIR_HOSTPKG)/lib/zig
endef

define Host/Clean
	rm -rf $(STAGING_DIR_HOSTPKG)/bin/zig
	rm -rf $(STAGING_DIR_HOSTPKG)/lib/zig
endef

$(eval $(call HostBuild))
$(eval $(call BuildPackage,zig))
