include $(TOPDIR)/rules.mk

PKG_NAME:=zig
PKG_VERSION:=0.15.2
PKG_RELEASE:=1
PKG_LICENSE:=MIT

PKG_BUILD_DIR:=$(BUILD_DIR_HOST)/zig-$(PKG_VERSION)

include $(INCLUDE_DIR)/host-build.mk
include $(INCLUDE_DIR)/package.mk

# Detect host architecture
ZIG_HOST_OS:=linux
ZIG_HOST_ARCH:=$(shell uname -m)

ifeq ($(shell uname -s),Darwin)
  ZIG_HOST_OS:=macos
endif

# Map host arch names
ifeq ($(ZIG_HOST_ARCH),arm64)
  ZIG_HOST_ARCH:=aarch64
endif

ZIG_TAR:=zig-$(ZIG_HOST_OS)-$(ZIG_HOST_ARCH)-$(PKG_VERSION).tar.xz
ZIG_URL:=https://ziglang.org/download/$(PKG_VERSION)/$(ZIG_TAR)

define Package/zig
  SECTION:=lang
  CATEGORY:=Languages
  TITLE:=Zig programming language compiler
  URL:=https://ziglang.org
endef

define Package/zig/description
  Zig is a general-purpose programming language and build system.
  This package provides the Zig compiler as a host tool for
  cross-compiling Zig programs for OpenWrt targets.
endef

define Host/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	if [ ! -f $(DL_DIR)/$(ZIG_TAR) ]; then \
		wget -O $(DL_DIR)/$(ZIG_TAR) $(ZIG_URL); \
	fi
	tar -xf $(DL_DIR)/$(ZIG_TAR) -C $(PKG_BUILD_DIR) --strip-components=1
endef

define Host/Compile
endef

define Host/Install
	$(INSTALL_DIR) $(STAGING_DIR_HOSTPKG)/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/zig $(STAGING_DIR_HOSTPKG)/bin/zig
	$(CP) $(PKG_BUILD_DIR)/lib $(STAGING_DIR_HOSTPKG)/lib/zig
endef

define Host/Clean
	rm -rf $(STAGING_DIR_HOSTPKG)/bin/zig
	rm -rf $(STAGING_DIR_HOSTPKG)/lib/zig
endef

$(eval $(call HostBuild))
$(eval $(call BuildPackage,zig))
