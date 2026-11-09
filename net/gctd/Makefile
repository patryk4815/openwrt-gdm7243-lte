include $(TOPDIR)/rules.mk

PKG_NAME:=gctd
PKG_VERSION:=1.3.0
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
  DEPENDS:=@(mipsel||mips||mips64||aarch64||arm||i386||x86_64||riscv64) @!arm_v5
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

# Map OpenWrt target to Zig target triple (and CPU model where Zig's
# baseline would be too new for some OpenWrt subtargets)
ZIG_TARGET:=
ZIG_CPU:=
ifeq ($(ARCH),mipsel)
  ZIG_TARGET:=mipsel-linux-musl
endif
ifeq ($(ARCH),mips)
  ZIG_TARGET:=mips-linux-musl
endif
ifeq ($(ARCH),mips64)
  ZIG_TARGET:=mips64-linux-muslabi64
endif
ifeq ($(ARCH),aarch64)
  ZIG_TARGET:=aarch64-linux-musl
endif
ifeq ($(ARCH),arm)
  ifeq ($(CONFIG_SOFT_FLOAT),y)
    ZIG_TARGET:=arm-linux-musleabi
  else
    ZIG_TARGET:=arm-linux-musleabihf
  endif
  ifneq ($(filter cortex-a5 cortex-a7 cortex-a8 cortex-a9 cortex-a15 cortex-a53 cortex-a72 arm1176jzf-s mpcore,$(CPU_TYPE)),)
    ZIG_CPU:=$(subst -,_,$(CPU_TYPE))
  endif
endif
ifeq ($(ARCH),i386)
  ZIG_TARGET:=x86-linux-musl
  # Zig's x86 baseline is pentium4 (SSE2); legacy/geode subtargets are older
  ifneq ($(filter pentium-mmx geode,$(CPU_TYPE)),)
    ZIG_CPU:=$(subst -,_,$(CPU_TYPE))
  endif
endif
ifeq ($(ARCH),x86_64)
  ZIG_TARGET:=x86_64-linux-musl
endif
ifeq ($(ARCH),riscv64)
  ZIG_TARGET:=riscv64-linux-musl
endif

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(CURDIR)/../../src $(PKG_BUILD_DIR)/src
	$(CP) $(CURDIR)/../../build.zig $(PKG_BUILD_DIR)/build.zig
endef

define Build/Compile
	$(if $(ZIG_TARGET),,$(error gctd: unsupported ARCH '$(ARCH)'))
	cd $(PKG_BUILD_DIR) && \
	$(STAGING_DIR_HOSTPKG)/bin/zig build \
		--zig-lib=$(STAGING_DIR_HOSTPKG)/lib/zig \
		-Dtarget=$(ZIG_TARGET) \
		$(if $(ZIG_CPU),-Dcpu=$(ZIG_CPU)) \
		--release=small
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
