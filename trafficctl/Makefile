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
PKG_VERSION:=1.30.3
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Denis Iusupov <yusdyr@gmail.com>

include $(INCLUDE_DIR)/package.mk

# hostapd-utils is deliberately not a dependency: it can only be selected
# together with a hostapd/wpad variant, so depending on it would make this
# package unselectable on wired-only builds. The WiFi block helpers check for
# hostapd_cli at run time and fall back to a timed ubus ban
# (tctl_hostapd_block_iface, tctl_wifi_filter_support in trafficctl-fw.sh).
# iw stays: it is selectable on every target and only reads station lists.
#
# kmod-nft-netdev carries CONFIG_NF_TABLES_NETDEV, the nft family of the
# limiter's table (netdev tm_ratelimit); firewall4 does not pull it in. It is
# unconditional: build-ipk.sh cannot express a condition, and on a fw3 router
# it only adds unused modules.
# iptables-mod-hashlimit (the fw3 limiter) is not declared: a condition on
# PACKAGE_firewall holds in any build that selects all packages, which would
# pull iptables onto fw4 routers. fw3 reports and logs its absence instead.
define Package/trafficctl
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Per-device traffic monitoring and control
  URL:=https://github.com/YusDyr/luci-app-trafficctl
  DEPENDS:=+conntrack +curl +tc +iw +kmod-nft-netdev
  PKGARCH:=all
endef

define Package/trafficctl/description
 Per-device traffic monitoring (conntrack), rate limiting (nft/iptables),
 traffic shaping (tc/HTB), internet blocking, WiFi MAC filtering, a global
 internet cut, a Telegram bot and a Prometheus exporter. The web interface
 is luci-app-trafficctl.
 WiFi MAC filtering needs hostapd-utils, which is optional so the package can
 be installed on wired-only builds. Without it a WiFi block is a temporary
 (one hour) hostapd ban over ubus.
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
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-rules.sh $(1)/usr/libexec/trafficctl/
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
# Services follow their uci flag, so the state after an install or an upgrade
# is the state after the next reboot. Boot only runs what rc.d enables, and
# the released packages never enabled trafficctl-telegram: the postinst
# started the bot unconditionally and the Settings toggle only reloaded it.
# A bot switched on in the UI therefore ran until the next reboot and was then
# gone, and an upgrade brought it back until the reboot after that. When the
# flag is 1 the service is enabled and started; when it is 0 nothing is
# started or enabled (the init script would not start the bot anyway). The
# same goes for history.enabled. rc.d is never disabled here: the SDK's
# default_postinst, which runs after this script, enables every init script
# on a fresh install, and the flag check in each service keeps that harmless.
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
	# Releases up to 1.30.1 gave the cut keeper START=95, so rc.d may
	# still link it for boot. It is started on demand only.
	rm -f /etc/rc.d/S95trafficctl-cut /etc/rc.d/K10trafficctl-cut
	if [ -x /etc/init.d/trafficctl-telegram ] && [ "$$(uci -q get trafficctl.telegram.enabled)" = "1" ]; then
		/etc/init.d/trafficctl-telegram enable 2>/dev/null || true
		/etc/init.d/trafficctl-telegram start 2>/dev/null || true
	fi
	if [ -x /etc/init.d/trafficctl-history ]; then
		if [ "$$(uci -q get trafficctl.history.enabled)" = "1" ]; then
			/etc/init.d/trafficctl-history enable 2>/dev/null || true
		fi
		if /etc/init.d/trafficctl-history enabled; then
			/etc/init.d/trafficctl-history restart 2>/dev/null || true
		fi
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
