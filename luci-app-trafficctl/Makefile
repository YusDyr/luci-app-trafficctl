include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-trafficctl
PKG_VERSION:=1.5.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Denis Iusupov <yusdyr@gmail.com>

LUCI_TITLE:=LuCI Traffic Control
LUCI_DESCRIPTION:=Per-device traffic monitoring, rate limiting (nft/iptables), \
 traffic shaping (tc/HTB), internet blocking, and WiFi MAC filtering.
LUCI_DEPENDS:=+conntrack +luci-base +rpcd +curl
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# Only list files that ship in the package and may be user-edited.
# shapes.json / telegram_known.json are runtime state created by scripts.
define Package/$(PKG_NAME)/conffiles
/etc/config/trafficctl
endef

# call BuildPackage - OpenWrt buildroot will pick up the standard LuCI layout
$(eval $(call BuildPackage,$(PKG_NAME)))
