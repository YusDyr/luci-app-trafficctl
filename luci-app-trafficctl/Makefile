include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-trafficctl
PKG_VERSION:=1.13.4
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Denis Iusupov <yusdyr@gmail.com>

LUCI_TITLE:=LuCI Traffic Control
LUCI_DESCRIPTION:=Per-device traffic monitoring, rate limiting (nft/iptables), \
 traffic shaping (tc/HTB), internet blocking, and WiFi MAC filtering.
LUCI_DEPENDS:=+conntrack +luci-base +rpcd +curl +tc +iw +hostapd-utils
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# Only list files that ship in the package and may be user-edited.
# shapes.json / telegram_known.json are runtime state created by scripts; they
# survive sysupgrade via root/lib/upgrade/keep.d/ instead.
define Package/$(PKG_NAME)/conffiles
/etc/config/trafficctl
endef

# The config holds the Telegram bot token and the metrics token, so it must not
# be world-readable before the first save from the UI applies the same mode.
define Package/$(PKG_NAME)/postinst
#!/bin/sh
chmod 0600 "$${IPKG_INSTROOT}/etc/config/trafficctl" 2>/dev/null || true
exit 0
endef

# call BuildPackage - OpenWrt buildroot will pick up the standard LuCI layout
$(eval $(call BuildPackage,$(PKG_NAME)))
