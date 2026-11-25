# SPDX-License-Identifier: Apache-2.0
#
# The backend of luci-app-trafficctl: the trafficctl CLI and its ucode
# modules, the init scripts, the hotplug hooks, the config and the metrics
# CGI. Everything except the LuCI view and its rpcd plugin, which stay in
# ../luci-app-trafficctl, so the backend can run (notifications, Prometheus
# exporter, `trafficctl <command>` from a shell) on a router without LuCI.
#
# Releases up to 1.30.x shipped the commands as shell scripts in
# /usr/libexec/trafficctl; 2.0.0 removes them. A cron line or a script that
# called one runs `trafficctl <command>` instead, with the same arguments and
# the same JSON on stdout.
#
# The Telegram bot is a second package from this Makefile, trafficctl-telegram:
# a resident process that a router without a bot should not carry.
# trafficctl-shaper and trafficctl-wifi are two more, dependencies only, and
# trafficctl-full pulls in all of them: see the table above Package/trafficctl.
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
PKG_VERSION:=2.3.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Denis Iusupov <yusdyr@gmail.com>

include $(INCLUDE_DIR)/package.mk

# The packages built here, and why each dependency is there. trafficctl is
# the core; each optional part is a package that only pulls in what that part
# needs, so a router carries the combination it uses (trafficctl-shaper and
# trafficctl-wifi hold no files of their own). Without a part the core checks
# for its tools at run time and says which package to install; `trafficctl
# device` reports shaping and wifi_filter, so the view hides or qualifies the
# control.
#
#   package             dependency       what needs it
#   trafficctl          firewall4        blocks, the port-forward controls and
#                                        the cut are nft rules next to fw4's
#                                        table; nftables alone is not enough
#                       kmod-nft-netdev  the limiter's table, netdev
#                                        tm_ratelimit; firewall4 does not pull
#                                        it in
#                       conntrack        flushing a device's flows when it is
#                                        blocked, limited or cut, so the rule
#                                        applies to connections already open
#                       ucode, ucode-mod-fs, ucode-mod-uci, ucode-mod-ubus
#                                        the CLI and every module
#   trafficctl-shaper   tc               the shaper (tc/HTB); tc-tiny is
#                                        enough, tc-full adds only iptables
#                                        actions, ipset and eBPF
#                       kmod-sched-core  sch_htb, cls_u32, sch_ingress and
#                                        act_mirred (there is no
#                                        kmod-sched-htb); fq_codel is built
#                                        into OpenWrt's kernel
#                       kmod-ifb         the upload half; without it the
#                                        shaper applies download only and says
#                                        so
#   trafficctl-wifi     iw               WiFi clients, band and signal in the
#                                        device list and the device scan
#                       hostapd-utils    hostapd_cli: a WiFi block in the
#                                        radio's ACL. Without it the block is a
#                                        one-hour hostapd ban over ubus. It can
#                                        only be selected with a hostapd/wpad
#                                        variant, which is why it is not on
#                                        trafficctl
#   trafficctl-telegram curl             the bot's API calls
#   trafficctl-full     the four above   everything; what luci-app-trafficctl
#                                        depends on and the default install
#
# curl is on no package but the bot: the ntfy, webhook and Telegram senders
# need it, the ubus events, hotplug scripts and mail do not, and a sender
# without it replies "curl is not installed".
define Package/trafficctl
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Per-device traffic monitoring and control
  URL:=https://github.com/YusDyr/luci-app-trafficctl
  DEPENDS:=+conntrack +kmod-nft-netdev +firewall4 +ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus
  PKGARCH:=all
endef

define Package/trafficctl-shaper
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Traffic shaping (tc/HTB) for trafficctl
  URL:=https://github.com/YusDyr/luci-app-trafficctl
  DEPENDS:=+trafficctl +tc +kmod-sched-core +kmod-ifb
  EXTRA_DEPENDS:=trafficctl (=$(PKG_VERSION)-r$(PKG_RELEASE))
  PKGARCH:=all
endef

define Package/trafficctl-wifi
  SECTION:=net
  CATEGORY:=Network
  TITLE:=WiFi clients and WiFi blocking for trafficctl
  URL:=https://github.com/YusDyr/luci-app-trafficctl
  DEPENDS:=+trafficctl +iw +hostapd-utils
  EXTRA_DEPENDS:=trafficctl (=$(PKG_VERSION)-r$(PKG_RELEASE))
  PKGARCH:=all
endef

define Package/trafficctl-telegram
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Telegram bot for trafficctl
  URL:=https://github.com/YusDyr/luci-app-trafficctl
  DEPENDS:=+trafficctl +curl
  # Pinned to the same build: the bot loads trafficctl's modules, and both
  # come from the same source, so a newer core next to an older bot is a
  # pairing nobody tested.
  EXTRA_DEPENDS:=trafficctl (=$(PKG_VERSION)-r$(PKG_RELEASE))
  PKGARCH:=all
endef

define Package/trafficctl-full
  SECTION:=net
  CATEGORY:=Network
  TITLE:=trafficctl with every optional part
  URL:=https://github.com/YusDyr/luci-app-trafficctl
  DEPENDS:=+trafficctl +trafficctl-shaper +trafficctl-wifi +trafficctl-telegram
  EXTRA_DEPENDS:=trafficctl (=$(PKG_VERSION)-r$(PKG_RELEASE)), trafficctl-shaper (=$(PKG_VERSION)-r$(PKG_RELEASE)), trafficctl-wifi (=$(PKG_VERSION)-r$(PKG_RELEASE)), trafficctl-telegram (=$(PKG_VERSION)-r$(PKG_RELEASE))
  PKGARCH:=all
endef

define Package/trafficctl/description
 Per-device traffic monitoring (conntrack), rate limiting (nftables),
 internet blocking, a global internet cut, port-forward control, device
 notifications and a Prometheus exporter. Optional parts are packages of
 their own: trafficctl-shaper (traffic shaping with tc/HTB), trafficctl-wifi
 (WiFi clients and WiFi MAC filtering), trafficctl-telegram (the Telegram
 bot). The web interface is luci-app-trafficctl. The ntfy, webhook and
 Telegram notification senders need curl.
endef

define Package/trafficctl-shaper/description
 Traffic shaping for trafficctl: per-device tc/HTB queues on the LAN device
 (download) and an IFB device (upload). Pulls in tc, kmod-sched-core and
 kmod-ifb; holds no files of its own.
endef

define Package/trafficctl-wifi/description
 WiFi support for trafficctl: the WiFi clients with their band and signal,
 and WiFi MAC filtering through the radio's ACL. Pulls in iw and
 hostapd-utils; holds no files of its own. Without hostapd-utils a WiFi block
 is a temporary (one hour) hostapd ban over ubus.
endef

define Package/trafficctl-full/description
 trafficctl with every optional part: trafficctl-shaper, trafficctl-wifi and
 trafficctl-telegram. Holds no files of its own; install trafficctl and only
 the parts you need instead for a smaller install.
endef

define Package/trafficctl-telegram/description
 A Telegram bot for trafficctl: device status, and block, WiFi block,
 limit and shape buttons per device. Configured in /etc/config/trafficctl
 (section telegram) or from luci-app-trafficctl.
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
# compares this list and the one of trafficctl-telegram with the tree under
# files/, so a new file that is not added here fails the suite instead of
# going missing from the release.
define Package/trafficctl/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/trafficctl $(1)/usr/sbin/
	$(INSTALL_DIR) $(1)/usr/share/ucode/trafficctl
	$(INSTALL_DATA) ./files/usr/share/ucode/trafficctl/lib.uc $(1)/usr/share/ucode/trafficctl/
	$(INSTALL_DATA) ./files/usr/share/ucode/trafficctl/net.uc $(1)/usr/share/ucode/trafficctl/
	$(INSTALL_DATA) ./files/usr/share/ucode/trafficctl/report.uc $(1)/usr/share/ucode/trafficctl/
	$(INSTALL_DATA) ./files/usr/share/ucode/trafficctl/ctl.uc $(1)/usr/share/ucode/trafficctl/
	$(INSTALL_DATA) ./files/usr/share/ucode/trafficctl/notify.uc $(1)/usr/share/ucode/trafficctl/
	$(INSTALL_DATA) ./files/usr/share/ucode/trafficctl/cut.uc $(1)/usr/share/ucode/trafficctl/
	$(INSTALL_DATA) ./files/usr/share/ucode/trafficctl/portfw.uc $(1)/usr/share/ucode/trafficctl/
	$(INSTALL_DATA) ./files/usr/share/ucode/trafficctl/history.uc $(1)/usr/share/ucode/trafficctl/
	$(INSTALL_DATA) ./files/usr/share/ucode/trafficctl/limit.uc $(1)/usr/share/ucode/trafficctl/
	$(INSTALL_DATA) ./files/usr/share/ucode/trafficctl/shape.uc $(1)/usr/share/ucode/trafficctl/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/trafficctl $(1)/etc/config/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/trafficctl-cut $(1)/etc/init.d/
	$(INSTALL_BIN) ./files/etc/init.d/trafficctl-history $(1)/etc/init.d/
	$(INSTALL_BIN) ./files/etc/init.d/trafficctl-notify $(1)/etc/init.d/
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/80_trafficctl-notify $(1)/etc/uci-defaults/
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
# same goes for history.enabled, and for the bot, which is its own package
# now: trafficctl-telegram's postinst applies the rule to it. rc.d is never
# disabled here: the SDK's default_postinst, which runs after this script,
# enables every init script on a fresh install, and the flag check in each
# service keeps that harmless.
#
# The history sampler is a long-running loop. One started by a release up to
# 1.30.x is a shell loop that calls the scripts in /usr/libexec/trafficctl
# (under /usr/local/bin up to 1.28.0) by absolute path, which this upgrade
# removes: it would record nothing until the next reboot. Restarting it picks
# up the new init script, `trafficctl history keeper`.
#
# The cut keeper is restarted when a cut is engaged: one started by an older
# release runs that release's code (a shell loop until 1.30.x) until it ends,
# and procd only starts the new command, `trafficctl cut keeper`, on a restart.
#
# trafficctl_mon: releases up to 1.30.x built this nft table for a per-device
# byte counter under flow offload. No kernel accepted its dynamic counter maps,
# so it was often left half-built, a forward chain with nothing reading it.
# Byte counts come from conntrack now; the table is dropped if it is there.
#
# trafficctl-opkg.backup: when /etc/config/trafficctl moves here from the
# single luci-app-trafficctl package of releases up to 1.28.x, opkg saves the
# user's modified copy under that name as it drops the old owner's conffile.
# The config itself is kept, so the copy is clutter. It is removed only while
# the real file is there, and nothing else is touched.
#
# rpcd: luci-app-trafficctl's plugin runs inside rpcd (rpcd-mod-ucode), which
# loads it and the trafficctl modules it imports once, when rpcd starts. An
# upgrade of this package alone reaches the plugin only when rpcd starts over.
# `/etc/init.d/rpcd reload` (SIGHUP) does that: rpcd re-executes itself,
# loads its plugins anew and keeps its sessions, as rpcd-mod-ucode's own
# postinst does. A restart would log every LuCI user out. The upgrade itself
# is safe either way: LuCI's software page runs opkg/apk through cgi-io
# (/cgi-bin/cgi-exec) under uhttpd, not as a child of rpcd.
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
	nft delete table inet trafficctl_mon 2>/dev/null || true
	# Releases up to 1.30.1 gave the cut keeper START=95, so rc.d may
	# still link it for boot. It is started on demand only.
	rm -f /etc/rc.d/S95trafficctl-cut /etc/rc.d/K10trafficctl-cut
	if [ -f /var/run/trafficctl/cut.state ] && [ -x /etc/init.d/trafficctl-cut ]; then
		/etc/init.d/trafficctl-cut restart 2>/dev/null || true
	fi
	# A luci-app-trafficctl up to 1.30.x depends on any trafficctl, so this
	# package can be upgraded on its own. That web interface has no ucode
	# plugin in /usr/share/rpcd/ucode, and its exec plugin sources
	# trafficctl-fw.sh, which 2.0.0 removed, so every page fails.
	if [ ! -e /usr/share/rpcd/ucode/luci.trafficctl.uc ] &&
	   grep -q 'trafficctl-fw.sh' /usr/libexec/rpcd/luci.trafficctl 2>/dev/null; then
		_m="The installed luci-app-trafficctl predates trafficctl 2.0.0 and does not work with it: upgrade luci-app-trafficctl too (opkg upgrade luci-app-trafficctl, or apk upgrade luci-app-trafficctl) unless this run already does"
		echo "$$_m"
		logger -t trafficctl "$$_m" 2>/dev/null || true
	fi
	# The Telegram options of releases up to 1.30.x move to the notification
	# senders (once: only while the 'notify' section is missing).
	if [ -x /usr/sbin/trafficctl ]; then
		/usr/sbin/trafficctl notify migrate >/dev/null 2>&1 || true
	fi
	# A bot of a release up to 1.30.x lost its files to trafficctl-telegram
	# with this upgrade. Without that package it would run on until the next
	# reboot (and scan for devices, which the watcher took over), and rc.d
	# would keep links to a missing init script.
	if [ ! -e /etc/init.d/trafficctl-telegram ]; then
		ubus call service delete '{"name":"trafficctl-telegram"}' >/dev/null 2>&1 || true
		rm -f /etc/rc.d/S99trafficctl-telegram /etc/rc.d/K10trafficctl-telegram
		# Headless (no luci-app-trafficctl to pull it in): say so where
		# the operator will look.
		if [ "$$(uci -q get trafficctl.telegram.enabled)" = "1" ]; then
			logger -t trafficctl "The Telegram bot is stopped: it is the package trafficctl-telegram now; install it (opkg install trafficctl-telegram, or apk add trafficctl-telegram) to run it again" 2>/dev/null || true
		fi
	fi
	# The watcher decides for itself whether anything wants the scan.
	if [ -x /etc/init.d/trafficctl-notify ]; then
		/etc/init.d/trafficctl-notify enable 2>/dev/null || true
		/etc/init.d/trafficctl-notify restart 2>/dev/null || true
	fi
	if [ -x /etc/init.d/trafficctl-history ]; then
		if [ "$$(uci -q get trafficctl.history.enabled)" = "1" ]; then
			/etc/init.d/trafficctl-history enable 2>/dev/null || true
		fi
		if /etc/init.d/trafficctl-history enabled; then
			/etc/init.d/trafficctl-history restart 2>/dev/null || true
		fi
	fi
	# Every saved block, limit, shape and port control goes back in force, as
	# the `ifup lan` hook does. Up to 1.30.x each shape added removed the u32
	# filters of the others, so only the last one was in force, and an upgrade
	# from there left the rest unshaped until the next reboot. TCTL_NOTIFY=0:
	# nothing new is applied, so no notification per device.
	if [ -x /usr/sbin/trafficctl ]; then
		TCTL_NOTIFY=0 /usr/sbin/trafficctl restore >/dev/null 2>&1 || true
	fi
	if [ -f /usr/share/rpcd/ucode/luci.trafficctl.uc ]; then
		/etc/init.d/rpcd reload 2>/dev/null || true
	fi
fi
exit 0
endef

# Fail open on removal. A global internet cut left engaged by a package that is
# going away is a lockout with no UI left to undo it: the drop rule would sit
# in nftables with nothing on the router admitting to owning it. The release
# needs ucode and every module to load, so its effect is then made sure of
# without them: no state for a keeper to re-assert from, and no table.
define Package/trafficctl/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	/usr/sbin/trafficctl cut release >/dev/null 2>&1 || true
	rm -f /var/run/trafficctl/cut.state /etc/trafficctl/cut.state
	nft delete table inet tctl_cut 2>/dev/null || true
fi
exit 0
endef

# Restarted, not started: a bot of a release up to 1.30.x runs the device
# scan itself, which the notification watcher took over. The flag rule is
# trafficctl's (above). trafficctl's postinst has run by now: the package
# manager configures a dependency first, so the Telegram options of 1.30.x
# have already moved to the notification senders.
define Package/trafficctl-telegram/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-telegram ] && [ "$$(uci -q get trafficctl.telegram.enabled)" = "1" ]; then
	/etc/init.d/trafficctl-telegram enable 2>/dev/null || true
	/etc/init.d/trafficctl-telegram restart 2>/dev/null || true
fi
exit 0
endef

define Package/trafficctl-telegram/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-telegram ]; then
	/etc/init.d/trafficctl-telegram stop 2>/dev/null || true
	/etc/init.d/trafficctl-telegram disable 2>/dev/null || true
fi
exit 0
endef

define Package/trafficctl-telegram/install
	$(INSTALL_DIR) $(1)/usr/share/ucode/trafficctl
	$(INSTALL_DATA) ./files/usr/share/ucode/trafficctl/telegram.uc $(1)/usr/share/ucode/trafficctl/
	$(INSTALL_DIR) $(1)/usr/libexec/trafficctl
	$(INSTALL_BIN) ./files/usr/libexec/trafficctl/trafficctl-telegram.uc $(1)/usr/libexec/trafficctl/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/trafficctl-telegram $(1)/etc/init.d/
endef

# Dependencies only: the code they enable ships in trafficctl, which checks
# for the tools at run time.
define Package/trafficctl-shaper/install
	true
endef

define Package/trafficctl-wifi/install
	true
endef

define Package/trafficctl-full/install
	true
endef

$(eval $(call BuildPackage,trafficctl))
$(eval $(call BuildPackage,trafficctl-shaper))
$(eval $(call BuildPackage,trafficctl-wifi))
$(eval $(call BuildPackage,trafficctl-telegram))
$(eval $(call BuildPackage,trafficctl-full))
