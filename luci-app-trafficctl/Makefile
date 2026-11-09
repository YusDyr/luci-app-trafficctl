include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-trafficctl
PKG_VERSION:=1.28.1
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
#
# rpcd only learns about a plugin when it starts, so without the restart below
# every ubus call lands on "Object not found" (-32000) and the dashboard is
# empty until the router is rebooted. build-ipk.sh and build-apk.sh have always
# done this in their own postinst; this Makefile did not, and the RELEASED
# packages are the ones built from here through the SDK — so the bug only ever
# reached the people installing the published artifacts.
#
# Guarded on IPKG_INSTROOT: when it is set the package is being unpacked into
# an image being built, where there is no running rpcd to talk to.
#
# The history sampler is a long-running loop that calls its sibling scripts by
# absolute path. Releases up to 1.28.0 installed them under /usr/local/bin, so
# a sampler started by one of those keeps calling paths the upgrade has just
# removed and records nothing until the next reboot. Restarting it picks up
# the new init script.
define Package/$(PKG_NAME)/postinst
#!/bin/sh
chmod 0600 "$${IPKG_INSTROOT}/etc/config/trafficctl" 2>/dev/null || true
if [ -z "$${IPKG_INSTROOT}" ]; then
	/etc/init.d/rpcd restart 2>/dev/null || true
	if [ -x /etc/init.d/trafficctl-telegram ]; then
		/etc/init.d/trafficctl-telegram start 2>/dev/null || true
	fi
	if [ -x /etc/init.d/trafficctl-history ] && /etc/init.d/trafficctl-history enabled; then
		/etc/init.d/trafficctl-history restart 2>/dev/null || true
	fi
fi
exit 0
endef

# Fail open on removal. A global internet cut left engaged by a package that is
# going away is a lockout with no UI left to undo it — the drop rule would sit
# in nftables with nothing on the router admitting to owning it.
define Package/$(PKG_NAME)/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ] && [ -x /usr/libexec/trafficctl/trafficctl-cut.sh ]; then
	/usr/libexec/trafficctl/trafficctl-cut.sh release >/dev/null 2>&1 || true
fi
exit 0
endef

# No explicit $(eval $(call BuildPackage,...)) here: luci.mk already calls it
# for the main package, so the explicit call was a duplicate. Spotted by
# @ntbowen in #73.
