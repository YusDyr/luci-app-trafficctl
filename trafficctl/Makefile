# SPDX-License-Identifier: Apache-2.0
#
# The backend of luci-app-trafficctl: the helper scripts, the init scripts, the
# hotplug hooks, the config and the metrics CGI. Everything except the LuCI
# view and its rpcd plugin, which stay in ../luci-app-trafficctl, so the
# backend can run (Telegram bot, Prometheus exporter, the helpers from a
# shell) on a router without LuCI.
#
# An upgrade from a release that still shipped everything in
# luci-app-trafficctl needs nothing special here: opkg and apk both hand a
# file to its new owner when the old owner is upgraded in the same run and no
# longer carries it. Do NOT add CONFLICTS:=luci-app-trafficctl: the new
# luci-app-trafficctl depends on this package, so the conflict makes that very
# upgrade impossible.

include $(TOPDIR)/rules.mk

PKG_NAME:=trafficctl
# Released in lockstep with luci-app-trafficctl: auto-release.yml sets both
# PKG_VERSIONs to the same value.
PKG_VERSION:=1.29.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Denis Iusupov <yusdyr@gmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/trafficctl
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Per-device traffic monitoring and control
  URL:=https://github.com/YusDyr/luci-app-trafficctl
  DEPENDS:=+conntrack +curl +tc +iw +hostapd-utils
  PKGARCH:=all
endef

define Package/trafficctl/description
 Per-device traffic monitoring (conntrack), rate limiting (nft/iptables),
 traffic shaping (tc/HTB), internet blocking, WiFi MAC filtering, a global
 internet cut, a Telegram bot and a Prometheus exporter. The web interface
 is luci-app-trafficctl.
endef

# Only list files that ship in the package and may be user-edited.
# shapes.json / telegram_known.json are runtime state created by scripts; they
# survive sysupgrade via /lib/upgrade/keep.d/trafficctl instead.
define Package/trafficctl/conffiles
/etc/config/trafficctl
endef

define Build/Compile
endef

# Every file is listed by name rather than globbed. tests/test_package_split.sh
# compares this list with the tree under files/, so a new file that is not
# added here fails the suite instead of going missing from the release.
define Package/trafficctl/install
	$(INSTALL_DIR) $(1)/usr/libexec/trafficctl
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-block.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-bytes-nft.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-bytes.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-cut.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-device.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-fw.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-history.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-ifaces.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-macfilter-add.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-macfilter-remove.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-metrics.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-names.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-netify.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-portfw.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-ratelimit-stats.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-ratelimit.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-rdns-refresh.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-rdns.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-shape-stats.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-shape.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-subnets.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-summary.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-telegram-test.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-telegram.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-totals.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-unblock.sh $(1)/usr/libexec/trafficctl/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/trafficctl $(1)/etc/config/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/trafficctl-cut $(1)/etc/init.d/
	$(INSTALL_BIN) ./files/etc/init.d/trafficctl-history $(1)/etc/init.d/
	$(INSTALL_BIN) ./files/etc/init.d/trafficctl-telegram $(1)/etc/init.d/
	$(INSTALL_DIR) $(1)/etc/hotplug.d/dhcp
	$(INSTALL_DATA) ./files/etc/hotplug.d/dhcp/99-trafficctl-newdevice $(1)/etc/hotplug.d/dhcp/
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DATA) ./files/etc/hotplug.d/iface/99-trafficctl-shapes $(1)/etc/hotplug.d/iface/
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/trafficctl $(1)/lib/upgrade/keep.d/
	$(INSTALL_DIR) $(1)/www/cgi-bin
	$(INSTALL_BIN) ./files/www/cgi-bin/trafficctl-metrics $(1)/www/cgi-bin/
endef

# The config holds the Telegram bot token and the metrics token, so it must not
# be world-readable before the first save from the UI applies the same mode.
#
# The history sampler is a long-running loop that calls its sibling scripts by
# absolute path. Releases up to 1.28.0 installed them under /usr/local/bin, so
# a sampler started by one of those keeps calling paths the upgrade has just
# removed and records nothing until the next reboot. Restarting it picks up
# the new init script.
#
# trafficctl-opkg.backup: when /etc/config/trafficctl moves here from the
# single luci-app-trafficctl package of releases up to 1.28.x, opkg saves the
# user's modified copy under that name as it drops the old owner's conffile.
# The config itself is kept, so the copy is clutter. It is removed only while
# the real file is there, and nothing else is touched.
#
# Guarded on IPKG_INSTROOT: when it is set the package is being unpacked into
# an image being built, where there are no running services to talk to.
define Package/trafficctl/postinst
#!/bin/sh
chmod 0600 "$${IPKG_INSTROOT}/etc/config/trafficctl" 2>/dev/null || true
if [ -z "$${IPKG_INSTROOT}" ]; then
	if [ -f /etc/config/trafficctl ]; then
		rm -f /etc/config/trafficctl-opkg.backup
	fi
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
# going away is a lockout with no UI left to undo it: the drop rule would sit
# in nftables with nothing on the router admitting to owning it.
define Package/trafficctl/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ] && [ -x /usr/libexec/trafficctl/trafficctl-cut.sh ]; then
	/usr/libexec/trafficctl/trafficctl-cut.sh release >/dev/null 2>&1 || true
fi
exit 0
endef

$(eval $(call BuildPackage,trafficctl))
